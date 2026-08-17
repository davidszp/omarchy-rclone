import QtQuick
import qs.Commons

// The handful of theme values every row in this plugin needs, bundled so a row
// takes one `ui:` property instead of four colour properties. Values come from
// the bar when there is one, and from the shared theme singleton otherwise, so
// components still render standalone.
QtObject {
  property QtObject bar: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)

  // DELIBERATELY the same as `foreground`: this plugin does not colour text.
  //
  // The theme's real urgent colour is red in Omarchy's dark themes and plain
  // foreground in the light ones, so the same warning rendered as alarming red
  // text for half the users and as ordinary text for the other half — the
  // emphasis was inconsistent, and where it did show it was loud enough to make
  // routine advice look like an error.
  //
  // Kept as a named role rather than deleted so the places that mean "this
  // matters" still say so, and so restoring a colour is one line here rather
  // than fifteen call sites. Emphasis is carried by weight instead: an urgent
  // line renders at full foreground where its neighbours are `dim`.
  readonly property color urgent: foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
}
