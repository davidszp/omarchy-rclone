#!/usr/bin/env bash
# Behaviour tests for the LIVE panel, driven over IPC.
#
#   test/panel-test.sh
#
# Why not headless: the components import `qs.Ui` / `qs.Commons`, which only
# resolve inside the running Omarchy shell, so `qs -p` cannot instantiate them
# standalone. Driving the real widget is both achievable and a truer test — it
# exercises the same objects the user touches.
#
# Skips (exit 0) when the shell or the widget is not available, so `check` stays
# runnable on a machine with no session.
set -uo pipefail

IPC="omarchy-shell davidszp.rclone"
fails=0
checks=0

eq() { # eq <actual> <expected> <label>
  checks=$((checks + 1))
  if [ "$1" != "$2" ]; then
    fails=$((fails + 1))
    printf '  FAIL %s\n       expected %s\n       got      %s\n' "$3" "$2" "$1"
  fi
}

nav() { $IPC nav "$1" "$2" >/dev/null 2>&1; }
cursor() { $IPC cursor 2>/dev/null; }

if ! command -v omarchy-shell >/dev/null 2>&1; then
  echo "  (skipped: no omarchy-shell)"; exit 0
fi
if [ "$($IPC status 2>&1)" = "Target not found." ] || [ -z "$($IPC status 2>&1)" ]; then
  echo "  (skipped: widget not registered — restart the shell)"; exit 0
fi

# The widget polls asynchronously, so a freshly (re)loaded plugin has empty
# state for a moment. Asserting before the first poll lands reads as "no
# remotes" and fails everything downstream — wait for readiness instead.
ready=no
for _ in $(seq 1 30); do
  s="$($IPC status 2>&1)"
  case "$s" in
    "rclone is not installed"|"daemon not set up"|""|"Target not found.") sleep 0.5 ;;
    *) ready=yes; break ;;
  esac
done
if [ "$ready" != "yes" ]; then
  echo "  (skipped: widget never became ready — status: ${s:-none})"; exit 0
fi

# The bandwidth row exists ONLY while the widget can reach the daemon
# (`sectionOrder()` gates it on rcRunning), and a single poll that cannot reach
# it drops the whole section. The cursor then starts in the remotes list, the
# first arrow press goes somewhere else entirely, and six later assertions fail
# while reporting nothing about what they were meant to test.
#
# Measured flaky exactly that way — 1 run in 3. So ESTABLISH the precondition by
# probing for it and reopening, rather than assuming a fixed sleep is enough.
bandwidth_ready=no
for _ in $(seq 1 10); do
  $IPC close >/dev/null 2>&1; sleep 0.5
  $IPC open  >/dev/null 2>&1; sleep 1
  nav 1 0
  case "$(cursor)" in bandwidth*) bandwidth_ready=yes; break ;; esac
done
if [ "$bandwidth_ready" != "yes" ]; then
  echo "  (skipped: widget cannot reach the daemon — no bandwidth section)"; exit 0
fi

# Reopen so the assertions below start from a genuinely fresh panel: the probe
# above left the cursor active and parked on a preset.
$IPC close >/dev/null 2>&1; sleep 0.5
$IPC open  >/dev/null 2>&1; sleep 1

# ---- cursor starts inactive -------------------------------------------------
# Opening the panel must not preselect anything; the first key press only wakes
# the cursor.
eq "$(cursor)" "(inactive)" "cursor is inactive on a freshly opened panel"

# ---- bandwidth row ----------------------------------------------------------
nav 1 0; eq "$(cursor)" "bandwidth[1]" "right enters the bandwidth row"
nav 1 0; nav 1 0
eq "$(cursor)" "bandwidth[3]" "right walks to the last preset"
nav 1 0; eq "$(cursor)" "bandwidth[3]" "right clamps at the last preset"
nav -1 0; nav -1 0; nav -1 0; nav -1 0
eq "$(cursor)" "bandwidth[0]" "left clamps at the first preset"

# ---- into the remotes list --------------------------------------------------
nav 0 1
case "$(cursor)" in
  remotes*) eq "$(cursor)" "remotes[0] row=0" "down enters the remotes list at the first row" ;;
  *) echo "  (no remotes configured — skipping remote-row checks)" ;;
esac

if [ "$(cursor)" = "remotes[0] row=0" ]; then
  nav 1 0
  eq "$(cursor)" "remotes[1] row=0" "right moves across a row's actions"

  # A row is 3 targets when unmounted (row, sync, mount) and 5 when mounted
  # (row, pin, sync, move, unmount), so assert CLAMPING rather than a fixed
  # width — the width legitimately differs per row.
  nav 1 0; nav 1 0; nav 1 0; nav 1 0; nav 1 0
  at_end="$(cursor)"
  nav 1 0
  eq "$(cursor)" "$at_end" "right clamps at the end of a row (row width varies)"
fi

# ---- a row's secondary actions are hidden until expanded --------------------
# The cursor must not be able to reach an action that is not on screen.
nav 0 -1; nav 0 -1; nav 0 -1   # back up to the remotes list
if [ "$(cursor)" = "remotes[0] row=0" ]; then
  nav 1 0; nav 1 0            # -> mount, -> more
  collapsed="$(cursor)"
  nav 1 0
  eq "$(cursor)" "$collapsed" "collapsed row clamps after the overflow button"

  $IPC activate >/dev/null 2>&1; sleep 0.5
  nav 1 0
  if [ "$(cursor)" = "$collapsed" ]; then
    fails=$((fails+1)); echo "  FAIL expanding a row should reveal more targets"
  fi
  checks=$((checks + 1))

  # Collapse again so the rest of the run starts from a known state.
  $IPC activate >/dev/null 2>&1; sleep 0.5
fi

# ---- actions section --------------------------------------------------------
# Enough downs to walk past however many remotes exist.
for _ in 1 2 3 4 5 6 7 8; do nav 0 1; done
section="$(cursor)"
eq "${section%%[*}" "actions" "down eventually reaches the actions section"

nav 0 1
eq "$(cursor)" "$section" "down past the last section clamps"

nav 0 -1
case "$(cursor)" in
  actions*) fails=$((fails+1)); echo "  FAIL up should leave the actions section, got $(cursor)" ;;
esac
checks=$((checks + 1))

# ---- the seed question, and that it does not outlive the panel --------------
# Some backends need a value before rclone will start (zoho's region). No flow
# exists at that point, so flowAsks() still says "(no flow)" and a broken picker
# is invisible to every other assertion here.
#
# The leak this guards: seedFor once survived closeForms(), so reopening and
# picking the same provider TOGGLED the question shut instead of opening it —
# the button appeared to do nothing at all.
eq "$($IPC seedAsks 2>&1)" "(none)" "no seed question at rest"

# The seeded provider is located by ASKING the model, never by stepping across
# the grid and activating each one: activating an unseeded provider starts a
# real config flow and writes a half-made remote to the user's rclone.conf.
# An earlier version of this test did exactly that.
seed_index="$(node -e '
  const M = require("./Model.js")
  process.stdout.write(String(M.quickProviders.findIndex(p => p.seed)))' 2>/dev/null)"

if [ -n "$seed_index" ] && [ "$seed_index" -ge 0 ] 2>/dev/null; then
  $IPC close >/dev/null 2>&1; sleep 0.5
  $IPC open >/dev/null 2>&1; sleep 1
  # Down to the actions section, then activate "Add a remote" to reveal the grid.
  for _ in $(seq 1 12); do
    case "$(cursor)" in actions*) break ;; esac
    nav 0 1
  done
  $IPC activate >/dev/null 2>&1; sleep 0.5
  case "$(cursor)" in
    providers*)
      i=0
      while [ "$i" -lt "$seed_index" ]; do nav 1 0; i=$((i + 1)); done
      # cursorText() only appends " row=N" for the remotes section.
      eq "$(cursor)" "providers[$seed_index]" "cursor reaches the seeded provider"
      $IPC activate >/dev/null 2>&1; sleep 0.5
      seed_now="$($IPC seedAsks 2>&1)"
      checks=$((checks + 1))
      if [ "$seed_now" = "(none)" ]; then
        fails=$((fails + 1)); echo "  FAIL activating a seeded provider should open its question"
      fi
      eq "$($IPC flowAsks 2>&1)" "(no flow)" "a seed question does NOT start a flow yet"
      $IPC close >/dev/null 2>&1; sleep 0.5
      $IPC open >/dev/null 2>&1; sleep 1
      eq "$($IPC seedAsks 2>&1)" "(none)" "the seed question does not survive closing the panel"
      ;;
    *) echo "  (skipped: could not reach the provider grid)" ;;
  esac
fi

# ---- opening a mount --------------------------------------------------------
# Only the REFUSAL is asserted: the success path spawns a file manager window,
# which a test run must not do to someone's desktop. The guard is the half worth
# protecting anyway — without it a double click on an unmounted remote hands
# xdg-open a path that does not exist.
eq "$($IPC openFolder __nosuchremote__ 2>&1)" "not mounted: __nosuchremote__" \
   "opening an unknown remote is refused rather than guessed at"

# ---- provider flow contracts ------------------------------------------------
eq "$($IPC flowAsks 2>&1)" "(no flow)" "no flow in progress at rest"

# Walk a MULTI-STEP flow shaped like OneDrive's, including the post-auth picker
# that a one-shot create cannot answer. Uses a fixture, so no account is needed
# and no remote is created — see rclone-config's __fixture__ mode.
$IPC connect __fixture__ >/dev/null 2>&1; sleep 1.5
eq "$($IPC flowAsks 2>&1)" "config_is_local" "flow starts at the first question"

$IPC answer true >/dev/null 2>&1; sleep 1
eq "$($IPC flowAsks 2>&1)" "config_type" "reaches the POST-AUTH picker step"

$IPC answer onedrive >/dev/null 2>&1; sleep 1
# Two pickers back to back, which is Zoho's real shape (organization, then
# workspace). The rendered LABEL of this step is overridden — asserted in
# model-test, since flowAsks reports the step name, not what is drawn.
eq "$($IPC flowAsks 2>&1)" "config_team_drive_id" "reaches a SECOND picker without a text step between"

$IPC answer org-1 >/dev/null 2>&1; sleep 1
eq "$($IPC flowAsks 2>&1)" "config_driveid" "reaches the drive-id step"

$IPC answer 'b!ABC123' >/dev/null 2>&1; sleep 1
eq "$($IPC flowAsks 2>&1)" "config_token_secret" "reaches the secret step"

$IPC answer hunter2 >/dev/null 2>&1; sleep 1.5
eq "$($IPC flowAsks 2>&1)" "(no flow)" "flow completes and clears"

# A second flow must not be startable over a live one — that orphaned a
# half-made remote in the config.
#
# The second connect names the FIXTURE, not a real backend. It used to say
# `connect box`, which is fine exactly as long as the guard works — and on the
# run where the guard did not, the test created a real half-made `box2` in the
# user's config. A test for a safety mechanism must not depend on that
# mechanism to stay safe.
$IPC connect __fixture__ >/dev/null 2>&1; sleep 1.5
second="$($IPC connect __fixture__ 2>&1)"
case "$second" in
  busy:*) : ;;
  *) fails=$((fails+1)); echo "  FAIL second connect should be refused, got: $second" ;;
esac
checks=$((checks + 1))
$IPC cancel >/dev/null 2>&1; sleep 1
eq "$($IPC flowAsks 2>&1)" "(no flow)" "cancel clears the flow"

$IPC close >/dev/null 2>&1

echo
if [ "$fails" -eq 0 ]; then
  echo "  $checks panel checks passed"
else
  echo "  $fails of $checks panel checks FAILED"
fi
exit "$fails"
