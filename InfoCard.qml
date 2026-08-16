import QtQuick
import qs.Commons

// A tinted rounded container for a block of explanation. `urgent: true` tints
// it with the warning colour instead of the foreground.
//
// Callers put their content in `content` and set `contentHeight`; this only
// owns the box. Three of these appear in the setup wizard alone, which is why
// it is a component rather than a Rectangle copied three times.
Rectangle {
  id: root

  property QtObject ui: null
  property bool urgent: false
  property real contentHeight: 0
  property real padding: Style.space(16)
  default property alias content: holder.data

  readonly property color tint: urgent
    ? (ui ? ui.urgent : Color.urgent)
    : (ui ? ui.foreground : Color.foreground)

  implicitHeight: contentHeight + padding
  radius: Style.space(4)
  color: Qt.rgba(tint.r, tint.g, tint.b, urgent ? 0.08 : 0.06)

  Item {
    id: holder
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    height: root.contentHeight
  }
}
