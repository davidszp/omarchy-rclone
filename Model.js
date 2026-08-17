// Pure helpers for the rclone plugin: no Quickshell imports, no side effects,
// no QML types. Everything here runs under plain node, which is what
// test/model-test.js exercises.

// ---- Status payload --------------------------------------------------------

// The exact shape applyStatus() expects. The success and failure paths MUST
// agree on it — when they drifted apart, the error path silently produced
// objects missing the newer fields.
function defaultStatus() {
  return {
    ok: true,
    installed: false,
    daemonInstalled: false,
    version: "",
    rcRunning: false,
    rcError: "",
    remotes: [],
    // Names of config sections that are NOT remotes; see classify_config() in
    // status.py. Defaulted here so an older helper's payload cannot leave the
    // panel reaping against a stale list.
    configResidue: [],
    mounts: [],
    autoMounts: [],
    suppressed: [],
    stats: {},
    transferring: [],
    transferred: [],
    runningJobs: 0,
    jobs: [],
    bwLimit: "off",
    probes: {},
    probed: false,
    configMtime: 0
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    var failed = defaultStatus()
    failed.ok = false
    failed.rcError = "Could not parse rclone status"
    return failed
  }
  if (!parsed || typeof parsed !== "object") return defaultStatus()
  // Fill every missing key from the default rather than trusting the helper to
  // have sent them all; a partial payload must not leave stale bindings.
  var base = defaultStatus()
  for (var key in base) {
    if (parsed[key] === undefined || parsed[key] === null) parsed[key] = base[key]
  }
  var arrays = ["remotes", "configResidue", "mounts", "autoMounts", "suppressed", "transferring", "transferred", "jobs"]
  for (var i = 0; i < arrays.length; i++) {
    if (!Array.isArray(parsed[arrays[i]])) parsed[arrays[i]] = []
  }
  return parsed
}

// ---- Formatting ------------------------------------------------------------

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function formatSpeed(bytesPerSecond) {
  var value = Number(bytesPerSecond || 0)
  if (!isFinite(value) || value <= 0) return ""
  return formatBytes(value) + "/s"
}

function formatEta(seconds) {
  // rclone sends null for "unknown", which Number() turns into 0 — treat both
  // as unknown rather than claiming the transfer finishes this instant.
  if (seconds === null || seconds === undefined) return ""
  var value = Number(seconds)
  if (!isFinite(value) || value <= 0) return ""
  if (value < 60) return Math.round(value) + "s"
  var minutes = Math.floor(value / 60)
  if (minutes < 60) return minutes + "m " + Math.round(value % 60) + "s"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h " + (minutes % 60) + "m"
  return Math.floor(hours / 24) + "d " + (hours % 24) + "h"
}

// Shorten a home-relative path for display: /home/you/GDrive -> ~/GDrive.
// Lets a remote row carry its full mount location, which is what made the
// separate MOUNTS section redundant.
function tildePath(path, home) {
  var value = String(path || "")
  var base = String(home || "")
  if (base !== "" && value.indexOf(base + "/") === 0) return "~" + value.substring(base.length)
  if (base !== "" && value === base) return "~"
  return value
}

function baseName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1] || String(path || "")
}

// ---- Derived status --------------------------------------------------------

// True only when rclone is actually moving bytes. Deliberately NOT a job count:
// every rc call is itself a job, so job/list is polluted by our own polling.
function isActive(status) {
  return status.rcRunning === true && status.transferring.length > 0
}

// The one-line summary under the panel title, and the bar tooltip.
function statusText(status) {
  if (!status.installed) return "rclone is not installed"
  if (!status.daemonInstalled) return "daemon not set up"
  if (!status.rcRunning) return status.rcError || "rclone rcd is not running"
  var active = status.transferring.length
  if (active > 0) {
    var speed = formatSpeed(status.stats.speed)
    return active + (active === 1 ? " transfer" : " transfers") + (speed ? " · " + speed : "")
  }
  // A job that is listing or checking moves no bytes yet, so it would otherwise
  // read as "Idle" while plainly working.
  var jobs = Number(status.runningJobs || 0)
  if (jobs > 0) return jobs + (jobs === 1 ? " job running" : " jobs running")

  // Deliberately NOT `stats.errors`. That counter is cumulative for the whole
  // rcd lifetime and cannot be cleared per group — stopping a job on purpose
  // increments it, so the panel would show "1 error" forever for something the
  // user chose to do, with nothing to click and nothing to fix. Errors that
  // matter are already visible where they are actionable: per job in JOBS, and
  // per file in RECENT, both in the urgent colour.
  return "Idle"
}

// ---- Remotes and mounts ----------------------------------------------------

// The badge letters for a backend that has no drawn mark, guaranteed distinct
// among the types actually configured.
//
// A fixed rule cannot be collision-free: across rclone's 69 backends a
// two-letter monogram clashes 17 ways — protondrive/premiumizeme both give PR,
// mega/memory both ME. But a collision only MATTERS when both are configured,
// so the badge grows by one letter at a time until it is unique among the
// present types. With one of a pair configured you get the short form; add the
// other and both lengthen.
//
// Capped at 4 letters, which is what fits a 22px badge. With ALL 69 backends
// configured at once — not a real scenario — that leaves four pairs sharing a
// badge (azureblob/azurefiles, filelu/filen, the two google ones,
// internetarchive/internxt). Their names differ only after the cap, so a longer
// badge would be unreadable rather than helpful; the remote's name, which sits
// beside the icon, is what separates those.
function monogramFor(type, presentTypes) {
  var self = String(type || "").toLowerCase().replace(/[^a-z0-9]/g, "")
  if (self === "") return "?"
  var others = []
  for (var i = 0; i < (presentTypes || []).length; i++) {
    var other = String(presentTypes[i] || "").toLowerCase().replace(/[^a-z0-9]/g, "")
    if (other !== "" && other !== self) others.push(other)
  }
  for (var len = 1; len <= 4 && len <= self.length; len++) {
    var candidate = self.substring(0, len)
    var clash = false
    for (var j = 0; j < others.length; j++) {
      if (others[j].substring(0, len) === candidate) { clash = true; break }
    }
    if (!clash) return candidate.toUpperCase()
  }
  return self.substring(0, 4).toUpperCase()
}

// What a MOUNTED remote's row says underneath its name.
//
// Storage was previously unreachable: `remoteSubtitle` formats it, but the row
// only reaches that branch when the remote is UNMOUNTED — and remotes are
// normally mounted, so the used/total figures the probe already pays for were
// never once displayed.
//
// Ordering is by urgency, not by richness: files that have not reached the
// provider yet are the one thing worth interrupting for, so they replace the
// quota rather than being appended to it. Appending both wraps the line.
function mountedSubtitle(mount, probe, homeDir) {
  var where = "mounted at " + tildePath(mount ? mount.mountPoint : "", homeDir)
  var pending = Number(mount ? mount.pendingCount || 0 : 0)
  if (pending > 0) {
    return where + " · " + pending + " not uploaded yet"
  }
  if (probe && probe.quotaKnown && Number(probe.totalBytes) > 0) {
    return where + " · " + formatBytes(probe.usedBytes) + " of " + formatBytes(probe.totalBytes)
  }
  return where
}

// The question asked before deleting a remote from rclone's config.
//
// Leads with what is NOT lost. "Remove box?" invites the reading that the files
// go too, which is the one thing that does not happen — this deletes a stored
// connection, and re-adding it means signing in again.
function removeRemoteMessage(name, incomplete, mounted) {
  if (incomplete) {
    return "Remove " + name + " from rclone's config? Its setup never finished."
  }
  return "Remove " + name + "? Your files stay in the cloud — this deletes the "
    + "saved connection" + (mounted ? " and unmounts it" : "")
    + ", so you would have to sign in again to use it."
}

// The question asked before taking every mount down at once.
//
// Says what will be LOST, not just what will happen. A bulk unmount with
// nothing queued is entirely reversible — the switches turn back on — so the
// two cases must not read alike, or the dangerous one stops registering.
function unmountAllMessage(count, pending) {
  var mounts = count + (count === 1 ? " mount" : " mounts")
  if (Number(pending) > 0) {
    return "Unmount all " + mounts + "? " + pending
      + (pending === 1 ? " file has" : " files have")
      + " not finished uploading and will be discarded."
  }
  return "Unmount all " + mounts + "? Nothing is lost — turn them back on any time."
}

// The question asked before a sync that can delete at the destination.
//
// Names the DESTINATION explicitly. "Run mirror?" is not something anyone can
// answer safely — the whole risk is which folder gets emptied.
function syncConfirmMessage(mode, dstFs, homeDir) {
  var target = tildePath(String(dstFs || ""), homeDir)
  if (mode === "bisync") {
    return "Two-way sync with " + target
      + " — a delete on either side removes the file from the other. Continue?"
  }
  return "Mirror deletes anything in " + target + " that is not in the source. Continue?"
}

// Which keyboard targets a remote's row exposes, in visual order.
//
// The empty first entry is the ROW ITSELF — landing there means "no action
// selected", which is what makes Enter on a row toggle it open rather than
// firing whichever button the cursor last sat on.
//
// The list must match what is actually drawn: a collapsed row shows one action
// plus an overflow, and the rest appear only once expanded. If this returned
// them unconditionally the cursor could land on a button that is not on screen,
// and Enter would fire something invisible.
//
// Lives here rather than in the panel so it can be tested directly — the
// alternative was driving the live widget over IPC and inferring the list from
// how far the cursor could travel.
function rowActions(state) {
  if (!state || !state.remote) return [""]
  // An unfinished remote carries a type and nothing else (see classify_config in
  // status.py): `config create` wrote the section and the flow was abandoned
  // before answering a single question. There is nothing yet to mount or sync, so
  // offering those would be offering actions that cannot work. Removal is one
  // press away rather than hidden behind the overflow.
  //
  // Finishing one instead is a CLI job — `rclone-config resume <name>`, which the
  // panel does not expose. Wire that up here if it is ever wanted.
  if (state.remote.incomplete === true) return ["", "remove"]
  var actions = ["", "mount", "more"]
  if (!state.expanded) return actions
  // This order MUST match the order the buttons are declared in RemoteRow's
  // expanded strip. Highlighting is by NAME so a mismatch does not light up the
  // wrong button — but arrow-key traversal follows this list, so the highlight
  // would jump around the strip instead of moving along it. They disagreed
  // about `reconnect` until the remove button was added and the two were
  // compared side by side.
  // First, because it is what people expand a row to do. Double click on the
  // row does the same thing, but that affordance is invisible — someone looking
  // for their files opens the overflow and reads the list.
  if (state.mounted) actions.push("open")
  if (state.mounted) actions.push("pin")
  actions.push("sync")
  if (state.mounted) actions.push("move")
  if (state.needsReauth) actions.push("reconnect")
  actions.push("config")
  // LAST, and only once expanded: removing a working remote is rare and the
  // only irreversible thing a row can do, so it sits at the far end of the
  // expanded set rather than next to the everyday controls.
  actions.push("remove")
  return actions
}

function remoteSubtitle(remote, probes) {
  // Says what it is and what to do, rather than "unknown · unreachable" —
  // which is true but reads as a network fault the user might wait out.
  if (remote.incomplete === true) return "setup never finished — remove it"
  var type = String(remote.type || "unknown")
  var probe = probes ? probes[remote.name] : null
  if (!probe) return type
  if (!probe.online) return type + " · unreachable"
  if (probe.quotaKnown && Number(probe.totalBytes) > 0) {
    return type + " · " + formatBytes(probe.usedBytes) + " of " + formatBytes(probe.totalBytes)
  }
  return type + " · online"
}

// Find the live mount belonging to a remote.
//
// Prefix-based, because a mount's fs is rarely the plain remote name: mount
// "gdrive,skip_gdocs=true:" and rclone reports it back as "gdrive{YRXYK}:",
// rewriting the connection string into a hashed form. Neither equality nor a
// "name," test finds that. Accept the name followed by : , or { — and nothing
// else, so "gdrive" must not match "gdrivebackup:".
function mountForRemote(mounts, name) {
  var prefix = String(name || "")
  if (prefix === "" || !Array.isArray(mounts)) return null
  for (var i = 0; i < mounts.length; i++) {
    var fs = String(mounts[i].fs || "")
    if (fs.indexOf(prefix) !== 0) continue
    var next = fs.charAt(prefix.length)
    if (next === ":" || next === "," || next === "{") return mounts[i]
  }
  return null
}

// Shorten one end of a job for display. A remote ("box:", "gdrive:documents")
// is already short and is the most identifying thing there is, so it survives
// intact; a long local path collapses to ~/… and then to its last component.
function shortFs(fs, home) {
  var value = tildePath(String(fs || ""), home)
  if (value.length <= 22) return value
  var colon = value.indexOf(":")
  if (colon > 0 && colon < 20) {
    // Keep the remote name, shorten only the path after it.
    return value.substring(0, colon + 1) + "…/" + baseName(value)
  }
  return "…/" + baseName(value)
}

// A job's label is the `_group` rclone-rc set: "<verb> <src> -> <dst>".
//
// Shows BOTH ends. Showing only the destination produced titles like
// "copy → prov", which does not say what is being copied — the question a
// glance at a running job is meant to answer.
function jobTitle(job, home) {
  var label = String(job.label || "")
  var space = label.indexOf(" ")
  var verb = space > 0 ? label.substring(0, space) : "job"
  var arrow = label.indexOf(" -> ")
  // An unrecognised label is still better shown than replaced with "job".
  if (arrow < 0) return label !== "" ? label : "job"
  var src = label.substring(space + 1, arrow)
  var dest = label.substring(arrow + 4)
  return verb + " " + shortFs(src, home) + " → " + shortFs(dest, home)
}

function jobSubtitle(job) {
  if (job.error) return String(job.error)
  var parts = []
  var total = Number(job.totalBytes || 0)
  if (total > 0) parts.push(formatBytes(job.bytes) + " of " + formatBytes(total))
  var speed = formatSpeed(job.speed)
  if (speed) parts.push(speed)
  var eta = formatEta(job.eta)
  if (eta) parts.push(eta + " left")
  if (Number(job.errors || 0) > 0) parts.push(job.errors + " errors")
  return parts.length ? parts.join(" · ") : "starting…"
}

// Which configured remote does an fs string belong to?
//
// The inverse of mountForRemote, and it must handle the same forms: a plain
// "gdrive:documents", and the hashed "gdrive{YRXYK}:" that rclone reports for a
// mount created from a connection string. Returns null for a local path, which
// is correct — a local-to-local copy has no provider.
function remoteForFs(remotes, fs) {
  var value = String(fs || "")
  if (value === "" || !Array.isArray(remotes)) return null
  for (var i = 0; i < remotes.length; i++) {
    var name = String(remotes[i].name || "")
    if (name === "" || value.indexOf(name) !== 0) continue
    var next = value.charAt(name.length)
    if (next === ":" || next === "," || next === "{") return remotes[i]
  }
  return null
}

// A transfer's provider: whichever end of it is a configured remote. A download
// has the remote as source, an upload as destination.
function transferRemote(row, remotes) {
  return remoteForFs(remotes, row.srcFs) || remoteForFs(remotes, row.dstFs)
}

function transferSubtitle(row, remote) {
  var parts = []
  var size = Number(row.size || 0)
  if (size > 0) parts.push(formatBytes(row.bytes) + " of " + formatBytes(size))
  var speed = formatSpeed(row.speed)
  if (speed) parts.push(speed)
  var eta = formatEta(row.eta)
  if (eta) parts.push(eta + " left")
  // Which remote this is moving through, LAST — the same position RECENT uses,
  // so the eye finds the provider in one place across both lists. With more
  // than one drive configured, "9 MB · 191 KB/s" alone does not say whether
  // your upload or your backup is the thing saturating the link.
  var provider = remote ? String(remote.name || "") : ""
  if (provider) parts.push(provider)
  return parts.join(" · ")
}

// Subtitle for a finished transfer. Errors win over size — a failed transfer
// that shows only its byte count reads as success.
//
// `remote` names the provider. RECENT mixes providers, and the filename alone
// does not say which one a file came from. A NAME rather than a glyph, because
// the glyph set does not distinguish them: box, s3, pcloud and zoho all fall
// through to the same default cloud, so an icon would be actively wrong with
// two of those configured. Nerd Fonts has brand icons for a handful of
// providers and rclone supports 69.
function transferredSubtitle(row, remote) {
  var provider = remote ? String(remote.name || "") : ""
  if (row.error) return provider ? provider + " · " + String(row.error) : String(row.error)
  var size = Number(row.size || 0)
  var head = size > 0 ? formatBytes(size) : "done"
  return provider ? head + " · " + provider : head
}

// Offered as buttons and as keyboard targets, so the two cannot disagree about
// what exists or in what order.
var bwPresets = [
  { label: "Off", rate: "off" },
  { label: "1M", rate: "1M" },
  { label: "5M", rate: "5M" },
  { label: "10M", rate: "10M" }
]

// Does a bandwidth preset match what rclone currently reports?
//
// rclone answers in BINARY units, so a "5M" request reads back as "5Mi". A
// naive prefix test gets this wrong in a way that is easy to miss: "10Mi"
// starts with "1", so setting 10M lit up BOTH the 1M and 10M presets. Strip the
// binary "i" and compare whole values.
function bwMatches(current, preset) {
  var now = String(current || "").trim()
  var limited = now !== "" && now !== "off"
  if (String(preset) === "off") return !limited
  if (!limited) return false
  return now.replace(/i$/, "").toUpperCase() === String(preset).toUpperCase()
}

// One line describing what the SELECTED mode will do, always shown.
//
// Previously only the dangerous modes said anything, so the safe default was
// the one mode with no explanation — there was nothing to contrast "mirror"
// against, and "Copy or mirror" meant nothing on its own.
function syncModeHelp(mode, destination) {
  var where = String(destination || "").trim() !== "" ? destination : "the destination"
  if (mode === "mirror") {
    return "Makes " + where + " identical to the source. Files there that are "
         + "NOT in the source are deleted."
  }
  if (mode === "bisync") {
    return "Keeps both sides the same, in both directions. A delete on either "
         + "side removes the file from the other."
  }
  return "Adds files to " + where + ". Nothing there is ever deleted, even if "
       + "you delete it at the source."
}

// True for modes that can remove data.
function syncModeDestroys(mode) {
  return mode === "mirror" || mode === "bisync"
}

// ---- Google Drive setup content --------------------------------------------

// Google's own scope strings. Typing these by hand is the most common way to
// end up with a consent screen that fails later, so the panel offers a copy
// button rather than asking anyone to transcribe them.
var driveScopes = [
  "https://www.googleapis.com/auth/drive",
  "https://www.googleapis.com/auth/docs",
  "https://www.googleapis.com/auth/drive.metadata.readonly"
]

// The console walk-through, as DATA rather than markup, so it can be tested and
// edited without touching layout. These URLs are the part most likely to rot —
// Google redesigns this console regularly — so the test asserts their shape and
// this list is the single place to fix them.
var driveSetupSteps = [
  {
    title: "Create or pick a Google Cloud project",
    detail: "Any Google account works — it does not have to be the one whose Drive you are connecting.",
    url: "https://console.cloud.google.com/projectcreate",
    action: "Open console"
  },
  {
    title: "Enable the Google Drive API",
    detail: "Press Enable on the Drive API page for that project.",
    url: "https://console.cloud.google.com/apis/library/drive.googleapis.com",
    action: "Enable API"
  },
  {
    title: "Configure the OAuth consent screen",
    detail: "User type External · App name \"rclone\" · your email as support contact. Add the three Drive scopes (copy them below).",
    url: "https://console.cloud.google.com/apis/credentials/consent",
    action: "Open consent"
  },
  {
    // The single most consequential step: a Testing-mode app expires every
    // grant after 7 days, so Drive quietly stops working a week later.
    title: "PUBLISH the app — do not leave it in Testing",
    detail: "In Testing mode every grant expires after 7 days and Drive silently stops working. Publishing shows an \"unverified app\" warning you can accept for personal use.",
    url: "https://console.cloud.google.com/apis/credentials/consent",
    action: "Publish",
    warn: true
  },
  {
    title: "Create credentials → OAuth client ID",
    detail: "Application type must be Desktop app. Google then shows your Client ID and Client Secret.",
    url: "https://console.cloud.google.com/apis/credentials/oauthclient",
    action: "Create"
  }
]

var driveCredentialsUrl = "https://console.cloud.google.com/apis/credentials"

// The clouds offered as buttons behind "Add a remote", in rough order of how
// commonly people have one. All verified present in `config/providers`.
//
// Google Drive is in the SAME grid as everything else rather than getting its
// own row: it is one more cloud you might have, and singling it out made the
// panel read as "Google Drive, and also some others". It just routes to the
// wizard instead of the generic flow, because its setup needs console work
// rclone cannot reach — see `wizard: true`.
//
// Anything not here still works through "Any other provider", which opens
// `rclone config` for all 69 backends.
// rclone's own Help stays the default wording, and that is deliberate: a
// backend nobody anticipated must render with no work here. But a few of its
// labels name an INTERNAL FIELD rather than the thing being chosen — zoho's
// org step asks for a "Team Drive ID" while offering buttons labelled with
// company names, so the question and its answers read as different subjects.
//
// Keyed on the step NAME, rclone's stable identifier for the question, rather
// than on the help text, which changes whenever upstream rewords it.
var stepLabels = {
  config_team_drive_id: "Organization (Zoho calls this the Team Drive ID)"
}

function stepLabel(step) {
  if (!step) return ""
  var name = String(step.name || "")
  if (stepLabels.hasOwnProperty(name)) return stepLabels[name]
  return String(step.help || "")
}

var quickProviders = [
  { type: "drive",      label: "Google Drive", wizard: true },
  { type: "onedrive",   label: "OneDrive" },
  { type: "dropbox",    label: "Dropbox" },
  { type: "box",        label: "Box" },
  { type: "pcloud",     label: "pCloud" },
  { type: "jottacloud", label: "Jottacloud" },
  { type: "yandex",     label: "Yandex Disk" },
  // Zoho cannot START without a region — rclone exits "Error: no region set"
  // before the state machine runs, so there is no step to answer it in. `seed`
  // is asked by the panel first and passed to `rclone config create` as
  // key=value. Any backend with the same shape can be added the same way.
  // `form: true` means "no interactive setup" — every option is plain
  // key=value, so these are created in ONE call from a generated form rather
  // than by walking rclone's state machine. See BackendForm.qml.
  { type: "s3",         label: "S3 storage",   form: true },
  { type: "b2",         label: "Backblaze B2", form: true },
  { type: "sftp",       label: "SFTP",         form: true },
  { type: "webdav",     label: "WebDAV",       form: true },
  { type: "ftp",        label: "FTP",          form: true },
  { type: "zoho",       label: "Zoho WorkDrive", seed: {
      key: "region",
      prompt: "Which Zoho region? Use whichever domain you sign in at.",
      // .com first: it is Zoho's default and covers accounts worldwide. Living
      // in Europe does NOT imply zoho.eu — that is a separate data centre you
      // are only on if you signed up there.
      options: [
        { value: "com",    label: "zoho.com" },
        { value: "eu",     label: "zoho.eu" },
        { value: "in",     label: "zoho.in" },
        { value: "com.au", label: "zoho.com.au" },
        { value: "jp",     label: "zoho.jp" }
      ] } }
]

// DELIBERATELY ABSENT, each verified by starting a real flow:
//
//   zoho, iclouddrive   rclone refuses to begin at all — "no region set",
//                       "an Apple ID is required" — because they need a value
//                       BEFORE the state machine starts.
//   mega, protondrive,  the flow completes instantly asking nothing, which
//   koofr               writes a remote with no credentials. Our panel would
//                       report "connected" for something that cannot work.
//
// All five need the key=value form for non-state-machine backends, which does
// not exist yet; until it does they belong behind "Any other provider", where
// `rclone config` collects their fields properly. Listing a button that cannot
// finish is worse than not listing it.

// A remote name rclone will accept, derived from the backend type, made unique
// against what already exists so a second OneDrive does not collide.
function suggestRemoteName(type, existingRemotes) {
  var base = String(type || "remote").replace(/[^a-zA-Z0-9_-]/g, "")
  var taken = {}
  for (var i = 0; i < (existingRemotes || []).length; i++) {
    taken[String(existingRemotes[i].name)] = true
  }
  if (!taken[base]) return base
  for (var n = 2; n < 100; n++) {
    if (!taken[base + n]) return base + n
  }
  return base + "_new"
}

// ---- Setup -----------------------------------------------------------------

// Creates a Google Drive remote. The client SECRET arrives on stdin and is
// never passed as an argument TO THIS SCRIPT — argv is readable by any process
// via `ps`, stdin is not. It is then handed to rclone as an argument, so it is
// exposed in rclone's own argv for that one sub-second call; rclone offers no
// stdin input for config values (`--json` is argv too).
// Same handling as the enterprise Wi-Fi passphrase in Omarchy's own shell.

if (typeof module !== "undefined") {
  module.exports = {
    defaultStatus: defaultStatus, parseStatus: parseStatus,
    formatBytes: formatBytes, formatSpeed: formatSpeed, formatEta: formatEta,
    baseName: baseName, tildePath: tildePath, isActive: isActive, statusText: statusText,
    remoteSubtitle: remoteSubtitle, monogramFor: monogramFor,
    mountForRemote: mountForRemote, remoteForFs: remoteForFs,
    transferRemote: transferRemote,
    syncModeHelp: syncModeHelp, syncModeDestroys: syncModeDestroys, transferSubtitle: transferSubtitle,
    jobTitle: jobTitle, jobSubtitle: jobSubtitle, shortFs: shortFs,
    transferredSubtitle: transferredSubtitle,
    driveScopes: driveScopes, driveSetupSteps: driveSetupSteps,
    driveCredentialsUrl: driveCredentialsUrl,
    quickProviders: quickProviders, suggestRemoteName: suggestRemoteName,
    stepLabel: stepLabel, mountedSubtitle: mountedSubtitle, rowActions: rowActions,
    syncConfirmMessage: syncConfirmMessage, unmountAllMessage: unmountAllMessage,
    removeRemoteMessage: removeRemoteMessage,
    bwMatches: bwMatches, bwPresets: bwPresets
  }
}
