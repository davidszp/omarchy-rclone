# rclone for the Omarchy bar

Your cloud drives in the bar: what's transferring, what's mounted, how much
space is left — and adding a new provider without opening a terminal.

Built for my own machine and verified against live Google Drive, Box, OneDrive,
Dropbox and Zoho accounts on Omarchy 4.0 / rclone 1.75.

## Install

```bash
git clone https://github.com/davidszp/omarchy-rclone ~/.config/omarchy/plugins/davidszp.rclone
omarchy restart shell
```

Add the widget to your bar, click it, and follow the panel. It sets up the
rclone daemon on first run and walks you through connecting a drive. If rclone
isn't installed it offers to do that too.

Needs Omarchy 4.x and Python 3. That's it.

## What it does

- **Mount a drive** with a switch, and have it come back after a reboot.
- **See what's transferring**, with speed and progress, and stop a job.
- **Add a provider in the panel** — Drive, OneDrive, Dropbox, Box, pCloud,
  Jottacloud, Yandex, Zoho, plus S3, B2, SFTP, WebDAV and FTP. Anything else
  falls back to `rclone config` in a terminal.
- **Copy, mirror or two-way sync** a folder, with a dry run first.
- **Cap the bandwidth** so a big upload doesn't eat your connection.

## Mounting and transferring are different things

Worth knowing, because rclone is not Dropbox and this trips people up.

**Mounting** gives you a folder that *is* the cloud. Nothing is downloaded up
front; files are fetched when you open them and uploaded a few seconds after you
save. Unmount and they're gone from your disk again. There's no local copy.

**Transferring** makes a real second copy — for offline access, or a backup that
survives losing the account. It runs once when you click it. Nothing watches for
changes afterwards.

So: mount to *use* your files, transfer to *duplicate* them.

If a row says "3 not uploaded yet", those writes are still in the local cache.
Unmounting then will ask before throwing them away.

## Keyboard

Up/down between remotes, left/right across a row's actions, Enter to run one.
Actions are matched by name rather than position, so a row that gains a button
doesn't shift what Enter does.

`r` refreshes, `c` checks each remote is reachable, `a` opens the Drive wizard.

## Settings

Two, in the bar's plugin settings: how often to poll when idle (30s) and while
something is transferring (2s).

## Development

```bash
./check          # everything verifiable without a running shell — run this first
```

That covers the pure logic, the Python helper, shell syntax, the manifest, and
that every icon exists in the font. It also drives the *live* panel over IPC,
which is the only way to test QML that imports Omarchy's own components.

One rule worth repeating: **after changing a `.qml` file, restart the shell
before believing anything.** Hot reload silently keeps the old component often
enough that I've been fooled twice.

`status.py` is the only thing that talks to rclone. `Model.js` is pure logic
with no QML imports, which is why it can be unit tested. Everything else is a
panel component. See [NOTES.md](NOTES.md) for how it fits together and the
traps found on the way.

## Not done yet

- **Most of rclone's 69 backends** — thirteen are in the grid; the rest go
  through the terminal.
- **Encrypted remotes (`crypt`)** — wraps an existing remote, so it needs a
  different form than "pick a provider and sign in".
- **Scheduling** — every transfer is one-shot and manual. No "back this up
  nightly" yet, which is the first thing you'll want after using it twice.
- **Notifications** — a mount that fails at login is only visible if you look.

## License

MIT — see [LICENSE](LICENSE).
