import QtQuick
import qs.Commons

// Glyph-based rather than a drawn Shape (which is what the first-party Dropbox
// icon does) because rclone is provider-agnostic — there is no single brand
// mark to render. A cloud reads correctly for every backend.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // Swaps to a sync glyph while bytes are moving, so the bar shows activity
  // without needing a separate spinner.
  property bool active: false

  width: iconSize * 1.1
  height: iconSize
  implicitWidth: iconSize * 1.1
  implicitHeight: iconSize

  Text {
    anchors.centerIn: parent
    text: root.active ? "󰅢" : "󰅧"
    color: root.color
    font.family: Style.font.family
    font.pixelSize: root.iconSize
  }
}
