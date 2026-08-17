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
#   * The daemon is our own, on a free port, and is killed on the way out.
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

# A free port, so a second run (or the user's own daemon on 5572) cannot clash.
PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

# rclone-rc refuses to run without this file, and reads the address and
# credentials from it. Ours has no auth, and rclone rc sends the empty
# user/pass harmlessly.
cat > "$HOME/.config/rclone/rcd.env" <<EOF
RCLONE_RC_ADDR=127.0.0.1:$PORT
RCLONE_RC_USER=
RCLONE_RC_PASS=
EOF

rclone rcd --rc-addr "127.0.0.1:$PORT" --rc-no-auth \
  --log-file "$WORK/rcd.log" --log-level INFO >/dev/null 2>&1 &
DAEMON_PID=$!

rc() { rclone rc --url "http://127.0.0.1:$PORT/" "$@" 2>/dev/null; }

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
