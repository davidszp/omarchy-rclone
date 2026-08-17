# Implementation notes

Everything that does not belong in a README: how the pieces fit, what the
non-obvious decisions were, and the traps that cost time. Written for whoever
touches this next.

**If you are here to change something,** the sections are in reading order:
*Architecture* for where things live, *Working on this* for how to test it, then
*Gotchas* before trusting anything you cannot see fail. The gotchas are not
trivia — most of them are the reason some piece of code looks the way it does,
and several describe failures that produce no error at all.

The short version: **QML fails silently.** A rule that parses is not a rule that
matches, a hot reload is not a restart, and a command that exits 0 has not
necessarily done anything.

## Architecture

One `rclone rcd` daemon owns everything, and the plugin asks it one question.
The alternative — a separate `rclone mount` per remote, each with its own
`--rc-addr` — means polling N ports and still seeing nothing from ad-hoc
`rclone sync` runs. So: **start jobs through the daemon** (`sync/copy`,
`mount/mount` with `_async=true`) and they all show up in one place.

```
Panel.qml → Service.qml → status.py → rcclient.py → HTTP over a unix socket → rclone rcd
```

Where things live. `Panel.qml` owns layout and the keyboard cursor and nothing
else; `Service.qml` owns all state and every subprocess; `Model.js` is pure
logic with no QML imports, which is the only reason it can be unit tested.
Five pieces are split out because they change for their own reasons:

| file | what it owns |
|---|---|
| `PanelIpc.qml` | the scripting surface (`omarchy-shell <id> <fn>`), also how the tests drive the live widget |
| `ConfigFlow.qml` | one run through rclone's interactive config machine, including cleanup of the half-made remote a failure leaves behind |
| `rcclient.py` | the ONLY thing that talks to the rc API — HTTP, with the password in a header and parameters in the body (see "Keeping credentials out of argv") |
| `AddRemoteSection.qml` | "Add a remote", the cloud grid, and the extra question some backends need first |
| `BackendForm.qml` | the generated form for backends with no interactive setup |

The shell runs a Python helper rather than speaking HTTP from QML, because that
is the grain of every first-party Omarchy plugin (Dropbox shells to a Python
helper, Tailscale to the CLI) and there is no `XMLHttpRequest` anywhere in the
Omarchy shell. Inside that helper the rc calls are plain HTTP via `rcclient.py`;
they used to shell out again to `rclone rc`, which leaked the daemon password
into argv on every poll.

The daemon runs as `~/.config/systemd/user/rclone-rcd.service`, with its bind
address and credentials in `~/.config/rclone/rcd.env` (0600), shared with
`status.py`. rclone maps every `--rc-*` flag to a `RCLONE_RC_*` env var, so
the unit needs no flags beyond `EnvironmentFile`.

It listens on a **unix socket** at `$XDG_RUNTIME_DIR/rclone-rcd.sock`, not a
loopback port. `/run/user/<uid>` is mode 0700, so the filesystem keeps every
other user out; the unit sets `UMask=0077` so the socket itself is 0600 too. A
loopback port would be different in kind: it is not uid-restricted, so any local
user can connect and attempt auth, with only the password in the way. The
password stays regardless — two independent barriers for the cost of one header.
A TCP address in `rcd.env` still works, and `setup-daemon.sh` migrates the old
default to a socket (restarting the daemon, because otherwise it would keep
listening on the port while the plugin looked for a socket).

**Security:** rclone's docs are blunt — "access to the rc API is equivalent to
shell access as the user running rclone". Hence loopback-only *and*
`--rc-user`/`--rc-pass` with a random password, rather than `--rc-no-auth`. A
local web page cannot POST to an authenticated endpoint.

**Nothing sensitive may go in argv, ever** — `/proc/<pid>/cmdline` is readable by
every local process, so an argument is public for as long as the command runs.
That rules out the obvious `rclone rc --user U --pass P` and
`rclone config create … pass=…`, so all rc traffic goes through `rcclient.py`,
which puts the password in an `Authorization` header and the parameters in the
request body. See "Keeping credentials out of argv".

`config dump` is read directly from the config file (no daemon needed), and only
`name` + `type` are copied into the payload, plus an `incomplete` flag for a
section that has a type and nothing else — **never** the OAuth tokens and
passwords that live in the same blocks. Sections with no type at all are not
remotes; see gotcha 12.

## Two cost tiers

| Tier | What it does | Cadence |
|---|---|---|
| fast (default) | local config read + `core/stats`, `core/transferred`, `mount/listmounts`, `job/list` | 2s while transferring, 30s idle (configurable) |
| `--probe` | adds `operations/about` **per remote** — a network round-trip each | only on the user pressing the check button |

The two intervals exist because a live transfer wants a moving progress bar
and an idle daemon wants to be left alone. Polling idle at 2s would spawn a
subprocess every 2s forever to re-read a number that never changes.

## Working on this

`./check` runs everything below plus syntax, `omarchy plugin validate`, and a
warning for any `.qml` no other file references. **Run it before committing**; it
must be green, and it must leave no file behind in this directory (gotcha 10).

| test | needs | covers |
|---|---|---|
| `test/model-test.js` | node | all of `Model.js` — pure logic, no QML imports |
| `test/status-test.py` | python3 | `status.py`'s pure functions (dict in, dict out) |
| `test/glyph-coverage.py` | python3 | every Nerd Font codepoint the QML draws actually exists |
| `test/remote-lifecycle-test.sh` | rclone + fusermount3 | add → mount → remove, against its own daemon in a temp `HOME`; also asserts no credential reaches argv |
| `test/panel-test.sh` | a running Omarchy shell | drives the LIVE widget over IPC |

The last two **skip with exit 0** when their dependency is missing, so `check`
stays runnable on a machine with no session. A skip is not a pass — if you touch
mounting or removal, run the lifecycle test on a machine that has rclone.

**Put new logic where it can be tested.** `Model.js` imports no QML, which is the
only reason it is unit-testable; `status.py` keeps its pure transforms as
module-level functions for the same reason. Anything that shells out or holds QML
state can only be reached by the last two tests, which are slower and skippable —
so prefer a pure function called from a thin wrapper.

**`check` cannot see QML errors,** because QML only fails at instantiation. After
a QML change: `omarchy restart shell`, then open the panel while watching
`journalctl --user -f | grep omarchy-shell`. Editing an existing function
hot-reloads on save, but **adding one needs the restart** (gotcha 11), so restart
by default rather than wondering.

The single most useful smoke test — it exercises widget → service → helper → rc →
daemon in one call, so a sensible answer means the whole chain is intact:

```bash
omarchy-shell io.github.davidszp.omarchy-rclone status
```

Other handles for poking at a live install:

```bash
systemctl --user status rclone-rcd.service                    # daemon up?
python3 status.py | python3 -m json.tool                      # the whole payload
omarchy-shell io.github.davidszp.omarchy-rclone refresh       # force a poll
omarchy-shell io.github.davidszp.omarchy-rclone setup         # jump into the Drive wizard
omarchy-shell io.github.davidszp.omarchy-rclone connect box   # start a provider flow
omarchy-shell io.github.davidszp.omarchy-rclone flowAsks      # what it is asking now
omarchy-shell io.github.davidszp.omarchy-rclone cancel        # abort it and clean up
```

Driving the daemon by hand, the way the panel does (so the panel can see it):

```bash
./rclone-rc mount   "gdrive,skip_gdocs=true:"  ~/GDrive
./rclone-rc unmount ""                         ~/GDrive
./rclone-rc pin     "gdrive,skip_gdocs=true:"  ~/GDrive   # restore at login
./rclone-rc copy    "gdrive:docs"  ~/Documents  dry      # preview; omit dry to run
./rclone-rc mirror  "gdrive:docs"  ~/Documents  dry      # DELETES at dest
./rclone-rc remove-remote gdrive                         # unmount, unpin, delete config
./rclone-rc stop    <jobid>
```

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
clear the daemon-wide numbers (measured: global `errors` stayed at 1 after
resetting the offending group), and stopping a job on purpose *increments*
`errors` — so a status line built on it badges "1 error" forever for something
the user chose to do. `statusText()` ignores the cumulative counter entirely;
errors surface per job in JOBS and per file in RECENT, where they name the thing
that failed.

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
on a `property var` leaves every binding that reads it holding the old value,
with no error anywhere — it empties the output of every command that does it.
`CommandRunner` accumulates into a `property string`, which notifies on
assignment and cannot regress the same way. Either reassign
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

**10. This directory is watched — anything that writes here reloads the plugin,
and enough reloads break the running widget** (its IPC target starts answering
`Target not found.`, per gotcha 11). `python3 -m py_compile` is the trap: it
drops `__pycache__/` here, so running the test suite used to knock the live
widget out. Checks must write nothing into this directory — `check` uses
`ast.parse`, and `.gitignore` is a backstop, not a licence. Verify any new check
with `journalctl --user -f | grep "Local plugin changed"`; it must stay silent.

Tests that need scratch files put them in a temp dir instead — see
`test/remote-lifecycle-test.sh`, which runs a whole daemon out of `mktemp -d`.

**11. Hot-reload does NOT pick up NEW QML functions.** Editing the body of an
existing function reloads fine; *adding* one does not take effect at all, even
after a logged `Local plugin changed, reloading` and an
`omarchy-shell shell rescanPlugins`. A new `IpcHandler` function answers
`Function not found.` indefinitely; a new plain function on `Service` silently
never runs. Cause: with two monitors the widget is instantiated twice, only one
instance per target wins registration, and a reload does not hand the win to the
new one. **Fix is `omarchy restart shell`.** Everything else here genuinely does
hot-reload, which is what makes this so easy to misread as broken code.

**12. `fusermount3 -u` orphans the daemon's VFS, and an orphaned VFS resurrects
a deleted remote.** The chain, measured against rclone 1.75:

* `mount/unmount` shuts the VFS down and it leaves `vfs/list`. A forced
  `fusermount3 -u` removes the *kernel* mount only — the mount disappears from
  `mount/listmounts` while its VFS stays **active for the lifetime of the
  daemon**. Nothing in the rc API can shut it down again: `vfs/forget` is the
  directory cache, `fscache/clear` does not touch active VFSes, and re-mounting
  then unmounting cleanly only drops the *new* reference. Only restarting
  `rclone-rcd.service` clears it.
* An orphan keeps polling, so it keeps refreshing its OAuth token, and rclone
  writes each refreshed token back into the config file.
* After the section has been deleted, that write **re-creates the section** —
  holding a `token` and no `type`.

So: **a config section with no `type` is never a half-made remote.** A real
abandoned setup keeps its type — `rclone config create <name> <type>` writes the
section and its `type` in the same write, leaving exactly `[db]` +
`type = dropbox`, which is what `incomplete` means and what the panel offers to
remove (finishing one is `rclone-config resume`, CLI only). And
`config update <name> --continue` refuses a name not already in the file
(*"couldn't find type field in config"*). A typeless section can therefore only
be write-back residue. `classify_config()` reports those separately from remotes,
never shows or probes them, and `rclone-rc reap-residue` deletes them —
`remove-remote` sweeps after its own delete, and the panel sweeps whenever
`configResidue` is non-empty.

Reading "no type" as "setup never finished" instead is what produced the zombie
rows: an undeletable remote per removal, because each delete was undone by the
next token refresh.

**Fingerprint if it recurs:** `vfs/list` naming a remote that
`config/listremotes` does not. `systemctl --user restart rclone-rcd.service` is
the only cure for the orphan itself.

## Keeping credentials out of argv

Reported by the marketplace reviewer (HANCORE-linux/omarchy-plugin-marketplace
#441): backend answers were passed as arguments, so provider credentials could be
read from the local process list during configuration. Confirmed, and the search
that followed found a second, larger instance of the same mistake.

**Why an argument is not private.** `/proc/<pid>/cmdline` is world-readable, so
any local process — another user, a sandboxed app, a service account — can poll
the process list and read an argument for as long as the command runs. Measured
with a plain `/proc` poller:

    rclone config create leaktest sftp host=example.com user=bob pass=hunter2secret

Three paths were affected, in ascending order of how bad they were:

| what leaked | where | for how long |
|---|---|---|
| the Drive client secret | `rclone config create client_secret=…` | one call |
| every `BackendForm` value — SFTP/WebDAV/FTP passwords, S3 secret keys | `rclone-config` argv, then `config create key=value` | one call |
| **the rcd password** | `rclone rc --user … --pass …` | **every poll, every 2–30s, forever** |

The third was not in the report and is the worst of the three: that password *is*
the security boundary the `--rc-user`/`--rc-pass` setup exists to create, and it
was being published continuously by the status poll.

**The fix.** `rcclient.py` is now the only thing that speaks to the daemon. The
password goes in an `Authorization` header, parameters go in the request body, and
argv carries at most a method name. The config flow moved from the `rclone config`
CLI to the rc API, whose `config/create` accepts the *same* state machine
(`opt.state` / `opt.result` / `continue`), so `rclone-config` kept its shape while
values moved to stdin: `start`/`connect` read `{"parameters": {…}}` and `next`
reads `{"result": …}`. `rclone-config` is Python now because it builds and parses
JSON around credentials, and quoting those through a shell is the same class of
mistake.

Two things that had to be checked rather than assumed, because they are silent
behaviour changes:

- **`rclone rc key=value` sends every value as a STRING**, even valid JSON —
  measured, the daemon parses it server-side. `rcclient.py`'s CLI path does the
  same, so swapping transports cannot quietly change how a mount is configured.
- **The OAuth handshake now runs inside the daemon**, not in a child process of
  ours, so its output is no longer ours to read. The daemon does open the browser
  itself (verified), but if it cannot, the auth URL would exist only in its log.
  `config/oauthstatus` returns that URL, so Service polls it while a step is in
  flight and opens it. `abort` also calls `config/oauthstop`, which fixes a
  pre-existing leak: an abandoned flow used to leave rclone's callback server
  listening on :53682, where it refuses the next flow's handshake.

Passwords are still obscured on disk exactly as before: the rc API obscures a
plain value on its own, like `config create --non-interactive` did, so no
`obscure` flag is passed — declaring it again risks obscuring twice.

**VERIFIED ON A REAL SIGN-IN.** `test/secret-trace.py` ran through an actual
Google Drive setup — console credentials pasted into the wizard, browser
handshake, mount — sweeping every process's argv and environment every 20ms:

    4497 process sweeps
    CLEAN — no credential seen in any process's arguments or environment,
            in the journal, or in any world-readable file.

The credentials existed in exactly one place afterwards, `rclone.conf` at mode
0600. For scale: a planted decoy is caught 200+ times in a few seconds, and the
old code held the value for a whole call, so the pattern this replaces would have
shown up in hundreds of sweeps rather than none.

**The regression test is in `test/remote-lifecycle-test.sh`** ("credentials never
reach argv"): it polls `/proc` while a remote is created and asserts that no
process holds the value. The marker reaches both the watcher and the request
builder through the *environment*, so the test cannot trip over its own argv —
verified to fail (`expected 0, got 2`) when pointed back at the old CLI form.

### The rest of the audit

Everything below was measured while checking the fix, not assumed.

**Three more channels, all closed:**

- **A failed rc call echoes the request back.** The 500 body is
  `{"error": …, "input": {"parameters": {"pass": "hunter2"}}, …}`, and an error
  string ends up in the panel's status line. `rcclient.call` therefore reads
  *only* the `error` field — never the raw body — and scrubs any value we sent
  under a sensitive-looking key out of it, because rclone is free to quote the
  offending value in its own wording.
- **The form displayed secrets in clear text.** Masking used rclone's
  `IsPassword`, which it does not set for `s3 secret_access_key`, `b2 key`,
  `webdav bearer_token`, `sftp key_pem` or `drive client_secret` — all of which
  report `Sensitive: true` instead. `provider_fields` now masks on either flag.
  It deliberately does not also match on field NAME: that would hide `key_file`
  and `pubkey_file`, which are paths the user needs to read back.
- **The daemon's own credentials are fine.** They arrive by `EnvironmentFile`, so
  they live in its environment, and `/proc/<pid>/environ` is owner-only, unlike
  `cmdline`. `ExecStart` carries no secret, and the daemon's log records only the
  error message, not the parameters (checked against the live journal).

**One exposure that cannot be closed, and is not the panel's:** the IPC
scripting surface takes its argument on a command line, so
`omarchy-shell io.github.davidszp.omarchy-rclone answer <value>` puts that value
in the argv of `omarchy-shell` and `qs ipc`. Typing into the panel does not go
near a command line. Do not paste a credential into that IPC call — it exists for
testing.

**Where the remaining trust sits:** `rcclient` sends the password to whatever
`RCLONE_RC_ADDR` in `rcd.env` names. That file is 0600 and written by
`setup-daemon.sh`, and anything able to rewrite it could already read the
password out of it, so this adds no exposure — but it does mean the address is
not hardcoded, and a review that assumes loopback should check the file.

Verified with the marketplace's own scanner (`scripts/security-baseline-scanner.mjs`
run against the pushed commit): no findings, and the same four capabilities as
before — this work added no new ones.

## Setup flow

**Google Drive is the one provider with a hand-written wizard**
(`SetupWizard.qml`), because ~10 minutes of its setup happens in Google's console
where rclone cannot reach: it needs an OAuth client of your own, rclone's
built-in credentials being retired during 2026. Two details in it are load-bearing
rather than decorative — the **publish-the-app** warning (left in Testing mode,
Google expires every grant after 7 days, so Drive stops working a week later),
and the copy button for the three scopes.

Pressing Connect runs `rclone config create <name> drive client_id=… scope=drive`
and lets rclone drive its own OAuth handshake. The client secret reaches our
wrapper over **stdin**, so it is never in this plugin's argv nor in shell history
— the same handling as the first-party Wi-Fi panel
(`plugins/panels/network/Panel.qml`, `stdinEnabled: true`).

`rclone-config` then forwards it to the daemon in an HTTP body, so it is in no
process's argv at any point — see "Keeping credentials out of argv" below for
what that replaced and why.

Every other provider is set up **inside the panel**, with no per-provider code —
see "Connecting other providers" below. `rclone config` in a floating terminal
remains in the grid as the escape hatch for the backends the grid does not list.

## Provider icons

`ProviderIcon.qml`, three tiers: a **drawn mark** where the shape is worth
drawing (box, s3/b2, sftp/ftp/webdav, crypt, local), a **font glyph** where the
Nerd Font has a good distinct one (Drive, Dropbox, OneDrive), otherwise a
**monogram badge** of the type's initial.

Adding a provider therefore needs no art. **Do not replace this with a fixed
glyph table:** rclone supports 69 backends and Nerd Fonts has brand icons for a
handful, so every such table ends up mapping `box`, `s3`, `pcloud` and `zoho` to
the same default cloud — an icon that is actively wrong rather than vague. Marks
are drawn with `Shape`/`ShapePath` rather than shipped as SVGs, which is the
house pattern (so does the first-party Dropbox plugin) and inherits the theme
colour for free.

## RECENT rows

Each row names its provider (`107 B · gdrive`), because a filename alone does not
say where it came from. A **name, not an icon** — rows are one line each, and a
name is read without a legend; icons stay in REMOTES where the name sits beside
them.

Two constraints if you touch `transferred_rows` or `transferRemote()`:

- The provider is resolved from `srcFs` (download) or `dstFs` (upload) with the
  same prefix rule as `mountForRemote`, so it must handle both `gdrive:documents`
  and the hashed `gdrive{YRXYK}:` a mount reports (gotcha 6).
- **Only `what == "transferring"` may be listed.** rclone reports checks and
  bisync listings through `core/transferred` too (measured: 14 of 77 entries were
  `"checking"` or `"listing file - Path1"`), and showing those claims files moved
  when nothing did. It is also exactly the set that carries an `srcFs`.

## Moving a mount

rclone cannot relocate a live FUSE mount, so moving one is really unmount +
mount. `rclone-rc remount` does the pair **in one process**, and `repin` rewrites
the pin file in a single atomic write — otherwise there is a window where the pin
names a folder that no longer exists.

Two things it must not do:

- **It reuses the live mount's own fs** (e.g. `gdrive{YRXYK}:`) rather than
  recomposing one from the form. The Google Docs switch is hidden while moving,
  so recomposing could silently change a mount's options with nothing on screen
  to show it.
- **It verifies the unmount instead of trusting it.** `mount/unmount` returned
  `{}` — success — while the mountpoint stayed live, and the follow-up mount then
  produced *two* mounts of the same remote. `unmount_verified()` checks
  `mountpoint -q`, retries, and aborts the move rather than mounting a second
  copy. The plain unmount path uses it too.

  Do not simplify this away as paranoia: it rests on one real observation that
  19 controlled trials could not reproduce (repeat reads, double mounts, hashed
  connection strings, a network backend with a live VFS cache), so the cause is
  still unknown. Every hypothesis about rclone itself failed — if it recurs, the
  detail worth capturing is what else was touching that mountpoint.

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

`force` as the last argument overrides it. Moving refuses the same way and leaves
nothing half-done — no stub directory, original still mounted. In the panel the
row's subtitle turns urgent (`· N not uploaded yet`) only while it is true; a
badge that is always there stops being read.

The count comes from `status.py --pending <mountpoint>` — one implementation, used
by both the guard and the panel. **Do not re-implement it in bash:** behind the
`|| echo 0` fallback a shell version needs, any mistake reads as "nothing
pending" and the guard silently never fires.

## Automatic mounts

Login mounts are declared in `~/.config/rclone/omarchy-automounts.json`:

```json
[ { "fs": "gdrive,skip_gdocs=true:", "mountPoint": "/home/you/GDrive" } ]
```

Pressing mount opens an inline form under that row (path, "mount at login", and
"hide Google Docs" for `drive` only), composes the connection string, and pins in
the same action if asked. Inline rather than a nested popup, which is easy to lose
at this width.

**Any open form takes the keyboard**, or `r`/`c`/`a` get swallowed as panel
shortcuts while typing a path, and Escape unwinds one layer at a time
(form → wizard → panel). Keep both properties in any new input.

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

Everything except Drive is set up in-panel with **no per-provider code**, on one
of two paths. Adding a provider means adding a row to `PROVIDERS` in `Model.js`
and nothing else; if it needs a value rclone never asks for, give it a `seed`
(zoho refuses to start without `region`).

| path | for | how |
|---|---|---|
| `rclone-config` + `ProviderFlow.qml` | OAuth backends | steps rclone's config state machine; it returns a question with `Help`, `Default`, `Examples` and `Required`, and the panel renders that |
| `BackendForm.qml` | backends with no interactive setup (`form: true`) | generates a form from `config/providers`, passes the answers as seeds to one `config create` |

Measured: `s3`, `b2`, `webdav`, `sftp` and `crypt` all return done on the first
call, so **only OAuth flows ever walk the state machine**. Two traps in the
generated form: rclone's `Required` flag is not the whole story (s3 marks nothing
required, because it depends on which provider you pick — so the form leads with
the first few fields when a backend declares none), and password fields need no
special handling because `config create --non-interactive` obscures them itself.

**Where help is most useful:** the post-auth branch is covered by a fixture, not
an account. `test/fixtures/onedrive-like.json` walks islocal → type → org picker →
drive id → secret through the real widget, which proves our half. That rclone's
actual `choose_type` output matches the fixture's shape is **unverified** — only
a real OneDrive account settles it. Box is the one flow confirmed end to end
against a live account.

Step a flow by hand with the `connect` / `flowAsks` / `cancel` handles above.

