import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Daemon-wide transfer cap. Presets rather than a text field, because rclone's
// rate syntax has real traps (a bare number means BYTES per second, and it
// reports back in binary units — "5M" comes back as "5Mi") and none of that is
// worth teaching for what is a "stop saturating my uplink" control.
//
// It applies to the whole daemon, not one job, which the subtitle says plainly.
Column {
  id: root

  property QtObject service: null
  property QtObject ui: null

  readonly property string current: service ? String(service.bwLimit) : "off"
  readonly property bool limited: current !== "off" && current !== ""

  // Shared with the panel's keyboard navigation — one list, one order.
  readonly property var presets: Model.bwPresets
  // Which preset the keyboard cursor is on, or -1 when it is elsewhere.
  property int focusedIndex: -1

  spacing: Style.space(4)

  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: "Bandwidth"
        color: root.ui ? root.ui.foreground : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        text: root.limited ? "all transfers capped at " + root.current : "unlimited"
        color: root.ui ? root.ui.dim : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Repeater {
      model: root.presets
      Button {
        required property var modelData
        required property int index
        text: modelData.label
        hasCursor: root.focusedIndex === index
        bordered: true
        fontSize: Style.font.caption
        selected: Model.bwMatches(root.current, modelData.rate)
        opacity: selected ? 1.0 : 0.55
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (root.service) root.service.setBwLimit(modelData.rate)
      }
    }
  }
}
