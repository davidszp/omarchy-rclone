#!/usr/bin/env bash
# One-shot bootstrap of the rclone rc daemon for a user who just installed this
# plugin. Idempotent: safe to run again, never overwrites existing credentials.
#
# The plugin cannot do anything without an rcd to talk to, and expecting every
# user to hand-write a systemd unit and invent a password is a bad first run.
# The panel calls this from its "Set up the rclone daemon" button.
set -euo pipefail
MIGRATED=no

ENV_FILE="$HOME/.config/rclone/rcd.env"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/rclone-rcd.service"

command -v rclone >/dev/null 2>&1 || {
  echo "rclone is not installed — install it first (Arch: omarchy pkg add rclone)" >&2
  exit 1
}

mkdir -p "$HOME/.config/rclone" "$UNIT_DIR"

# A UNIX SOCKET, not a loopback port. $XDG_RUNTIME_DIR is mode 0700, so the
# socket cannot be reached by another user at all — the filesystem does the
# access control. A loopback port is NOT uid-restricted: every local user can
# connect and attempt auth, and only the password stands in the way.
#
# The password stays anyway. Two independent barriers, and it costs one header.
SOCKET_PATH="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rclone-rcd.sock"

if [ -f "$ENV_FILE" ]; then
  # MIGRATE the address, keeping the credentials. Only the exact loopback default
  # this script used to write is replaced: anything else is a deliberate choice by
  # the user and is left alone.
  if grep -q '^RCLONE_RC_ADDR=127\.0\.0\.1:5572$' "$ENV_FILE"; then
    tmp="$(mktemp "$ENV_FILE.XXXXXX")"
    sed "s|^RCLONE_RC_ADDR=127\.0\.0\.1:5572$|RCLONE_RC_ADDR=unix://$SOCKET_PATH|" \
      "$ENV_FILE" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
    echo "moved the daemon off the loopback port onto $SOCKET_PATH"
    MIGRATED=yes
  else
    echo "keeping existing $ENV_FILE"
  fi
else
  umask 077
  cat > "$ENV_FILE" <<EOF
# Written by the Omarchy rclone plugin. Shared by rclone-rcd.service and the
# plugin's status.py. rclone maps every --rc-* flag to RCLONE_RC_*.
RCLONE_RC_ADDR=unix://$SOCKET_PATH
RCLONE_RC_USER=omarchy
RCLONE_RC_PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
EOF
  chmod 600 "$ENV_FILE"
  echo "created $ENV_FILE"
fi

cat > "$UNIT_FILE" <<'EOF'
[Unit]
Description=rclone remote control daemon (rcd)
Documentation=https://rclone.org/rc/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/rclone/rcd.env
# So rclone creates the rc socket 0600 rather than 0755. Belt and braces: the
# runtime directory above it is already 0700.
UMask=0077
ExecStart=/usr/bin/rclone rcd --log-level INFO
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
echo "wrote $UNIT_FILE"

systemctl --user daemon-reload
systemctl --user enable --now rclone-rcd.service

# `enable --now` does NOT restart a service that is already running, so a daemon
# migrated off the loopback port would keep listening on it while the plugin
# looked for a socket that does not exist — the panel would just report the
# daemon as down. Restart only in that case; a plain re-run must not disturb
# live mounts, which live inside the daemon and do not survive it.
if [ "${MIGRATED:-no}" = "yes" ]; then
  systemctl --user restart rclone-rcd.service
  echo "restarted the daemon onto the socket — any live mounts were remounted by the panel"
else
  echo "rclone-rcd.service enabled and started"
fi
