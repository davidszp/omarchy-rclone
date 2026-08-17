import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup. This file owns layout, keyboard handling and IPC only;
// state lives in Service.qml and each row is its own component.
Panel {
  id: root
  moduleName: "io.github.davidszp.omarchy-rclone"
  ipcTarget: "io.github.davidszp.omarchy-rclone"
  manageIpc: false

  property string focusSection: "bandwidth"
  property int remoteIndex: 0
  // Horizontal position within the focused remote row. 0 is the row itself;
  // 1..3 are its action buttons. Left/right move here, Enter activates.
  property int actionIndex: 0
  property bool cursorActive: false
  property bool setupOpen: false
  // Remote name whose inline "mount as…" form is open; "" means none.
  property string mountPromptFor: ""
  // Remote name whose inline copy/mirror form is open; "" means none.
  property string syncPromptFor: ""
  // Remote name whose "move the mount" form is open; "" means none.
  property string movePromptFor: ""
  // Remote whose secondary actions are revealed; "" means none.
  property string expandedRemote: ""
  // One entry point for adding a remote instead of three rows.
  property bool addOpen: false

  // The ScrollBar is drawn OVER the content, so a row with buttons at its right
  // edge ends up underneath it. Reserve a gutter for it.
  //
  // Constant rather than conditional on `panelFlick.interactive`: narrowing the
  // column changes where text wraps, which changes its height, which changes
  // whether it overflows — a feedback loop. A few px of unused width when there
  // is nothing to scroll is the cheaper trade.
  readonly property int scrollGutter: Style.space(8)

  readonly property color barIconColor: rclone.rcRunning ? barForeground : Qt.darker(barForeground, 1.55)
  // Any inline form owns the keyboard while open — otherwise r/c/a would be
  // swallowed as panel shortcuts while typing a mount path.
  // An open confirmation counts as a form: it must swallow the bare-letter
  // shortcuts too, or answering a "discard these files?" dialog with a stray
  // keystroke could fire `a` and swap the whole view out underneath it.
  readonly property bool formOpen: setupOpen || mountPromptFor !== "" || syncPromptFor !== ""
    || confirmAction !== null || formBackend !== null
    || movePromptFor !== "" || addOpen || rclone.flowActive

  // Keyboard model: the panel is a list of SECTIONS, each a row of targets.
  // Up/down moves between sections (and between remote rows), left/right moves
  // within the current row, Enter activates. Sections that are not on screen are
  // not in the order, so the cursor can never land somewhere invisible.
  function sectionOrder() {
    var order = []
    if (rclone.rcRunning) order.push("bandwidth")
    if (rclone.remotes.length > 0) order.push("remotes")
    if (addOpen) order.push("providers")
    order.push("actions")
    return order
  }

  // How many targets the current row has.
  function sectionTargetCount(section) {
    if (section === "bandwidth") return Model.bwPresets.length
    if (section === "remotes") return actionCount(selectedRemote())
    if (section === "providers") return Model.quickProviders.length
    // "Add a remote", plus "Any other provider" once the grid is open.
    return addOpen ? 2 : 1
  }

  function ensureCursor() {
    var order = sectionOrder()
    if (order.indexOf(focusSection) < 0) focusSection = order[0]
    if (focusSection === "remotes") {
      remoteIndex = Math.max(0, Math.min(rclone.remotes.length - 1, remoteIndex))
    }
    actionIndex = Math.max(0, Math.min(sectionTargetCount(focusSection) - 1, actionIndex))
  }

  function moveSection(delta) {
    var order = sectionOrder()
    var at = order.indexOf(focusSection)
    var next = Math.max(0, Math.min(order.length - 1, at + delta))
    if (next === at) return
    focusSection = order[next]
    // Entering the remotes list from above lands on the first row, from below
    // on the last — so the cursor keeps travelling in the direction you pushed.
    if (focusSection === "remotes") {
      remoteIndex = delta > 0 ? 0 : Math.max(0, rclone.remotes.length - 1)
    }
    actionIndex = 0
  }

  function moveCursor(dx, dy) {
    if (confirmAction !== null) {
      if (dx !== 0) confirmSelection = confirmSelection === 0 ? 1 : 0
      return
    }
    cursorActive = true
    ensureCursor()

    if (dx !== 0) {
      actionIndex = Math.max(0, Math.min(sectionTargetCount(focusSection) - 1, actionIndex + dx))
      return
    }
    if (dy === 0) return

    // Within the remotes list, vertical movement walks rows before leaving.
    if (focusSection === "remotes") {
      var target = remoteIndex + dy
      if (target >= 0 && target < rclone.remotes.length) {
        remoteIndex = target
        actionIndex = Math.max(0, Math.min(actionCount(selectedRemote()) - 1, actionIndex))
        return
      }
    }
    moveSection(dy > 0 ? 1 : -1)
  }

  // Gathers the per-remote facts Model.rowActions needs. The branching itself
  // lives in Model.js so it can be tested without driving the live widget.
  function rowActions(remote) {
    if (!remote) return [""]
    return Model.rowActions({
      remote: remote,
      mounted: rclone.mountForRemote(remote.name) !== null,
      expanded: expandedRemote === String(remote.name),
      needsReauth: rclone.needsReauth(remote.name)
    })
  }

  function actionCount(remote) { return rowActions(remote).length }

  function focusedActionName() {
    var actions = rowActions(selectedRemote())
    return actions[Math.max(0, Math.min(actions.length - 1, actionIndex))]
  }

  function selectedRemote() {
    if (rclone.remotes.length === 0) return null
    return rclone.remotes[Math.max(0, Math.min(remoteIndex, rclone.remotes.length - 1))]
  }

  // Enter runs whichever target the cursor is on — the same calls the mouse
  // makes, so each action has exactly one implementation.
  function activateCursor() {
    // A confirmation is modal: it consumes Enter before anything underneath.
    // This lives here, not in the key catcher, because the IPC `activate` calls
    // this function directly — when the check sat in the catcher instead, a
    // scripted activate re-fired the underlying action and re-asked the same
    // question forever, which is exactly how the remove button appeared dead.
    if (confirmAction !== null) {
      resolveConfirm(confirmSelection !== 0)
      return
    }
    ensureCursor()

    if (focusSection === "bandwidth") {
      rclone.setBwLimit(Model.bwPresets[actionIndex].rate)
      return
    }

    if (focusSection === "providers") {
      startProvider(Model.quickProviders[actionIndex])
      return
    }

    if (focusSection === "actions") {
      if (actionIndex === 0) {
        addOpen = !addOpen
        if (addOpen) { focusSection = "providers"; actionIndex = 0 }
      } else rclone.addRemote()
      return
    }

    var remote = selectedRemote()
    if (!remote) return
    var name = String(remote.name)
    var mount = rclone.mountForRemote(name)
    var action = focusedActionName()

    if (action === "open") {
      rclone.openMount(mount)
      close()
    } else if (action === "" || action === "more") {
      expandedRemote = (expandedRemote === name) ? "" : name
    } else if (action === "remove") {
      requestRemove(name)
    } else if (action === "reconnect") {
      rclone.reconnectRemote(name)
    } else if (action === "config") {
      rclone.reconfigureRemote(name)
    } else if (action === "move") {
      movePromptFor = (movePromptFor === name) ? "" : name
    } else if (action === "sync") {
      syncPromptFor = (syncPromptFor === name) ? "" : name
    } else if (action === "mount") {
      // Must match the switch exactly — one behaviour, two ways to reach it,
      // including the confirmation when writes are still queued.
      if (mount) requestUnmount(mount.mountPoint, Number(mount.pendingCount || 0))
      else {
        var spec = rclone.pinnedSpecFor(name)
        if (spec) rclone.mountRemote(spec.fs, spec.mountPoint)
        else mountPromptFor = (mountPromptFor === name) ? "" : name
      }
    } else if (action === "pin" && mount) {
      rclone.setAutoMount(mount.requestedFs, mount.mountPoint, !rclone.isAutoMounted(mount.mountPoint))
    }
  }

  // Where the keyboard cursor is. Exists so navigation can be tested from a
  // script — pixels cannot distinguish a cursor ring from a selected button.
  //
  // Lives on root, NOT on the IpcHandler: a function declared inside the
  // handler is scoped to it, so `root.cursor()` threw a TypeError and every
  // nav()/activate() call aborted at its return statement.
  function cursorText() {
    if (!cursorActive) return "(inactive)"
    return focusSection + "[" + actionIndex + "]"
      + (focusSection === "remotes" ? " row=" + remoteIndex : "")
  }

  // Starting a provider: Drive needs the console walk-through, everything else
  // rclone can drive itself.
  function startProvider(provider) {
    if (!provider) return
    // A seeded backend needs one answer BEFORE rclone will start, so the grid
    // stays open and the choices appear under it. Nothing is created yet.
    if (provider.seed) {
      seedFor = (seedFor === provider.type) ? "" : provider.type
      return
    }
    // A backend with no interactive setup gets a generated form instead of a
    // flow — starting a flow for one completes instantly and writes a remote
    // with no credentials.
    if (provider.form === true) {
      formBackend = provider
      rclone.loadBackendSchema(provider.type)
      addOpen = false
      seedFor = ""
      focusSection = "actions"
      panelFlick.contentY = 0
      return
    }
    addOpen = false
    seedFor = ""
    focusSection = "actions"
    if (provider.wizard === true) {
      setupOpen = true
      panelFlick.contentY = 0
      return
    }
    rclone.startProviderFlow(
      Model.suggestRemoteName(provider.type, rclone.remotes), provider.type)
  }

  // Which seeded provider has its choices open, by type. Empty means none.
  property string seedFor: ""
  // The backend whose generated form is open, or null. Holds the whole provider
  // entry so the form can show its label without looking it up again.
  property var formBackend: null

  function startSeeded(provider, value) {
    if (!provider || !provider.seed) return
    addOpen = false
    seedFor = ""
    focusSection = "actions"
    rclone.startProviderFlow(
      Model.suggestRemoteName(provider.type, rclone.remotes), provider.type,
      [provider.seed.key + "=" + value])
  }

  // ---- Confirmation for actions that can lose data --------------------------
  // Held as a pending FUNCTION rather than a "kind" string plus arguments: each
  // caller already has the values it needs in scope, so a closure keeps the
  // question and the action that answers it in one place instead of spreading
  // them across a dispatcher.
  //
  // `confirmAction !== null` IS the open state — one source of truth, so the
  // dialog cannot be visible with nothing to run, or armed while invisible.
  property var confirmAction: null
  property string confirmMessage: ""
  property string confirmLabel: "Confirm"
  // Which button is selected: 0 cancel, 1 confirm. Held HERE rather than inside
  // ConfirmDialog so the keyboard, the mouse and the IPC surface all read and
  // write one value — the dialog binds to it.
  property int confirmSelection: 1

  function askConfirm(message, label, action) {
    confirmMessage = String(message)
    confirmLabel = String(label)
    // Always reopen on "confirm": the dialog is dismissed by answering it, so a
    // selection left over from a previous question is never what was meant.
    confirmSelection = 1
    confirmAction = action
  }

  function resolveConfirm(go) {
    var action = confirmAction
    confirmAction = null
    if (go && action) action()
  }

  // Unmounting is safe once nothing is queued, so the question is only asked
  // when there is genuinely something to lose.
  function requestUnmount(mountPoint, pending) {
    if (Number(pending) > 0) {
      askConfirm(pending + (pending === 1 ? " file has" : " files have")
                 + " not finished uploading. Force unmount and discard "
                 + (pending === 1 ? "it" : "them") + "?",
                 "Discard and unmount",
                 function() { rclone.unmountPath(mountPoint, true, true) })
      return
    }
    rclone.unmountPath(mountPoint, true)
  }

  // A dry run writes nothing, so it is never worth a dialog — confirming it
  // would train the habit of dismissing this prompt unread.
  function requestSync(mode, srcFs, dstFs, dryRun, resync) {
    function go() {
      if (mode === "bisync") rclone.startBisync(srcFs, dstFs, resync, dryRun)
      else rclone.startSync(mode, srcFs, dstFs, dryRun)
    }
    if (!dryRun && Model.syncModeDestroys(mode)) {
      askConfirm(Model.syncConfirmMessage(mode, dstFs, rclone.homeDir), "Run " + mode, go)
      return
    }
    go()
  }

  // Removing a remote edits rclone.conf, so it asks first — even though the
  // only remotes that offer this are half-made ones with nothing worth keeping.
  // The name is in the question because the row it came from will be gone.
  function requestRemove(name) {
    if (!name) return
    var remote = null
    for (var i = 0; i < rclone.remotes.length; i++) {
      if (String(rclone.remotes[i].name) === String(name)) remote = rclone.remotes[i]
    }
    var mount = rclone.mountForRemote(name)
    var incomplete = remote ? remote.incomplete === true : false
    askConfirm(Model.removeRemoteMessage(name, incomplete, mount !== null),
               "Remove", function() { rclone.removeRemote(name) })
  }

  // Taking every mount down at once is always worth a question, even with
  // nothing queued: it is one click in a corner and it changes the state of
  // every remote you have.
  function requestUnmountAll() {
    var count = rclone.mounts.length
    if (count === 0) return
    var pending = rclone.totalPending()
    askConfirm(Model.unmountAllMessage(count, pending),
               pending > 0 ? "Discard and unmount" : "Unmount all",
               function() { rclone.unmountAll(pending > 0) })
  }

  function closeForms() {
    mountPromptFor = ""
    syncPromptFor = ""
    movePromptFor = ""
    expandedRemote = ""
    addOpen = false
    // Left out originally, and it leaked: the seed question outlived the panel,
    // so reopening and picking that provider again TOGGLED it shut instead of
    // opening it. The provider then looked inert — one click did nothing
    // visible — which is indistinguishable from a broken button.
    seedFor = ""
    formBackend = null
    rclone.clearBackendSchema()
    setupOpen = false
    panelFlick.contentY = 0
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    // Reset WHERE the cursor is, not just whether it is showing. Leaving the
    // section and row behind meant reopening the panel resumed halfway down the
    // remotes list, so the first arrow press jumped somewhere unrelated to what
    // you were looking at.
    focusSection = sectionOrder()[0]
    remoteIndex = 0
    actionIndex = 0
    // Always open on the main view. setup() re-arms the wizard AFTER calling
    // open(), so the IPC entry point still lands where it should.
    closeForms()
    rclone.refresh()
    // Opening the panel is the natural moment to notice a dead grant. Rate
    // limited to 10 minutes because each probe is one network round-trip per
    // remote — cheap when you look, not something to run on a timer.
    rclone.probeIfStale(10 * 60 * 1000)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: rclone
    settings: root.settings
  }

  PanelTheme {
    id: theme
    bar: root.bar
  }

  // Finishing the wizard leaves you with a remote and nothing mounted, which is
  // a dead end unless you happen to notice the mount button. Offer the mount
  // form for the remote just created — with its path prefilled and editable —
  // rather than choosing a path silently or leaving the job half done.
  Connections {
    target: rclone
    function onRemoteCreated(name) {
      root.open()
      root.setupOpen = false
      root.mountPromptFor = String(name)
      panelFlick.contentY = 0
    }
  }

  // The scripting surface, in its own file — see PanelIpc.qml.
  PanelIpc {
    target: root.ipcTarget
    panel: root
    service: rclone
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "rclone — " + rclone.statusText
    iconComponent: Component {
      Item {
        RcloneIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          active: rclone.active
          opacity: rclone.rcRunning ? 1.0 : 0.6
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) rclone.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(
      rclone.flowActive ? providerFlow.implicitHeight
        : (root.formBackend !== null ? backendForm.implicitHeight
          : (root.setupOpen ? setupWizard.implicitHeight : column.implicitHeight)),
      Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // A confirmation is modal, so it consumes the keys before anything else
      // sees them. ConfirmDialog owns its own Left/Right selection, so the
      // arrows drive that rather than the panel cursor underneath.
      onMoveRequested: function(dx, dy) {
        // moveCursor/activateCursor handle an open confirmation themselves, so
        // the modal behaves identically however it is reached.
        if (root.confirmAction !== null) { root.moveCursor(dx, dy); return }
        if (root.formOpen) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.confirmAction !== null) { root.activateCursor(); return }
        if (!root.formOpen && root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        // Escape always means "no" here, never "close the panel".
        if (root.confirmAction !== null) { root.resolveConfirm(false); return }
        // Escape unwinds one layer at a time, innermost first.
        if (rclone.flowActive) rclone.abortFlow()
        else if (root.addOpen) { root.addOpen = false; root.focusSection = "actions" }
        else if (root.movePromptFor !== "") root.movePromptFor = ""
        else if (root.syncPromptFor !== "") root.syncPromptFor = ""
        else if (root.mountPromptFor !== "") root.mountPromptFor = ""
        else if (root.setupOpen) { root.setupOpen = false; panelFlick.contentY = 0 }
        else root.close()
      }
      onTabRequested: function(direction) { if (!root.formOpen) root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.formOpen) return
        var key = String(t || "").toLowerCase()
        if (key === "r") rclone.refresh()
        else if (key === "c") rclone.probe()
        else if (key === "a") root.setupOpen = true
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: rclone.flowActive ? providerFlow.implicitHeight
          : (root.formBackend !== null ? backendForm.implicitHeight
            : (root.setupOpen ? setupWizard.implicitHeight : column.implicitHeight))
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // The guided setup replaces the normal view rather than stacking on it —
        // a popup inside a popup would be unreadable at this width.
        // A config flow owns the panel while it runs — it is a conversation with
        // rclone, and leaving the rest of the panel live would invite starting a
        // second one midway.
        ProviderFlow {
          id: providerFlow
          width: panelFlick.width - root.scrollGutter
          visible: rclone.flowActive
          service: rclone
          ui: theme
          onCancelled: rclone.abortFlow()
        }

        // Same rule as ProviderFlow: it owns the panel while open. Creating a
        // remote is a form you finish or abandon, not something to leave half
        // filled behind a list of other remotes.
        BackendForm {
          id: backendForm
          width: panelFlick.width - root.scrollGutter
          visible: root.formBackend !== null && !rclone.flowActive
          ui: theme
          schema: rclone.backendSchema
          backendType: root.formBackend ? String(root.formBackend.type) : ""
          backendLabel: root.formBackend ? String(root.formBackend.label) : ""
          suggestedName: root.formBackend
            ? Model.suggestRemoteName(String(root.formBackend.type), rclone.remotes) : ""
          existingNames: rclone.allRemoteNames
          busy: rclone.backendSchemaLoading || rclone.flowBusy
          onCancelled: {
            root.formBackend = null
            rclone.clearBackendSchema()
          }
          onSubmitted: function(remoteName, seeds) {
            // Straight to startProviderFlow with every answer as a seed: these
            // backends finish on the first call, so the "flow" completes
            // immediately and reports "Connected <name>" like any other.
            rclone.startProviderFlow(remoteName, backendForm.backendType, seeds)
            root.formBackend = null
            rclone.clearBackendSchema()
          }
        }

        SetupWizard {
          id: setupWizard
          width: panelFlick.width - root.scrollGutter
          visible: root.setupOpen && !rclone.flowActive && root.formBackend === null
          service: rclone
          ui: theme
          onDone: root.closeForms()
        }

        Column {
          id: column
          width: panelFlick.width - root.scrollGutter
          visible: !root.setupOpen && !rclone.flowActive && root.formBackend === null
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "rclone"
              meta: rclone.statusText
              foreground: theme.foreground
              fontFamily: theme.fontFamily
              iconOpacity: rclone.rcRunning ? 1.0 : 0.5
              iconComponent: Component {
                RcloneIcon {
                  iconSize: Style.font.display
                  color: rclone.rcRunning ? theme.foreground : theme.dim
                  active: rclone.active
                }
              }
            }

            // Everything-at-once controls, in the corner rather than among the
            // rows: they act on the whole panel, and a bulk action sitting in a
            // per-remote list is one misread away from being aimed at one row.
            //
            // BOTH are always present, greying out rather than disappearing.
            // The first cut hid each until it had something to act on, which
            // meant the pair was almost never both on screen — a control you
            // cannot find when idle is not a control. Their position is the
            // thing being learned, so it has to stay put.
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              visible: rclone.rcRunning

              PanelActionButton {
                iconText: "󰓛"
                // Not "pause" — see Service.stopAllJobs. rclone cannot resume a
                // stopped job, so the label must not imply one.
                tooltipText: rclone.runningJobs > 0
                  ? "Stop all transfers" : "Nothing is transferring"
                foreground: theme.foreground
                fontFamily: theme.fontFamily
                enabled: rclone.runningJobs > 0 && !rclone.busy
                opacity: enabled ? 1.0 : 0.4
                onClicked: rclone.stopAllJobs()
              }

              PanelActionButton {
                // md-eject (U+F01EA). Verified present in the bar font by
                // reading its cmap and post tables directly — the previous
                // glyph rendered, but as a tray-arrow that read as "download".
                // Material Design set, like every other icon in this panel.
                iconText: "󰇪"
                tooltipText: rclone.mounts.length > 0 ? "Unmount all" : "Nothing is mounted"
                foreground: theme.foreground
                fontFamily: theme.fontFamily
                enabled: rclone.mounts.length > 0 && !rclone.busy
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.requestUnmountAll()
              }
            }
          }

          Text {
            visible: rclone.actionStatus !== "" || rclone.lastError !== ""
            width: parent.width
            text: rclone.actionStatus !== "" ? rclone.actionStatus : rclone.lastError
            color: rclone.lastError !== "" && rclone.actionStatus === "" ? theme.urgent : theme.dim
            font.family: theme.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          DaemonNotice {
            width: parent.width
            visible: !rclone.installed || !rclone.rcRunning
            service: rclone
            ui: theme
          }

          // ---- Bandwidth --------------------------------------------------
          PanelSeparator { visible: rclone.rcRunning; foreground: theme.foreground }

          BandwidthRow {
            width: parent.width
            visible: rclone.rcRunning
            service: rclone
            ui: theme
            focusedIndex: (root.cursorActive && root.focusSection === "bandwidth")
              ? root.actionIndex : -1
          }

          // ---- Jobs -------------------------------------------------------
          // Copy/mirror jobs, each with its OWN progress read from
          // core/stats?group=… — the daemon-wide counters are cumulative.
          PanelSeparator { visible: rclone.jobs.length > 0; foreground: theme.foreground }

          Column {
            visible: rclone.jobs.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "JOBS"
              foreground: theme.foreground
              fontFamily: theme.fontFamily
            }

            Repeater {
              model: rclone.jobs
              JobRow {
                required property var modelData
                width: column.width
                job: modelData
                service: rclone
                ui: theme
                homeDir: rclone.homeDir
              }
            }
          }

          // ---- Activity ---------------------------------------------------
          PanelSeparator { visible: rclone.transferring.length > 0; foreground: theme.foreground }

          Column {
            visible: rclone.transferring.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "TRANSFERRING"
              foreground: theme.foreground
              fontFamily: theme.fontFamily
            }

            Repeater {
              model: rclone.transferring
              TransferRow {
                required property var modelData
                width: column.width
                transfer: modelData
                remote: Model.transferRemote(modelData, rclone.remotes)
                ui: theme
              }
            }
          }

          // ---- Remotes ----------------------------------------------------
          PanelSeparator { foreground: theme.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: remotesHeader.implicitHeight

              PanelSectionHeader {
                id: remotesHeader
                text: "REMOTES"
                foreground: theme.foreground
                fontFamily: theme.fontFamily
              }

              // Probing is a network round-trip per remote, so it is a button
              // the user presses, never something a timer does.
              PanelActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰑐"
                tooltipText: "Check each remote is reachable"
                foreground: theme.foreground
                fontFamily: theme.fontFamily
                enabled: rclone.rcRunning && rclone.remotes.length > 0 && !rclone.busy
                onClicked: rclone.probe()
              }
            }

            Text {
              visible: rclone.remotes.length === 0
              width: parent.width
              text: "No remotes configured yet."
              color: theme.dim
              font.family: theme.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: remoteColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: rclone.remotes
                RemoteRow {
                  required property var modelData
                  required property int index
                  width: remoteColumn.width
                  remote: modelData
                  rowIndex: index
                  service: rclone
                  ui: theme
                  homeDir: rclone.homeDir
                  expanded: root.expandedRemote === String(modelData.name)
                  onExpandToggled: {
                    root.expandedRemote =
                      (root.expandedRemote === String(modelData.name)) ? "" : String(modelData.name)
                    root.cursorActive = true
                    root.focusSection = "remotes"
                    root.remoteIndex = index
                  }
                  // Double click opens the folder. The panel closes with it:
                  // the file manager takes focus, so leaving the popup behind
                  // would strand it over the window the user just asked for.
                  onOpenRequested: {
                    rclone.openMount(rclone.mountForRemote(String(modelData.name)))
                    root.close()
                  }
                  hasCursor: root.cursorActive && root.focusSection === "remotes" && root.remoteIndex === index
                  focusedAction: (root.cursorActive && root.focusSection === "remotes"
                                  && root.remoteIndex === index) ? root.focusedActionName() : ""
                  promptOpen: root.mountPromptFor === String(modelData.name)
                  onCursorRequested: {
                    root.cursorActive = true
                    root.focusSection = "remotes"
                    root.remoteIndex = index
                    // Hovering targets the row, not whichever button the
                    // keyboard last sat on.
                    root.actionIndex = 0
                  }
                  onPromptToggled: root.mountPromptFor =
                    (root.mountPromptFor === String(modelData.name)) ? "" : String(modelData.name)
                  onPromptClosed: root.mountPromptFor = ""
                  onMountRequested: function(fs, mountPoint, atLogin) {
                    rclone.mountRemote(fs, mountPoint)
                    if (atLogin) rclone.setAutoMount(fs, mountPoint, true)
                    root.mountPromptFor = ""
                  }
                  syncPromptOpen: root.syncPromptFor === String(modelData.name)
                  onSyncPromptToggled: root.syncPromptFor =
                    (root.syncPromptFor === String(modelData.name)) ? "" : String(modelData.name)
                  onSyncPromptClosed: root.syncPromptFor = ""
                  movePromptOpen: root.movePromptFor === String(modelData.name)
                  onMovePromptToggled: root.movePromptFor =
                    (root.movePromptFor === String(modelData.name)) ? "" : String(modelData.name)
                  onMovePromptClosed: root.movePromptFor = ""
                  onMoveRequested: function(fs, oldPath, newPath) {
                    rclone.remountAt(fs, oldPath, newPath)
                    root.movePromptFor = ""
                  }
                  onSyncRequested: function(mode, srcFs, dstFs, dryRun, resync) {
                    root.requestSync(mode, srcFs, dstFs, dryRun, resync)
                    root.syncPromptFor = ""
                  }
                  onUnmountRequested: function(mountPoint, pending) {
                    root.requestUnmount(mountPoint, pending)
                  }
                  onRemoveRequested: function(remoteName) {
                    root.requestRemove(remoteName)
                  }
                }
              }
            }

            AddRemoteSection {
              width: parent.width
              ui: theme
              installed: rclone.installed
              expanded: root.addOpen
              seedFor: root.seedFor
              cursorActive: root.cursorActive
              focusSection: root.focusSection
              actionIndex: root.actionIndex
              onToggleRequested: {
                root.addOpen = !root.addOpen
                // Step straight into the grid rather than making the user press
                // down into a list that has just appeared.
                if (root.addOpen) { root.focusSection = "providers"; root.actionIndex = 0 }
                else root.focusSection = "actions"
              }
              onProviderPicked: function(provider) { root.startProvider(provider) }
              onSeedPicked: function(provider, value) { root.startSeeded(provider, value) }
              onOtherProviderRequested: rclone.addRemote()
            }
          }

          // ---- Recently transferred ---------------------------------------
          // core/transferred is fetched on every poll regardless, so not
          // rendering it was paying for data and throwing it away.
          PanelSeparator { visible: rclone.transferred.length > 0; foreground: theme.foreground }

          Column {
            visible: rclone.transferred.length > 0
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: parent.width
              implicitHeight: recentHeader.implicitHeight

              PanelSectionHeader {
                id: recentHeader
                text: "RECENT"
                foreground: theme.foreground
                fontFamily: theme.fontFamily
              }

              // Icon only, and it exists solely while there is something to
              // clear — the whole section is already conditional on that, so it
              // never sits there greyed out asking to be understood.
              PanelActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰃢"
                tooltipText: "Clear this list"
                foreground: theme.foreground
                fontFamily: theme.fontFamily
                enabled: rclone.rcRunning && !rclone.busy
                onClicked: rclone.clearRecents()
              }
            }

            Repeater {
              model: rclone.transferred.slice(0, 8)
              // With more than one provider configured, a bare filename does
              // not say where it came from. The glyph is the same one the
              // REMOTES rows use two sections above, so the vocabulary is
              // already taught — and it costs one dim character rather than a
              // line of text.
              Column {
                required property var modelData
                width: column.width
                spacing: 0

                Text {
                  width: parent.width
                  text: Model.baseName(modelData.name)
                  color: modelData.error ? theme.urgent : theme.foreground
                  font.family: theme.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  // Names the provider, because with more than one configured a
                  // filename alone does not say where it came from.
                  text: Model.transferredSubtitle(
                    modelData, Model.transferRemote(modelData, rclone.remotes))
                  color: modelData.error ? theme.urgent : theme.dim
                  font.family: theme.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          // Version last: useful when reporting a problem, noise otherwise.
          Text {
            visible: rclone.version !== ""
            width: parent.width
            text: "rclone " + rclone.version
            color: theme.dim
            opacity: 0.7
            font.family: theme.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }

      // Sits OUTSIDE the Flickable so it covers the panel rather than
      // scrolling with it, and above everything so the scrim actually blocks
      // the controls behind it.
      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 20
        opened: root.confirmAction !== null
        message: root.confirmMessage
        confirmText: root.confirmLabel
        selectedIndex: root.confirmSelection
        onSelectedIndexChanged: root.confirmSelection = selectedIndex
        foreground: theme.foreground
        fontFamily: theme.fontFamily
        onCanceled: root.resolveConfirm(false)
        onConfirmed: root.resolveConfirm(true)
      }
    }
  }
}
