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
import http.client
import socket
from pathlib import Path

ENV_FILE = Path.home() / ".config" / "rclone" / "rcd.env"

# A UNIX SOCKET under $XDG_RUNTIME_DIR, not a TCP port. /run/user/<uid> is mode
# 0700, so the socket is unreachable by any other user on the machine — the
# filesystem does the access control. A loopback port is different: it is not
# uid-restricted, so every local user can connect to it and attempt auth, and
# only the password stands in the way. Nothing can be sniffed either way without
# CAP_NET_RAW, but this removes the door rather than locking it.
#
# A TCP address in rcd.env still works; installs made before this keep running
# until setup-daemon.sh migrates them.
DEFAULT_SOCKET = "unix://%s/rclone-rcd.sock" % (
    os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid())
DEFAULT_ADDR = DEFAULT_SOCKET
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


def address_of(env):
    """-> ("unix", path) or ("tcp", host, port). rclone's own --rc-addr syntax."""
    addr = env.get("RCLONE_RC_ADDR", DEFAULT_ADDR).strip()
    for scheme in ("unix://", "http://", "https://"):
        if addr.startswith(scheme):
            rest = addr[len(scheme):]
            if scheme == "unix://":
                return ("unix", "/" + rest.lstrip("/"))
            addr = rest.rstrip("/")
            break
    host, _, port = addr.rpartition(":")
    return ("tcp", host or "127.0.0.1", int(port or 5572))


def url_for(env):
    """A human-readable address for the panel to show."""
    target = address_of(env)
    return target[1] if target[0] == "unix" else "http://%s:%d/" % (target[1], target[2])


class _UnixConnection(http.client.HTTPConnection):
    """HTTPConnection over an AF_UNIX socket. http.client speaks HTTP down any
    stream, so only connect() has to change — and urllib cannot do this at all,
    which is why the transport moved off it."""

    def __init__(self, path, timeout=DEFAULT_TIMEOUT):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if self.timeout:
            self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


def _connect(env, timeout):
    target = address_of(env)
    if target[0] == "unix":
        return _UnixConnection(target[1], timeout=timeout)
    return http.client.HTTPConnection(target[1], target[2], timeout=timeout)


# Keys whose value must never appear in a message. Same list as rclone-config's,
# and for the same reason: rclone does not reliably flag which fields are
# sensitive, so match on the name and accept false positives.
SENSITIVE_KEYS = ("pass", "secret", "token", "key", "password", "passwd")


def _sensitive_values(params, found=None):
    """Every value in `params` that sits under a sensitive-looking key."""
    found = [] if found is None else found
    if isinstance(params, dict):
        for key, value in params.items():
            if isinstance(value, (dict, list)):
                _sensitive_values(value, found)
            elif value not in (None, "") and any(
                    word in str(key).lower() for word in SENSITIVE_KEYS):
                found.append(str(value))
    elif isinstance(params, list):
        for value in params:
            _sensitive_values(value, found)
    return found


def _scrub(message, params):
    """Redact anything we sent that must not be shown.

    Necessary because a FAILED rc call answers with the whole request echoed
    back — measured:

        {"error": "couldn't find backend for type \\"nope\\"",
         "input": {"parameters": {"pass": "hunter2"}}, "status": 500}

    Only the `error` field is ever read below, but rclone is free to quote an
    offending value inside that field too, and an error string travels to the
    panel's status line where it would be on screen (and in a screenshot). So
    strip our own secrets out of it rather than trusting the wording.
    """
    text = str(message or "")
    for value in _sensitive_values(params):
        if len(value) > 2 and value in text:
            text = text.replace(value, "***")
    return text


def call(method, params=None, timeout=DEFAULT_TIMEOUT, env=None):
    """Call one rc method. Returns (payload, error); payload is None on failure.

    `params` values may be any JSON type. Pass strings to mirror what the
    `rclone rc` CLI would have sent.
    """
    env = read_env() if env is None else env
    headers = {"Content-Type": "application/json"}
    user = env.get("RCLONE_RC_USER", "")
    if user:
        # Kept even on a unix socket, where the directory mode already keeps other
        # users out: two independent barriers, and it costs one header.
        token = "%s:%s" % (user, env.get("RCLONE_RC_PASS", ""))
        headers["Authorization"] = (
            "Basic " + base64.b64encode(token.encode("utf-8")).decode("ascii"))

    connection = _connect(env, timeout)
    try:
        connection.request("POST", "/" + method.lstrip("/"),
                           body=json.dumps(params or {}).encode("utf-8"),
                           headers=headers)
        response = connection.getresponse()
        status = response.status
        body = response.read().decode("utf-8", "replace")
    except (ConnectionRefusedError, FileNotFoundError):
        # No listener, or the socket file is not there — the same condition, and
        # the same sentence the CLI path used to produce, so the panel's handling
        # of "the daemon is down" is unchanged.
        return None, "rclone rcd is not running"
    except (socket.timeout, TimeoutError):
        return None, "rclone rcd did not answer in %ss" % timeout
    except OSError as exc:
        return None, _scrub(str(exc), params)[:200]
    finally:
        connection.close()

    if status >= 400:
        # ONLY the `error` field, and NEVER the raw body: the body also contains
        # `input`, which is the request echoed back verbatim — passwords and all.
        message = ""
        try:
            parsed = json.loads(body)
            if isinstance(parsed, dict):
                message = str(parsed.get("error") or "")
        except ValueError:
            message = ""
        if not message:
            message = "rc call %s failed (HTTP %s)" % (method, status)
        return None, _scrub(message, params)[:200]

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
