import QtQuick
import Quickshell
import qs.Commons
import "Model.js" as Model

// Headless state for the rclone plugin. Owns every subprocess and all polling;
// the panel only reads properties off this and calls its functions.
Item {
  id: root

  property var settings: ({})

  // A third-party plugin cannot use OMARCHY_PATH to find its own files — it
  // does not live under it. Resolving against this QML file works wherever the
  // plugin is checked out. Qt.resolvedUrl(".") keeps its trailing slash.
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")

  // ---- State, all of it written only by applyStatus() ----------------------
  property bool installed: false
  property bool daemonInstalled: false
  property string version: ""
  property bool rcRunning: false
  property string rcError: ""
  property var remotes: []
  // Config sections that are not remotes (see classify_config). Kept because
  // `config create` collides with these too — they are section names in the same
  // file — even though they are never shown as remotes.
  property var configResidue: []

  // Every name the config file holds. What the setup forms must refuse: creating
  // over any of them replaces that section and loses whatever it held.
  readonly property var allRemoteNames: {
    var names = []
    for (var i = 0; i < remotes.length; i++) names.push(String(remotes[i].name))
    for (var j = 0; j < configResidue.length; j++) names.push(String(configResidue[j]))
    return names
  }
  property var mounts: []
  property var autoMounts: []
  property var stats: ({})
  property var transferring: []
  property var transferred: []
  property int runningJobs: 0
  property var jobs: []
  property string bwLimit: "off"
  property var probes: ({})

  // ---- Provider config flow ------------------------------------------------
  // The state machine itself lives in ConfigFlow.qml; these aliases keep the
  // service's API unchanged for the panel and the IPC handler.
  readonly property alias flowStep: configFlow.step
  readonly property alias flowName: configFlow.name
  readonly property alias flowType: configFlow.type
  readonly property alias flowActive: configFlow.active
  readonly property alias flowBusy: configFlow.busy

  // The form description for a backend with no interactive setup, fetched from
  // config/providers on demand. Empty object means nothing is being set up.
  property var backendSchema: ({})
  readonly property bool backendSchemaLoading: schemaRunner.running

  function loadBackendSchema(type) {
    backendSchema = ({})
    if (!type) return
    schemaRunner.start(["python3", pluginDir + "status.py", "--provider-schema", String(type)])
  }

  function clearBackendSchema() { backendSchema = ({}) }

  property bool probing: false
  property string actionStatus: ""

  // What the panel's status line should show — "" for nothing, and a message the
  // user has no time to read counts as nothing.
  //
  // The status line is a ROW in the panel's column, so showing one grows the panel
  // and clearing it shrinks it back. Unmounting finishes in well under a second,
  // so "Unmounting…" appeared and vanished and the whole list visibly jumped down
  // and up again. Transient notes are therefore held back briefly: anything that
  // finishes inside the delay says nothing at all, which is right — the row
  // leaving the list is the feedback.
  //
  // Errors are never delayed. They persist rather than flicker, and they are the
  // case where the user actually needs the words.
  readonly property string statusLine:
    lastError !== "" && actionStatus === "" ? lastError
      : (_actionStatusDue ? actionStatus : "")

  property bool _actionStatusDue: false

  // Catches the direct `actionStatus = ""` assignments in the runners too, not
  // just the ones that go through report().
  onActionStatusChanged: if (actionStatus === "") {
    _actionStatusDue = false
    actionStatusDelay.stop()
  }
  property string lastError: ""

  // Model functions read plain properties, and a QML object exposes exactly
  // those, so `root` can be passed straight in — no intermediate copy.
  readonly property bool active: Model.isActive(root)
  readonly property string statusText: Model.statusText(root)

  // Every runner that represents a USER ACTION, so a button gated on `busy`
  // cannot fire twice — omitting the mount and pin runners here once let a second
  // click through while the first was still running.
  //
  // NOT the status poll, and NOT a probe. Both are background reads that cannot
  // conflict with anything, and including them made every button gated on `busy`
  // blink its disabled state:
  //
  //   * the poll runs every 2s while anything is happening and takes ~230ms;
  //   * a probe is a network round-trip PER REMOTE, and opening the panel starts
  //     one on its own (probeIfStale) — so simply opening the panel dimmed the
  //     refresh and unmount-all buttons for seconds, and doing that just before
  //     an unmount produced dim, undim, dim, undim around the click.
  //
  // The runners each refuse to start while already running, so nothing here needs
  // a global flag to prevent a double click — `probing` guards the probe button
  // itself. `busy` means "a user action that changes something is in flight".
  readonly property bool busy: actionRunner.running || mountRunner.running
    || pinRunner.running || createRunner.running || syncRunner.running

  // Two intervals, because the two states have genuinely different costs: a
  // running transfer wants a live progress bar, an idle daemon wants to be left
  // alone. Polling idle at 2s would spawn a subprocess every 2s forever to
  // re-read a number that never changes.
  readonly property int idleIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int activeIntervalSec: intSetting("activeIntervalSec", 2, 1, 60)

  // ---- Settings ------------------------------------------------------------

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ---- Polling -------------------------------------------------------------

  function refresh() {
    statusRunner.start(["python3", pluginDir + "status.py", "25"])
  }

  // Expensive: one network round-trip PER REMOTE. Only ever from an explicit
  // user action, never from a timer.
  function probe() {
    if (!rcRunning || remotes.length === 0) return
    if (!probeRunner.start(["python3", pluginDir + "status.py", "--probe"])) return
    probing = true
    report("Checking " + remotes.length + (remotes.length === 1 ? " remote…" : " remotes…"), false)
  }

  // rclone.conf's mtime at the last poll. 0 means "not seen yet".
  property int _configMtime: 0

  // The daemon builds a filesystem per remote and CACHES it, so a remote that
  // is created or repaired after rcd started keeps answering from the config it
  // had at first use — the panel then shows a working remote as unreachable
  // with no way back short of restarting the daemon. Measured on zoho: the CLI
  // listed files while `operations/about` still returned the pre-setup error.
  //
  // Keyed off the config file rather than off our own flows because
  // `rclone config reconnect` runs in its own terminal, so there is no
  // completion for us to hook. Any edit, from anywhere, is caught.
  //
  // The first poll only records the baseline: clearing there would fire on
  // every shell start, and once per monitor, for nothing.
  function _noteConfigChange(mtime) {
    if (mtime <= 0) return
    var previous = _configMtime
    _configMtime = mtime
    if (previous === 0 || previous === mtime) return
    forgetRunner.start([pluginDir + "rclone-rc", "forget-config"])
  }

  // Config sections that are not remotes — no `type`, so rclone does not list
  // them and nothing can mount or repair them. status.py reports them instead of
  // dressing them up as remotes; clear them here so they stop accumulating.
  //
  // Reaped rather than merely hidden because the daemon RE-CREATES them: an
  // orphaned VFS (left behind by a forced unmount) writes its refreshed OAuth
  // token back into a section that has been deleted, and rclone obliges by
  // making the section again. Hiding alone would leave the file growing a new
  // dead section per removed remote per token refresh.
  //
  // Silent: the user removed these remotes already, so there is nothing to
  // report. `start()` refuses while a run is in flight, so a resurrection that
  // outpaces the poll cannot stack up reaps.
  function _reapResidue(names) {
    if (!names || names.length === 0) return
    reapRunner.start([pluginDir + "rclone-rc", "reap-residue"])
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.rcError || "Could not read rclone status"
      return
    }
    installed = parsed.installed === true
    daemonInstalled = parsed.daemonInstalled === true
    version = String(parsed.version || "")
    rcRunning = parsed.rcRunning === true
    rcError = String(parsed.rcError || "")
    remotes = parsed.remotes
    mounts = parsed.mounts
    if (JSON.stringify(autoMounts) !== JSON.stringify(parsed.autoMounts)) _mountFailures = ({})
    suppressed = parsed.suppressed
    autoMounts = parsed.autoMounts
    stats = parsed.stats
    transferring = parsed.transferring
    transferred = parsed.transferred
    runningJobs = Number(parsed.runningJobs || 0)
    jobs = parsed.jobs
    bwLimit = String(parsed.bwLimit || "off")
    // A fast poll carries no probe results; keeping the previous ones stops the
    // remote list flickering back to "unknown" every couple of seconds.
    if (parsed.probed === true) { probes = parsed.probes; _lastProbeMs = Date.now() }
    lastError = ""
    _noteConfigChange(Number(parsed.configMtime || 0))
    configResidue = parsed.configResidue
    _reapResidue(parsed.configResidue)
    reconcileMounts()
  }

  // ---- User feedback -------------------------------------------------------

  // Single path for anything shown in the panel's status line, so a transient
  // note and a real error cannot disagree about which one is on screen.
  function report(message, isError) {
    if (isError) {
      lastError = message
      actionStatus = message
      // Straight to visible: an error is not a flicker risk and is worth a jump.
      _actionStatusDue = true
      actionStatusDelay.stop()
    } else {
      actionStatus = message
      if (message !== "") lastError = ""
      _actionStatusDue = false
      if (message !== "") actionStatusDelay.restart()
    }
    actionStatusTimer.restart()
  }

  // ---- Remotes -------------------------------------------------------------

  // First-run dead end: with no rclone there is nothing to read, mount or
  // configure, so the panel is inert until this is done. It runs in a terminal
  // rather than silently in the background because `omarchy pkg add` needs a
  // sudo password, and a package install that asks for credentials must be
  // visible — a hidden polkit prompt behind a bar popup is how you get a
  // "nothing happened" report.
  function installRclone() {
    report("Installing rclone…", false)
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation", "omarchy", "pkg", "add", "rclone"
    ])
  }

  // Setup runs in a real terminal on purpose for providers the in-panel flow
  // does not cover. Every OAuth backend needs a browser handshake against
  // rclone's local callback, and `rclone config` already drives that correctly.
  function addRemote() {
    report("Opened rclone config", false)
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation", "rclone", "config"
    ])
  }

  // Re-runs the OAuth handshake for a remote whose grant has expired or been
  // revoked. In a terminal because re-auth is inherently interactive — rclone
  // asks whether to keep the existing token before opening the browser.
  function reconnectRemote(name) {
    if (!name) return
    report("Re-authenticating " + name + "…", false)
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "rclone", "config", "reconnect", String(name) + ":"
    ])
  }

  // True when a remote's last probe failed specifically on authentication.
  function needsReauth(name) {
    var probe = probes[String(name)]
    return !!probe && probe.online === false && probe.errorKind === "auth"
  }

  function probeIfStale(maxAgeMs) {
    if (!rcRunning || remotes.length === 0) return
    var now = Date.now()
    if (_lastProbeMs !== 0 && (now - _lastProbeMs) < maxAgeMs) return
    _lastProbeMs = now
    probe()
  }

  property double _lastProbeMs: 0

  // Deletes a remote from rclone.conf. Only ever offered for a half-made one
  // (no `type`), which cannot be repaired — `rclone config update` has nothing
  // to work from. Callers must confirm first; this asks nothing.
  //
  // Runs `rclone` directly rather than through the daemon: the rc API has no
  // config-delete, and a typeless section is invisible to it anyway.
  function removeRemote(name) {
    if (!name) return
    // Via rclone-rc, not `rclone config delete` directly: a live mount has to
    // come down FIRST and its pin has to go, and those three steps have to
    // happen in that order. Deleting the config out from under a mount leaves
    // FUSE pointing at a backend that no longer exists.
    if (!mountRunner.start([pluginDir + "rclone-rc", "remove-remote", String(name)])) return
    report("Removing " + name + "…", false)
  }

  function reconfigureRemote(name) {
    if (!name) return
    report("Opened rclone config", false)
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "rclone", "config", "update", String(name)
    ])
  }

  // Creates a Drive remote, then lets rclone run its OAuth handshake (it serves
  // a callback on 127.0.0.1:53682 and opens the browser).
  //
  // The client ID and SECRET both go over stdin as JSON, and `rclone-config`
  // forwards them to the daemon in an HTTP body, so neither ever appears in any
  // process's argv. The previous version handed the secret to
  // `rclone config create` as an argument, where /proc/<pid>/cmdline exposed it
  // to every local process for the length of the call — reported by the
  // marketplace reviewer, and the same hole existed for every provider password.
  function createDriveRemote(name, clientId, clientSecret) {
    if (createRunner.running) return
    _authUrlOpened = false
    _creatingName = String(name || "gdrive")
    createRunner.secret = JSON.stringify({
      parameters: {
        client_id: String(clientId || ""),
        client_secret: String(clientSecret || ""),
        scope: "drive"
      }
    })
    if (!createRunner.start(["python3", pluginDir + "rclone-config", "connect",
                             String(name || "gdrive"), "drive"])) {
      createRunner.secret = ""
      return
    }
    report("Signing in to Google — finish in your browser…", false)
  }

  property bool _authUrlOpened: false
  // Remembered across the async OAuth handshake so the panel can offer to mount
  // the remote once it actually exists.
  property string _creatingName: ""

  // Emitted only after `rclone config create` succeeds — i.e. after the browser
  // handshake finished and the remote is real. A mount attempted any earlier
  // would race a remote that does not exist yet.
  signal remoteCreated(string name)

  // rclone normally opens the browser itself; if it only tells us the URL we
  // open it. Same fallback as the first-party Dropbox plugin. Fed from two
  // places: the Drive wrapper's output, and ConfigFlow's oauthstatus poll (the
  // provider flows run their handshake inside the daemon, whose output we never
  // see). The guard makes it open-once per flow, not once per session.
  function openAuthUrlIn(text) {
    if (_authUrlOpened) return
    var match = String(text || "").match(/https?:\/\/\S*(accounts\.google\.com|127\.0\.0\.1:53682)\S*/)
    if (!match || !match[0]) return
    _authUrlOpened = true
    Qt.openUrlExternally(match[0])
  }

  function copyText(text, label) {
    var value = String(text || "")
    if (value === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
    report("Copied " + (label || "text"), false)
  }

  // Drives any backend that needs more than a one-shot create. Non-OAuth
  // backends finish on the first call (measured: every one of s3, b2, webdav,
  // sftp, crypt returns done immediately), so this loop only really runs for
  // Reset the open-once guard per flow, or a second setup in the same session
  // would never get its browser opened.
  function startProviderFlow(name, type, seeds) {
    _authUrlOpened = false
    configFlow.start(name, type, seeds)
  }
  function answerFlow(value) { configFlow.answer(value) }
  function abortFlow() { configFlow.abort() }

  // ---- Mounts --------------------------------------------------------------

  function expandPath(path) {
    var value = String(path || "")
    var home = Quickshell.env("HOME") || ""
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.substring(1)
    if (value.indexOf("$HOME") === 0) return home + value.substring(5)
    return value
  }

  function mountForRemote(name) {
    return Model.mountForRemote(mounts, name)
  }

  function isMounted(mountPoint) {
    var target = expandPath(mountPoint)
    for (var i = 0; i < mounts.length; i++) {
      if (String(mounts[i].mountPoint) === target) return true
    }
    return false
  }

  // The login-mount entry for a remote, if it has one. Lets the mount switch
  // turn a remote back on without asking where — the pin already records the
  // folder and the durable fs.
  function suppressedPaths() { return suppressed }

  // Every configured backend type, so an icon can be made distinct against the
  // set actually present.
  function remoteTypes() {
    var out = []
    for (var i = 0; i < remotes.length; i++) out.push(String(remotes[i].type || ""))
    return out
  }

  function pinnedSpecFor(name) {
    for (var i = 0; i < autoMounts.length; i++) {
      var spec = autoMounts[i]
      if (!spec || !spec.fs) continue
      if (Model.remoteForFs(remotes, spec.fs)
          && String(Model.remoteForFs(remotes, spec.fs).name) === String(name)) return spec
    }
    return null
  }

  function isAutoMounted(mountPoint) {
    for (var i = 0; i < autoMounts.length; i++) {
      if (autoMounts[i] && String(autoMounts[i].mountPoint) === String(mountPoint)) return true
    }
    return false
  }

  // Re-applies declared mounts whenever any are missing. Runs after every
  // refresh, which matters more than it sounds: rcd owns the mounts, so if it
  // restarts (crash, Restart=on-failure, an rclone upgrade) every mount is
  // silently gone. A one-shot systemd unit would never notice; this does, and
  // costs nothing when there is nothing to do.
  // Mount points that have failed to restore, and how often. A pin can hold an
  // fs rclone will not accept — that is exactly what a stale
  // "gdrive{YRXYK}:" pin was — and retrying it forever meant every LATER pin
  // in the list never got a turn. One bad entry silently disabled the rest.
  property var _mountFailures: ({})

  // Mount points the user switched OFF by hand, read from disk via status.py.
  //
  // Without this, reconcile put a pinned mount straight back within ~1.5s —
  // the unmount itself schedules the refresh that restores it, so the switch
  // appeared to do nothing. It is on DISK rather than in memory because the
  // widget is instantiated once per monitor: the instance you clicked
  // suppressed the mount, and the other instance reconciled it back.
  property var suppressed: []

  function reconcileMounts() {
    // Stand down while a pin write is in flight too, not just a mount. A move
    // updates the pin AFTER the remount succeeds, so for that brief window the
    // pin file still names the old folder — and a refresh landing there would
    // "restore" the old mount and leave two mounts of the same remote.
    if (!rcRunning || mountRunner.running || pinRunner.running) return
    for (var i = 0; i < autoMounts.length; i++) {
      var spec = autoMounts[i]
      if (!spec || !spec.fs || !spec.mountPoint) continue
      if (isMounted(spec.mountPoint)) continue
      if (suppressed.indexOf(expandPath(spec.mountPoint)) >= 0) continue
      if (Number(_mountFailures[spec.mountPoint] || 0) >= 3) continue
      _pendingMount = String(spec.mountPoint)
      mountRemote(String(spec.fs), String(spec.mountPoint))
      return // one at a time; the next refresh picks up the rest
    }
  }

  property string _pendingMount: ""

  function _noteMountResult(ok) {
    if (_pendingMount === "") return
    var failures = _mountFailures
    if (ok) delete failures[_pendingMount]
    else {
      failures[_pendingMount] = Number(failures[_pendingMount] || 0) + 1
      if (failures[_pendingMount] === 3) {
        report("Cannot restore " + _pendingMount + " — check its login mount", true)
      }
    }
    _mountFailures = failures
    _pendingMount = ""
  }

  function mountRemote(fs, mountPoint) {
    if (!rcRunning) return
    // Mounting again is the user changing their mind; stop suppressing it.
    var target0 = expandPath(mountPoint)
    if (suppressed.indexOf(target0) >= 0) {
      suppressRunner.start([pluginDir + "rclone-rc", "unsuppress", "", target0])
    }
    if (!mountRunner.start([pluginDir + "rclone-rc", "mount", String(fs), expandPath(mountPoint)])) return
    report("Mounting " + fs + "…", false)
  }

  // `manual` marks a deliberate switch-off, which suppresses auto-remount until
  // the user turns it back on. A move is NOT manual — it wants the mount back.
  // `force` bypasses the pending-upload check in rclone-rc, which DISCARDS
  // anything still queued in the VFS cache. The helper has always supported it
  // and its refusal message even says "wait, or force" — but nothing in the UI
  // passed it, so the panel named an action it did not offer and a mount with
  // permanently stuck uploads could not be unmounted at all. Callers must
  // confirm with the user first; nothing here asks on their behalf.
  function unmountPath(mountPoint, manual, force) {
    if (!rcRunning) return
    var target = expandPath(mountPoint)
    var argv = [pluginDir + "rclone-rc", "unmount", "", target]
    if (force === true) argv.push("force")
    if (!mountRunner.start(argv)) return
    if (manual) suppressRunner.start([pluginDir + "rclone-rc", "suppress", "", target])
    report("Unmounting…", false)
  }

  // Move a live mount to a different folder.
  //
  // rclone cannot relocate a FUSE mount in place, so this really is unmount +
  // mount — but as ONE action, and the login pin moves with it. Doing it by
  // hand means three steps (unmount, mount elsewhere, re-pin) with a window
  // where the pin still names the old folder.
  property string _remountFs: ""
  property string _remountNew: ""
  property string _remountOld: ""
  property bool _remountWasPinned: false

  function remountAt(fs, oldPath, newPath) {
    if (!rcRunning) return
    var target = expandPath(newPath)
    var previous = expandPath(oldPath)
    if (target === "" || target === previous) return
    _remountFs = String(fs)
    _remountNew = target
    _remountOld = previous
    _remountWasPinned = isAutoMounted(previous)
    if (!mountRunner.start([pluginDir + "rclone-rc", "remount", String(fs), target, previous])) {
      _remountFs = ""
      return
    }
    report("Moving mount…", false)
  }

  function setAutoMount(fs, mountPoint, enabled) {
    if (!pinRunner.start([pluginDir + "rclone-rc", enabled ? "pin" : "unpin",
                          String(fs), expandPath(mountPoint)])) return
    report(enabled ? "Will mount at login" : "Removed from login mounts", false)
  }

  // xdg-open, not a hardcoded file manager: this plugin is meant to run on
  // other people's machines, and nautilus is not a safe assumption.
  // Empties the RECENT list. The daemon is the only store — rclone keeps
  // finished transfers in memory per stats group and there is no file to edit,
  // so this genuinely discards them rather than hiding them from the panel.
  // ---- Everything, at once --------------------------------------------------
  // Deliberately NOT called "pause": rclone cannot resume a stopped job. Picking
  // the work back up means re-running it, which is cheap only because copy skips
  // what already reached the destination. Promising a pause we cannot deliver
  // would be the more comfortable label and the wrong one.
  function stopAllJobs() {
    if (!rcRunning) return "daemon down"
    if (!actionRunner.start([pluginDir + "rclone-rc", "stop-all"])) return "busy"
    report("Stopping all transfers…", false)
    return "ok"
  }

  // Runs on mountRunner, not actionRunner, for one specific reason:
  // reconcileMounts() stands down while mountRunner is running, so nothing gets
  // restored underneath the sweep. The helper also suppresses each mount as it
  // takes it down, which is what stops the next poll putting them all back.
  function unmountAll(force) {
    if (!rcRunning) return "daemon down"
    var argv = [pluginDir + "rclone-rc", "unmount-all"]
    if (force === true) argv.push("force")
    if (!mountRunner.start(argv)) return "busy"
    report(force === true ? "Force unmounting everything…" : "Unmounting everything…", false)
    return "ok"
  }

  // Writes still sitting in the VFS cache across every live mount. Drives the
  // wording of the confirmation, so the user is told what they stand to lose
  // rather than being asked a generic "are you sure".
  function totalPending() {
    var total = 0
    for (var i = 0; i < mounts.length; i++) total += Number(mounts[i].pendingCount || 0)
    return total
  }

  function clearRecents() {
    if (!rcRunning) { report("The rclone daemon is not running", true); return "daemon down" }
    // A shared runner, so a refusal here means something else is mid-flight.
    // Returning WHY rather than falling out silently: the first version
    // returned nothing on both branches and a no-op was indistinguishable from
    // a success.
    if (!actionRunner.start([pluginDir + "rclone-rc", "clear-recents"])) return "busy"
    report("Clearing recent transfers…", false)
    return "ok"
  }

  function openMount(mount) {
    if (!mount || !mount.mountPoint) return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-open", String(mount.mountPoint)])
  }

  // ---- Sync ----------------------------------------------------------------

  // mode is "copy" (additive, never deletes) or "mirror" (sync/sync, which
  // DELETES at the destination). The two are separate verbs all the way down to
  // rclone-rc so nothing can reach the destructive one by passing a flag.
  //
  // The job runs async inside rcd and is labelled with a _group, so its own
  // progress is readable via core/stats?group=… rather than the daemon-wide
  // counters, which are cumulative for the whole rcd lifetime.
  function startSync(mode, srcFs, dstFs, dryRun) {
    if (!rcRunning) return
    if (String(srcFs) === "" || String(dstFs) === "") return
    var argv = [pluginDir + "rclone-rc", String(mode), String(srcFs), expandPath(dstFs)]
    if (dryRun) argv.push("dry")
    if (!syncRunner.start(argv)) return
    report((dryRun ? "Previewing " : "Starting ") + mode + "…", false)
  }

  // Two-way. Needs seeding on the first run for a given pair — rclone aborts
  // otherwise — and seeding is not a no-op: it merges both sides (measured: a
  // union, with path1 winning conflicts) and writes the baseline listings.
  function startBisync(path1, path2, resync, dryRun) {
    if (!rcRunning) return
    if (String(path1) === "" || String(path2) === "") return
    var flags = []
    if (resync) flags.push("resync")
    if (dryRun) flags.push("dry")
    var argv = [pluginDir + "rclone-rc", "bisync", String(path1), expandPath(path2)]
    if (flags.length) argv.push(flags.join(","))
    if (!syncRunner.start(argv)) return
    report((dryRun ? "Previewing " : "Starting ") + (resync ? "first two-way sync…" : "two-way sync…"), false)
  }

  // Applies to the whole daemon, not one job — every transfer shares it.
  function setBwLimit(rate) {
    if (!rcRunning) return
    if (!actionRunner.start([pluginDir + "rclone-rc", "bwlimit", String(rate)])) return
    report(rate === "off" ? "Bandwidth limit removed" : "Bandwidth limited to " + rate, false)
  }

  function stopJob(id) {
    if (!rcRunning) return
    if (!syncRunner.start([pluginDir + "rclone-rc", "stop", String(id)])) return
    report("Stopping job…", false)
  }

  // ---- Daemon --------------------------------------------------------------

  function installDaemon() {
    if (!actionRunner.start(["bash", pluginDir + "setup-daemon.sh"])) return
    report("Setting up the rclone daemon…", false)
  }

  function restartDaemon() {
    if (!actionRunner.start(["systemctl", "--user", "restart", "rclone-rcd.service"])) return
    report("Restarting rclone rcd…", false)
  }

  CommandRunner {
    id: schemaRunner
    failMessage: "Could not read the backend's options"
    onSucceeded: function(output) {
      var parsed
      try {
        parsed = JSON.parse(String(output || "").trim())
      } catch (e) {
        root.report("Could not read the backend's options", true)
        return
      }
      if (parsed.ok !== true) {
        root.report(String(parsed.error || "Unknown backend"), true)
        return
      }
      root.backendSchema = parsed
    }
    onFailed: function(message) { root.report(message, true) }
  }

  ConfigFlow {
    id: configFlow
    pluginDir: root.pluginDir
    onReported: function(message, isError) { root.report(message, isError) }
    onFinished: function(remoteName) { root.remoteCreated(remoteName) }
    onRefreshNeeded: delayedRefresh.restart()
  }

  // The OAuth handshake now happens inside the DAEMON, not in a child process of
  // ours: every config step goes over the rc API so that credentials stay out of
  // argv. The daemon does open the browser itself — verified — but when it
  // cannot (no session environment, no xdg-open) the auth URL exists only in its
  // log, and the panel would sit at "Signing in…" forever with no way through.
  //
  // Polled, not awaited: the call that answers the OAuth question BLOCKS until
  // the sign-in completes, and the URL only exists while it is in flight. Runs
  // for both paths — the provider flows and the Drive wizard.
  Timer {
    interval: 1500
    repeat: true
    running: createRunner.running || configFlow.busy
    onTriggered: authStatusRunner.start(["python3", root.pluginDir + "rcclient.py",
                                         "config/oauthstatus"])
  }

  CommandRunner {
    id: authStatusRunner
    // Deliberately silent on failure: with no sign-in in progress the method
    // errors, which is the common case on every poll of a non-OAuth step.
    onSucceeded: function(output) {
      try {
        var parsed = JSON.parse(String(output || "").trim())
        if (String(parsed.status) === "running") root.openAuthUrlIn(String(parsed.authUrl || ""))
      } catch (e) { /* not JSON: nothing to open */ }
    }
  }

  // ---- Timers --------------------------------------------------------------

  Timer {
    interval: (root.active ? root.activeIntervalSec : root.idleIntervalSec) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 1200
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    onTriggered: root.actionStatus = ""
  }

  // Long enough that a mount, unmount or pin never shows a word — those finish in
  // a few hundred ms — and short enough that anything genuinely slow still
  // explains itself.
  Timer {
    id: actionStatusDelay
    interval: 700
    onTriggered: root._actionStatusDue = true
  }

  // ---- Runners -------------------------------------------------------------

  CommandRunner {
    id: statusRunner
    failMessage: "Could not run the rclone status helper"
    onSucceeded: function(output) { root.applyStatus(output) }
    onFailed: function(message) { root.lastError = message }
  }

  CommandRunner {
    id: probeRunner
    failMessage: "Remote check failed"
    onSucceeded: function(output) {
      root.probing = false
      root.applyStatus(output)
      root.actionStatus = ""
    }
    onFailed: function(message) {
      root.probing = false
      root.report(message, true)
    }
  }

  CommandRunner {
    id: mountRunner
    failMessage: "Mount failed"
    onSucceeded: function() {
      root._noteMountResult(true)
      // A move carries its pin across; a plain mount has nothing to carry.
      if (root._remountFs !== "" && root._remountWasPinned) {
        pinRunner.start([root.pluginDir + "rclone-rc", "repin",
                         root._remountFs, root._remountNew, root._remountOld])
      }
      root._remountFs = ""
      root.actionStatus = ""
      delayedRefresh.restart()
    }
    onFailed: function(message) {
      root._noteMountResult(false)
      // rclone-rc aborts rather than mounting a second copy when the old mount
      // will not let go, so the original is still live and usable here.
      root._remountFs = ""
      root.report(message, true)
      delayedRefresh.restart()
    }
  }

  CommandRunner {
    id: pinRunner
    failMessage: "Could not update the login mounts"
    // Re-read either way, so the pin icon reflects what is on disk rather than
    // what we hoped we wrote.
    onSucceeded: function() { delayedRefresh.restart() }
    onFailed: function(message) { root.report(message, true); delayedRefresh.restart() }
  }

  CommandRunner {
    id: syncRunner
    failMessage: "Job command failed"
    onSucceeded: function() { root.actionStatus = ""; delayedRefresh.restart() }
    onFailed: function(message) { root.report(message, true); delayedRefresh.restart() }
  }

  CommandRunner {
    id: suppressRunner
    failMessage: "Could not record the switch state"
    onSucceeded: function() { delayedRefresh.restart() }
    onFailed: function(message) { root.report(message, true) }
  }

  CommandRunner {
    id: reapRunner
    failMessage: "Could not clear leftover config sections"
    // No success TOAST, and no refresh kick either: deleting the section changes
    // rclone.conf's mtime, which the next poll already turns into a forget-config
    // plus a re-probe. Adding one here would run that twice per reap.
    //
    // It does go to the journal, though — this edits the user's config without
    // being asked, so `journalctl --user | grep omarchy-shell` has to be able to
    // say what was removed and when.
    onSucceeded: function(output) { console.log("rclone: reaped config residue:", output) }
    onFailed: function(message) { root.report(message, true) }
  }

  CommandRunner {
    id: forgetRunner
    failMessage: "Could not refresh the daemon's view of the config"
    // Deliberately silent on success: this fires on its own after any config
    // edit, and a toast for routine bookkeeping the user never asked for is
    // noise. A probe result changing from broken to working is the feedback.
    onSucceeded: function() { root.probe() }
    onFailed: function(message) { root.report(message, true) }
  }

  CommandRunner {
    id: actionRunner
    failMessage: "Command failed"
    onSucceeded: function() { root.actionStatus = ""; delayedRefresh.restart() }
    onFailed: function(message) { root.report(message, true); delayedRefresh.restart() }
  }

  CommandRunner {
    id: createRunner
    failMessage: "rclone config create failed"
    // The helper reports a refused setup as {"ok":false,"error":…} and still
    // exits 0 — it is a JSON protocol, not an exit status — so a zero exit is
    // NOT success on its own. Announcing "connected" on exit code alone would
    // claim a working remote when rclone had rejected the credentials.
    onSucceeded: function(output) {
      var parsed = null
      try { parsed = JSON.parse(String(output || "").trim()) } catch (e) { parsed = null }
      if (parsed && parsed.ok === false) {
        root.report(String(parsed.error || "Could not connect Google Drive"), true)
        root._creatingName = ""
        delayedRefresh.restart()
        return
      }
      root.report("Google Drive connected", false)
      delayedRefresh.restart()
      if (root._creatingName !== "") root.remoteCreated(root._creatingName)
      root._creatingName = ""
    }
    onFailed: function(message) {
      root.report(message, true)
      root._creatingName = ""
      delayedRefresh.restart()
    }
  }
}
