#!/usr/bin/env python3
"""Status helper for the Omarchy rclone bar plugin.

Prints a single JSON object on stdout describing rclone's current state. It is
the ONLY thing in this plugin that touches rclone, so the QML side never has to
know how rclone is reached.

Two cost tiers, deliberately separated:

  fast (default)  local config read + `rclone rc` calls against the local rcd.
                  Cheap enough for a 2s poll while transfers are running.
  --probe         adds one `operations/about` network round-trip PER REMOTE.
                  Seconds, not milliseconds. Never call this on a timer.

Everything degrades instead of lying: no rclone binary, no daemon, or a daemon
that refuses auth each produce a well-formed object with the relevant flag
false and a human-readable `rcError`. A dead sensor must look dead, not idle.
"""

import json
import concurrent.futures
import os
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_ADDR = "127.0.0.1:5572"
ENV_FILE = Path.home() / ".config" / "rclone" / "rcd.env"

# Mounts to restore at login, as [{"fs": ..., "mountPoint": ...}].
#
# This deliberately does NOT live in the widget's shell.json entry. Omarchy's
# own writer, `omarchy bar set <id> <key> <value> --json`, forwards the value
# into an IPC call whose argument splitting breaks on commas — a two-element
# array fails outright ("4 required but 5 were provided") and a one-element
# array is silently stored unwrapped as a bare object. Structured settings
# cannot survive that path, so the plugin owns this file instead.
AUTOMOUNTS_FILE = Path.home() / ".config" / "rclone" / "omarchy-automounts.json"

# mountPoint -> the fs originally requested, written by rclone-rc at mount time.
# mount/listmounts reports a rewritten form ("gdrive{YRXYK}:") that rclone then
# REFUSES as input, so anything that needs to re-mount later must use this.
MOUNTFS_FILE = Path.home() / ".config" / "rclone" / "omarchy-mountfs.json"

# Mount points the user switched off by hand. On disk because the widget runs
# once per monitor and each instance keeps its own state.
SUPPRESSED_FILE = Path.home() / ".config" / "rclone" / "omarchy-suppressed.json"
TIMEOUT_FAST = 4
TIMEOUT_PROBE = 15

# rclone's config holds live OAuth tokens and passwords. Only these keys are
# ever copied into the payload that reaches the shell; everything else in a
# remote's config block is dropped on the floor.
SAFE_CONFIG_KEYS = ("type",)


def read_env_file(path):
    """Parse the KEY=value file shared with the rclone-rcd systemd unit."""
    values = {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        return {}
    return values


def config_mtime(path=None):
    """Modification time of rclone.conf, or 0 if it is not there yet.

    Honours RCLONE_CONFIG so a caller pointing rclone elsewhere is not silently
    watching the wrong file. Returned as an int: float seconds compare
    unequal across a JSON round-trip on some filesystems, which would clear the
    daemon cache on every single poll.
    """
    if path is None:
        env = os.environ.get("RCLONE_CONFIG")
        path = Path(env) if env else Path.home() / ".config" / "rclone" / "rclone.conf"
    try:
        return int(Path(path).stat().st_mtime)
    except OSError:
        return 0


def read_automounts(path=None):
    """Desired login mounts. A malformed file must not break the whole panel.

    `path` exists so the tests can point this at a fixture; production callers
    leave it out and get the real file.
    """
    path = AUTOMOUNTS_FILE if path is None else path
    try:
        with path.open("r", encoding="utf-8") as handle:
            parsed = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(parsed, list):
        return []
    rows = []
    for item in parsed:
        if isinstance(item, dict) and item.get("fs") and item.get("mountPoint"):
            rows.append({
                "fs": str(item["fs"]),
                "mountPoint": str(item["mountPoint"]),
            })
    return rows


def run(command, timeout):
    try:
        completed = subprocess.run(
            command, check=False, capture_output=True, text=True, timeout=timeout
        )
    except (OSError, subprocess.TimeoutExpired):
        return 1, "", "timed out"
    return completed.returncode, completed.stdout.strip(), completed.stderr.strip()


def tidy_error(text):
    """Turn rclone's timestamped multi-line noise into one short line.

    The panel has ~40 characters of room for this, and "connection refused"
    against our own port means exactly one thing worth telling the user.
    """
    line = str(text or "").strip().splitlines()[0] if str(text or "").strip() else ""
    # Strip a leading "2026/08/15 14:42:21 NOTICE: " style prefix.
    for marker in ("NOTICE: ", "ERROR: ", "Failed to rc: "):
        index = line.find(marker)
        if index >= 0:
            line = line[index + len(marker):]
    lowered = line.lower()
    if "connection refused" in lowered:
        return "rclone rcd is not running"
    if "401" in lowered or "unauthorized" in lowered:
        return "rcd rejected our credentials"
    return line[:200]


class Rclone:
    def __init__(self, binary, env):
        self.binary = binary
        addr = env.get("RCLONE_RC_ADDR", DEFAULT_ADDR)
        self.url = addr if addr.startswith("http") else "http://%s/" % addr
        self.user = env.get("RCLONE_RC_USER", "")
        self.password = env.get("RCLONE_RC_PASS", "")
        self.error = ""

    def rc(self, method, params=None, timeout=TIMEOUT_FAST):
        """Call one rc method. Returns the parsed object, or None on failure."""
        command = [self.binary, "rc", "--url", self.url]
        if self.user:
            command += ["--user", self.user, "--pass", self.password]
        command.append(method)
        for key, value in (params or {}).items():
            command.append("%s=%s" % (key, value))

        code, stdout, stderr = run(command, timeout)
        if code != 0:
            # Only the first failure is worth reporting; later calls fail for
            # the same reason and would just overwrite it with noise.
            if not self.error:
                self.error = tidy_error(stderr or stdout or "rc call failed")
            return None
        try:
            return json.loads(stdout) if stdout else {}
        except json.JSONDecodeError:
            if not self.error:
                self.error = "could not parse rc response for %s" % method
            return None

    def rc_detailed(self, method, params=None, timeout=TIMEOUT_FAST):
        """Like rc(), but returns (payload, error) WITHOUT touching self.error.

        Probes run concurrently, so recording the failure on the shared client
        would attribute one remote's error to whichever call happened to be
        first — and the whole point here is to say which remote is broken.
        """
        command = [self.binary, "rc", "--url", self.url]
        if self.user:
            command += ["--user", self.user, "--pass", self.password]
        command.append(method)
        for key, value in (params or {}).items():
            command.append("%s=%s" % (key, value))
        code, stdout, stderr = run(command, timeout)
        if code != 0:
            return None, (stderr or stdout or "call failed")
        try:
            return (json.loads(stdout) if stdout else {}), ""
        except json.JSONDecodeError:
            return None, "could not parse response"

    def config_dump(self):
        """Remote name + type, read straight from the config file (no daemon)."""
        code, stdout, _ = run([self.binary, "config", "dump"], TIMEOUT_FAST)
        if code != 0 or not stdout:
            return []
        try:
            parsed = json.loads(stdout)
        except json.JSONDecodeError:
            return []
        remotes = []
        for name in sorted(parsed):
            block = parsed[name] if isinstance(parsed[name], dict) else {}
            remote = {"name": name}
            for key in SAFE_CONFIG_KEYS:
                remote[key] = str(block.get(key, ""))
            # A section with no `type` is a HALF-MADE remote: `rclone config
            # create` writes the section before the flow that fills it in, so a
            # crash, a shell restart, or a killed terminal mid-setup leaves this
            # behind. It cannot be mounted, probed or repaired — only removed.
            #
            # Worth surfacing loudly because `rclone listremotes` does NOT list
            # a typeless section, so the usual way of checking gives a false
            # all-clear and the orphan is invisible outside the config file.
            remote["incomplete"] = remote.get("type", "") == ""
            remotes.append(remote)
        return remotes


def transferring_rows(stats):
    rows = []
    for item in stats.get("transferring") or []:
        if not isinstance(item, dict):
            continue
        rows.append({
            "name": str(item.get("name", "")),
            "bytes": int(item.get("bytes") or 0),
            "size": int(item.get("size") or 0),
            "percentage": int(item.get("percentage") or 0),
            "speed": float(item.get("speed") or 0),
            "eta": item.get("eta"),
            "group": str(item.get("group", "")),
        })
    return rows


def transferred_rows(payload, limit):
    """Recently TRANSFERRED files, newest first.

    Filtered to `what == "transferring"`. rclone also reports checks and bisync
    listings through this endpoint — measured: 14 of 77 entries were
    "checking"/"listing file - Path1", which are not transfers and were being
    shown in the panel as if they were. Those entries are also exactly the ones
    with no srcFs, so filtering them is what makes the source remote reliably
    derivable for every row that survives.
    """
    rows = []
    for item in reversed(payload.get("transferred") or []):
        if not isinstance(item, dict):
            continue
        if str(item.get("what") or "") != "transferring":
            continue
        rows.append({
            "name": str(item.get("name", "")),
            "size": int(item.get("size") or 0),
            "bytes": int(item.get("bytes") or 0),
            "error": str(item.get("error", "")),
            "checked": item.get("checked") is True,
            "completedAt": str(item.get("completed_at", "")),
            "what": str(item.get("what", "")),
            "srcFs": str(item.get("srcFs", "")),
            "dstFs": str(item.get("dstFs", "")),
        })
        if len(rows) >= limit:
            break
    return rows


def pending_uploads(client, mounts):
    """Per-mount count and size of writes not yet flushed to the provider.

    This is the only thing that makes unmounting genuinely dangerous: with
    `--vfs-cache-mode full` a write lands in the local cache first, and a forced
    unmount can drop it before it reaches the remote. Measured shape of a
    populated queue:
        {"queue":[{"id":1,"name":"big.bin","size":3000000,"uploading":false,...}]}
    An idle mount answers {} — so the warning appears only when there is
    something to lose, rather than sitting there permanently and being ignored.

    One local rc call per mount; no network.
    """
    for mount in mounts:
        mount["pendingCount"] = 0
        mount["pendingBytes"] = 0
        payload = client.rc("vfs/queue", {"fs": mount["fs"]})
        if not payload:
            continue
        queued = payload.get("queue") or []
        if not isinstance(queued, list):
            continue
        mount["pendingCount"] = len(queued)
        mount["pendingBytes"] = sum(int(q.get("size") or 0)
                                    for q in queued if isinstance(q, dict))
    return mounts


def read_suppressed(path=None):
    """Mount points switched off by hand; auto-mount must leave them alone."""
    path = SUPPRESSED_FILE if path is None else path
    try:
        with path.open("r", encoding="utf-8") as handle:
            rows = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return []
    return [str(r) for r in rows] if isinstance(rows, list) else []


def read_mount_fs():
    try:
        with MOUNTFS_FILE.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def mount_rows(payload, requested=None):
    """Live mounts.

    `requestedFs` is what must be used to mount this again — see MOUNTFS_FILE.
    It falls back to the reported fs so a mount made outside this plugin still
    produces a usable row, even though that value may not be re-mountable.
    """
    requested = requested or {}
    rows = []
    for item in payload.get("mountPoints") or []:
        if not isinstance(item, dict):
            continue
        point = str(item.get("MountPoint", ""))
        reported = str(item.get("Fs", ""))
        rows.append({
            "fs": reported,
            "requestedFs": str(requested.get(point) or reported),
            "pendingCount": 0,
            "pendingBytes": 0,
            "mountPoint": point,
            "mountedOn": str(item.get("MountedOn", "")),
        })
    return rows


def job_rows(client, running_ids):
    """Per-job progress for running sync/copy jobs.

    Deliberately reads core/stats PER GROUP rather than the daemon-wide
    counters: `core/stats` with no group is cumulative for the whole rcd
    lifetime, so a progress bar built on it drifts further from the truth the
    longer the daemon runs. rclone-rc labels each job with
    `_group="<verb> <src> -> <dst>"`, which doubles as the row's title.

    Costs 2 rc calls per running job, so it is skipped entirely when nothing
    is running — which is the normal case.
    """
    rows = []
    for job_id in running_ids:
        status_payload = client.rc("job/status", {"jobid": job_id})
        if status_payload is None:
            continue
        group = str(status_payload.get("group", ""))
        if not group.startswith(("copy ", "mirror ", "bisync ")):
            continue  # not one of ours; rc calls themselves are jobs too
        stats = client.rc("core/stats", {"group": group}) or {}
        rows.append({
            "id": job_id,
            "group": group,
            "label": group,
            "bytes": int(stats.get("bytes") or 0),
            "totalBytes": int(stats.get("totalBytes") or 0),
            "speed": float(stats.get("speed") or 0),
            "eta": stats.get("eta"),
            "errors": int(stats.get("errors") or 0),
            "transfers": int(stats.get("transfers") or 0),
            "totalTransfers": int(stats.get("totalTransfers") or 0),
            "error": str(status_payload.get("error", "")),
            "finished": status_payload.get("finished") is True,
        })
    return rows


# An expired or revoked OAuth grant needs re-authentication; a flat network
# failure needs nothing but patience. Flattening both to "unreachable" told the
# user neither, so the two are separated here and the panel offers a Reconnect
# only for the first.
AUTH_MARKERS = (
    "invalid_grant", "token expired", "refresh token", "oauth",
    "unauthenticated", "401", "invalid credentials", "could not refresh",
    "authentication", "unauthorized",
)
NETWORK_MARKERS = (
    "no such host", "connection refused", "network is unreachable",
    "timeout", "timed out", "temporary failure", "dial tcp", "eof",
)


def classify_remote_error(text):
    """'auth' | 'network' | 'other' for a failed remote probe."""
    lowered = str(text or "").lower()
    # Auth first: an expired grant often also mentions a URL or a transport.
    for marker in AUTH_MARKERS:
        if marker in lowered:
            return "auth"
    for marker in NETWORK_MARKERS:
        if marker in lowered:
            return "network"
    return "other"


def probe_one(client, name):
    """One remote's quota. Network-bound, so callers run these concurrently."""
    about, error = client.rc_detailed(
        "operations/about", {"fs": "%s:" % name}, timeout=TIMEOUT_PROBE)
    if about is None:
        kind = classify_remote_error(error)
        return name, {
            "online": False,
            "errorKind": kind,
            "error": tidy_error(error) or "unreachable",
        }
    return name, {
        "errorKind": "",
        "online": True,
        "error": "",
        "usedBytes": int(about.get("used") or 0),
        "freeBytes": int(about.get("free") or 0),
        "totalBytes": int(about.get("total") or 0),
        "quotaKnown": bool(about.get("total")),
    }


def probe_remotes(client, remotes):
    """Quota for every remote, probed CONCURRENTLY.

    Each probe is a network round-trip to a different provider, so serialising
    them made the check button cost the SUM of every remote's latency — with a
    15s timeout each, a handful of slow or unreachable remotes could stall it
    for a minute. Run in parallel and it costs the slowest one instead.

    Bounded so a user with many remotes cannot fork a request storm at their
    providers; the cap is well above any realistic remote count.
    """
    names = [r["name"] for r in remotes]
    if not names:
        return {}
    workers = min(8, len(names))
    probes = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for name, result in pool.map(lambda n: probe_one(client, n), names):
            probes[name] = result
    return probes


def provider_fields(payload, backend):
    """The fields a form needs to create `backend`, from config/providers.

    rclone describes all 69 backends this way, so the panel renders a form it
    was never taught — the alternative is hand-writing a form per backend and
    watching them drift as rclone changes.

    ADVANCED options are dropped. They are the long tail (s3 alone has 78
    options, 14 of them basic) and including them would turn a bar popup into a
    settings dialog. Anyone who needs them has `rclone config` in a terminal.

    `Required` is rclone's own flag and is NOT always trustworthy as "the user
    must fill this in": s3 marks nothing required because what is needed depends
    on which provider you pick. So the caller decides how many fields to show up
    front; this reports the flag as-is rather than second-guessing it.
    """
    for provider in payload.get("providers") or []:
        if str(provider.get("Name", "")) != backend:
            continue
        fields = []
        for option in provider.get("Options") or []:
            if option.get("Advanced"):
                continue
            examples = []
            for example in option.get("Examples") or []:
                examples.append({
                    "value": str(example.get("Value", "")),
                    "help": str(example.get("Help", "")).strip().split("\n")[0],
                })
            default = option.get("Default")
            fields.append({
                "name": str(option.get("Name", "")),
                # Only the first line: rclone's help runs to paragraphs, and the
                # panel has one caption's worth of room.
                "help": str(option.get("Help", "")).strip().split("\n")[0],
                "required": option.get("Required") is True,
                "password": option.get("IsPassword") is True,
                "default": "" if default in (None, False) else str(default),
                "boolean": isinstance(default, bool),
                "examples": examples,
            })
        return {"ok": True, "type": backend, "fields": fields}
    return {"ok": False, "type": backend, "fields": [], "error": "unknown backend " + backend}


def provider_schema_mode(argv):
    """`status.py --provider-schema <type>` -> the form description, as JSON."""
    try:
        backend = argv[argv.index("--provider-schema") + 1]
    except (ValueError, IndexError):
        print(json.dumps({"ok": False, "fields": [], "error": "no backend named"}))
        return
    binary = shutil.which("rclone")
    if binary is None:
        print(json.dumps({"ok": False, "fields": [], "error": "rclone is not installed"}))
        return
    client = Rclone(binary, read_env_file(ENV_FILE) if ENV_FILE.exists() else {})
    payload = client.rc("config/providers", timeout=TIMEOUT_PROBE)
    if payload is None:
        print(json.dumps({"ok": False, "fields": [],
                          "error": client.error or "could not read the backend list"}))
        return
    print(json.dumps(provider_fields(payload, backend)))


def pending_mode(argv):
    """`status.py --pending <mountpoint>` -> prints the queued-upload count.

    Exists so the shell helper does not re-implement the lookup: the bash
    version silently returned 0 (its errors were swallowed by a `|| echo 0`
    fallback) and the guard never fired. One implementation, already covered by
    the normal payload path.
    """
    try:
        target = argv[argv.index("--pending") + 1]
    except (ValueError, IndexError):
        print(0)
        return
    binary = shutil.which("rclone")
    if binary is None:
        print(0)
        return
    client = Rclone(binary, read_env_file(ENV_FILE) if ENV_FILE.exists() else {})
    mounts = client.rc("mount/listmounts")
    if mounts is None:
        print(0)
        return
    rows = pending_uploads(client, mount_rows(mounts, read_mount_fs()))
    for row in rows:
        if row["mountPoint"] == target:
            print(row["pendingCount"])
            return
    print(0)


def main():
    if "--pending" in sys.argv:
        pending_mode(sys.argv)
        return
    if "--provider-schema" in sys.argv:
        provider_schema_mode(sys.argv)
        return
    probe = "--probe" in sys.argv
    limit = 25
    for arg in sys.argv[1:]:
        if arg.isdigit():
            limit = max(1, min(100, int(arg)))

    binary = shutil.which("rclone")
    # "Not installed" and "installed but down" need different offers in the UI —
    # one is a first-run bootstrap, the other is a restart button.
    daemon_unit = Path.home() / ".config" / "systemd" / "user" / "rclone-rcd.service"

    payload = {
        "ok": True,
        "installed": binary is not None,
        "daemonInstalled": daemon_unit.exists(),
        "version": "",
        "rcRunning": False,
        "rcUrl": "",
        "rcError": "",
        "remotes": [],
        "mounts": [],
        "autoMounts": read_automounts(),
        "suppressed": read_suppressed(),
        "stats": {},
        "transferring": [],
        "transferred": [],
        "runningJobs": 0,
        "jobs": [],
        "bwLimit": "off",
        "probes": {},
        "probed": probe,
        # Lets the panel notice a remote that was created or repaired OUTSIDE
        # it — `rclone config reconnect` runs in its own terminal, so there is
        # no completion to hook. The daemon caches a built filesystem per
        # remote, so without this a freshly repaired remote keeps answering
        # from its old config and reads as broken forever.
        "configMtime": config_mtime(),
    }

    if binary is None:
        payload["rcError"] = "rclone is not installed"
        print(json.dumps(payload))
        return

    code, stdout, _ = run([binary, "version"], TIMEOUT_FAST)
    if code == 0 and stdout:
        payload["version"] = stdout.splitlines()[0].replace("rclone ", "").strip()

    client = Rclone(binary, read_env_file(ENV_FILE) if ENV_FILE.exists() else {})
    payload["rcUrl"] = client.url
    payload["remotes"] = client.config_dump()

    stats = client.rc("core/stats")
    if stats is None:
        payload["rcError"] = client.error or "rclone rcd is not reachable"
        print(json.dumps(payload))
        return

    payload["rcRunning"] = True
    payload["stats"] = {
        "bytes": int(stats.get("bytes") or 0),
        "totalBytes": int(stats.get("totalBytes") or 0),
        "speed": float(stats.get("speed") or 0),
        "eta": stats.get("eta"),
        "errors": int(stats.get("errors") or 0),
        "checks": int(stats.get("checks") or 0),
        "transfers": int(stats.get("transfers") or 0),
        "elapsedTime": float(stats.get("elapsedTime") or 0),
        "fatalError": stats.get("fatalError") is True,
        "lastError": str(stats.get("lastError", "")),
    }
    payload["transferring"] = transferring_rows(stats)

    transferred = client.rc("core/transferred")
    if transferred is not None:
        payload["transferred"] = transferred_rows(transferred, limit)

    # Daemon-wide bandwidth cap. "off" or an rclone rate string like "5Mi".
    bw = client.rc("core/bwlimit")
    if bw is not None:
        payload["bwLimit"] = str(bw.get("rate", "off"))

    mounts = client.rc("mount/listmounts")
    if mounts is not None:
        payload["mounts"] = pending_uploads(client, mount_rows(mounts, read_mount_fs()))

    # GOTCHA: every rc call is itself a job, so `jobids` accumulates one entry
    # per poll forever and `runningIds` always contains the job/list call we are
    # making right now. Verified on an idle daemon: 4 finished ids and
    # runningIds=[5] with nothing whatsoever happening. Count only OTHER running
    # jobs, and never use this as the activity signal — stats.transferring is
    # the honest one.
    jobs = client.rc("job/list")
    if jobs is not None:
        running = [int(j) for j in (jobs.get("runningIds") or []) if str(j).isdigit()]
        payload["runningJobs"] = max(0, len(running) - 1)
        # Only pay for per-job stats when something is actually running. The
        # `- 1` above is our own in-flight job/list call; job_rows filters by
        # group prefix, so rc-call jobs drop out there too.
        if payload["runningJobs"] > 0:
            payload["jobs"] = job_rows(client, running)

    if probe:
        payload["probes"] = probe_remotes(client, payload["remotes"])

    # A late failure on a secondary call still leaves rcRunning true — the
    # daemon answered core/stats, so it is up; surface the detail separately.
    payload["rcError"] = client.error
    print(json.dumps(payload))


if __name__ == "__main__":
    main()
