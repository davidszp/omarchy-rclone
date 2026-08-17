#!/usr/bin/env python3
"""Talk to rclone's rc API over HTTP, with nothing sensitive in argv.

WHY THIS EXISTS. The obvious way to call the daemon is `rclone rc --user U
--pass P <method> key=value`, and that is what this plugin used to do from both
`status.py` and `rclone-rc`. Two things then sit in the process table, where
`/proc/<pid>/cmdline` is world-readable and any local process can poll it:

  * the daemon's password, on EVERY poll — every 2s during a transfer, forever.
    rclone's own documentation says "access to the rc API is equivalent to shell
    access as the user running rclone", so that is the whole security boundary
    the `--rc-user`/`--rc-pass` setup exists to create.
  * whatever the call carries, which for the config methods is the user's
    provider credentials.

Here the password goes in an `Authorization` header and the parameters go in the
request body, so argv holds only a method name. Reported by the marketplace
reviewer for the config path; the polling path was the larger half.

Two ways in, because the callers differ:

    from rcclient import call                 # status.py, in-process
    printf 'k=v\\0' | rcclient.py <method>    # rclone-rc, from shell (NUL-separated)

WIRE COMPATIBILITY. `rclone rc key=value` sends every value as a STRING, even
one that is valid JSON — measured: `obj='{"CacheMode":"full"}'` arrives as a
string, and the daemon parses it itself. The CLI path here does the same, so
swapping transports cannot quietly change how a mount is configured. Callers
that need real JSON types (the config methods want `parameters` and `opt` as
objects) pass a dict to call() instead.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ENV_FILE = Path.home() / ".config" / "rclone" / "rcd.env"
DEFAULT_ADDR = "127.0.0.1:5572"
DEFAULT_TIMEOUT = 4


def read_env(path=ENV_FILE):
    """The KEY=value file the rclone-rcd unit and this plugin share."""
    values = {}
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def url_for(env):
    addr = env.get("RCLONE_RC_ADDR", DEFAULT_ADDR)
    return addr if addr.startswith("http") else "http://%s/" % addr


def call(method, params=None, timeout=DEFAULT_TIMEOUT, env=None):
    """Call one rc method. Returns (payload, error); payload is None on failure.

    `params` values may be any JSON type. Pass strings to mirror what the
    `rclone rc` CLI would have sent.
    """
    env = read_env() if env is None else env
    request = urllib.request.Request(
        url_for(env).rstrip("/") + "/" + method.lstrip("/"),
        data=json.dumps(params or {}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    user = env.get("RCLONE_RC_USER", "")
    if user:
        token = "%s:%s" % (user, env.get("RCLONE_RC_PASS", ""))
        request.add_header(
            "Authorization",
            "Basic " + base64.b64encode(token.encode("utf-8")).decode("ascii"),
        )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        # rclone answers a failed method with 500 and a JSON body carrying the
        # real message; without reading it every failure reads as "HTTP Error
        # 500", which says nothing about what went wrong.
        detail = exc.read().decode("utf-8", "replace")
        try:
            return None, str(json.loads(detail).get("error") or detail)[:200]
        except (ValueError, AttributeError):
            return None, (detail or str(exc))[:200]
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", exc)
        # Same sentence the old CLI path produced, so the panel's handling of
        # "daemon is not running" does not change.
        if isinstance(reason, ConnectionRefusedError) or "refused" in str(reason).lower():
            return None, "rclone rcd is not running"
        return None, str(reason)[:200]
    except OSError as exc:
        return None, str(exc)[:200]
    try:
        return (json.loads(body) if body.strip() else {}), ""
    except json.JSONDecodeError:
        return None, "could not parse rc response for %s" % method


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: rcclient.py <method>   # key=value pairs, "
                         "NUL-separated, on stdin\n")
        return 2
    raw = sys.stdin.buffer.read().decode("utf-8", "replace") if not sys.stdin.isatty() else ""
    params = {}
    for item in raw.split("\0"):
        if not item or "=" not in item:
            continue
        key, _, value = item.partition("=")
        params[key] = value          # string, exactly as `rclone rc` would send
    timeout = int(os.environ.get("RC_TIMEOUT") or 0) or DEFAULT_TIMEOUT
    payload, error = call(argv[1], params, timeout=timeout)
    if error:
        sys.stderr.write(error + "\n")
        return 1
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
