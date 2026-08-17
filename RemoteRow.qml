import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One configured remote, plus its inline mount form when open.
//
// A Column rather than a bare row because the form has to expand beneath the
// row; the row itself is still a CursorSurface so keyboard/mouse highlighting
// behaves exactly like every other Omarchy panel row.
Column {
  id: root

  property var remote: null
  property int rowIndex: 0
  property QtObject service: null
  property QtObject ui: null
  property string homeDir: ""
  property bool hasCursor: false
  // Which action the keyboard cursor is on, BY NAME: "" (the row itself),
  // "pin", "sync" or "mount". Named rather than numbered because the visual
  // order and the declaration order are not the same thing, and an index
  // silently meant "whichever button I declared third".
  property string focusedAction: ""
  property bool promptOpen: false
  property bool syncPromptOpen: false
  property bool movePromptOpen: false
  // Secondary actions live behind this rather than as four permanent icons.
  // The first-party panels do the same: Dropbox has ZERO action buttons on its
  // file rows and Tailscale puts its several copy actions behind a menu. A row
  // should read as state, not as a control surface.
  property bool expanded: false

  readonly property string remoteName: remote ? String(remote.name) : ""
  // No `type` in the config: rclone wrote the section but the setup that
  // fills it in never finished. Cannot be mounted, probed or repaired.
  readonly property bool incomplete: remote ? remote.incomplete === true : false
  readonly property bool isDrive: remote ? String(remote.type) === "drive" : false
  readonly property var mount: (service && remoteName !== "") ? service.mountForRemote(remoteName) : null
  // Writes sitting in the local cache that have not reached the provider. Only
  // ever non-zero while something is genuinely at risk, which is why the
  // warning is conditional rather than a permanent icon next to a routine
  // action — a badge that is always there stops being read.
  readonly property bool needsReauth: (service && remoteName !== "")
    ? service.needsReauth(remoteName) : false
  readonly property int pending: mount ? Number(mount.pendingCount || 0) : 0
  readonly property bool pinned: (mount && service) ? service.isAutoMounted(mount.mountPoint) : false

  signal cursorRequested()
  signal promptToggled()
  signal promptClosed()
  signal mountRequested(string fs, string mountPoint, bool atLogin)
  signal syncPromptToggled()
  signal syncPromptClosed()
  signal syncRequested(string mode, string srcFs, string dstFs, bool dryRun, bool resync)
  signal movePromptToggled()
  signal movePromptClosed()
  signal moveRequested(string fs, string oldPath, string newPath)
  signal expandToggled()
  signal openRequested()
  signal unmountRequested(string mountPoint, int pending)
  signal removeRequested(string remoteName)

  spacing: Style.space(6)

  CursorSurface {
    width: root.width
    hasCursor: root.hasCursor && root.focusedAction === ""
    foreground: root.ui ? root.ui.foreground : Color.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursorRequested()
      // Expanding is the obvious thing a row click should do. Launching a
      // terminal for `rclone config update` was a surprising primary action.
      //
      // Double click opens the mounted folder. Qt delivers onClicked for the
      // FIRST press of a double click as well, so acting on it immediately
      // would expand the row on the way to opening the folder and leave it
      // expanded afterwards. Deferring the expand by the double-click interval
      // is the only way to tell one gesture from the other.
      // Deferred ONLY on a mounted row. The system double-click interval here
      // is 400ms, and paying that on every expand — the far more common click —
      // to serve a gesture that is meaningless without a folder to open would
      // be a bad trade. An unmounted row has nothing to open, so it expands at
      // once and behaves exactly as it always did.
      onClicked: {
        if (root.mount && root.mount.mountPoint) singleClick.restart()
        else root.expandToggled()
      }
      onDoubleClicked: {
        singleClick.stop()
        if (root.mount && root.mount.mountPoint) root.openRequested()
      }
    }

    Timer {
      id: singleClick
      // The SYSTEM interval, not a guess: shorter and a slow double click
      // expands the row on its way to opening the folder, which is the exact
      // confusion this timer exists to prevent. Falls back if the hint is
      // unavailable rather than binding to nothing.
      interval: (typeof Application !== "undefined" && Application.styleHints)
        ? Application.styleHints.mouseDoubleClickInterval : 250
      onTriggered: root.expandToggled()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ProviderIcon {
        type: root.remote ? String(root.remote.type) : ""
        siblingTypes: root.service ? root.service.remoteTypes() : []
        iconSize: Style.font.icon
        color: root.ui ? root.ui.foreground : Color.foreground
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: root.remoteName
          color: root.ui ? root.ui.foreground : Color.foreground
          font.family: root.ui ? root.ui.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: root.mount
            ? Model.mountedSubtitle(root.mount,
                (root.service && root.remoteName !== "") ? root.service.probes[root.remoteName] : null,
                root.homeDir)
            : (root.needsReauth
               ? "sign-in expired — reconnect to use it again"
               : Model.remoteSubtitle(root.remote || {}, root.service ? root.service.probes : {}))
          color: (root.pending > 0 || root.needsReauth)
            ? (root.ui ? root.ui.urgent : Color.foreground)
            : (root.ui ? root.ui.dim : Color.foreground)
          font.family: root.ui ? root.ui.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Appears only while writes are unflushed. Unmounting or moving the mount
      // now would drop them — rclone-rc refuses both, and this says why before
      // the click rather than after.
      Text {
        visible: root.pending > 0 || root.needsReauth
        text: "󰀦"
        color: root.ui ? root.ui.urgent : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      // Mounted-or-not is a STATE, so it gets a switch rather than a verb
      // button — the same control Tailscale uses for its connection, sized down
      // via `trackHeight` (which the component supports explicitly) rather than
      // scaled, so the track and knob stay on whole pixels.
      // A half-made remote cannot be mounted, so it gets the one action it
      // can actually perform instead of a switch that would do nothing.
      PanelActionButton {
        visible: root.incomplete
        hasCursor: root.hasCursor && root.focusedAction === "remove"
        iconText: "󰆴"
        tooltipText: "Remove " + root.remoteName
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        enabled: root.service && !root.service.busy
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.removeRequested(root.remoteName)
      }

      ToggleSwitch {
        id: mountSwitch
        visible: !root.incomplete
        checked: root.mount !== null
        busy: root.service ? root.service.busy : false
        hasCursor: root.hasCursor && root.focusedAction === "mount"
        trackHeight: Style.space(14)
        cursorPad: Style.space(4)
        foreground: root.ui ? root.ui.foreground : Color.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: {
          if (!root.service) return
          // Routed through the panel rather than called directly: unmounting
          // with writes still queued needs a confirmation, and the dialog that
          // asks lives one level up.
          if (root.mount) { root.unmountRequested(root.mount.mountPoint, root.pending); return }
          // Turning it back on should not interrogate you about a folder you
          // already chose: if this remote has a login mount, reuse it. Only a
          // remote with nothing recorded needs the form.
          var spec = root.service.pinnedSpecFor(root.remoteName)
          if (spec) root.service.mountRemote(spec.fs, spec.mountPoint)
          else root.promptToggled()
        }

        PanelToolTip {
          visible: mountSwitch.containsMouse
          text: root.mount ? "Unmount " + root.remoteName : "Mount " + root.remoteName
          fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        }
      }

      PanelActionButton {
        visible: !root.incomplete
        hasCursor: root.hasCursor && root.focusedAction === "more"
        iconText: "󰇘"
        tooltipText: root.expanded ? "Fewer actions" : "More actions"
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.expandToggled()
      }
    }
  }

  Flow {
    width: root.width
    visible: root.expanded
    spacing: Style.space(6)

    StripButton {
      visible: root.mount !== null
      text: "Open folder"
      cursorName: "open"
      onPicked: root.openRequested()
    }

    StripButton {
      visible: root.mount !== null
      text: root.pinned ? "Don’t mount on login" : "Mount on login"
      cursorName: "pin"
      onPicked: {
        if (!root.mount || !root.service) return
        root.service.setAutoMount(root.mount.requestedFs, root.mount.mountPoint, !root.pinned)
      }
    }

    StripButton {
      text: "Transfer files"
      cursorName: "sync"
      onPicked: root.syncPromptToggled()
    }

    StripButton {
      visible: root.mount !== null
      text: "Change folder"
      cursorName: "move"
      onPicked: root.movePromptToggled()
    }

    StripButton {
      // Offered first when the grant is dead — it is the only thing that helps.
      visible: root.needsReauth
      text: "Reconnect " + root.remoteName
      cursorName: "reconnect"
      onPicked: if (root.service) root.service.reconnectRemote(root.remoteName)
    }

    StripButton {
      text: "Reconfigure"
      cursorName: "config"
      onPicked: if (root.service) root.service.reconfigureRemote(root.remoteName)
    }

    // Last, and the only irreversible thing here. Model.rowActions puts it at
    // the end of the expanded set for the same reason — the two orders have to
    // agree or the keyboard lands on a different button than it highlights.
    StripButton {
      text: "Remove " + root.remoteName
      cursorName: "remove"
      onPicked: root.removeRequested(root.remoteName)
    }
  }

  component StripButton: Button {
    property string cursorName: ""
    signal picked()
    bordered: true
    fontSize: Style.font.caption
    hasCursor: root.hasCursor && root.focusedAction === cursorName
    foreground: root.ui ? root.ui.foreground : Color.foreground
    fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
    onClicked: picked()
  }

  MountPrompt {
    width: root.width
    visible: root.promptOpen
    remoteName: root.remoteName
    isDrive: root.isDrive
    ui: root.ui
    onAccepted: function(fs, mountPoint, atLogin) { root.mountRequested(fs, mountPoint, atLogin) }
    onCancelled: root.promptClosed()
  }

  MountPrompt {
    width: root.width
    visible: root.movePromptOpen
    remoteName: root.remoteName
    isDrive: root.isDrive
    ui: root.ui
    currentPath: root.mount ? String(root.mount.mountPoint) : ""
    currentFs: root.mount ? String(root.mount.fs) : ""
    onAccepted: function(fs, mountPoint) {
      root.moveRequested(fs, root.mount ? String(root.mount.mountPoint) : "", mountPoint)
    }
    onCancelled: root.movePromptClosed()
  }

  SyncPrompt {
    width: root.width
    visible: root.syncPromptOpen
    remoteName: root.remoteName
    ui: root.ui
    onAccepted: function(mode, srcFs, dstFs, dryRun, resync) { root.syncRequested(mode, srcFs, dstFs, dryRun, resync) }
    onCancelled: root.syncPromptClosed()
  }
}
