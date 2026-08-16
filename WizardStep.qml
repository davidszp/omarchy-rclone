import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// One numbered step of a guided setup: circle, title, detail, and a button that
// opens the relevant page. A step flagged `warn` renders in the urgent colour —
// used for the publish step, whose omission silently breaks Drive a week later.
Rectangle {
  id: root

  property var step: null
  property int number: 0
  property QtObject ui: null

  readonly property bool warn: step && step.warn === true
  readonly property color accent: warn
    ? (ui ? ui.urgent : Color.urgent)
    : (ui ? ui.foreground : Color.foreground)

  implicitHeight: content.implicitHeight + Style.space(16)
  radius: Style.space(4)
  color: "transparent"

  RowLayout {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(4)
    anchors.rightMargin: Style.space(4)
    spacing: Style.space(10)

    Rectangle {
      width: Style.space(20)
      height: Style.space(20)
      radius: width / 2
      Layout.alignment: Qt.AlignTop
      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.warn ? 0.18 : 0.12)

      Text {
        anchors.centerIn: parent
        text: String(root.number)
        color: root.accent
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    ColumnLayout {
      id: content
      Layout.fillWidth: true
      spacing: Style.space(2)

      Text {
        Layout.fillWidth: true
        text: root.step ? String(root.step.title) : ""
        color: root.accent
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        Layout.fillWidth: true
        text: root.step ? String(root.step.detail) : ""
        color: root.ui ? root.ui.dim : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Button {
      text: root.step ? String(root.step.action) : ""
      bordered: true
      fontSize: Style.font.caption
      foreground: root.ui ? root.ui.foreground : Color.foreground
      fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
      Layout.alignment: Qt.AlignVCenter
      onClicked: if (root.step) Qt.openUrlExternally(String(root.step.url))
    }
  }
}
