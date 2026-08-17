#!/usr/bin/env python3
"""Tests for status.py's pure functions. Run with:  python3 test/status-test.py

status.py is the only thing that talks to rclone, so everything the panel
displays passes through these functions. They take dicts and return dicts —
no subprocess, no network — so there is no excuse for them being untested.

Not covered here (they shell out): run(), probe_remotes(), main(), Rclone.rc().
Those are exercised by actually running `python3 status.py`.
"""

import os
import sys
import tempfile
from pathlib import Path

# MUST come before importing status: the plugin directory is watched by the
# shell, and a __pycache__ written there triggers a plugin reload, which knocks
# the widget's IpcHandler out of registration (see README gotchas 9 and 10).
# Running the tests must not disturb the running widget.
sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import status  # noqa: E402

failures = 0
checks = 0


def eq(actual, expected, label):
    global failures, checks
    checks += 1
    if actual != expected:
        failures += 1
        print("  FAIL %s\n       expected %r\n       got      %r" % (label, expected, actual))


def with_temp_file(content):
    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    handle.write(content)
    handle.close()
    return Path(handle.name)


# ---- tidy_error ------------------------------------------------------------
# rclone prefixes errors with a timestamp and level; the panel has ~40 columns.
# The two recognised cases each mean exactly one thing worth telling the user.
eq(status.tidy_error(
    '2026/08/15 14:42:21 NOTICE: Failed to rc: connection failed: Post '
    '"http://127.0.0.1:5572/core/stats": dial tcp 127.0.0.1:5572: connect: connection refused'),
   "rclone rcd is not running", "connection refused becomes a plain sentence")
eq(status.tidy_error("2026/08/15 10:00:00 ERROR: 401 Unauthorized"),
   "rcd rejected our credentials", "401 becomes a plain sentence")
eq(status.tidy_error("Failed to rc: something odd"), "something odd",
   "known prefixes are stripped")
eq(status.tidy_error(""), "", "empty stays empty")
eq(status.tidy_error(None), "", "None does not explode")
eq(status.tidy_error("first line\nsecond line"), "first line", "only the first line")
eq(len(status.tidy_error("x" * 500)), 200, "long errors are capped at 200")

# ---- read_env_file ---------------------------------------------------------
# Shared with the systemd unit, so it must tolerate comments, blanks and quotes.
env_path = with_temp_file(
    "# a comment\n"
    "\n"
    "RCLONE_RC_ADDR=127.0.0.1:5572\n"
    'RCLONE_RC_USER="omarchy"\n'
    "RCLONE_RC_PASS='se cret'\n"
    "MALFORMED_LINE\n"
    "  SPACED  =  value  \n"
)
env = status.read_env_file(env_path)
eq(env.get("RCLONE_RC_ADDR"), "127.0.0.1:5572", "plain value")
eq(env.get("RCLONE_RC_USER"), "omarchy", "double quotes stripped")
eq(env.get("RCLONE_RC_PASS"), "se cret", "single quotes stripped, inner space kept")
eq("MALFORMED_LINE" in env, False, "a line with no '=' is skipped")
eq(env.get("SPACED"), "value", "keys and values are trimmed")
eq(status.read_env_file(Path("/nonexistent/nope.env")), {}, "missing file yields {}")
os.unlink(env_path)

# ---- read_automounts -------------------------------------------------------
# A malformed file here would otherwise silently drop every login mount.
good = with_temp_file('[{"fs": "gdrive:", "mountPoint": "/home/u/GDrive"}]')
eq(status.read_automounts(good),
   [{"fs": "gdrive:", "mountPoint": "/home/u/GDrive"}], "well-formed entry")
os.unlink(good)

partial = with_temp_file('[{"fs": "gdrive:"}, {"mountPoint": "/x"}, {"fs": "b:", "mountPoint": "/y"}]')
eq(status.read_automounts(partial), [{"fs": "b:", "mountPoint": "/y"}],
   "entries missing fs or mountPoint are dropped, the good one survives")
os.unlink(partial)

for content, label in (
    ("not json at all", "unparseable file yields []"),
    ('{"fs": "x:"}', "a dict where a list belongs yields []"),
    ("[]", "empty list yields []"),
    ('["a string", 42, null_placeholder]'.replace("null_placeholder", "null"),
     "non-dict members are ignored"),
):
    p = with_temp_file(content)
    eq(status.read_automounts(p), [], label)
    os.unlink(p)

eq(status.read_automounts(Path("/nonexistent/nope.json")), [], "missing file yields []")

# ---- transferring_rows -----------------------------------------------------
# This drives the progress bars, so field-by-field coercion matters.
eq(status.transferring_rows({"transferring": [{
    "name": "blob.bin", "bytes": 100, "size": 1000, "percentage": 10,
    "speed": 2.5, "eta": 30, "group": "job/7"}]}),
   [{"name": "blob.bin", "bytes": 100, "size": 1000, "percentage": 10,
     "speed": 2.5, "eta": 30, "group": "job/7", "srcFs": "", "dstFs": ""}],
   "full row passes through")
eq(status.transferring_rows({}), [], "no transferring key")
eq(status.transferring_rows({"transferring": None}), [], "null transferring")
eq(status.transferring_rows({"transferring": ["not a dict", 5]}), [],
   "non-dict members are skipped")
row = status.transferring_rows({"transferring": [{"name": "x"}]})[0]
eq((row["bytes"], row["size"], row["percentage"]), (0, 0, 0), "missing numbers default to 0")
eq(row["eta"], None, "a missing eta stays None, NOT 0 — 0 would render as 'finishing now'")

# ---- transferring rows carry their remote ----------------------------------
# The panel names the provider on an in-flight transfer the same way RECENT
# names it on a finished one — but it can only do that if these fields survive.
# They were dropped here originally, so the QML asked and always got nothing.
rows = status.transferring_rows({"transferring": [{
    "name": "sample-01.bin", "bytes": 3141632, "size": 9000000,
    "speed": 1380400.0, "eta": 3, "group": "copy zoho:hero-demo -> /tmp/out",
    "srcFs": "zoho:hero-demo", "dstFs": "/tmp/out",
}]})
eq(rows[0]["srcFs"], "zoho:hero-demo", "the source fs survives into the row")
eq(rows[0]["dstFs"], "/tmp/out", "so does the destination")
eq(status.transferring_rows({"transferring": [{"name": "x"}]})[0]["srcFs"], "",
   "a transfer with no fs reported yields empty strings, not None")

# ---- transferred_rows ------------------------------------------------------
# rclone returns oldest-first; the panel wants newest-first.
payload = {"transferred": [
    {"name": "old.bin", "size": 1, "bytes": 1, "what": "transferring"},
    {"name": "mid.bin", "size": 2, "bytes": 2, "what": "transferring"},
    {"name": "new.bin", "size": 3, "bytes": 3, "error": "boom", "what": "transferring"},
]}
rows = status.transferred_rows(payload, 10)
eq([r["name"] for r in rows], ["new.bin", "mid.bin", "old.bin"], "newest first")
eq(rows[0]["error"], "boom", "errors are preserved")
eq(len(status.transferred_rows(payload, 2)), 2, "limit is honoured")
eq(status.transferred_rows({}, 10), [], "no transferred key")
eq(status.transferred_rows({"transferred": None}, 10), [], "null transferred")
eq(status.transferred_rows({"transferred": [{"name": "a", "what": "transferring"}]}, 10)[0]["checked"],
   False, "checked defaults to False, not None")

# rclone reports checks and bisync listings through the same endpoint. They are
# not transfers, they carry no srcFs, and showing them made RECENT lie.
eq(status.transferred_rows({"transferred": [
    {"name": "listed.txt", "what": "listing file - Path1"},
    {"name": "checked.txt", "what": "checking"},
    {"name": "real.bin", "what": "transferring"},
]}, 10), [status.transferred_rows({"transferred": [{"name": "real.bin", "what": "transferring"}]}, 10)[0]],
   "only actual transfers survive the filter")
eq(status.transferred_rows({"transferred": [{"name": "x"}]}, 10), [],
   "an entry with no `what` is not assumed to be a transfer")

# ---- mount_rows ------------------------------------------------------------
eq(status.mount_rows({"mountPoints": [
    {"Fs": "gdrive{ABC}:", "MountPoint": "/home/u/GDrive", "MountedOn": "2026-08-15T15:05:04Z"}]}),
   [{"fs": "gdrive{ABC}:", "requestedFs": "gdrive{ABC}:",
     "pendingCount": 0, "pendingBytes": 0,
     "mountPoint": "/home/u/GDrive", "mountedOn": "2026-08-15T15:05:04Z"}],
   "capitalised rclone keys are lowercased for the panel")


# ---- probe error classification --------------------------------------------
# An expired grant and a dead network both used to read "unreachable", which
# told the user nothing about which one to fix.
eq(status.classify_remote_error("oauth2: token expired and refresh token is not set"),
   "auth", "an expired OAuth grant is an auth failure")
eq(status.classify_remote_error("invalid_grant"), "auth", "invalid_grant is an auth failure")
eq(status.classify_remote_error('Get "https://x": dial tcp: lookup x: no such host'),
   "network", "DNS failure is a network failure")
eq(status.classify_remote_error("context deadline exceeded (timeout)"),
   "network", "a timeout is a network failure")
eq(status.classify_remote_error("permission denied on object"),
   "other", "anything unrecognised stays 'other' rather than guessing")
eq(status.classify_remote_error(""), "other", "empty is not classified as a failure type")
# An auth error that also mentions a transport must still read as auth, since
# that is the one the user can act on.
eq(status.classify_remote_error('dial tcp ok but oauth2: cannot refresh token'),
   "auth", "auth wins over an incidental transport mention")


class FailClient:
    def __init__(self, error):
        self.error = error

    def rc_detailed(self, method, params=None, timeout=None):
        return None, self.error


name, result = status.probe_one(FailClient("oauth2: token expired"), "gdrive")
eq(result["online"], False, "a failed probe is offline")
eq(result["errorKind"], "auth", "the failure kind is reported")
eq(result["error"] != "unreachable", True, "rclone's own message is preserved, not flattened")

name, result = status.probe_one(FailClient("dial tcp: no such host"), "gdrive")
eq(result["errorKind"], "network", "a network failure is distinguished from auth")

# ---- read_suppressed --------------------------------------------------------
# Switched-off mounts live on DISK, not in the widget: it runs once per monitor
# and each instance has its own state, so an in-memory set let the other
# instance reconcile a manually-unmounted remote straight back.
good = with_temp_file('["/home/u/box", "/home/u/GDrive"]')
eq(status.read_suppressed(good), ["/home/u/box", "/home/u/GDrive"], "list is read back")
os.unlink(good)
bad = with_temp_file('{"not": "a list"}')
eq(status.read_suppressed(bad), [], "a non-list yields nothing suppressed")
os.unlink(bad)
broken = with_temp_file("not json")
eq(status.read_suppressed(broken), [], "unparseable yields nothing suppressed")
os.unlink(broken)
eq(status.read_suppressed(Path("/nonexistent/none.json")), [], "missing file yields nothing")

# ---- config_mtime -----------------------------------------------------------
# The panel clears the daemon's cached filesystems whenever this value MOVES,
# so its two failure modes are both silent: a missing file that reports garbage
# would clear on every poll, and a float that does not survive JSON would do the
# same. Both look like a working plugin while hammering the daemon.
eq(status.config_mtime(Path("/nonexistent/rclone.conf")), 0,
   "a missing config reads as 0, not an exception")
conf = with_temp_file("[demo]\ntype = local\n")
stamp = status.config_mtime(conf)
eq(isinstance(stamp, int), True, "the stamp is an int, so it survives a JSON round-trip")
eq(stamp > 0, True, "an existing config has a non-zero stamp")
eq(status.config_mtime(conf), stamp, "reading twice without a write is stable")
os.utime(conf, (stamp + 10, stamp + 10))
eq(status.config_mtime(conf) > stamp, True, "a write moves the stamp")
os.unlink(conf)

# ---- pending_uploads --------------------------------------------------------
# The only thing that makes unmounting genuinely dangerous: writes still in the
# local cache. A forced unmount drops them.
class QueueClient:
    def __init__(self, queues):
        self.queues = queues

    def rc(self, method, params=None, timeout=None):
        return self.queues.get((params or {}).get("fs"))


rows = status.pending_uploads(
    QueueClient({"gdrive:": {"queue": [{"name": "a", "size": 10}, {"name": "b", "size": 5}]},
                 "box:": {}}),
    [{"fs": "gdrive:", "mountPoint": "/g"}, {"fs": "box:", "mountPoint": "/b"}])
eq((rows[0]["pendingCount"], rows[0]["pendingBytes"]), (2, 15), "queued files are counted and sized")
eq((rows[1]["pendingCount"], rows[1]["pendingBytes"]), (0, 0), "an idle mount reports nothing pending")

rows = status.pending_uploads(QueueClient({}), [{"fs": "x:", "mountPoint": "/x"}])
eq(rows[0]["pendingCount"], 0, "an unanswered queue query is treated as nothing pending")

rows = status.pending_uploads(
    QueueClient({"x:": {"queue": "not a list"}}), [{"fs": "x:", "mountPoint": "/x"}])
eq(rows[0]["pendingCount"], 0, "a malformed queue does not raise")

# mount/listmounts reports a rewritten fs ("gdrive{YRXYK}:") that rclone REFUSES
# as input — "config name contains invalid characters". Pinning that produced a
# login mount that could never be restored, silently. requestedFs carries what
# was actually asked for.
eq(status.mount_rows(
    {"mountPoints": [{"Fs": "gdrive{ABC}:", "MountPoint": "/home/u/GDrive"}]},
    {"/home/u/GDrive": "gdrive,skip_gdocs=true:"})[0]["requestedFs"],
   "gdrive,skip_gdocs=true:",
   "requestedFs is the durable fs, not the display one")
eq(status.mount_rows(
    {"mountPoints": [{"Fs": "box:", "MountPoint": "/home/u/box"}]}, {})[0]["requestedFs"],
   "box:", "with no record, requestedFs falls back to what was reported")
eq(status.mount_rows({}), [], "no mountPoints key")
eq(status.mount_rows({"mountPoints": None}), [], "null mountPoints")
eq(status.mount_rows({"mountPoints": ["nope"]}), [], "non-dict members are skipped")

# ---- SAFE_CONFIG_KEYS ------------------------------------------------------
# The config file holds live OAuth tokens and passwords. If this list ever
# grows beyond type, secrets start reaching the shell.
eq(tuple(status.SAFE_CONFIG_KEYS), ("type",),
   "only 'type' is copied out of a remote's config block")

# ---- classify_config -------------------------------------------------------
# THE ZOMBIE-REMOTE REGRESSION. A section with no `type` used to be reported as
# a half-finished remote, so the panel listed it, labelled it "setup never
# finished — remove it", and the trash button ran a delete that the daemon
# undid on its next token refresh: an undeletable row per removed remote.
#
# The classification rests on two measured facts about rclone 1.75 (see
# classify_config's docstring): `config create` writes `type` in the same write
# as the section, and `config update --continue` refuses a name that is not
# already in the file. So no setup path can leave a section without a `type`,
# and a typeless section is always residue from a write-back.
remotes, residue = status.classify_config({
    "gdrive": {"type": "drive", "token": "{secret}"},
    "box": {"token": "{secret}"},
})
eq([r["name"] for r in remotes], ["gdrive"], "a typeless section is not a remote")
eq(residue, ["box"], "a typeless section is reported as residue")

# The exact artefact observed on 2026-08-17: three remotes were removed in the
# panel and came back holding nothing but a refreshed OAuth token.
_, residue = status.classify_config({
    "box": {"token": '{"access_token":"x","expiry":"2026-08-17T11:26:38+02:00"}'},
    "dropbox": {"token": '{"access_token":"y"}'},
    "onedrive": {"token": '{"access_token":"z"}'},
    "zoho": {"type": "zoho", "region": "com"},
})
eq(residue, ["box", "dropbox", "onedrive"], "every token-only section is residue")

remotes, residue = status.classify_config({})
eq((remotes, residue), ([], []), "an empty config yields nothing")

remotes, residue = status.classify_config({"broken": "not a dict"})
eq((remotes, residue), ([], ["broken"]), "a non-dict section cannot pass as a remote")

# `incomplete` now means what it says: `config create` wrote the section and its
# type, and the flow was abandoned before answering anything. Measured shape —
# an aborted dropbox setup leaves exactly `[db]` + `type = dropbox`.
remotes, _ = status.classify_config({"db": {"type": "dropbox"}})
eq(remotes[0]["incomplete"], True, "typed but empty is an unfinished setup")

remotes, _ = status.classify_config({"db": {"type": "dropbox", "token": "{}"}})
eq(remotes[0]["incomplete"], False, "typed with a token is a finished setup")

# Backends that need no configuration at all must not be called unfinished —
# `type = local` on its own is a perfectly usable remote.
remotes, _ = status.classify_config({"disk": {"type": "local"}})
eq(remotes[0]["incomplete"], False, "a self-sufficient backend is never unfinished")

# Residue is dropped before probe_remotes sees it, so a removed remote cannot
# cost a 15s probe on every refresh either.
remotes, _ = status.classify_config({"box": {"token": "{}"}, "z": {"type": "zoho"}})
eq([r["name"] for r in remotes], ["z"], "residue is not handed to the prober")

# Secrets must not ride along in the payload just because the block held them.
remotes, _ = status.classify_config(
    {"g": {"type": "drive", "token": "{tok}", "client_secret": "shh", "pass": "p"}})
eq(sorted(remotes[0]), ["incomplete", "name", "type"],
   "only name/type/incomplete reach the shell")

# ---- job_rows --------------------------------------------------------------
# Reads per-group stats, and must ignore the jobs our own rc calls create.
class FakeClient:
    """Answers rc() from a table, and records what was asked."""
    def __init__(self, table):
        self.table = table
        self.calls = []

    def rc(self, method, params=None, timeout=None):
        self.calls.append((method, dict(params or {})))
        return self.table.get((method, str((params or {}).get("jobid",
                              (params or {}).get("group", "")))))


client = FakeClient({
    ("job/status", "7"): {"group": "copy /src -> /dst", "finished": False, "error": ""},
    ("job/status", "8"): {"group": "job/8", "finished": False, "error": ""},
    ("core/stats", "copy /src -> /dst"): {"bytes": 50, "totalBytes": 100, "speed": 10.0,
                                          "eta": 5, "errors": 0, "transfers": 1,
                                          "totalTransfers": 2},
})
rows = status.job_rows(client, [7, 8])
eq(len(rows), 1, "only OUR jobs are reported; an rc call's own job/N group is skipped")
eq(rows[0]["id"], 7, "job id carried through")
eq(rows[0]["label"], "copy /src -> /dst", "label is the group, which becomes the row title")
eq((rows[0]["bytes"], rows[0]["totalBytes"]), (50, 100), "per-group stats, not daemon-wide")
eq(rows[0]["eta"], 5, "eta carried through")
eq(("core/stats", {"group": "copy /src -> /dst"}) in client.calls, True,
   "stats were requested BY GROUP — the whole point, since core/stats with no "
   "group is cumulative for the daemon lifetime")

eq(status.job_rows(FakeClient({}), [1, 2]), [],
   "a client that answers nothing yields no rows rather than raising")

# ---- probe_remotes runs concurrently ---------------------------------------
# Serial probing made the check button cost the SUM of every remote's latency.
# This asserts the shape of the fix, not a wall-clock threshold that would make
# the suite flaky on a loaded machine.
import time


class SlowClient:
    """Every rc call sleeps, so serial vs parallel is unambiguous."""
    def __init__(self, delay):
        self.delay = delay

    def rc_detailed(self, method, params=None, timeout=None):
        time.sleep(self.delay)
        return {"used": 1, "free": 2, "total": 3}, ""


DELAY = 0.20
remotes = [{"name": "r%d" % i} for i in range(6)]
started = time.monotonic()
probes = status.probe_remotes(SlowClient(DELAY), remotes)
elapsed = time.monotonic() - started

eq(len(probes), 6, "every remote is probed")
eq(all(p["online"] for p in probes.values()), True, "all report online")
# Serial would be 6 * 0.20 = 1.2s. Parallel is ~0.20s. Half of serial is a wide
# margin that still fails loudly if the concurrency is ever removed.
eq(elapsed < (DELAY * 6) / 2, True,
   "6 probes finish in well under serial time (took %.2fs, serial would be %.2fs)"
   % (elapsed, DELAY * 6))

eq(status.probe_remotes(SlowClient(0), []), {}, "no remotes means no work")

print()
if failures:
    print("  %d of %d checks FAILED" % (failures, checks))
else:
    print("  %d checks passed" % checks)
print()
sys.exit(1 if failures else 0)
