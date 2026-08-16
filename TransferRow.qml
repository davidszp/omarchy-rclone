import QtQuick
import qs.Commons
import "Model.js" as Model

// One in-flight transfer: name, progress bar, and a size/speed/ETA line.
//
// The bar is driven by the per-file `percentage`, never by the global
// bytes/totalBytes — core/stats is cumulative for the daemon's whole lifetime,
// so a bar built on it drifts further from the truth the longer rcd runs.
Column {
  id: root

  property var transfer: null
  property QtObject ui: null
  // Resolved by the panel, not looked up here: the row has no service
  // reference and RECENT already resolves its provider the same way.
  property var remote: null

  spacing: Style.space(4)

  Text {
    width: parent.width
    text: Model.baseName(root.transfer ? root.transfer.name : "")
    color: ui ? ui.foreground : Color.foreground
    font.family: ui ? ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  Rectangle {
    width: parent.width
    height: Style.space(3)
    radius: height / 2
    color: Qt.rgba(root.ui ? root.ui.foreground.r : 0,
                   root.ui ? root.ui.foreground.g : 0,
                   root.ui ? root.ui.foreground.b : 0, 0.18)

    Rectangle {
      width: parent.width * Math.max(0, Math.min(100, Number(root.transfer ? root.transfer.percentage : 0))) / 100
      height: parent.height
      radius: parent.radius
      color: root.ui ? root.ui.foreground : Color.foreground

      Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutQuad } }
    }
  }

  Text {
    width: parent.width
    text: Model.transferSubtitle(root.transfer || {}, root.remote)
    color: ui ? ui.dim : Color.foreground
    font.family: ui ? ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
