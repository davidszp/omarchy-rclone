import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A generic "do this" row: glyph, title, subtitle. Used for the setup entry
// points at the bottom of the remotes list.
CursorSurface {
  id: root

  property string glyph: "󰐕"
  property string title: ""
  property string subtitle: ""
  property bool enabledAction: true
  property QtObject ui: null

  signal triggered()

  foreground: ui ? ui.foreground : Color.foreground
  implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX
  opacity: enabledAction ? 1.0 : 0.5

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.enabledAction ? Qt.PointingHandCursor : Qt.ArrowCursor
    enabled: root.enabledAction
    onClicked: root.triggered()
  }

  RowLayout {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(8)

    Text {
      text: root.glyph
      color: root.ui ? root.ui.foreground : Color.foreground
      font.family: root.ui ? root.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.heading
      Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
      id: content
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: root.title
        color: root.ui ? root.ui.foreground : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        text: root.subtitle
        color: root.ui ? root.ui.dim : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
