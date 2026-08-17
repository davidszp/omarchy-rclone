import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One running copy/mirror job, with a stop button.
//
// The progress bar is driven by this job's OWN bytes/totalBytes, read from
// core/stats?group=<label>. The daemon-wide counters are cumulative for the
// whole rcd lifetime and would drift; per-group stats do not.
Column {
  id: root

  property var job: null
  property QtObject service: null
  property QtObject ui: null
  property string homeDir: ""

  readonly property real fraction: {
    var total = Number(root.job ? root.job.totalBytes : 0)
    if (!total) return 0
    return Math.max(0, Math.min(1, Number(root.job.bytes) / total))
  }

  spacing: Style.space(4)

  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    Text {
      Layout.fillWidth: true
      text: Model.jobTitle(root.job || {}, root.homeDir)
      color: root.ui ? root.ui.foreground : Color.foreground
      font.family: root.ui ? root.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }

    PanelActionButton {
      iconText: "󰓛"
      tooltipText: "Stop this job"
      // Normal weight: stopping a job you started is routine, not destructive —
      // nothing is deleted and it can be restarted. Urgent colouring is
      // reserved for things that lose data.
      foreground: root.ui ? root.ui.foreground : Color.foreground
      fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
      enabled: root.service && !root.service.busy
      Layout.alignment: Qt.AlignVCenter
      onClicked: if (root.service && root.job) root.service.stopJob(root.job.id)
    }
  }

  Rectangle {
    width: parent.width
    height: Style.space(3)
    radius: height / 2
    color: Qt.rgba(root.ui ? root.ui.foreground.r : 0,
                   root.ui ? root.ui.foreground.g : 0,
                   root.ui ? root.ui.foreground.b : 0, 0.18)

    Rectangle {
      width: parent.width * root.fraction
      height: parent.height
      radius: parent.radius
      color: root.ui ? root.ui.foreground : Color.foreground

      Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutQuad } }
    }
  }

  Text {
    width: parent.width
    text: Model.jobSubtitle(root.job || {})
    color: (root.job && root.job.errors > 0)
      ? (root.ui ? root.ui.urgent : Color.foreground)
      : (root.ui ? root.ui.dim : Color.foreground)
    font.family: root.ui ? root.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
