#!/usr/bin/env bash
# End-to-end tests for the ADD -> MOUNT -> REMOVE lifecycle, against a real
# rclone and a real `rclone rcd`.
#
#   test/remote-lifecycle-test.sh
#
# Why this exists: the zombie-remote bug of 2026-08-17 lived entirely in the
# seams between rclone, the daemon and our own bookkeeping, so every part of it
# was invisible to a unit test. Removing a remote deleted its config section,
# the daemon then wrote a refreshed OAuth token back into the section it had just
# lost, rclone re-created the section holding a token and no `type`, and the
# panel rendered that as a half-finished remote whose trash button could never
# win. Nothing about that is reproducible from dicts.
#
# ISOLATION — this test must never touch the user's own rclone setup:
#   * HOME is redirected, so rcd.env, omarchy-automounts.json and
#     omarchy-suppressed.json are all temporary.
#   * RCLONE_CONFIG points at a temporary config file, so `rclone config
#     delete` (which rclone-rc calls without a --config flag) cannot reach the
#     real one.
#   * The daemon is our own, on a unix socket inside the work dir, and is killed
#     on the way out.
# The backend is `local`, so nothing here needs an account or a network.
#
# Skips (exit 0) when rclone or fusermount3 is missing, so `check` stays
# runnable anywhere.
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

eq() { # eq <actual> <expected> <label>
  checks=$((checks + 1))
  if [ "$1" != "$2" ]; then
    fails=$((fails + 1))
    printf '  FAIL %s\n       expected %s\n       got      %s\n' "$3" "$2" "$1"
  fi
}

command -v rclone >/dev/null 2>&1 || { echo "  (skipped: no rclone)"; exit 0; }
command -v fusermount3 >/dev/null 2>&1 || { echo "  (skipped: no fusermount3)"; exit 0; }

WORK="$(mktemp -d)"
DAEMON_PID=""

cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  for mp in "$WORK/mnt" "$WORK/mnt2"; do
    mountpoint -q "$mp" 2>/dev/null && fusermount3 -u "$mp" 2>/dev/null
  done
  # Never `rm -rf` a path that could still be a live FUSE mount.
  sleep 0.2
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

export HOME="$WORK/home"
export RCLONE_CONFIG="$WORK/rclone.conf"
mkdir -p "$HOME/.config/rclone" "$WORK/data" "$WORK/mnt" "$WORK/mnt2"
: > "$RCLONE_CONFIG"
echo "hello" > "$WORK/data/file.txt"

# A unix socket in the work directory, which is what the plugin uses in
# production — no port to clash with the user's own daemon, and nothing another
# user could connect to. The TCP form still works and is covered by the
# address_of unit tests.
SOCK="$WORK/rcd.sock"

# rclone-rc refuses to run without this file, and reads the address and
# credentials from it. Ours has no auth, and rclone rc sends the empty
# user/pass harmlessly.
cat > "$HOME/.config/rclone/rcd.env" <<EOF
RCLONE_RC_ADDR=unix://$SOCK
RCLONE_RC_USER=
RCLONE_RC_PASS=
EOF

rclone rcd --rc-addr "unix://$SOCK" --rc-no-auth \
  --log-file "$WORK/rcd.log" --log-level INFO >/dev/null 2>&1 &
DAEMON_PID=$!

rc() { rclone rc --unix-socket "$SOCK" "$@" 2>/dev/null; }

up=no
for _ in $(seq 1 20); do
  if rc rc/noop >/dev/null 2>&1; then up=yes; break; fi
  sleep 0.5
done
if [ "$up" != "yes" ]; then
  echo "  (skipped: test daemon never came up — see $WORK/rcd.log)"
  exit 0
fi

# What status.py makes of the config file as it stands. Prints two lines:
# the remote names, then the residue names.
classify() {
  python3 - <<'PY'
import json, os, subprocess, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["PLUGIN_DIR"])
import status
dump = subprocess.run(["rclone", "config", "dump"], capture_output=True, text=True).stdout
remotes, residue = status.classify_config(json.loads(dump or "{}"))
print(",".join(r["name"] for r in remotes))
print(",".join(residue))
PY
}
export PLUGIN_DIR

sections() { grep -o '^\[[^]]*\]' "$RCLONE_CONFIG" 2>/dev/null | tr -d '[]' | sort | paste -sd, -; }
vfses() { rc vfs/list | python3 -c 'import json,sys
try: print(",".join(json.load(sys.stdin).get("vfses") or []))
except Exception: print("")'; }

echo
echo "  -- add a remote"
rclone config create disk local >/dev/null 2>&1
eq "$(sections)" "disk" "the new remote is in the config file"
eq "$(classify | sed -n 1p)" "disk" "the new remote is reported as a remote"
eq "$(classify | sed -n 2p)" "" "a fresh remote leaves no residue"

echo "  -- mount it"
"$PLUGIN_DIR/rclone-rc" mount "disk:$WORK/data" "$WORK/mnt" >/dev/null 2>&1
sleep 1
eq "$(mountpoint -q "$WORK/mnt" && echo mounted || echo no)" "mounted" "the remote mounts"
eq "$(cat "$WORK/mnt/file.txt" 2>/dev/null)" "hello" "the mount serves its files"
eq "$(vfses)" "disk:$WORK/data" "the daemon holds one filesystem for it"

echo "  -- delete it"
out="$("$PLUGIN_DIR/rclone-rc" remove-remote disk 2>&1)"
eq "$(echo "$out" | tail -1)" '{"ok":true,"removed":"disk"}' "remove-remote reports success"
eq "$(mountpoint -q "$WORK/mnt" && echo mounted || echo no)" "no" "removal unmounts first"
eq "$(sections)" "" "the config section is gone"
eq "$(classify | sed -n 1p)" "" "nothing is left to show as a remote"
# THE ROOT-CAUSE ASSERTION. rclone's own mount/unmount disposes the VFS;
# `fusermount3 -u` does not, and an undisposed VFS is what resurrects a deleted
# section. If this ever fails, removal has gone back to forcing the unmount and
# the zombie bug is live again.
eq "$(vfses)" "" "the daemon holds no orphaned filesystem afterwards"

echo "  -- a forced unmount is what orphans a filesystem (the cause)"
rclone config create disk2 local >/dev/null 2>&1
"$PLUGIN_DIR/rclone-rc" mount "disk2:$WORK/data" "$WORK/mnt2" >/dev/null 2>&1
sleep 1
fusermount3 -u "$WORK/mnt2" 2>/dev/null
sleep 0.5
eq "$(mountpoint -q "$WORK/mnt2" && echo mounted || echo no)" "no" "the kernel mount is gone"
eq "$(vfses)" "disk2:$WORK/data" "but the daemon still holds the filesystem"
eq "$(rc mount/listmounts | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("mountPoints") or []))')" \
   "0" "and mount/listmounts can no longer see it, so nothing can unmount it by name"

echo "  -- the write-back that follows, and the zombie it used to make"
# Exactly what an orphaned VFS does when its OAuth token is refreshed: rclone
# writes the token into a section that no longer exists, so the section comes
# back holding a token and nothing else. Written by hand because reaching it for
# real needs an expiring OAuth token and an hour of waiting.
rclone config delete disk2 >/dev/null 2>&1
printf '\n[disk2]\ntoken = {"access_token":"x","expiry":"2026-08-17T11:26:38+02:00"}\n' \
  >> "$RCLONE_CONFIG"
eq "$(sections)" "disk2" "the section is back in the file"
eq "$(rclone listremotes 2>/dev/null | tr -d ':' | paste -sd, -)" "" \
   "rclone itself does not count it as a remote"
eq "$(classify | sed -n 1p)" "" "and neither do we — this is the bug that showed a zombie row"
eq "$(classify | sed -n 2p)" "disk2" "it is reported as residue instead"

echo "  -- reap it"
eq "$("$PLUGIN_DIR/rclone-rc" reap-residue 2>&1 | tail -1)" '{"ok": true, "reaped": 1, "names": ["disk2"]}' \
   "reap-residue reports what it removed"
eq "$(sections)" "" "the residue is gone from the config file"
eq "$("$PLUGIN_DIR/rclone-rc" reap-residue 2>&1 | tail -1)" '{"ok": true, "reaped": 0, "names": []}' \
   "reaping again is a no-op"

echo "  -- credentials never reach argv"
# THE REGRESSION TEST for the marketplace review finding. Setting up a remote
# used to run `rclone config create … pass=<secret>`, and /proc/<pid>/cmdline is
# readable by every local process, so any of them could poll the password out of
# the process list while setup ran. Values now travel on stdin and reach the
# daemon in an HTTP body.
#
# The marker is passed through the ENVIRONMENT into both the watcher and the
# request builder, so it never appears in this test's own argv either — otherwise
# the harness would trip its own alarm and the test would be worthless.
cat > "$WORK/watch.py" <<'PY'
import glob, os, time
needle, me = os.environ["NEEDLE"], str(os.getpid())
hits, end = set(), time.time() + 8
while time.time() < end:
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        pid = path.split("/")[2]
        if pid == me:
            continue
        try:
            argv = open(path, "rb").read().decode("utf-8", "ignore")
        except OSError:
            continue
        if needle in argv:
            hits.add(pid)
    time.sleep(0.01)
print(len(hits))
PY
NEEDLE=lifecycle-marker-pw python3 "$WORK/watch.py" > "$WORK/leak.txt" &
watcher=$!
sleep 0.5
MARKER=lifecycle-marker-pw python3 -c 'import json, os, sys
sys.stdout.write(json.dumps({"parameters": {"host": "h.example", "user": "bob",
                                            "pass": os.environ["MARKER"]}}))' \
  | "$PLUGIN_DIR/rclone-config" start argvtest sftp >/dev/null 2>&1
wait "$watcher"
eq "$(cat "$WORK/leak.txt")" "0" "no process holds a config value in its argv"
eq "$(rclone config dump | python3 -c 'import json,sys;print(json.load(sys.stdin)["argvtest"]["pass"] != "lifecycle-marker-pw")')" \
   "True" "and it is obscured on disk, not stored as typed"
rclone config delete argvtest >/dev/null 2>&1

echo "  -- a failed setup does not block retrying the same name"
# A `config/create` that FAILS leaves the half-built remote in the daemon's
# in-memory config while writing nothing to disk — measured: the daemon's
# config/dump lists it, the file and `rclone config dump` are empty. The
# existence guard therefore has to read the FILE. Reading the daemon instead
# answered "already exists — use resume" for a remote that does not exist,
# leaving the user no way to retry a setup that failed.
echo '{"parameters":{}}' | "$PLUGIN_DIR/rclone-config" start retryme no-such-backend >/dev/null 2>&1
eq "$(rc config/dump | python3 -c 'import json,sys;print("retryme" in json.load(sys.stdin))')" \
   "True" "the failed create leaves a phantom in the daemon"
eq "$(sections)" "" "and nothing on disk"
retry="$(printf '{"parameters":{"host":"h","user":"u"}}' | "$PLUGIN_DIR/rclone-config" start retryme sftp)"
eq "$(printf '%s' "$retry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" \
   "True" "so the same name can still be used"
eq "$(printf '%s' "$retry" | python3 -c 'import json,sys;print("already exists" in (json.load(sys.stdin).get("error") or ""))')" \
   "False" "and it is not refused as already existing"
# Now it IS on disk, so a second attempt must be refused — create would discard
# the remote it already made.
eq "$(printf '{"parameters":{}}' | "$PLUGIN_DIR/rclone-config" start retryme sftp \
      | python3 -c 'import json,sys;print("already exists" in (json.load(sys.stdin).get("error") or ""))')" \
   "True" "a remote that really exists is still protected"
rclone config delete retryme >/dev/null 2>&1

echo "  -- setup never overwrites an existing remote"
# `config create` REPLACES a remote of the same name, discarding its token
# without asking. The Drive wizard pre-fills a name, so connecting a second
# account of the same provider is exactly when this bites. Both entry points
# must refuse, because both reach config/create.
rclone config create precious local >/dev/null 2>&1
for verb in start connect; do
  refused="$(printf '{"parameters":{}}' | "$PLUGIN_DIR/rclone-config" $verb precious local \
    | python3 -c 'import json,sys;print("already exists" in (json.load(sys.stdin).get("error") or ""))')"
  eq "$refused" "True" "$verb refuses a name that is already taken"
done
eq "$(rclone config dump | python3 -c 'import json,sys;print(json.load(sys.stdin)["precious"]["type"])')" \
   "local" "and the existing remote is untouched"
rclone config delete precious >/dev/null 2>&1

echo "  -- only the plugin's own jobs are reported"
# The writer (rclone-rc) and the reader (status.py job_rows) have to agree on the
# group prefix, in two languages. status-test.py asserts the literals match; this
# asserts the round trip through a real daemon, which is the part a typo survives.
mkdir -p "$WORK/dest"
copy_out="$("$PLUGIN_DIR/rclone-rc" copy "disk:$WORK/data" "$WORK/dest" 2>&1)"
jobid="$(printf '%s' "$copy_out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("jobid", ""))
except Exception: print("")')"
eq "$([ -n "$jobid" ] && echo yes || echo no)" "yes" "the copy returns a jobid"
eq "$(rc job/status jobid="$jobid" | python3 -c 'import json,sys
print(json.load(sys.stdin).get("group","").startswith("omarchy-rclone/"))')"    "True" "the daemon records the job under our namespace"

# What the panel would show for it. A foreign job — every rc call is one, grouped
# `job/<n>` — must not appear here.
rows="$(PLUGIN_DIR="$PLUGIN_DIR" JOBID="$jobid" python3 - <<'PY2'
import json, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["PLUGIN_DIR"])
import status, rcclient
env = rcclient.read_env()
client = status.Rclone("rclone", env)
ids = (client.rc("job/list") or {}).get("jobids") or []
rows = status.job_rows(client, ids)
print(json.dumps([{"label": r["label"], "group": r["group"]} for r in rows]))
PY2
)"
eq "$(printf '%s' "$rows" | python3 -c 'import json,sys
rows=json.load(sys.stdin)
print(all(not r["label"].startswith("omarchy-rclone/") for r in rows))')"    "True" "the label has the namespace stripped, so the panel never shows it"
eq "$(printf '%s' "$rows" | python3 -c 'import json,sys
rows=json.load(sys.stdin)
print(all(r["group"].startswith("omarchy-rclone/") for r in rows))')"    "True" "and every reported job is one of ours — no rc-call jobs leak in"
"$PLUGIN_DIR/rclone-rc" stop-all >/dev/null 2>&1

echo "  -- reaping never touches a real remote"
rclone config create keeper local >/dev/null 2>&1
printf '\n[ghost]\ntoken = {"access_token":"y"}\n' >> "$RCLONE_CONFIG"
"$PLUGIN_DIR/rclone-rc" reap-residue >/dev/null 2>&1
eq "$(sections)" "keeper" "the typed remote survives and only the ghost goes"
eq "$(rclone config dump | python3 -c 'import json,sys;print(json.load(sys.stdin)["keeper"]["type"])')" \
   "local" "and it is intact, not just present"

echo
if [ "$fails" -eq 0 ]; then
  echo "  $checks checks passed"
else
  echo "  $fails of $checks checks failed"
fi
exit "$fails"
