#!/usr/bin/env bash
# One-shot bootstrap of the rclone rc daemon for a user who just installed this
# plugin. Idempotent: safe to run again, never overwrites existing credentials.
#
# The plugin cannot do anything without an rcd to talk to, and expecting every
# user to hand-write a systemd unit and invent a password is a bad first run.
# The panel calls this from its "Set up the rclone daemon" button.
set -euo pipefail

ENV_FILE="$HOME/.config/rclone/rcd.env"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/rclone-rcd.service"

command -v rclone >/dev/null 2>&1 || {
  echo "rclone is not installed — install it first (Arch: omarchy pkg add rclone)" >&2
  exit 1
}

mkdir -p "$HOME/.config/rclone" "$UNIT_DIR"

if [ -f "$ENV_FILE" ]; then
  echo "keeping existing $ENV_FILE"
else
  # Loopback + a random password rather than --rc-no-auth. rclone's own docs:
  # "access to the rc API is equivalent to shell access as the user running
  # rclone", and an unauthenticated local port can be reached by any local
  # process, a browser page included.
  umask 077
  cat > "$ENV_FILE" <<EOF
# Written by the Omarchy rclone plugin. Shared by rclone-rcd.service and the
# plugin's status.py. rclone maps every --rc-* flag to RCLONE_RC_*.
RCLONE_RC_ADDR=127.0.0.1:5572
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
ExecStart=/usr/bin/rclone rcd --log-level INFO
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
echo "wrote $UNIT_FILE"

systemctl --user daemon-reload
systemctl --user enable --now rclone-rcd.service
echo "rclone-rcd.service enabled and started"
