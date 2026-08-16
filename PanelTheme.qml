import QtQuick
import qs.Commons

// The handful of theme values every row in this plugin needs, bundled so a row
// takes one `ui:` property instead of four colour properties. Values come from
// the bar when there is one, and from the shared theme singleton otherwise, so
// components still render standalone.
QtObject {
  property QtObject bar: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
}
