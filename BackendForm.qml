import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Creates a remote for a backend that has NO interactive setup: S3, B2, SFTP,
// WebDAV, FTP. Every option is a plain key=value, so rclone's config state
// machine finishes on the first call and ProviderFlow never gets a question to
// draw — starting a flow for one of these writes a remote with no credentials,
// which is why they were absent from the grid rather than merely broken in it.
//
// The fields are NOT hand-written per backend. `config/providers` describes all
// 69 with per-option Required/Advanced/IsPassword flags, so this renders a form
// it was never taught and cannot drift as rclone changes.
Column {
  id: root

  property QtObject ui: null
  // { type, fields: [{ name, help, required, password, boolean, default, examples }] }
  property var schema: ({})
  property string backendType: ""
  property string backendLabel: ""
  property string suggestedName: ""
  property bool busy: false

  // Answers so far, keyed by option name. A plain object rather than per-field
  // state so submit() has one place to read from.
  property var values: ({})
  property bool showAll: false

  signal submitted(string remoteName, var seeds)
  signal cancelled()

  readonly property var fields: (schema && schema.fields) ? schema.fields : []
  readonly property var requiredFields: fields.filter(function (f) { return f.required })

  // What to show before "More options" is pressed.
  //
  // rclone's Required flag is not a complete answer: s3 marks NOTHING required
  // because what you must fill in depends on which provider you pick, so an
  // obedient form would show an empty page and a Create button. When a backend
  // declares no required fields, lead with its first few instead — for s3 that
  // is provider, env_auth, access_key_id, secret_access_key, which is exactly
  // the set someone connecting a bucket needs.
  readonly property var leadFields: {
    if (requiredFields.length > 0) return requiredFields
    return fields.slice(0, 4)
  }
  readonly property var shownFields: showAll ? fields : leadFields

  function reset() {
    values = ({})
    showAll = false
    nameField.text = suggestedName
  }

  function setValue(name, value) {
    // Replace the object rather than mutating it: assigning into a `property
    // var` in place emits no change signal, so anything bound to it keeps the
    // old contents. That exact mistake silently emptied this form once.
    var next = ({})
    for (var key in values) next[key] = values[key]
    next[name] = value
    values = next
  }

  function valueFor(field) {
    if (values[field.name] !== undefined) return String(values[field.name])
    return String(field.default || "")
  }

  readonly property bool complete: {
    for (var i = 0; i < requiredFields.length; i++) {
      if (valueFor(requiredFields[i]).trim() === "") return false
    }
    return nameField.text.trim() !== ""
  }

  function submit() {
    if (!complete) return
    var seeds = []
    for (var i = 0; i < fields.length; i++) {
      var field = fields[i]
      var value = values[field.name]
      if (value === undefined) continue
      var text = String(value).trim()
      // Send only what the user actually set. Passing every field with its
      // default back to rclone writes a config full of redundant lines and
      // pins today's defaults forever.
      if (text === "" || text === String(field.default || "")) continue
      seeds.push(field.name + "=" + text)
    }
    submitted(nameField.text.trim(), seeds)
  }

  spacing: Style.space(10)

  Text {
    width: parent.width
    text: "Connect " + (root.backendLabel || root.backendType)
    color: root.ui ? root.ui.foreground : Color.foreground
    font.family: root.ui ? root.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  // The schema is a subprocess away, so there is a beat before any field
  // exists. Without this the panel renders an all-but-empty card and collapses
  // to a sliver — which reads as the button having broken, not as loading.
  Text {
    width: parent.width
    visible: root.fields.length === 0
    text: root.busy ? "Reading " + root.backendType + "'s options…"
                    : "No options found for " + root.backendType
    color: root.ui ? root.ui.dim : Color.foreground
    font.family: root.ui ? root.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
  }

  Column {
    width: parent.width
    visible: root.fields.length > 0
    spacing: Style.space(3)

    Text {
      text: "Name for this remote"
      color: root.ui ? root.ui.dim : Color.foreground
      font.family: root.ui ? root.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: nameField
      width: parent.width
      text: root.suggestedName
      placeholderText: root.backendType
      foreground: root.ui ? root.ui.foreground : Color.foreground
    }
  }

  Repeater {
    model: root.shownFields

    Column {
      required property var modelData
      width: root.width
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: modelData.name + (modelData.required ? " *" : "")
        color: root.ui ? root.ui.foreground : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: String(modelData.help || "") !== ""
        text: modelData.help
        color: root.ui ? root.ui.dim : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // A yes/no option is a switch, never a text box someone has to guess
      // "true" into.
      Toggle {
        width: parent.width
        visible: modelData.boolean === true
        label: ""
        checked: root.valueFor(modelData) === "true"
        foreground: root.ui ? root.ui.foreground : Color.foreground
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        onClicked: root.setValue(modelData.name, root.valueFor(modelData) === "true" ? "false" : "true")
      }

      // Long example lists get a filter box — s3's provider field alone has 53
      // entries, which is a scroll, not a choice.
      SearchableDropdown {
        width: parent.width
        visible: modelData.boolean !== true && (modelData.examples || []).length > 10
        showLabel: false
        value: root.valueFor(modelData)
        options: (modelData.examples || []).map(function (e) {
          return { value: e.value, label: e.help !== "" ? e.help : e.value }
        })
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        onValueChanged: if (visible) root.setValue(modelData.name, value)
      }

      Dropdown {
        width: parent.width
        visible: modelData.boolean !== true
                 && (modelData.examples || []).length > 0
                 && (modelData.examples || []).length <= 10
        showLabel: false
        value: root.valueFor(modelData)
        options: (modelData.examples || []).map(function (e) {
          return { value: e.value, label: e.help !== "" ? e.help : e.value }
        })
        fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
        onValueChanged: if (visible) root.setValue(modelData.name, value)
      }

      TextField {
        width: parent.width
        visible: modelData.boolean !== true && (modelData.examples || []).length === 0
        text: root.valueFor(modelData)
        placeholderText: modelData.default || ""
        // rclone obscures password fields itself on `config create` — verified
        // by revealing a stored value — so nothing here has to encrypt, only
        // avoid showing it on screen.
        echoMode: modelData.password === true ? TextInput.Password : TextInput.Normal
        foreground: root.ui ? root.ui.foreground : Color.foreground
        onTextChanged: root.setValue(modelData.name, text)
      }
    }
  }

  Button {
    visible: root.fields.length > root.leadFields.length
    text: root.showAll
      ? "Fewer options"
      : "More options (" + (root.fields.length - root.leadFields.length) + ")"
    bordered: true
    fontSize: Style.font.caption
    foreground: root.ui ? root.ui.foreground : Color.foreground
    fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
    onClicked: root.showAll = !root.showAll
  }

  RowLayout {
    width: parent.width
    spacing: Style.space(6)

    Button {
      visible: root.fields.length > 0
      text: root.busy ? "Creating…" : "Create"
      bordered: true
      fontSize: Style.font.caption
      foreground: root.ui ? root.ui.foreground : Color.foreground
      fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
      Layout.fillWidth: true
      enabled: root.complete && !root.busy
      opacity: enabled ? 1.0 : 0.45
      onClicked: root.submit()
    }

    Button {
      text: "Cancel"
      bordered: true
      fontSize: Style.font.caption
      foreground: root.ui ? root.ui.foreground : Color.foreground
      fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
      onClicked: root.cancelled()
    }
  }
}
