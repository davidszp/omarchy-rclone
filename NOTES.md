# Implementation notes

For whoever changes this next. Sections are in reading order: *Architecture* for
where things live, *Working on this* for how to test it, then *Gotchas* — which are
not trivia, they are mostly the reason some piece of code looks the way it does,
and several describe failures that produce no error at all.

The short version: **QML fails silently.** A rule that parses is not a rule that
matches, a hot reload is not a restart, and a command that exits 0 has not
necessarily done anything.

Two rules with teeth, before you touch anything: **no credential may ever go in
argv** (*Credentials*), and **nothing may write into this directory** (gotcha 10).

## Architecture

One `rclone rcd` daemon owns everything. The alternative — a separate
`rclone mount` per remote — means polling N ports and still seeing nothing from an
ad-hoc `rclone sync`. So **start every job through the daemon** (`sync/copy`,
`mount/mount` with `_async=true`) and it all shows up in one place.

```
Panel.qml → Service.qml → status.py → rcclient.py → HTTP over a unix socket → rclone rcd
```

`Panel.qml` owns layout and the keyboard cursor and nothing else. `Service.qml`
owns all state and every subprocess. `Model.js` is pure logic with no QML imports,
which is the only reason it can be unit tested. Five files are split out because
they change for their own reasons:

| file | what it owns |
|---|---|
| `PanelIpc.qml` | the scripting surface (`omarchy-shell <id> <fn>`), also how the tests drive the live widget |
| `ConfigFlow.qml` | one run through rclone's config state machine, including cleanup of the half-made remote a failure leaves |
| `rcclient.py` | the ONLY thing that talks to the rc API (see *Credentials*) |
| `AddRemoteSection.qml` | "Add a remote", the provider grid, and the extra question some backends need first |
| `BackendForm.qml` | the generated form for backends with no interactive setup |

QML shells out to a Python helper rather than speaking HTTP itself: that is the
grain of every first-party Omarchy plugin, and there is no `XMLHttpRequest` in the
Omarchy shell at all.

**The daemon** is `~/.config/systemd/user/rclone-rcd.service`, with its address and
credentials in `~/.config/rclone/rcd.env` (0600). rclone maps every `--rc-*` flag to
a `RCLONE_RC_*` env var, so the unit needs nothing but `EnvironmentFile`. It listens
on a **unix socket** at `$XDG_RUNTIME_DIR/rclone-rcd.sock`: that directory is 0700,
so no other user can reach it, and `UMask=0077` makes the socket 0600 too. A
loopback port is different in kind — not uid-restricted, so any local user could
connect and attempt auth. Auth stays anyway; rclone's docs are blunt that "access
to the rc API is equivalent to shell access as the user running rclone". A TCP
address in `rcd.env` still works, and `setup-daemon.sh` migrates the old default.

**Two polling tiers,** because a live transfer wants a moving progress bar and an
idle daemon wants to be left alone:

| tier | what it does | cadence |
|---|---|---|
| fast (default) | local config read + `core/stats`, `core/transferred`, `mount/listmounts`, `job/list` | 2s transferring, 30s idle |
| `--probe` | adds `operations/about` **per remote** — a network round-trip each | only when the user presses check |

`config dump` is read straight from the config file, and only `name` + `type` reach
the payload, plus an `incomplete` flag — **never** the tokens and passwords in the
same blocks.

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

`omarchy-shell io.github.davidszp.omarchy-rclone status` is the smoke test worth
knowing: it runs widget → service → helper → rc → daemon, so a sensible answer
means the whole chain is intact. `IPC=…` below stands for that same prefix.

```bash
python3 status.py | python3 -m json.tool   # the whole payload the panel sees
$IPC refresh | setup | connect box         # force a poll / open the wizard / start a flow
$IPC flowAsks | cancel                     # what a flow is asking, and abort it
./rclone-rc mount "gdrive,skip_gdocs=true:" ~/gdrive     # drive the daemon by hand,
./rclone-rc pin   "gdrive,skip_gdocs=true:" ~/gdrive     # the way the panel does, so
./rclone-rc mirror "gdrive:docs" ~/Documents dry         # the panel can see it
./rclone-rc remove-remote gdrive                         # unmount, unpin, delete config
```

`rclone-rc` without arguments lists every verb.

## Gotchas — do not re-derive these

**1. Every rc call is itself a job,** so `job/list` grows one entry per poll
forever and `runningIds` always holds the `job/list` call in flight — an idle
daemon reports `runningIds: [5]`. Subtracting that one call is not enough either:
ANY hung rc call sits in `runningIds`, and two `operations/about` probes stuck
dialling an unroutable host had the bar claiming "2 jobs running" for hours while
the JOBS list was empty. **The count is now the list** — `len(payload["jobs"])`. A number the
panel cannot explain is worse than none, and `stats.transferring` remains the
honest activity signal.

**How "ours" is decided:** `rclone-rc` labels every job it starts
`omarchy-rclone/<verb> <src> -> <dst>`, and the reader filters on that prefix. The
prefix is the identity; the rest is the display label, which `job_rows` strips so
nothing downstream knows about it. The filter used to be
`startswith(("copy ", "mirror ", "bisync "))`, which made the **verb** the
identity — add one and two filters in two languages silently stop matching it, and
any other tool's job labelled `copy …` counted as ours. The literal lives in both
`rclone-rc` and `status.py`; `test/status-test.py` reads the shell file and asserts
they agree, because a typo there shows no jobs and stops nothing. `stop-all` also
still matches the legacy verb forms, deliberately: a transfer started before an
upgrade is still running, and not stopping it would be worse than matching widely.

**2. `core/stats` is cumulative for the daemon's lifetime, not per job.** A
progress bar on the global `bytes / totalBytes` drifts wrong the longer it runs.
`rclone-rc` labels every copy/mirror with `_group` and `status.py` reads
`core/stats?group=…`. Two traps: `core/stats-reset group=…` does **not** clear the
daemon-wide numbers, and *stopping a job increments `errors`*, so anything built on
that counter badges an error forever for something the user chose to do.
`statusText()` ignores it; errors surface per job and per file instead.

**3. The IpcHandler "another handler is registered" warning is not yours.** Bar
widgets are instantiated once per monitor, so every widget with an `IpcHandler`
logs it — including all the first-party ones. Benign.

**4. `OMARCHY_PATH` cannot find a third-party plugin's own files** — it does not
live under it. Use `Qt.resolvedUrl(".")`, as `Service.qml` does.

**5. `omarchy bar set … --json` cannot store structured values.** Its argument
splitting breaks on the commas inside JSON. A two-element array errors; a
one-element array **appears to succeed** while storing the inner object unwrapped,
so `Array.isArray()` is false on the way back and the feature silently does
nothing. That silent success is why the mount list lives in its own file. Scalars
are fine; anything with a comma is not.

**6. rclone rewrites connection strings in `mount/listmounts`.** Mount
`gdrive,skip_gdocs=true:` and it comes back as `gdrive{YRXYK}:`. Matching a mount
to its remote cannot use equality or a `name,` prefix — `mountForRemote()` accepts
the name followed by `:`, `,` or `{`. Test changes against `gdrivebackup:`, which
must NOT match `gdrive`.

**7. Mutating a `property var` array emits no change signal.** `arr.push(x)`
leaves every binding holding the old value, with no error anywhere. Reassign
(`arr = arr.concat([x])`) or use a `property string`, as `CommandRunner` does.

**8. A config step with no question is not the end of a flow.** rclone's state
strings are a stack (`*oauth-islocal,choose_type,,` = after oauth, still do
choose_type) and it returns steps with a `State` but a null `Option`. A flow is
finished only when **State is empty**. Treating "no Option" as done truncated
OneDrive setup right after sign-in — the remote got a token but no `drive_id`, and
mounting failed. `rclone-config` auto-continues through question-less states.

To finish such a remote without another browser login:
`rclone config update <name> --non-interactive` resumes at `*oauth-confirm,…`
("Token already configured - replace it?"); answering **false** skips to the picker.

**9. `ui: ui` inside a delegate binds a property to itself** — Qt reports a
binding loop and the row renders unthemed. The outer object needs a distinct id;
here `PanelTheme` is `id: theme` and rows get `ui: theme`. Watch for this whenever
a property name matches an id.

**10. This directory is watched: anything written here reloads the plugin,** and
enough reloads break the running widget (its IPC target starts answering `Target
not found.`). `python3 -m py_compile` is the trap — it drops `__pycache__` here, so
running the tests used to knock the live widget out. Checks must write nothing
into this directory; tests needing scratch files use `mktemp -d`.

**11. Hot-reload does NOT pick up NEW QML functions.** Editing a function's body
reloads fine; *adding* one does not take effect at all, even after a logged
`Local plugin changed, reloading`. A new `IpcHandler` function answers `Function
not found.`; a new plain function silently never runs. **Fix is `omarchy restart
shell`** — do that by default rather than doubting your code.

**12. `fusermount3 -u` orphans the daemon's VFS, and an orphan resurrects a
deleted remote.** `mount/unmount` disposes the VFS; the forced unmount removes
only the kernel mount and leaves the VFS running for the daemon's lifetime, where
nothing in the rc API can stop it. An orphan keeps polling, so it keeps refreshing
its OAuth token, and rclone writes that token back — re-creating a section that was
deleted, with a `token` and no `type`.

So **a section with no `type` is never a half-made remote**: `config create` writes
the type in the same write, and `config update --continue` refuses an unknown name,
so a typeless section can only be write-back residue. `classify_config()` reports
those separately and `rclone-rc reap-residue` deletes them. Reading "no type" as
"setup never finished" is what produced undeletable zombie rows.

Fingerprint if it recurs: `vfs/list` naming a remote that `config/listremotes` does
not. `systemctl --user restart rclone-rcd.service` is the only cure for an orphan.

**13. `config create` REPLACES a remote of the same name,** discarding its token
without asking. `rclone-config` refuses in `start` and `connect`, and the two
editable name fields block submission. Check against `Service.allRemoteNames`,
which includes residue — those are sections in the same file. Exact matches only:
remote names are case-sensitive, so `Box` and `box` are two remotes.

**14. A failed `config/create` leaves a phantom in the daemon's memory** with
nothing on disk — its `config/dump` lists the remote, the file and the CLI do not.
Existence checks must read the config FILE, or a user who retries a failed setup is
told the name already exists with nothing to resume.

**15. A message must never resize the panel.** The status area is a fixed-height
slot in the REMOTES header precisely for that reason: as its own row in the column
it pushed the whole list down and let it spring back on every message. Bind new
status text to `statusLine` (never `actionStatus`), and do not clear `actionStatus`
from a runner — the timer owns the lifetime. Detail in *What the panel renders*.

**16. `busy` must not include background reads.** It once included the status poll
(every 2s, ~230ms) and the probe (a network round-trip PER REMOTE, started on its
own by `probeIfStale` when the panel opens). Every button gated on `!busy` blinked
its disabled state as a result — and opening the panel then unmounting produced
dim, undim, dim, undim around the click. `busy` means "a user action that changes
something is in flight". Nothing needs a global flag to stop a double click: each
runner refuses to start while running, and the probe button gates on `probing`.

**A control must also not re-enable while its effect is still being read back.**
Unmounting the last mount dimmed unmount-all, BRIGHTENED it the moment the unmount
returned, then switched it off 1.2s later when the poll reported no mounts — three
transitions, seen as a blink. The middle one was a lie: nothing was left to
unmount, the panel just did not know yet. `_settling` holds `busy` from the end of
an action until the next poll lands, and **the order in `statusRunner.onSucceeded`
matters** — apply the payload first, clear the flag second, or bindings re-evaluate
against stale state and the blink comes back from the fix itself.

**The status area is in the REMOTES header, and that is the whole point.** It used
to be its own `visible:`-toggled Text in the column — which is the house pattern,
the first-party Dropbox and Tailscale panels do the same — so every message pushed
the entire panel down and let it spring back. It now lives in the empty middle of
the REMOTES header row, which exists at a FIXED height, so a message cannot move
anything. It fades in and out (350ms) rather than blinking, holds ~3.5s
(`actionStatusTimer`), and elides rather than wraps.

Three consequences worth knowing before changing it:

- `flashText` in Panel.qml holds the last message so the fade-OUT has words to
  fade. Binding `text` straight to `statusLine` blanks it the instant it clears.
- Runners must NOT clear `actionStatus` on success. They used to, so a fast action
  flashed its message for a few hundred ms — unreadable. The timer owns the
  lifetime now; a message may outlive the action that raised it, which is correct
  for a status area that fades.
- The hold-back before a message appears is 250ms, not 700ms. It was 700 only
  because showing a message resized the panel, so the cheapest fix was to say
  nothing at all for anything fast. Showing costs nothing now.

Errors also get a floor: `applyStatus` used to clear `lastError` on every
successful poll, and a poll lands 1.2s after any action, so a failed mount was
erased about a second after appearing. `errorMinMs` keeps it up for 8s.

The automatic probe (panel open, and after a config edit) stays silent —
`probe(false)`. It starts on its own, so it is noise wherever it is drawn.

`omarchy-shell <id> buttonState` prints every input to those buttons in one call,
because with each IPC round trip costing ~250ms you cannot sample four properties
separately fast enough to catch which one flipped. For anything shorter than that,
put a temporary `console.log` on the `Changed` signal and read journald at
`-o short-precise` — that is how this one was finally pinned down.

**17. Emphasis is weight, never colour.** `PanelTheme.urgent` resolves to
`foreground` on purpose: the theme's real urgent colour is red in dark themes and
plain foreground in light ones, so the same warning shouted at half the users and
whispered to the rest. An urgent line sits at full foreground where its neighbours
are `dim`. Do not reintroduce a colour, and note that every colour in the plugin is
theme-derived — there are no literals.

## Credentials

**Nothing sensitive may go in argv.** `/proc/<pid>/cmdline` is world-readable, so
an argument is public to every local process for as long as the command runs. That
rules out `rclone rc --user U --pass P` and `rclone config create … pass=…`, which
is how this plugin used to work — the daemon password went into argv on *every
poll*, and every provider password went in during setup.

So, four rules for anything that touches a credential:

1. **All rc traffic goes through `rcclient.py`** — password in an `Authorization`
   header, parameters in the request body. Never shell out to `rclone rc`.
2. **Config values reach `rclone-config` on stdin**, never as arguments:
   `start`/`connect` read `{"parameters": {…}}`, `next` reads `{"result": …}`.
   It is Python rather than shell because it builds JSON around secrets.
3. **Never show a raw rc error body.** A failed call echoes the request back —
   `{"error": …, "input": {"parameters": {"pass": "hunter2"}}}` — and error
   strings reach the panel. Read only `error`, and `_scrub()` it.
4. **Mask on `IsPassword` OR `Sensitive`.** rclone sets only the latter for
   `s3 secret_access_key`, `b2 key`, `webdav bearer_token`, `sftp key_pem` and
   `drive client_secret`. Do not also match on field name — that hides `key_file`
   and `pubkey_file`, which are paths the user must be able to read.

`test/remote-lifecycle-test.sh` polls `/proc` during a create and asserts nothing
holds the value; it is verified to fail against the old argv form.
`test/secret-trace.py` does the same across a whole live setup, reporting hits as
redacted fingerprints — a real Drive sign-in came back clean over 4497 sweeps.

**Known and deliberate:** the IPC surface takes its argument on a command line, so
`omarchy-shell <id> answer <value>` exposes that value. The panel's own fields do
not. Do not paste a credential into that call.

Three measured facts that a change here could silently break:

- **`rclone rc key=value` sends every value as a STRING**, even valid JSON; the
  daemon parses it server-side. `rcclient.py`'s CLI path does the same, so
  swapping transports cannot quietly change how a mount is configured.
- **The OAuth handshake runs inside the DAEMON**, so its output is not ours to
  read. It opens the browser itself, but when it cannot, the auth URL exists only
  in its log — `config/oauthstatus` returns it, and Service polls for it while a
  step is in flight. `abort` also calls `config/oauthstop`, or an abandoned flow
  leaves the callback server holding :53682 and the next sign-in fails.
- **The rc API obscures passwords on its own**, exactly as
  `config create --non-interactive` did, so no `obscure` flag is passed —
  declaring it again risks obscuring twice.

## What the panel renders

**Icons** (`ProviderIcon.qml`) are three tiers: a drawn mark where the shape is
worth drawing, a font glyph where the Nerd Font has a distinct one, otherwise a
monogram of the type's initial. So adding a provider needs no art. **Do not
replace this with a fixed glyph table** — rclone has 69 backends and Nerd Fonts has
brand icons for a handful, so every such table maps `box`, `s3`, `pcloud` and
`zoho` to the same default cloud, which is worse than vague. Marks are drawn with
`Shape`/`ShapePath` (the house pattern) so they inherit the theme colour.

**Never show an fs to a person.** An fs carries options and comes back from rclone
hashed — `gdrive,skip_gdocs=true:` and `gdrive{YRXYK}:` are the same remote — so
`Mounting gdrive,skip_gdocs=true:…` showed the user a connection string including
the internal spelling of their own toggle. `Model.remoteNameFromFs()` cuts at the
first `:`, `,` or `{`. Job rows are the exception and keep the path (`copy
gdrive:docs → ~/Documents`), because there the path is the thing being copied.

**RECENT rows** name their provider (`107 B · gdrive`) — a name, not an icon,
because rows are one line and a name reads without a legend. Two constraints if you
touch `transferred_rows` or `transferRemote()`:

- The provider is resolved from `srcFs`/`dstFs` with the same prefix rule as
  `mountForRemote`, so it must handle `gdrive:documents` *and* the hashed
  `gdrive{YRXYK}:` (gotcha 6).
- **Only `what == "transferring"` may be listed.** rclone reports checks and bisync
  listings through `core/transferred` too — measured, 14 of 77 entries — and showing
  those claims files moved when nothing did. It is also exactly the set carrying an
  `srcFs`.

## Mounts

Login mounts live in `~/.config/rclone/omarchy-automounts.json`:

```json
[ { "fs": "gdrive,skip_gdocs=true:", "mountPoint": "/home/you/gdrive" } ]
```

**Reconciled, not a systemd oneshot.** Mounts live inside rcd, so if the daemon
restarts — crash, `Restart=on-failure`, an rclone upgrade — every mount it owned is
silently gone, and a oneshot that already ran never notices.
`Service.reconcileMounts()` re-applies anything missing after **every** status
refresh; measured, it restored a dropped mount unaided 20s later. It costs nothing
when there is nothing to do, and mounts one at a time so a slow remote cannot stall
the rest.

**Unsynced writes are the one place this can lose data.** With
`--vfs-cache-mode full` a write sits in the local cache before upload, and the
`fusermount3 -u` fallback bypasses rclone entirely. So `rclone-rc` checks
`vfs/queue` and **refuses** rather than warning:

```
$ rclone-rc unmount "" ~/Busy
3 file(s) not yet uploaded from /home/you/Busy — wait, or force
exit 2                        # mount still live, nothing lost
```

`force` overrides. The count comes from `status.py --pending <mountpoint>` — one
implementation for both the guard and the panel. **Do not re-implement it in
bash:** behind the `|| echo 0` a shell version needs, any mistake reads as "nothing
pending" and the guard silently never fires.

**Moving a mount** is unmount + mount, because rclone cannot relocate a live FUSE
mount. `rclone-rc remount` does the pair in one process and `repin` rewrites the
pin file atomically, or there is a window where the pin names a folder that is
gone. Two things it must keep doing:

- **Reuse the live mount's own fs** (`gdrive{YRXYK}:`) rather than recomposing one
  from the form — the Google Docs switch is hidden while moving, so recomposing
  could change a mount's options with nothing on screen to say so.
- **Verify the unmount instead of trusting it.** `mount/unmount` returned `{}`
  while the mountpoint stayed live, and the follow-up mount produced *two* mounts of
  the same remote. Do not simplify this away as paranoia: 19 controlled trials
  could not reproduce it, so the cause is unknown — if it recurs, capture what else
  was touching that mountpoint.

**Any open form takes the keyboard**, or `r`/`c`/`a` get swallowed as panel
shortcuts while typing a path, and Escape unwinds one layer at a time
(form → wizard → panel). Keep both in any new input.

## Adding a provider

Adding one means **a row in `PROVIDERS` in `Model.js` and nothing else** — there is
no per-provider code. If a backend refuses to start without a value rclone never
asks for, give it a `seed` (zoho needs `region`).

| path | for | how |
|---|---|---|
| `rclone-config` + `ProviderFlow.qml` | OAuth backends | steps rclone's config state machine; each question carries `Help`, `Default`, `Examples`, `Required`, and the panel renders that |
| `BackendForm.qml` | backends with no interactive setup (`form: true`) | generates a form from `config/providers`, passes answers as seeds to one `config create` |
| `SetupWizard.qml` | **Google Drive only** | hand-written, because ~10 minutes of it happens in Google's console where rclone cannot reach |

Measured: `s3`, `b2`, `webdav`, `sftp` and `crypt` all return done on the first
call, so **only OAuth flows walk the state machine**. In the generated form,
rclone's `Required` flag is not the whole story — s3 marks nothing required because
it depends on which provider you pick, so the form leads with the first few fields
when a backend declares none.

Two things in the Drive wizard are load-bearing, not decorative: the
**publish-the-app** warning (left in Testing mode, Google expires every grant after
7 days and Drive stops a week later), and keeping the credential fields' contents
when the panel closes — the panel closes on focus loss, that setup sends you to the
console twice, and **Google shows a client secret exactly once**, so losing it
costs a trip back for a new one.

`rclone config` in a floating terminal stays in the grid as the escape hatch for
backends the grid does not list.

**Where help is most useful:** the post-auth branch is covered by a fixture, not an
account. `test/fixtures/onedrive-like.json` walks islocal → type → org picker →
drive id → secret through the real widget, which proves our half; that rclone's
real `choose_type` output matches that shape is **unverified**. Box and Drive are
the flows confirmed end to end against live accounts.
