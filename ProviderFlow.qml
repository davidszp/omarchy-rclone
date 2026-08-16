import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Renders ONE step of rclone's config state machine, whatever it happens to be.
//
// Deliberately schema-driven rather than per-provider: rclone hands back a
// question with Help, a Default, optional Examples and a Required flag, and
// that is enough to draw it. So this same component walks Box, OneDrive, Zoho
// and anything else — including the post-auth pickers ("which drive?") that a
// one-shot `config create` cannot answer, which is the actual reason a loop is
// needed at all. The browser handshake was never the hard part.
Column {
  id: root

  property QtObject service: null
  property QtObject ui: null

  readonly property var step: service ? (service.flowStep || ({})) : ({})
  readonly property var choices: step.examples || []
  // A step with Examples is a pick-one; anything else is free text.
  readonly property bool isChoice: choices.length > 0
  readonly property bool waiting: service && service.flowBusy

  signal cancelled()

  function submit(value) {
    if (!service) return
    service.answerFlow(value)
    field.text = ""
  }

  spacing: Style.space(8)

  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: "Connecting " + (root.service ? root.service.flowName : "")
        color: root.ui ? root.ui.foreground : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        text: root.service ? root.service.flowType : ""
        color: root.ui ? root.ui.dim : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      iconText: "󰅖"
      tooltipText: "Cancel setup"
      foreground: root.ui ? root.ui.foreground : Color.foreground
      fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.cancelled()
    }
  }

  // rclone's Help is the authoritative wording for the question — including the
  // Drive retirement warning, which rclone itself raises as the first step.
  // Showing it verbatim means new backends need no work here; stepLabel only
  // overrides the handful that name an internal field instead of the choice.
  Text {
    width: parent.width
    visible: Model.stepLabel(root.step) !== ""
    text: Model.stepLabel(root.step)
    color: root.ui ? root.ui.foreground : Color.foreground
    font.family: root.ui ? root.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    width: parent.width
    visible: root.waiting
    text: "Waiting for rclone… if a browser window opened, finish signing in there."
    color: root.ui ? root.ui.dim : Color.foreground
    font.family: root.ui ? root.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // ---- Pick one -------------------------------------------------------------
  Flow {
    width: parent.width
    visible: root.isChoice && !root.waiting
    spacing: Style.space(6)

    Repeater {
      model: root.choices
      Button {
        required property var modelData
        text: (modelData.help && modelData.help !== "") ? modelData.help : modelData.value
        bordered: true
        fontSize: Style.font.caption
        // Mark rclone's own default so a long Examples list still has an
        // obvious "just proceed" answer.
        selected: String(modelData.value) === String(root.step.default || "")
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        onClicked: root.submit(modelData.value)
      }
    }
  }

  // ---- Free text ------------------------------------------------------------
  Column {
    width: parent.width
    visible: !root.isChoice && !root.waiting
    spacing: Style.space(6)

    TextField {
      id: field
      width: parent.width
      // rclone does not flag every sensitive field, so rclone-config also
      // matches on the field name — see its SENSITIVE list.
      password: root.step.secret === true
      placeholderText: String(root.step.default || "") !== ""
        ? String(root.step.default)
        : String(root.step.name || "")
      foreground: root.ui ? root.ui.foreground : Color.foreground
      onAccepted: root.submit(field.text)
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(6)

      Button {
        text: "Next"
        bordered: true
        fontSize: Style.font.caption
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        Layout.fillWidth: true
        // Optional steps are legitimately blank — rclone's own advice for most
        // client_id fields is "leave blank normally" — so only Required blocks.
        enabled: !(root.step.required === true) || field.text.trim() !== ""
        opacity: enabled ? 1.0 : 0.45
        onClicked: root.submit(field.text)
      }

      Button {
        text: "Skip"
        visible: !(root.step.required === true)
        bordered: true
        fontSize: Style.font.caption
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        onClicked: root.submit("")
      }
    }
  }
}
