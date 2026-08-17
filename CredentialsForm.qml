import QtQuick
import qs.Commons
import qs.Ui

// The paste-your-credentials half of the Drive wizard.
//
// The two warnings here are not padding: people arrive with an API key (wrong
// credential type entirely) or expecting to look up an existing client's
// secret, which Google stopped allowing in 2025. Both cost real time if not
// said at the moment of pasting.
Column {
  id: root

  property QtObject ui: null

  // A name that is FREE, not a fixed "gdrive". Connecting a second Drive
  // account with the name of the first would run `config create` over it and
  // discard its token; rclone-config refuses that, and this keeps the user from
  // meeting the refusal in the first place.
  property string suggestedName: "gdrive"
  // See BackendForm: `config create` replaces a remote of the same name, so a
  // second Drive account named like the first would silently cost you the first.
  property var existingNames: []

  signal submitted(string name, string clientId, string clientSecret)

  readonly property bool complete: nameField.text.trim() !== ""
    && idField.text.trim() !== "" && secretField.text.trim() !== ""
    && !nameCollides

  // Exact match only — rclone remote names are case-sensitive.
  readonly property bool nameCollides:
    (existingNames || []).indexOf(nameField.text.trim()) !== -1

  function reset() {
    nameField.text = root.suggestedName
    idField.text = ""
    secretField.text = ""
  }

  spacing: Style.space(6)

  Note {
    text: "PASTE YOUR CREDENTIALS"
    color: root.ui ? root.ui.foreground : Color.foreground
    opacity: 0.6
  }

  Note {
    text: "Not an API key — those identify a project, carry no user identity, and "
        + "cannot authorize Drive. You need an entry from the OAuth 2.0 Client IDs section."
  }

  Note {
    text: "⚠ Google shows a client secret only once, when the client is created. "
        + "For an existing client you cannot look it up — add a new secret, or create "
        + "a fresh Desktop client and save the JSON it offers you."
    color: root.ui ? root.ui.urgent : Color.urgent
  }

  Note { text: "Remote name" ; opacity: 0.6 }
  TextField {
    id: nameField
    width: parent.width
    text: root.suggestedName
    placeholderText: root.suggestedName
    foreground: root.ui ? root.ui.foreground : Color.foreground
  }

  Note {
    visible: root.nameCollides
    text: "⚠ " + nameField.text.trim() + " already exists. Creating it again would "
        + "replace it and lose its sign-in. Pick another name."
    color: root.ui ? root.ui.urgent : Color.urgent
  }

  Note { text: "Client ID" ; opacity: 0.6 }
  TextField {
    id: idField
    width: parent.width
    placeholderText: "…apps.googleusercontent.com"
    foreground: root.ui ? root.ui.foreground : Color.foreground
  }

  Note { text: "Client secret" ; opacity: 0.6 }
  TextField {
    id: secretField
    width: parent.width
    password: true
    placeholderText: "GOCSPX-…"
    foreground: root.ui ? root.ui.foreground : Color.foreground
    onAccepted: root.submit()
  }

  Button {
    width: parent.width
    text: "Connect Google Drive"
    iconText: "󰌷"
    bordered: true
    foreground: root.ui ? root.ui.foreground : Color.foreground
    fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
    // Ui/Button never reads `enabled` itself — Qt's item tree still blocks the
    // click, but nothing dims, so a disabled button would look simply broken.
    // Carry the visual ourselves.
    enabled: root.complete
    opacity: enabled ? 1.0 : 0.45
    onClicked: root.submit()
  }

  Note {
    text: "rclone opens your browser to finish sign-in. The client secret is passed "
        + "over stdin, so it never reaches this plugin's command line or your shell "
        + "history. rclone itself does put it in its own arguments briefly while it runs."
  }

  function submit() {
    if (!complete) return
    submitted(nameField.text.trim(), idField.text.trim(), secretField.text.trim())
  }

  component Note: Text {
    width: root.width
    color: root.ui ? root.ui.dim : Color.foreground
    font.family: root.ui ? root.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
