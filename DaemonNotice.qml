import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Shown when rclone or its daemon is not ready. Never dresses a dead daemon up
// as "idle" — it says what is wrong and offers the one action that fixes it.
//
// "Not installed" and "installed but down" are deliberately different states:
// offering a restart to someone who has no unit at all is a dead end.
CursorSurface {
  id: root

  property QtObject service: null
  property QtObject ui: null

  readonly property bool needsDaemon: service && !service.daemonInstalled
  readonly property bool needsRclone: service && !service.installed

  foreground: ui ? ui.foreground : Color.foreground
  implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

  RowLayout {
    id: row
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(8)

    Text {
      text: "󰀦"
      color: ui ? ui.urgent : Color.urgent
      font.family: ui ? ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.heading
      Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
      id: content
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: root.needsRclone ? "rclone is not installed"
          : (root.needsDaemon ? "rclone daemon is not set up yet" : "rclone rcd is not running")
        color: ui ? ui.foreground : Color.foreground
        font.family: ui ? ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        // Kept to one line at panel width, like the two subtitles it alternates
        // with — a wrapping caption makes this row taller than the others and
        // the notice reads as an error rather than a next step.
        text: root.needsRclone ? "Runs omarchy pkg add — asks for your password"
          : (root.needsDaemon ? "Creates a loopback service with its own password"
                              : "No activity can be read without it")
        color: ui ? ui.dim : Color.foreground
        font.family: ui ? ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    // Every blocked state gets the ONE action that unblocks it. "rclone is
    // missing" used to be the exception — it printed a command to retype, which
    // is the only dead end a new user can hit, and the first thing they see.
    PanelActionButton {
      iconText: root.needsRclone ? "󰇚" : (root.needsDaemon ? "󰄬" : "󰜉")
      tooltipText: root.needsRclone ? "Install rclone"
        : (root.needsDaemon ? "Set up the rclone daemon" : "Restart rclone-rcd.service")
      foreground: ui ? ui.foreground : Color.foreground
      fontFamily: ui ? ui.fontFamily : Style.font.family
      enabled: service && !service.busy
      Layout.alignment: Qt.AlignVCenter
      onClicked: {
        if (!service) return
        if (root.needsRclone) service.installRclone()
        else if (root.needsDaemon) service.installDaemon()
        else service.restartDaemon()
      }
    }
  }
}
