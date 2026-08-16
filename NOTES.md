# Implementation notes

Everything that does not belong in a README: how the pieces fit, what the
non-obvious decisions were, and the traps that cost time. Written for whoever
touches this next, including me.

The short version of every gotcha below: **QML fails silently.** A rule that
parses is not a rule that matches, a hot reload is not a restart, and a command
that exits 0 has not necessarily done anything.

## Architecture

One `rclone rcd` daemon owns everything, and the plugin asks it one question.
The alternative — a separate `rclone mount` per remote, each with its own
`--rc-addr` — means polling N ports and still seeing nothing from ad-hoc
`rclone sync` runs. So: **start jobs through the daemon** (`sync/copy`,
`mount/mount` with `_async=true`) and they all show up in one place.

```
Panel.qml → Service.qml → status.py → rclone rc → rclone rcd (127.0.0.1:5572)
```

`status.py` shells out to `rclone rc` rather than speaking HTTP from QML,
because that is the grain of every first-party Omarchy plugin (Dropbox shells
to a Python helper, Tailscale to the CLI) and there is no `XMLHttpRequest`
anywhere in the Omarchy shell.

The daemon runs as `~/.config/systemd/user/rclone-rcd.service`, with its bind
address and credentials in `~/.config/rclone/rcd.env` (0600), shared with
`status.py`. rclone maps every `--rc-*` flag to a `RCLONE_RC_*` env var, so
the unit needs no flags beyond `EnvironmentFile`.

**Security:** rclone's docs are blunt — "access to the rc API is equivalent to
shell access as the user running rclone". Hence loopback-only *and*
`--rc-user`/`--rc-pass` with a random password, rather than `--rc-no-auth`. A
local web page cannot POST to an authenticated endpoint.

`config dump` is read directly from the config file (no daemon needed), and
only `name` + `type` are copied into the payload — **never** the OAuth tokens
and passwords that live in the same blocks.

## Two cost tiers

| Tier | What it does | Cadence |
|---|---|---|
| fast (default) | local config read + `core/stats`, `core/transferred`, `mount/listmounts`, `job/list` | 2s while transferring, 30s idle (configurable) |
| `--probe` | adds `operations/about` **per remote** — a network round-trip each | only on the user pressing the check button |

The two intervals exist because a live transfer wants a moving progress bar
and an idle daemon wants to be left alone. Polling idle at 2s would spawn a
subprocess every 2s forever to re-read a number that never changes.

## Gotchas found while building this — do not re-derive

**1. Every rc call is itself a job.** `job/list` accumulates one entry per poll
forever, and `runningIds` *always* contains the `job/list` call currently in
flight. Measured on a completely idle daemon: 4 finished ids and
`runningIds: [5]` with nothing happening. A naive job count therefore shows
permanent phantom activity that grows with uptime. `status.py` reports
`max(0, len(runningIds) - 1)`, and the honest activity signal is
`stats.transferring`, not any job count.

**2. `core/stats` is cumulative for the daemon's lifetime, not per job.**
After two 300 MB copies it reports `bytes: 600000000, transfers: 6` — the
current transfer's totals are mixed with every prior one, so a progress bar
built on the global `bytes / totalBytes` silently drifts wrong the longer the
daemon runs. **Solved for jobs:** `rclone-rc` labels every copy/mirror with
`_group`, and `status.py` reads `core/stats?group=…` so a job reports its own
totals. **Per-file entries in `transferring[]` were never affected.**

Two traps remain around this counter. `core/stats-reset group=…` does **not**
clear the daemon-wide numbers — measured: global `errors` stayed at 1 after
resetting the offending group. And stopping a job on purpose *increments*
`errors`, so a status line built on it would badge "1 error" forever for
something the user chose to do. `statusText()` therefore ignores the cumulative
counter entirely; errors surface per job in JOBS and per file in RECENT, where
they name the thing that failed and can actually be acted on.

**3. The IpcHandler "another handler is registered" warning is not yours.**
Bar widgets are instantiated once per monitor, so every widget with an
`IpcHandler` logs it. Confirmed pre-existing across all of `omarchy.tailscale`,
`omarchy.audio`, `omarchy.clock` and friends. Benign.

**4. A third-party plugin cannot use `OMARCHY_PATH` to find its own files** —
it does not live under it. `Service.qml` resolves `Qt.resolvedUrl(".")` instead,
which works wherever the plugin is checked out.

**5. `omarchy bar set <id> <key> <value> --json` CANNOT store structured values.**
It forwards the value into an IPC call
`setBarWidget(id, key, valueJson, selectorJson)` whose argument splitting breaks
on the commas inside JSON. A two-element array fails outright —
*"Too many arguments provided (4 required but 5 were provided.)"* — and, worse,
a one-element array **appears to succeed** ("Set autoMounts") while silently
storing the inner object unwrapped, so `Array.isArray()` on the reading side is
false and the feature quietly does nothing. That silent-success case is why this
plugin keeps its mount list in its own file. Scalars via `omarchy bar set` are
fine; anything with a comma is not.

**6. rclone rewrites connection strings in `mount/listmounts`.** Mount
`gdrive,skip_gdocs=true:` and it reports the fs back as **`gdrive{YRXYK}:`** —
a hashed form. Matching a mount to its remote therefore cannot use equality or a
`name,` prefix; `mountForRemote()` accepts the remote name followed by `:`, `,`
or `{`. Test any change against `gdrivebackup:`, which must NOT match `gdrive`.

**7. Mutating a `property var` array emits no change signal.** `_lines.push(x)`
on a `property var` leaves every binding that reads it holding the old value.
This silently emptied the output of *every* command in the plugin — the panel
reported "rclone is not installed" on a machine where it plainly was, with no
error anywhere. `CommandRunner` accumulates into a `property string` instead,
which notifies on assignment and cannot regress the same way. Either reassign
(`arr = arr.concat([x])`) or do not use an array.

**8. A config step with NO question is not the end of the flow.** rclone's
state strings are a stack — `*oauth-islocal,choose_type,,` means "after the
oauth step, still do choose_type" — and it returns intermediate steps carrying a
State but a null `Option`. Treating "no Option" as finished truncated OneDrive
setup immediately after the browser sign-in: the remote was written with only
`token` and `type`, the panel reported success, and mounting then failed with

    unable to get drive_id and drive_type - please run `rclone config` and
    re-configure this backend

because `drive_id`/`drive_type` come from the post-auth picker that never ran.
A flow is finished only when the **State** is empty; `rclone-config` now
auto-continues through question-less states so the panel only ever sees a step
a human can answer.

Recovering such a remote does NOT need another browser login:
`rclone config update <name> --non-interactive` resumes at
`*oauth-confirm,choose_type,,` ("Token already configured - replace it?"), and
answering **false** skips straight to the picker.

**9. `ui: ui` inside a delegate binds a property to itself.** A component with a
`property QtObject ui` that is handed `ui: ui` resolves the right-hand side to
its own property, not the outer object — Qt reports
*"Binding loop detected for property 'ui'"* and the row renders unthemed. The
outer object needs a distinct id; here the `PanelTheme` is `id: theme` and rows
get `ui: theme`. Watch for this whenever a property name matches an id.

**10. This directory is watched — anything that writes here reloads the plugin.**
`check` originally ran `python3 -m py_compile status.py`, which drops
`__pycache__/` in place, then deleted it again. That was six file events, six
`Local plugin changed, reloading` cycles, and — via gotcha 10 — a widget whose
IPC target answered `Target not found.` afterwards. **Running the test suite
broke the running widget.** `check` now uses `ast.parse` (writes nothing) and
carries a comment forbidding artefacts here; `.gitignore` is a backstop, not a
licence. Verify any new check with:
`journalctl --user -f | grep "Local plugin changed"` — it must stay silent.

**11. Hot-reload does NOT pick up NEW IpcHandler functions.** Editing the body of
an existing handler reloads fine, but adding a function leaves
`omarchy-shell davidszp.rclone <new>` answering `Function not found.` indefinitely —
even after `omarchy-shell shell rescanPlugins`. Cause: with two monitors the
widget is instantiated twice, only one `IpcHandler` per target wins the
registration, and reload does not hand the win to the new instance. Fix is
`omarchy restart shell`. Everything *else* about the plugin genuinely does
hot-reload, which is what makes this one so easy to misread as "my new function
is broken".

## Setup flow

**Google Drive is guided in-panel** (`SetupWizard.qml`): the five Google Cloud
Console steps in order, each with a button that opens the exact console page,
a copy button for the three Drive scopes, and fields for the client ID and
secret. It exists because Drive needs an OAuth client of your own —
rclone's built-in credentials are **being retired during 2026** and are capped
at Google's shared 10 requests/second.

The step the wizard shouts about is **publish the app**. Left in Testing mode,
every grant expires after 7 days and Drive quietly stops working a week later
— the single most common way this setup rots.

Pressing Connect runs `rclone config create <name> drive client_id=… scope=drive`
and lets rclone drive its own OAuth handshake. **The client secret goes over
stdin, not this plugin's argv** — argv is world-readable through `ps`, stdin is not. This
copies the first-party Wi-Fi panel's handling of enterprise passphrases
(`plugins/panels/network/Panel.qml`, `stdinEnabled: true`). If rclone prints the
auth URL rather than opening a browser, `openAuthUrlFrom()` opens it — the same
fallback the Dropbox plugin uses.

Other providers still go to `rclone config` in a floating terminal. Generalising
the wizard means driving `config/create`'s `opt.state`/`opt.result` state machine
and generating forms from `config/providers` for ~70 backends — that is what
rclone's own web GUI does, and it is a project, not a widget.

## Provider icons

`ProviderIcon.qml`, three tiers in order of preference:

1. a **drawn mark** for types with a shape worth drawing — box (isometric
   cube), s3/b2 (bucket), sftp/ftp/webdav (server bars), crypt (padlock),
   local (folder)
2. a **font glyph** where the Nerd Font already has a good, distinct one —
   Google Drive, Dropbox, OneDrive
3. a **monogram badge**, the type's initial in a rounded square

Tier 3 is the point. The previous mapping was a font-glyph lookup that gave
`box`, `s3`, `pcloud` and `zoho` the **same default cloud** — an icon that is
actively wrong rather than merely vague. Nerd Fonts has brand icons for a
handful of services and rclone supports 69, so any fixed table has this failure
built in. A monogram is never wrong and never needs new art.

Drawn rather than shipped as SVG assets because that is the house pattern — the
first-party Dropbox plugin draws its own logo with `Shape`/`ShapePath` — and a
drawn mark inherits the theme colour for free.

## Naming the provider in RECENT

With more than one remote configured, a filename alone does not say where it
came from, so each RECENT row names its provider: `107 B · gdrive`.

**A name, not an icon.** Even with `ProviderIcon` (below) an icon is the wrong
instrument in a dense list — RECENT rows are one line each and a name is read
at a glance without a legend. Icons stay in REMOTES, where the name sits beside
them and teaches the vocabulary.

The provider is derived with `transferRemote()`, which resolves `srcFs` (a
download) or `dstFs` (an upload) against the configured remotes using the same
prefix rule as `mountForRemote` — it must handle both `gdrive:documents` and the
hashed `gdrive{YRXYK}:` that a mount reports.

**This also fixed RECENT lying.** rclone reports checks and bisync listings
through `core/transferred` alongside real transfers — measured: 14 of 77 entries
were `what: "checking"` or `"listing file - Path1"`. They were being shown as if
files had moved. `transferred_rows` now keeps only `what == "transferring"`,
which is also exactly the set that carries an `srcFs`, so every surviving row
can name its provider.

## Verify

```bash
systemctl --user status rclone-rcd.service         # daemon up?
python3 ~/.config/omarchy/plugins/davidszp.rclone/status.py | python3 -m json.tool
omarchy-shell davidszp.rclone status                  # what the LIVE widget thinks
omarchy-shell davidszp.rclone refresh                 # force a poll
omarchy-shell davidszp.rclone setup                   # jump into the Drive wizard
journalctl --user --since "5 min ago" | grep omarchy-shell   # QML errors
```

Mount a remote on demand (through the daemon, so the panel can see it):

```bash
./rclone-rc mount   "gdrive,skip_gdocs=true:"  ~/GDrive
./rclone-rc unmount ""                         ~/GDrive
./rclone-rc pin     "gdrive,skip_gdocs=true:"  ~/GDrive   # restore at login
./rclone-rc unpin   ""                         ~/GDrive
./rclone-rc copy    "gdrive:docs"  ~/Documents           # additive
./rclone-rc copy    "gdrive:docs"  ~/Documents  dry      # preview only
./rclone-rc mirror  "gdrive:docs"  ~/Documents  dry      # DELETES at dest
./rclone-rc stop    <jobid>
```

Before committing anything:

```bash
./check      # tests, syntax, manifest, orphaned components
```

`check` cannot see QML errors — QML only fails at instantiation. After a QML
change also run `omarchy restart shell`, then open the panel while watching
`journalctl --user -f | grep omarchy-shell`.

`omarchy-shell davidszp.rclone status` is the check that matters: it returns
`Model.statusText()` computed from a real parsed payload, so a sensible answer
proves the whole chain — widget → service → helper → rc → daemon.

Saving any file here hot-reloads the plugin; no restart needed.

## Moving a mount

The move button on a mounted remote opens the same form prefilled with the
**current** folder. It is one action, and the login pin moves with it.

rclone cannot relocate a live FUSE mount, so underneath this really is unmount +
mount — the point is that you do not have to do those three steps (unmount,
mount elsewhere, re-pin) yourself, with a window in between where the pin still
names a folder that no longer exists. `rclone-rc remount` does the pair in one
process and `repin` rewrites the pin file in a single atomic write.

Two things it must not do, both learned the hard way:

- **It reuses the live mount's own fs** (e.g. `gdrive{YRXYK}:`) rather than
  recomposing one from the form. The Google Docs switch is hidden while moving,
  so recomposing could silently change a mount's options with nothing on screen
  to show it.
- **It verifies the unmount instead of trusting it.** `mount/unmount` returned
  `{}` — success — while the mountpoint stayed live; the follow-up mount then
  produced *two* mounts of the same remote. `unmount_verified()` now checks
  `mountpoint -q`, falls back to `fusermount3 -u`, and aborts the move rather
  than mounting a second copy. The plain unmount path uses it too.

  **It is not reproducible.** 19 controlled trials across four hypotheses, all
  clean: recent read before unmounting (6), two mounts of one fs (3), a
  connection-string mount reported back hashed as `utest{12rtk}:` (4), and a
  network backend with an active VFS cache (3, on Box), plus the local-backend
  baseline. So the defence stands on the single observation, and the cause is
  unknown. If it recurs, the useful detail to capture is what else was touching
  that mountpoint at the time — every hypothesis about rclone itself failed.

## Unsynced writes

With `--vfs-cache-mode full` a write lands in the local cache and is uploaded
afterwards. Unmounting or moving the mount in that window can drop it — and the
`fusermount3 -u` fallback in `unmount_verified` is a FORCED unmount that
bypasses rclone entirely, so it is the one path that can actually lose data.

`rclone-rc` therefore checks `vfs/queue` first and **refuses**, rather than
warning and proceeding:

```
$ rclone-rc unmount "" ~/Busy
3 file(s) not yet uploaded from /home/you/Busy — wait, or force
exit 2                        # mount still live, nothing lost
```

`force` as the last argument overrides it. Moving refuses the same way and
leaves nothing half-done — no stub directory, original still mounted.

The panel shows this **only while it is true**: the row's subtitle turns urgent
and reads `· N not uploaded yet`, with a warning glyph beside the actions. A
badge that is always present stops being read, so it appears when there is
something to lose and is invisible otherwise.

The count comes from `status.py --pending <mountpoint>`, which reuses the same
code path as the panel. An earlier version re-implemented the lookup in bash and
silently returned 0 behind a `|| echo 0` fallback, so the guard never fired —
one implementation, used by both.

Moving is refused when the path is unchanged, so the button cannot trigger a
pointless unmount/remount cycle. Anything holding a file open under the old path
sees it disappear, exactly as a manual unmount would.

## Automatic mounts

Login mounts are declared in `~/.config/rclone/omarchy-automounts.json`:

```json
[ { "fs": "gdrive,skip_gdocs=true:", "mountPoint": "/home/you/GDrive" } ]
```

Pressing mount on an unmounted remote opens an **inline form under that row** —
mount path (prefilled `~/<remote>`), a "mount at login" toggle, and, for `drive`
remotes only, a "hide Google Docs" toggle. It composes the connection string and
mounts, pinning in the same action if asked. Inline rather than a second popup:
a popup inside a popup is easy to lose at this width, and the form belongs
visually to the row that spawned it.

Any open form takes the keyboard — otherwise `r`/`c`/`a` would be swallowed as
panel shortcuts while typing a path — and Escape unwinds one layer at a time
(form → wizard → panel).

The pin button on an already-mounted remote writes the entry directly
(`rclone-rc pin|unpin`, atomic write). `Service.reconcileMounts()` then
re-applies anything missing after **every** status refresh.

**Why a reconcile and not a systemd oneshot.** The mounts live inside rcd, not
the shell. If rcd restarts — a crash, `Restart=on-failure`, an rclone upgrade —
every mount it owned is silently gone, and a `Type=oneshot` unit that already
ran will never notice. Measured: restarting `rclone-rcd.service` dropped
`~/GDrive`, and the widget restored it unaided **20 seconds later**. Reconciling
costs nothing when there is nothing to do, and mounts one at a time so a slow
remote cannot stall the rest.

## Connecting other providers

Drive has a wizard because ~10 minutes of its setup happens in Google's console,
where rclone cannot reach. **Every other OAuth backend needs no such guidance** —
their docs say "leave blank normally", so rclone can drive the whole thing.

The panel does drive it, via `rclone-config` + `ProviderFlow.qml`. There is no
per-provider code: rclone returns a question with `Help`, a `Default`, optional
`Examples` and a `Required` flag, and the panel renders that. Connecting Box
shows rclone's own wording and a Yes/No pair built from its Examples.

**What actually needed the loop.** Not the browser handshake — a one-shot
`config create` already opens the browser (that is how Drive works here). It is
the step *after* authenticating: OneDrive's state is `*oauth-islocal,choose_type,,`,
meaning it still has to ask which drive, fetched live from the API. Answering
that silently would connect you to the wrong drive with no indication.

Non-OAuth backends never enter the machine at all — measured: `s3`, `b2`,
`webdav`, `sftp`, `crypt` all return done on the first call, because their
options are ordinary key=values. So the loop is only ever walked by OAuth flows.

**Verified with a real account, 2026-08-15:** Box connected entirely from the
panel — rclone's built-in client_id, no console work, no terminal. The resulting
remote lists real folders and probes to `586.1 MB used of 53.7 GB`. Also stepped
Drive's machine with no authentication (`client_id_warning → client_id_set →
client_secret_set`), and cancelled a flow midway to confirm no partial remote is
left behind.

**Still unexercised:** Box's state is `*oauth-islocal,,,` — nothing follows the
handshake. So this proves the loop *through* OAuth, but NOT the post-auth picker
branch. OneDrive's `choose_type` (which drive?) remains untested, and that is the
branch the loop exists for.

```bash
omarchy-shell davidszp.rclone connect box    # start a flow by backend type
omarchy-shell davidszp.rclone flowAsks       # what it is currently asking
omarchy-shell davidszp.rclone cancel         # abort and clean up
```

