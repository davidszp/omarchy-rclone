import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Inline "copy / mirror" form, opened under the remote row it belongs to.
//
// Safety is the whole design here. `mirror` maps to rclone's sync/sync, which
// DELETES files at the destination that are not in the source — a one-click
// button for that with no friction would be irresponsible. So:
//   - Copy is the default and never deletes.
//   - Choosing Mirror auto-enables Dry run, and names the directory it would
//     delete from, marked with a warning glyph and set at full strength.
//   - The action button's own label changes to say which it will do.
Rectangle {
  id: root

  property string remoteName: ""
  property QtObject ui: null

  // mode is "copy", "mirror" or "bisync"; direction is "download" or "upload".
  signal accepted(string mode, string srcFs, string dstFs, bool dryRun, bool resync)
  signal cancelled()

  readonly property bool mirroring: modeMirror.checked
  readonly property bool twoWay: modeBisync.checked
  // Direction is meaningless for a two-way sync, so it is fixed to
  // remote→local (path1→path2) and the control is hidden.
  readonly property bool uploading: dirUpload.checked && !twoWay
  readonly property string remoteFs: remoteName + ":" + remotePath.text.trim()
  readonly property string localFs: localPath.text.trim()
  readonly property string sourceFs: uploading ? localFs : remoteFs
  readonly property string destFs: uploading ? remoteFs : localFs

  function reset() {
    remotePath.text = ""
    localPath.text = ""
    modeCopy.checked = true
    modeMirror.checked = false
    modeBisync.checked = false
    dirDownload.checked = true
    dirUpload.checked = false
    dryRun.checked = false
    resync.checked = false
  }

  function modeVerb() {
    if (twoWay) return "bisync"
    return mirroring ? "mirror" : "copy"
  }

  implicitHeight: content.implicitHeight + Style.space(18)
  radius: Style.space(4)
  color: Qt.rgba(ui ? ui.foreground.r : 0, ui ? ui.foreground.g : 0, ui ? ui.foreground.b : 0, 0.06)

  onRemoteNameChanged: reset()

  ColumnLayout {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(6)

    Label { text: "Direction" ; visible: !root.twoWay }

    RowLayout {
      Layout.fillWidth: true
      visible: !root.twoWay
      spacing: Style.space(6)

      Choice {
        id: dirDownload
        text: "Download"
        checked: true
        onPicked: { dirDownload.checked = true; dirUpload.checked = false }
      }
      Choice {
        id: dirUpload
        text: "Upload"
        onPicked: { dirUpload.checked = true; dirDownload.checked = false }
      }
    }

    Label { text: remoteName + ": path  (blank = whole remote)" }
    TextField {
      id: remotePath
      Layout.fillWidth: true
      placeholderText: "documents"
      foreground: ui ? ui.foreground : Color.foreground
    }

    Label { text: "Local path" }
    TextField {
      id: localPath
      Layout.fillWidth: true
      placeholderText: "~/Documents"
      foreground: ui ? ui.foreground : Color.foreground
    }

    Label { text: "Mode" }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Choice {
        id: modeCopy
        text: "Copy"
        checked: true
        onPicked: { modeCopy.checked = true; modeMirror.checked = false
                    modeBisync.checked = false; dryRun.checked = false }
      }
      Choice {
        id: modeMirror
        text: "Mirror"
        urgent: true
        // Auto-arm the dry run rather than trusting anyone to remember. It can
        // still be switched off deliberately.
        onPicked: { modeMirror.checked = true; modeCopy.checked = false
                    modeBisync.checked = false; dryRun.checked = true }
      }

      Choice {
        id: modeBisync
        text: "Two-way"
        urgent: true
        onPicked: { modeBisync.checked = true; modeCopy.checked = false
                    modeMirror.checked = false; dryRun.checked = true }
      }
    }

    // Describes whichever mode is selected, including Copy. A form that only
    // warns about the dangerous choices leaves the safe one unexplained.
    Text {
      Layout.fillWidth: true
      text: (Model.syncModeDestroys(root.modeVerb()) ? "⚠ " : "")
            + Model.syncModeHelp(root.modeVerb(), root.destFs)
      color: Model.syncModeDestroys(root.modeVerb())
        ? (ui ? ui.urgent : Color.foreground)
        : (ui ? ui.dim : Color.foreground)
      font.family: ui ? ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // rclone refuses a two-way sync on a pair it has no baseline listings for,
    // so the first run must be seeded. Seeding is not a no-op: it merges both
    // sides, keeping everything from each and letting the remote win conflicts.
    Toggle {
      id: resync
      Layout.fillWidth: true
      visible: root.twoWay
      label: "First run for this pair"
      description: "Required once. Merges both sides; the remote wins conflicts."
      foreground: ui ? ui.foreground : Color.foreground
      fontFamily: ui ? ui.fontFamily : Style.font.family
      onClicked: checked = !checked
    }

    Toggle {
      id: dryRun
      Layout.fillWidth: true
      label: "Dry run"
      description: "Report what would change, transfer and delete nothing"
      foreground: ui ? ui.foreground : Color.foreground
      fontFamily: ui ? ui.fontFamily : Style.font.family
      onClicked: checked = !checked
    }

    Text {
      Layout.fillWidth: true
      text: root.sourceFs === "" || root.destFs === "" ? " "
            : root.sourceFs + (root.twoWay ? "  ⇄  " : "  →  ") + root.destFs
      color: ui ? ui.dim : Color.foreground
      font.family: ui ? ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Button {
        text: (dryRun.checked ? "Preview " : "Start ") + root.modeVerb()
        bordered: true
        fontSize: Style.font.caption
        foreground: (root.mirroring || root.twoWay) && !dryRun.checked
          ? (root.ui ? root.ui.urgent : Color.foreground)
          : (root.ui ? root.ui.foreground : Color.foreground)
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        Layout.fillWidth: true
        enabled: root.localFs !== ""
        opacity: enabled ? 1.0 : 0.45
        onClicked: {
          if (root.localFs === "") return
          root.accepted(root.modeVerb(), root.sourceFs, root.destFs,
                        dryRun.checked, resync.checked)
        }
      }

      Button {
        text: "Cancel"
        bordered: true
        fontSize: Style.font.caption
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        onClicked: root.cancelled()
      }
    }
  }

  component Label: Text {
    Layout.fillWidth: true
    color: root.ui ? root.ui.foreground : Color.foreground
    opacity: 0.6
    font.family: root.ui ? root.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
  }

  // A two-state pill. Ui/Button has `selected`, so this stays a thin wrapper
  // rather than a hand-rolled control.
  component Choice: Button {
    property bool urgent: false
    signal picked()

    bordered: true
    fontSize: Style.font.caption
    selected: checked
    property bool checked: false
    foreground: urgent && checked
      ? (root.ui ? root.ui.urgent : Color.foreground)
      : (root.ui ? root.ui.foreground : Color.foreground)
    fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
    opacity: checked ? 1.0 : 0.55
    onClicked: picked()
  }
}
