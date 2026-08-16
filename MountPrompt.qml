import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The inline "mount as…" form, opened under the remote row it belongs to.
//
// Inline rather than a second popup: a popup inside a popup is easy to lose at
// this width, and the form visually belongs to the row that spawned it.
Rectangle {
  id: root

  property string remoteName: ""
  property bool isDrive: false
  property QtObject ui: null
  // Non-empty turns this into a "move an existing mount" form: the field
  // prefills the current folder, and the login pin follows automatically so
  // there is no toggle to get wrong.
  property string currentPath: ""
  // The live mount's fs, e.g. "gdrive{YRXYK}:". Reused verbatim when moving.
  property string currentFs: ""
  readonly property bool moving: currentPath !== ""

  // fs is composed here so the user never has to know rclone's connection
  // string syntax to get a Drive mount without broken Google Docs entries.
  signal accepted(string fs, string mountPoint, bool atLogin)
  signal cancelled()

  function reset() {
    pathField.text = moving ? currentPath : "~/" + remoteName
    loginToggle.checked = true
    gdocsToggle.checked = true
  }

  implicitHeight: content.implicitHeight + Style.space(18)
  radius: Style.space(4)
  color: Qt.rgba(ui ? ui.foreground.r : 0, ui ? ui.foreground.g : 0, ui ? ui.foreground.b : 0, 0.06)

  onRemoteNameChanged: reset()
  onCurrentPathChanged: reset()

  ColumnLayout {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(6)

    Text {
      Layout.fillWidth: true
      text: root.moving ? "Move " + root.remoteName + " to" : "Mount " + root.remoteName + " at"
      color: ui ? ui.foreground : Color.foreground
      opacity: 0.6
      font.family: ui ? ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: pathField
      Layout.fillWidth: true
      text: root.moving ? root.currentPath : "~/" + root.remoteName
      placeholderText: "~/" + root.remoteName
      foreground: ui ? ui.foreground : Color.foreground
      onAccepted: root.submit()
    }

    Toggle {
      id: loginToggle
      Layout.fillWidth: true
      visible: !root.moving
      label: "Mount on login"
      description: "Restored automatically, even if the daemon restarts"
      checked: true
      foreground: ui ? ui.foreground : Color.foreground
      fontFamily: ui ? ui.fontFamily : Style.font.family
      onClicked: checked = !checked
    }

    // Only Drive has the native-docs problem, so only Drive gets the switch.
    // Google Docs report size 0 through a mount and read back empty.
    Toggle {
      id: gdocsToggle
      Layout.fillWidth: true
      visible: root.isDrive && !root.moving
      label: "Hide Google Docs"
      description: "They report size 0 and cannot be opened through a mount"
      checked: true
      foreground: ui ? ui.foreground : Color.foreground
      fontFamily: ui ? ui.fontFamily : Style.font.family
      onClicked: checked = !checked
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Button {
        text: root.moving ? "Move" : "Mount"
        bordered: true
        fontSize: Style.font.caption
        foreground: ui ? ui.foreground : Color.foreground
        fontFamily: ui ? ui.fontFamily : Style.font.family
        Layout.fillWidth: true
        enabled: pathField.text.trim() !== "" && pathField.text.trim() !== root.currentPath
        opacity: enabled ? 1.0 : 0.45
        onClicked: root.submit()
      }

      Button {
        text: "Cancel"
        bordered: true
        fontSize: Style.font.caption
        foreground: ui ? ui.foreground : Color.foreground
        fontFamily: ui ? ui.fontFamily : Style.font.family
        onClicked: root.cancelled()
      }
    }
  }

  function submit() {
    var target = pathField.text.trim()
    if (target === "") return
    // A move MUST reuse the live mount's own fs. Recomposing it from the
    // toggles would silently change the mount's options — the Google Docs
    // switch is hidden while moving, so the user could not even see the change.
    var fs = moving ? currentFs
                    : remoteName + (isDrive && gdocsToggle.checked ? ",skip_gdocs=true:" : ":")
    accepted(fs, target, loginToggle.checked)
  }
}
