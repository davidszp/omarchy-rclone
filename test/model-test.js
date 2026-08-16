// Tests for the pure helpers. Run with:  node test/model-test.js
//
// Model.js deliberately has no Quickshell imports so this can exist. Every case
// below is a real behaviour that was either wrong at some point or is easy to
// break — not coverage for its own sake.

const M = require("../Model.js")

let failures = 0
let checks = 0

function eq(actual, expected, label) {
  checks++
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) {
    failures++
    console.log(`  FAIL ${label}\n       expected ${b}\n       got      ${a}`)
  }
}

// ---- mountForRemote --------------------------------------------------------
// rclone rewrites connection strings into a hashed form in mount/listmounts,
// so plain equality misses the mount. The prefix must still not over-match.
{
  const mounts = [
    { fs: "gdrive{YRXYK}:", mountPoint: "/home/u/GDrive" },
    { fs: "backup:", mountPoint: "/home/u/Backup" }
  ]
  eq(M.mountForRemote(mounts, "gdrive").mountPoint, "/home/u/GDrive", "hashed connection string matches")
  eq(M.mountForRemote(mounts, "backup").mountPoint, "/home/u/Backup", "plain remote matches")
  eq(M.mountForRemote(mounts, "gdrivebackup"), null, "prefix does not over-match a longer name")
  eq(M.mountForRemote(mounts, "drive"), null, "substring in the middle does not match")
  eq(M.mountForRemote([{ fs: "gdrive,skip_gdocs=true:" }], "gdrive").fs,
     "gdrive,skip_gdocs=true:", "raw connection string matches")
  eq(M.mountForRemote(mounts, ""), null, "empty name matches nothing")
  eq(M.mountForRemote(null, "gdrive"), null, "missing mount list is tolerated")
}

// ---- parseStatus -----------------------------------------------------------
// The success and failure paths must return the same shape; they drifted apart
// once and the error path quietly lost its newer fields.
{
  eq(Object.keys(M.parseStatus("")).sort(), Object.keys(M.defaultStatus()).sort(),
     "empty input yields the full default shape")
  eq(Object.keys(M.parseStatus("not json")).sort(), Object.keys(M.defaultStatus()).sort(),
     "unparseable input yields the full default shape")
  eq(M.parseStatus("not json").ok, false, "unparseable input is flagged not-ok")
  eq(M.parseStatus('{"installed":true}').remotes, [], "missing arrays are filled in")
  eq(M.parseStatus('{"remotes":"nope"}').remotes, [], "a non-array where an array belongs is replaced")
  eq(M.parseStatus('{"installed":true}').installed, true, "provided values survive")
  eq(M.parseStatus('{"runningJobs":null}').runningJobs, 0, "null falls back to the default")
}

// ---- formatEta -------------------------------------------------------------
// rclone sends null for "unknown"; Number(null) is 0, which would render as an
// instantly-finishing transfer.
{
  eq(M.formatEta(null), "", "null eta is unknown, not zero")
  eq(M.formatEta(undefined), "", "undefined eta is unknown")
  eq(M.formatEta(0), "", "zero eta is unknown")
  eq(M.formatEta(-5), "", "negative eta is unknown")
  eq(M.formatEta(45), "45s", "seconds")
  eq(M.formatEta(90), "1m 30s", "minutes and seconds")
  eq(M.formatEta(3700), "1h 1m", "hours and minutes")
  eq(M.formatEta(90000), "1d 1h", "days and hours")
}

// ---- formatBytes -----------------------------------------------------------
{
  eq(M.formatBytes(0), "0 B", "zero")
  eq(M.formatBytes(null), "0 B", "null is zero, not NaN")
  eq(M.formatBytes(999), "999 B", "below the unit boundary")
  eq(M.formatBytes(1000), "1 KB", "unit boundary")
  eq(M.formatBytes(1536), "1.54 KB", "two decimals under 10")
  eq(M.formatBytes(15360), "15.4 KB", "one decimal under 100")
  eq(M.formatBytes(153600), "154 KB", "no decimals at or above 100")
  eq(M.formatSpeed(0), "", "zero speed renders as nothing, not '0 B/s'")
}

// ---- statusText ------------------------------------------------------------
// Each state must be distinguishable; "Idle" for a dead daemon was the bug this
// guards against.
{
  const base = M.defaultStatus()
  eq(M.statusText(base), "rclone is not installed", "no binary")
  eq(M.statusText({ ...base, installed: true }), "daemon not set up", "no daemon unit")
  eq(M.statusText({ ...base, installed: true, daemonInstalled: true }),
     "rclone rcd is not running", "daemon installed but down")
  eq(M.statusText({ ...base, installed: true, daemonInstalled: true, rcRunning: true }),
     "Idle", "up with nothing to do")
  eq(M.statusText({ ...base, installed: true, daemonInstalled: true, rcRunning: true,
                    transferring: [{}, {}], stats: { speed: 1000000 } }),
     "2 transfers · 1 MB/s", "active transfers with speed")
  eq(M.statusText({ ...base, installed: true, daemonInstalled: true, rcRunning: true,
                    transferring: [{}], stats: {} }),
     "1 transfer", "singular, no speed yet")
  eq(M.statusText({ ...base, installed: true, daemonInstalled: true, rcRunning: true,
                    runningJobs: 1 }),
     "1 job running", "a job that moves no bytes is not 'Idle'")
  // The cumulative counter is deliberately ignored: stopping a job on purpose
  // increments it and it cannot be cleared, so it would badge "1 error" forever.
  eq(M.statusText({ ...base, installed: true, daemonInstalled: true, rcRunning: true,
                    stats: { errors: 3 } }),
     "Idle", "the daemon-lifetime error counter does NOT leak into the status line")
}

// ---- isActive --------------------------------------------------------------
{
  const base = M.defaultStatus()
  eq(M.isActive({ ...base, rcRunning: true, transferring: [{}] }), true, "transferring is active")
  eq(M.isActive({ ...base, rcRunning: true, runningJobs: 5 }), false,
     "job count alone is NOT activity — every rc call is itself a job")
  eq(M.isActive({ ...base, rcRunning: false, transferring: [{}] }), false, "down is never active")
}

// ---- subtitles -------------------------------------------------------------
{
  eq(M.remoteSubtitle({ name: "g", type: "drive" }, {}), "drive", "no probe yet")
  // remoteGlyph is gone: it mapped box, s3, pcloud and zoho to the SAME default
  // cloud. ProviderIcon replaces it and falls back to a monogram, so a backend
  // with no drawn mark is still distinguishable.
  eq(typeof M.remoteGlyph, "undefined", "the ambiguous glyph map is no longer exported")
  eq(M.remoteSubtitle({ name: "g", type: "drive" }, { g: { online: false } }),
     "drive · unreachable", "offline probe")
  eq(M.remoteSubtitle({ name: "g", type: "drive" },
     { g: { online: true, quotaKnown: true, usedBytes: 2200000000, totalBytes: 16100000000 } }),
     "drive · 2.2 GB of 16.1 GB", "quota probe")
  eq(M.transferredSubtitle({ size: 1000, error: "quota exceeded" }), "quota exceeded",
     "a failed transfer reports its error, not its size")
  eq(M.transferredSubtitle({ size: 1000 }), "1 KB", "a good transfer reports its size")
  // RECENT mixes providers, so a row names the one it came from.
  eq(M.transferredSubtitle({ size: 1000 }, { name: "gdrive" }), "1 KB · gdrive",
     "the provider is named alongside the size")
  eq(M.transferredSubtitle({ size: 1000, error: "boom" }, { name: "box" }), "box · boom",
     "the provider is named even when the transfer failed")
  eq(M.transferredSubtitle({ size: 0 }, null), "done",
     "a local-to-local transfer names no provider")
  eq(M.baseName("/a/b/c.txt"), "c.txt", "basename")
  eq(M.baseName("c.txt"), "c.txt", "basename of a bare name")
}

// ---- job rows --------------------------------------------------------------
// The label is the _group rclone-rc set: "<verb> <src> -> <dst>".
{
  // Both ends, because "copy → prov" did not say what was being copied.
  eq(M.jobTitle({label: "mirror gdrive:docs -> /home/u/Documents"}, "/home/u"),
     "mirror gdrive:docs → ~/Documents", "names source and destination")
  eq(M.jobTitle({label: "copy box: -> /home/u/prov"}, "/home/u"),
     "copy box: → ~/prov", "a bare remote survives intact")
  eq(M.jobTitle({}), "job", "no label still renders something")
  eq(M.jobTitle({label: "weird"}), "weird", "a label with no arrow shows what there is")
  eq(M.shortFs("/home/u/a/very/deeply/nested/place/file", "/home/u").indexOf("…/") >= 0, true,
     "a long local path collapses")
  eq(M.shortFs("box:", "/home/u"), "box:", "short remotes are left alone")
  eq(M.shortFs("gdrive:some/extremely/long/path/inside/the/drive", "/home/u"),
     "gdrive:…/drive", "a long remote path keeps the remote name")

  eq(M.jobSubtitle({bytes: 29200000, totalBytes: 60000000, speed: 6500000, eta: 4}),
     "29.2 MB of 60 MB · 6.5 MB/s · 4s left", "full progress line")
  eq(M.jobSubtitle({}), "starting…", "a job with no stats yet is not blank")
  eq(M.jobSubtitle({error: "quota exceeded", bytes: 5}), "quota exceeded",
     "an error replaces the progress line entirely")
  eq(M.jobSubtitle({totalBytes: 100, bytes: 50, errors: 2}), "50 B of 100 B · 2 errors",
     "error count is appended")
  eq(M.jobSubtitle({totalBytes: 100, bytes: 50, eta: null}), "50 B of 100 B",
     "a null eta is omitted, not rendered as 0s")
}

// ---- jobs in the status shape ----------------------------------------------
{
  eq(M.parseStatus('{"jobs":"nope"}').jobs, [], "a non-array jobs field is replaced")
  eq(M.defaultStatus().jobs, [], "jobs is part of the default shape")
}

// ---- Drive setup content ---------------------------------------------------
// These console URLs rot as Google redesigns; the data lives in one place and
// this asserts its shape so a broken edit fails here rather than in the panel.
{
  eq(M.driveScopes.length, 3, "three Drive scopes")
  eq(M.driveScopes.every(u => u.startsWith("https://www.googleapis.com/auth/")), true,
     "every scope is a googleapis auth URL")
  eq(M.driveSetupSteps.length, 5, "five setup steps")
  eq(M.driveSetupSteps.every(s => s.title && s.detail && s.url && s.action), true,
     "every step has a title, detail, url and action label")
  eq(M.driveSetupSteps.every(s => s.url.startsWith("https://console.cloud.google.com/")), true,
     "every step links into the Google Cloud console over https")
  eq(M.driveSetupSteps.filter(s => s.warn).length, 1,
     "exactly one step is flagged as a warning — publishing, the one that silently expires grants")
  eq(M.driveSetupSteps[3].warn, true, "the publish step is the flagged one")
  eq(M.driveCredentialsUrl.startsWith("https://console.cloud.google.com/"), true,
     "the existing-project shortcut is a console URL")
}

// ---- bandwidth presets -----------------------------------------------------
// rclone reports binary units, so "5M" comes back "5Mi". Prefix matching lit up
// 1M *and* 10M when the limit was 10M.
{
  eq(M.bwMatches("off", "off"), true, "off matches off")
  eq(M.bwMatches("", "off"), true, "empty counts as off")
  eq(M.bwMatches("5Mi", "off"), false, "a live limit is not off")
  eq(M.bwMatches("5Mi", "5M"), true, "binary suffix still matches its preset")
  eq(M.bwMatches("10Mi", "10M"), true, "10M matches")
  eq(M.bwMatches("10Mi", "1M"), false, "10M must NOT also light up 1M")
  eq(M.bwMatches("1Mi", "10M"), false, "1M must not light up 10M")
  eq(M.bwMatches("off", "5M"), false, "off matches no rate preset")
}

// ---- tildePath -------------------------------------------------------------
{
  eq(M.tildePath("/home/u/GDrive", "/home/u"), "~/GDrive", "home-relative path is shortened")
  eq(M.tildePath("/home/u", "/home/u"), "~", "home itself")
  eq(M.tildePath("/mnt/data", "/home/u"), "/mnt/data", "paths outside home are left alone")
  eq(M.tildePath("/home/username2/x", "/home/u"), "/home/username2/x",
     "a prefix that is not a path boundary must NOT be shortened")
  eq(M.tildePath("", "/home/u"), "", "empty stays empty")
  eq(M.tildePath("/home/u/GDrive", ""), "/home/u/GDrive", "no home means no shortening")
}

// ---- transfer provenance ---------------------------------------------------
// RECENT shows files from several providers at once, so each row needs to say
// which. srcFs comes in the same forms mountForRemote deals with.
{
  const remotes = [{name: "gdrive", type: "drive"}, {name: "box", type: "box"}]
  eq(M.remoteForFs(remotes, "gdrive:documents").name, "gdrive", "plain remote with a path")
  eq(M.remoteForFs(remotes, "gdrive{YRXYK}:").name, "gdrive", "hashed connection string")
  eq(M.remoteForFs(remotes, "box:").name, "box", "bare remote")
  eq(M.remoteForFs(remotes, "/tmp/thing"), null, "a local path has no provider")
  eq(M.remoteForFs(remotes, "gdrivebackup:"), null, "must not over-match a longer remote name")
  eq(M.remoteForFs(remotes, ""), null, "empty fs")
  eq(M.remoteForFs(null, "gdrive:"), null, "missing remote list is tolerated")

  eq(M.transferRemote({srcFs: "gdrive:x", dstFs: "/tmp/y"}, remotes).name, "gdrive",
     "download: the remote is the source")
  eq(M.transferRemote({srcFs: "/tmp/y", dstFs: "box:x"}, remotes).name, "box",
     "upload: the remote is the destination")
  eq(M.transferRemote({srcFs: "/a", dstFs: "/b"}, remotes), null,
     "local to local has no provider")
}

// ---- sync mode descriptions ------------------------------------------------
// "Copy or mirror" explained nothing, and only the dangerous modes had any
// wording at all — so the safe default was the unexplained one.
{
  eq(M.syncModeHelp("copy", "~/Docs").indexOf("Nothing there is ever deleted") > 0, true,
     "copy states that nothing is deleted")
  eq(M.syncModeHelp("mirror", "~/Docs").indexOf("deleted") > 0, true,
     "mirror states that files are deleted")
  eq(M.syncModeHelp("mirror", "~/Docs").indexOf("~/Docs") >= 0, true,
     "mirror names the directory it would delete from")
  eq(M.syncModeHelp("bisync", "~/Docs").indexOf("both directions") > 0, true,
     "two-way states that it goes both ways")
  eq(M.syncModeHelp("copy", "").indexOf("the destination") > 0, true,
     "with no path yet it still reads as a sentence")

  eq(M.syncModeDestroys("copy"), false, "copy never destroys")
  eq(M.syncModeDestroys("mirror"), true, "mirror can destroy")
  eq(M.syncModeDestroys("bisync"), true, "two-way can destroy")
}

// ---- row actions -----------------------------------------------------------
// The cursor must never be able to reach a button that is not drawn. Before
// this moved out of Panel.qml the only way to check that was to drive the live
// widget and count how far the cursor could travel.
{
  const remote = { name: "box", type: "box" }
  const collapsed = M.rowActions({ remote: remote, mounted: true, expanded: false })
  eq(collapsed, ["", "mount", "more"], "a collapsed row exposes only what is drawn")
  eq(collapsed[0], "", "the first target is the ROW, so Enter toggles it open")

  const expanded = M.rowActions({ remote: remote, mounted: true, expanded: true })
  eq(expanded.indexOf("pin") > 0, true, "pin appears once mounted")
  eq(expanded.indexOf("move") > 0, true, "move appears once mounted")
  eq(expanded.indexOf("reconnect"), -1, "reconnect stays hidden while the grant is good")

  const unmounted = M.rowActions({ remote: remote, mounted: false, expanded: true })
  eq(unmounted.indexOf("pin"), -1, "pin is meaningless with nothing mounted")
  eq(unmounted.indexOf("move"), -1, "so is move")
  eq(unmounted.indexOf("sync") > 0, true, "sync does not need a mount")

  eq(M.rowActions({ remote: remote, mounted: true, expanded: true, needsReauth: true })
      .indexOf("reconnect") > 0, true, "an expired grant offers reconnect")
  eq(M.rowActions({ remote: null }), [""], "no remote still yields a single row target")
  eq(M.rowActions(null), [""], "a missing state object does not throw")
  // Every action name here is dispatched by string in Panel.activateCursor —
  // a typo would silently do nothing, so pin the vocabulary.
  const known = ["", "mount", "more", "open", "reconnect", "pin", "sync", "move", "config", "remove"]
  eq(M.rowActions({ remote: remote, mounted: true, expanded: true, needsReauth: true })
      .every(a => known.indexOf(a) >= 0), true, "no action name outside the known set")
}

// ---- half-made remotes -----------------------------------------------------
// `rclone config create` writes the config section BEFORE the flow that fills
// it in, so a crash or a shell restart mid-setup leaves a section with no
// `type`. It cannot be mounted, probed or repaired — and `rclone listremotes`
// does not even list it, so the panel is the only place it becomes visible.
{
  const broken = { name: "onedrive2", type: "", incomplete: true }
  eq(M.rowActions({ remote: broken, mounted: false, expanded: false }), ["", "remove"],
     "a half-made remote offers ONLY removal")
  eq(M.rowActions({ remote: broken, mounted: false, expanded: true }), ["", "remove"],
     "expanding it reveals nothing extra — there is nothing else it can do")
  eq(M.rowActions({ remote: broken, mounted: true, expanded: true }).indexOf("mount"), -1,
     "it never offers mount, even if something claims it is mounted")

  eq(M.remoteSubtitle(broken, {}), "setup never finished — remove it",
     "the subtitle says what happened and what to do")
  // The old text was "unknown · unreachable", which reads as a network fault
  // the user might sit and wait out.
  eq(M.remoteSubtitle(broken, {}).indexOf("unreachable"), -1,
     "and does not read as a transient network problem")

  const fine = { name: "box", type: "box", incomplete: false }
  eq(M.rowActions({ remote: fine, mounted: true, expanded: false }), ["", "mount", "more"],
     "a healthy remote is untouched by any of this")
  // A working remote can also be removed, but only once expanded and only at
  // the very end — it is the one irreversible thing a row can do.
  const healthy = M.rowActions({ remote: fine, mounted: true, expanded: true })
  eq(healthy[healthy.length - 1], "remove", "remove is LAST in the expanded set")
  // Opening the folder is what people expand a row to do, so it leads.
  eq(healthy[3], "open", "open folder is the FIRST expanded action")
  eq(M.rowActions({ remote: fine, mounted: false, expanded: true }).indexOf("open"), -1,
     "nothing to open when it is not mounted")
  eq(M.rowActions({ remote: fine, mounted: true, expanded: false }).indexOf("remove"), -1,
     "and is not reachable while the row is collapsed")

  eq(M.removeRemoteMessage("box", false, true).indexOf("stay in the cloud") >= 0, true,
     "removing a working remote leads with what is NOT lost")
  eq(M.removeRemoteMessage("box", false, true).indexOf("unmounts it") >= 0, true,
     "and says it will unmount first when it is mounted")
  eq(M.removeRemoteMessage("box", false, false).indexOf("unmounts it"), -1,
     "but does not promise an unmount that will not happen")
  eq(M.removeRemoteMessage("x", true, false).indexOf("never finished") >= 0, true,
     "a half-made one gets the shorter, different question")
}

// ---- mounted subtitle ------------------------------------------------------
// The storage figures were fetched on every probe and never once displayed:
// remoteSubtitle formats them, but the row only reaches that branch when the
// remote is UNMOUNTED, and remotes are normally mounted.
{
  const mount = { mountPoint: "/home/u/box", pendingCount: 0 }
  const probe = { quotaKnown: true, usedBytes: 586055235, totalBytes: 53687091200 }
  eq(M.mountedSubtitle(mount, probe, "/home/u"),
     "mounted at ~/box · " + M.formatBytes(586055235) + " of " + M.formatBytes(53687091200),
     "a mounted remote finally shows its quota")
  eq(M.mountedSubtitle({ mountPoint: "/home/u/box", pendingCount: 3 }, probe, "/home/u"),
     "mounted at ~/box · 3 not uploaded yet",
     "queued writes REPLACE the quota — the urgent fact wins the one line there is")
  eq(M.mountedSubtitle({ mountPoint: "/home/u/box", pendingCount: 1 }, probe, "/home/u"),
     "mounted at ~/box · 1 not uploaded yet", "a single queued file still reports")
  eq(M.mountedSubtitle(mount, { quotaKnown: false }, "/home/u"), "mounted at ~/box",
     "a backend that cannot report a quota just shows the path")
  eq(M.mountedSubtitle(mount, null, "/home/u"), "mounted at ~/box",
     "no probe result yet is not an error state")
  eq(M.mountedSubtitle(mount, { quotaKnown: true, usedBytes: 0, totalBytes: 0 }, "/home/u"),
     "mounted at ~/box", "a zero total is treated as unknown, not as a full disk")
}

// ---- destructive-sync confirmation ----------------------------------------
// The message must name the DESTINATION. "Run mirror?" cannot be answered
// safely, because which folder gets emptied is the entire question.
{
  const mirror = M.syncConfirmMessage("mirror", "/home/u/docs", "/home/u")
  eq(mirror.indexOf("~/docs") >= 0, true, "mirror names the destination it will prune")
  eq(mirror.indexOf("deletes") >= 0, true, "mirror says plainly that it deletes")
  const bisync = M.syncConfirmMessage("bisync", "/home/u/docs", "/home/u")
  eq(bisync.indexOf("~/docs") >= 0, true, "two-way names the other side")
  eq(bisync.indexOf("either side") >= 0, true,
     "two-way explains that a delete propagates BOTH ways, which mirror's wording does not")
  eq(mirror === bisync, false, "the two destructive modes do not share one vague warning")
}

// ---- unmount-all confirmation ---------------------------------------------
// The reversible case and the destructive case must not read alike, or the
// dangerous one stops registering.
{
  eq(M.unmountAllMessage(4, 0).indexOf("Nothing is lost") >= 0, true,
     "with nothing queued it says plainly that this is reversible")
  eq(M.unmountAllMessage(4, 0).indexOf("discarded") >= 0, false,
     "and does NOT threaten data loss that cannot happen")
  const risky = M.unmountAllMessage(4, 2)
  eq(risky.indexOf("2 files have") >= 0, true, "queued writes are counted, not hinted at")
  eq(risky.indexOf("discarded") >= 0, true, "and named as a loss")
  eq(M.unmountAllMessage(1, 1).indexOf("1 mount?") >= 0, true, "singular mount reads correctly")
  eq(M.unmountAllMessage(1, 1).indexOf("1 file has") >= 0, true, "singular file reads correctly")
}

// ---- form-based backends ---------------------------------------------------
// S3, B2, SFTP, WebDAV and FTP have no interactive setup: rclone's state
// machine finishes on the first call, so a flow started for one writes a remote
// with NO credentials. They are created from a generated form instead, and the
// two mechanisms must never be claimed by the same entry.
{
  const forms = M.quickProviders.filter(p => p.form)
  eq(forms.length > 0, true, "the grid offers backends that need a form")
  eq(forms.map(p => p.type).sort(), ["b2", "ftp", "s3", "sftp", "webdav"],
     "and they are exactly the non-interactive ones verified by hand")
  eq(forms.every(p => !p.seed && !p.wizard), true,
     "a form backend never also claims a seed question or the wizard")
  // Every provider must be creatable by exactly one route.
  eq(M.quickProviders.every(p => [p.form, p.seed, p.wizard].filter(Boolean).length <= 1),
     true, "no provider declares two creation routes")
}

// ---- step labels -----------------------------------------------------------
// The override must be surgical. Replacing rclone's wording wholesale would
// mean every new backend renders a blank question until someone adds an entry
// here, which is exactly the per-provider maintenance the flow avoids.
{
  eq(M.stepLabel({ name: "config_team_drive_id", help: "Team Drive ID" }),
     "Organization (Zoho calls this the Team Drive ID)",
     "the org step is renamed from the internal field name")
  eq(M.stepLabel({ name: "config_is_local", help: "Use web browser?" }),
     "Use web browser?", "an un-overridden step keeps rclone's own wording")
  eq(M.stepLabel({ name: "", help: "Some new backend's question" }),
     "Some new backend's question", "a step with no name still renders its help")
  eq(M.stepLabel({ name: "config_thing" }), "", "a step with no help renders empty")
  eq(M.stepLabel(null), "", "a missing step does not throw")
  // Object.prototype keys must not be mistaken for overrides — `hasOwnProperty`
  // rather than a truthiness check is what stops "toString" resolving here.
  eq(M.stepLabel({ name: "toString", help: "real help" }), "real help",
     "an inherited property name is not treated as an override")
}

// ---- provider grid ---------------------------------------------------------
{
  const types = M.quickProviders.map(p => p.type)
  eq(types.indexOf("drive"), 0, "Google Drive leads the grid rather than having its own row")
  eq(M.quickProviders[0].wizard, true, "Drive routes to the wizard, not the generic flow")
  eq(M.quickProviders.filter(p => p.wizard).length, 1,
     "only Drive needs a wizard — every other provider rclone can drive itself")
  eq(new Set(types).size, types.length, "no duplicate backend types")
  // Digits are legal: rclone's own backend names include s3 and b2.
  eq(types.every(t => /^[a-z0-9]+$/.test(t)), true, "types are plain rclone backend names")
  // A backend is either walked through rclone's state machine or filled in from
  // a generated form — never both, since the two take different creation paths.
  eq(M.quickProviders.filter(p => p.form && p.seed).length, 0,
     "no provider claims both a seed question and a generated form")
  eq(M.quickProviders.filter(p => p.form && p.wizard).length, 0,
     "and none claims both a form and the guided wizard")
  // Verified by starting a real flow for each: these either refuse to begin
  // (zoho, iclouddrive — "no region set", "an Apple ID is required") or
  // complete instantly with no credentials (mega, protondrive, koofr). A plain
  // button for any of them cannot finish.
  //
  // A `seed` is the documented way out: it supplies the value rclone demands
  // before the state machine runs, which is why zoho is offered and the rest
  // are not. So the rule is not "never offer these" but "never offer these
  // WITHOUT a seed" — that keeps the guard while leaving the door open.
  const cannotFinish = ["zoho", "iclouddrive", "mega", "protondrive", "koofr"]
  const unseeded = M.quickProviders.filter(p => cannotFinish.includes(p.type) && !p.seed)
  eq(unseeded.map(p => p.type), [],
     "backends whose flow cannot complete are only offered when seeded")

  // A seed the panel cannot render is worse than no button at all.
  M.quickProviders.filter(p => p.seed).forEach(p => {
    eq(typeof p.seed.key === "string" && p.seed.key.length > 0, true,
       p.type + " seed names the config key it sets")
    eq(typeof p.seed.prompt === "string" && p.seed.prompt.length > 0, true,
       p.type + " seed carries a question to show")
    eq(Array.isArray(p.seed.options) && p.seed.options.length > 0, true,
       p.type + " seed offers at least one choice")
    eq(p.seed.options.every(o => o && o.value && o.label), true,
       p.type + " seed options all have a value and a label")
  })
  eq(M.quickProviders.every(p => p.label && p.label.length <= 16), true,
     "labels stay short enough to sit in a button grid")
}

// ---- monogram uniqueness ---------------------------------------------------
// A fixed rule collides 17 ways across rclone's 69 backends. Collisions only
// matter when both are configured, so the badge grows until it is unique among
// the types actually present.
{
  eq(M.monogramFor("zoho", ["zoho"]), "Z", "a lone type gets one letter")
  eq(M.monogramFor("protondrive", ["protondrive", "box"]), "P",
     "no clash present, so the short form is kept")
  // protondrive/premiumizeme share TWO letters, so both need three.
  eq(M.monogramFor("protondrive", ["protondrive", "premiumizeme"]), "PRO",
     "a clashing sibling lengthens the badge until it differs")
  eq(M.monogramFor("premiumizeme", ["protondrive", "premiumizeme"]), "PRE",
     "and the other side lengthens to match")
  eq(M.monogramFor("mega", ["mega", "memory"]), "MEG", "mega vs memory")
  eq(M.monogramFor("memory", ["mega", "memory"]), "MEM", "memory vs mega")
  eq(M.monogramFor("", ["box"]), "?", "an empty type still renders something")
  eq(M.monogramFor("box", []), "B", "no siblings at all")
  // Two remotes of the SAME type share a badge, which is correct — the icon
  // says what kind of cloud it is, and the name distinguishes the remotes.
  eq(M.monogramFor("pcloud", ["pcloud", "pcloud"]), "P", "same type is not a clash")
  // Known limit, documented rather than pretended away: 4 letters is what fits
  // the badge, so names differing only past that share one.
  eq(M.monogramFor("azureblob", ["azureblob", "azurefiles"]), "AZUR", "capped at four letters")
  eq(M.monogramFor("azurefiles", ["azureblob", "azurefiles"]), "AZUR", "so this pair collides, by design")
}

console.log(failures === 0
  ? `\n  ${checks} checks passed\n`
  : `\n  ${failures} of ${checks} checks FAILED\n`)
process.exit(failures === 0 ? 0 : 1)
