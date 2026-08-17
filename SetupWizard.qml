import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Guided setup for Google Drive — the one provider that forces you to create an
// OAuth client of your own, because rclone's shared credentials are being
// retired during 2026 and are capped at 10 req/s across every rclone user.
// Other providers do not need this and go through `rclone config` instead.
//
// Layout only. The console walk-through is data in Model.js (and tested there);
// the steps, cards and credential fields are their own components.
Column {
  id: wizard

  property QtObject service: null
  property QtObject ui: null

  signal done()

  // True once the user has entered a client id or secret.
  readonly property bool dirty: credentials.dirty

  function clearCredentials() { credentials.reset() }

  spacing: Style.space(10)

  // ---- Header -------------------------------------------------------------
  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    Text {
      text: "󰊶"
      color: wizard.ui ? wizard.ui.foreground : Color.foreground
      font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.heading
      Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: "Connect Google Drive"
        color: wizard.ui ? wizard.ui.foreground : Color.foreground
        font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        text: Model.driveSetupSteps.length + " steps, about ten minutes"
        color: wizard.ui ? wizard.ui.dim : Color.foreground
        font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      iconText: "󰅖"
      tooltipText: "Back"
      foreground: wizard.ui ? wizard.ui.foreground : Color.foreground
      fontFamily: wizard.ui ? wizard.ui.fontFamily : Style.font.family
      Layout.alignment: Qt.AlignVCenter
      onClicked: wizard.done()
    }
  }

  // ---- Why this is necessary ----------------------------------------------
  InfoCard {
    width: parent.width
    ui: wizard.ui
    contentHeight: whyText.implicitHeight

    Text {
      id: whyText
      width: parent.width
      text: "rclone's built-in Google credentials are being retired during 2026 and are "
          + "rate-limited to 10 requests/second shared across every rclone user worldwide. "
          + "Your own client ID avoids both."
      color: wizard.ui ? wizard.ui.dim : Color.foreground
      font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // ---- Reusing an existing project ----------------------------------------
  InfoCard {
    width: parent.width
    ui: wizard.ui
    urgent: true
    contentHeight: reuse.implicitHeight

    Column {
      id: reuse
      width: parent.width
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: "Already have a Google Cloud project?"
        color: wizard.ui ? wizard.ui.foreground : Color.foreground
        font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        text: "Reuse it only if it is your own and has no outside users. Create a NEW "
            + "credential of type Desktop app inside it — never reuse another app's "
            + "client — then skip to the fields below."
        color: wizard.ui ? wizard.ui.dim : Color.foreground
        font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        text: "⚠ If that project is a published, verified app with real users, use a "
            + "SEPARATE project instead. Full Drive access is a restricted scope, so "
            + "adding it forces re-verification and caps the app at 100 users until "
            + "Google approves it."
        color: wizard.ui ? wizard.ui.urgent : Color.foreground
        font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Button {
        width: parent.width
        text: "Open Credentials in an existing project"
        bordered: true
        fontSize: Style.font.caption
        foreground: wizard.ui ? wizard.ui.foreground : Color.foreground
        fontFamily: wizard.ui ? wizard.ui.fontFamily : Style.font.family
        onClicked: Qt.openUrlExternally(Model.driveCredentialsUrl)
      }
    }
  }

  // ---- The walk-through ----------------------------------------------------
  Text {
    width: parent.width
    text: "OR START A FRESH PROJECT"
    color: wizard.ui ? wizard.ui.foreground : Color.foreground
    opacity: 0.6
    font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
  }

  Column {
    id: stepColumn
    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: Model.driveSetupSteps
      WizardStep {
        required property var modelData
        required property int index
        width: stepColumn.width
        step: modelData
        number: index + 1
        ui: wizard.ui
      }
    }
  }

  // ---- Scopes --------------------------------------------------------------
  InfoCard {
    width: parent.width
    ui: wizard.ui
    contentHeight: scopeRow.implicitHeight

    RowLayout {
      id: scopeRow
      width: parent.width
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: "The " + Model.driveScopes.length + " scopes for step 3"
          color: wizard.ui ? wizard.ui.foreground : Color.foreground
          font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: ".../auth/drive · /docs · /drive.metadata.readonly"
          color: wizard.ui ? wizard.ui.dim : Color.foreground
          font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Transcribing these by hand is the most common way to end up with a
      // consent screen that fails later.
      PanelActionButton {
        iconText: "󰆏"
        tooltipText: "Copy all scopes"
        foreground: wizard.ui ? wizard.ui.foreground : Color.foreground
        fontFamily: wizard.ui ? wizard.ui.fontFamily : Style.font.family
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (wizard.service) wizard.service.copyText(Model.driveScopes.join("\n"), "scopes")
      }
    }
  }

  PanelSeparator { foreground: wizard.ui ? wizard.ui.foreground : Color.foreground }

  // ---- Credentials ---------------------------------------------------------
  CredentialsForm {
    id: credentials
    width: parent.width
    ui: wizard.ui
    suggestedName: wizard.service
      ? Model.suggestRemoteName("drive", wizard.service.remotes) : "gdrive"
    existingNames: wizard.service ? wizard.service.allRemoteNames : []
    onSubmitted: function(name, clientId, clientSecret) {
      if (!wizard.service) return
      wizard.service.createDriveRemote(name, clientId, clientSecret)
      wizard.done()
    }
  }

  Text {
    width: parent.width
    visible: wizard.service && wizard.service.statusLine !== ""
    text: wizard.service ? wizard.service.statusLine : ""
    color: wizard.ui ? wizard.ui.dim : Color.foreground
    font.family: wizard.ui ? wizard.ui.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
