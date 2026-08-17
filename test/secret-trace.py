#!/usr/bin/env python3
"""Watch the whole machine for a leaked credential while you set up a remote.

    test/secret-trace.py                 # watch for 10 minutes, then report
    test/secret-trace.py --minutes 3
    test/secret-trace.py --also GOCSPX-abc123   # ALSO hunt one exact value

Run it, then do the setup in the panel. It prints a verdict at the end.

WHAT IT LOOKS FOR. Google's credentials have recognisable shapes, so nothing has
to be typed in here and the tool never needs to be told your secret:

    GOCSPX-…    OAuth client secret
    ya29.…      OAuth access token
    1//…        OAuth refresh token
    …apps.googleusercontent.com   client id (not secret, but it should not be in
                                  a world-readable place either)

WHERE IT LOOKS, every 20ms for the argv scan:

    /proc/*/cmdline   every process's arguments — world-readable, and the
                      channel the marketplace review was about
    /proc/*/environ   every process's environment we are allowed to read
    the journal       omarchy-shell and rclone-rcd output
    world-readable    files under /tmp that anyone could open
    the config file   EXPECTED to hold it — reported separately, with its mode

IT NEVER WRITES A SECRET DOWN. A hit is reported as a redacted fingerprint —
`GOCSPX-…4f2a` (prefix + a truncated SHA-256) — which is enough to tell two
values apart and to match one place against another, and useless to anyone
reading the log. That matters because a leak report you cannot share, or that
becomes a second copy of the secret, is not much of a report.

Exit status is 1 if anything was found somewhere it should not be, so this can
gate a release.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

PATTERNS = {
    "google client secret": re.compile(r"GOCSPX-[A-Za-z0-9_\-]{6,}"),
    "google access token": re.compile(r"ya29\.[A-Za-z0-9_\-]{20,}"),
    "google refresh token": re.compile(r"1//[A-Za-z0-9_\-]{20,}"),
    "google client id": re.compile(r"[0-9]{6,}-[a-z0-9]{10,}\.apps\.googleusercontent\.com"),
}
# A generic "long base64-ish string" pattern was tried and removed: Chromium's
# own argv matched it thousands of times per run, which buried the real hits.
# For a non-Google provider, pass the value with --also instead.

# Patterns that are not secrets on their own. Reported, but they do not fail the
# run: a client id is public, and the obscured-value pattern matches plenty of
# innocent base64.
ADVISORY = {"google client id"}


def fingerprint(value):
    """Prefix + truncated hash. Identifies a value without disclosing it."""
    digest = hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()[:4]
    head = value[:7] if value.startswith(("GOCSPX-", "ya29.", "1//")) else value[:3]
    return "%s…%s (%d chars)" % (head, digest, len(value))


def scan(text, extra=None):
    """-> list of (label, fingerprint) for everything secret-shaped in `text`."""
    hits = []
    for label, pattern in PATTERNS.items():
        for match in pattern.findall(text or ""):
            hits.append((label, fingerprint(match)))
    for value in extra or []:
        if value and value in (text or ""):
            hits.append(("exact value you gave", fingerprint(value)))
    return hits


def scan_proc(extra, found):
    """One sweep of every process's argv and environment."""
    me = str(os.getpid())
    for path in glob.glob("/proc/[0-9]*/"):
        pid = path.split("/")[2]
        if pid == me:
            continue
        for kind in ("cmdline", "environ"):
            try:
                with open(path + kind, "rb") as handle:
                    text = handle.read().decode("utf-8", "ignore").replace("\0", " ")
            except OSError:
                continue          # process gone, or not ours to read
            if not text.strip():
                continue
            for label, print_ in scan(text, extra):
                try:
                    comm = open(path + "comm").read().strip()
                except OSError:
                    comm = "?"
                found.setdefault(("process %s" % kind, comm, label, print_), 0)
                found[("process %s" % kind, comm, label, print_)] += 1


def scan_journal(since, extra, found):
    for unit in ("rclone-rcd.service", None):
        command = ["journalctl", "--user", "--since", since, "--no-pager"]
        if unit:
            command += ["-u", unit]
        else:
            command += ["-t", "omarchy-shell"]
        try:
            text = subprocess.run(command, capture_output=True, text=True,
                                  timeout=30).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        for label, print_ in scan(text, extra):
            found.setdefault(("journal %s" % (unit or "omarchy-shell"), "-", label, print_), 0)
            found[("journal %s" % (unit or "omarchy-shell"), "-", label, print_)] += 1


def scan_world_readable(extra, found):
    """Files anyone on the machine could open."""
    for base in ("/tmp", "/var/tmp", str(Path.home() / ".cache")):
        for path in glob.glob(base + "/**/*", recursive=True)[:4000]:
            try:
                info = os.stat(path)
                if not os.path.isfile(path) or info.st_size > 2_000_000:
                    continue
                if not (info.st_mode & 0o044):        # not group/world readable
                    continue
                with open(path, "rb") as handle:
                    text = handle.read().decode("utf-8", "ignore")
            except OSError:
                continue
            for label, print_ in scan(text, extra):
                found.setdefault(("world-readable file", path, label, print_), 0)
                found[("world-readable file", path, label, print_)] += 1


def config_report(extra):
    """The config file SHOULD hold the credential. Report it with its mode."""
    path = os.environ.get("RCLONE_CONFIG", "")
    if not path:
        try:
            out = subprocess.run(["rclone", "config", "file"], capture_output=True,
                                 text=True, timeout=10).stdout
            path = out.strip().splitlines()[-1] if out.strip() else ""
        except (OSError, subprocess.SubprocessError):
            path = ""
    if not path or not os.path.isfile(path):
        return path, "", []
    mode = oct(os.stat(path).st_mode & 0o777)
    with open(path, encoding="utf-8", errors="ignore") as handle:
        return path, mode, scan(handle.read(), extra)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--minutes", type=float, default=10)
    parser.add_argument("--also", action="append", default=[],
                        help="an exact value to hunt for as well (never logged)")
    args = parser.parse_args()

    since = time.strftime("%Y-%m-%d %H:%M:%S")
    found = {}
    deadline = time.time() + args.minutes * 60
    print("tracing for %g minutes — do the setup now. Ctrl-C to stop early.\n"
          % args.minutes, flush=True)
    sweeps = 0
    try:
        while time.time() < deadline:
            scan_proc(args.also, found)
            sweeps += 1
            time.sleep(0.02)
    except KeyboardInterrupt:
        print("stopped early\n")

    print("scanning the journal and world-readable files…\n", flush=True)
    scan_journal(since, args.also, found)
    scan_world_readable(args.also, found)

    print("=" * 72)
    print("%d process sweeps" % sweeps)
    path, mode, config_hits = config_report(args.also)
    if path:
        print("\nconfig file: %s (mode %s)" % (path, mode))
        for label, print_ in config_hits:
            print("   holds %-22s %s" % (label, print_))
        print("   ^ expected: this is where a credential is SUPPOSED to live."
              "\n     mode 600 means only you can read it.")

    serious = {k: v for k, v in found.items() if k[2] not in ADVISORY}
    advisory = {k: v for k, v in found.items() if k[2] in ADVISORY}

    if advisory:
        print("\nadvisory (not secret by itself):")
        for (where, who, label, print_), count in sorted(advisory.items()):
            print("   %-22s %-24s %-22s %s  x%d" % (where, who[:24], label, print_, count))

    print()
    if serious:
        print("!! LEAK — a credential was visible outside the config file:")
        for (where, who, label, print_), count in sorted(serious.items()):
            print("   %-22s %-24s %-22s %s  x%d" % (where, who[:24], label, print_, count))
        return 1
    print("CLEAN — no credential seen in any process's arguments or environment,")
    print("        in the journal, or in any world-readable file.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
