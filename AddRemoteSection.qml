import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// "Add a remote", the cloud grid it opens, and the one extra question some
// backends need before rclone will start.
//
// One grid, every cloud. Google Drive sits in it like the rest and simply
// routes to the wizard — giving it its own row made the panel read as "Google
// Drive, and also some others".
//
// Raises signals rather than touching panel state directly: this section has no
// business knowing where the keyboard cursor goes next, and keeping that
// decision in the panel is what lets the grid be moved or reused.
Column {
  id: root

  property QtObject ui: null
  // Whether rclone itself is available — every action here needs it.
  property bool installed: false
  // Whether the grid is showing.
  property bool expanded: false
  // Backend type whose seed question is open, or "" for none.
  property string seedFor: ""

  // Cursor context, passed in so this file never reaches back into the panel.
  property bool cursorActive: false
  property string focusSection: ""
  property int actionIndex: 0

  signal toggleRequested()
  signal providerPicked(var provider)
  signal seedPicked(var provider, string value)
  signal otherProviderRequested()

  // The provider whose seed question is open. Looked up once here instead of
  // being re-derived at each use — the previous version reached through
  // `parent.parent.provider`, which silently breaks the moment anything is
  // nested differently.
  readonly property var seedProvider: {
    var list = Model.quickProviders
    for (var i = 0; i < list.length; i++) {
      if (list[i].type === root.seedFor) return list[i]
    }
    return null
  }

  spacing: Style.space(8)

  ActionRow {
    width: parent.width
    ui: root.ui
    glyph: "󰐕"
    title: "Add a remote"
    subtitle: root.expanded ? "Pick a cloud" : "Google Drive, OneDrive, Dropbox, Box and more"
    hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === 0
    enabledAction: root.installed
    onTriggered: root.toggleRequested()
  }

  Column {
    width: parent.width
    visible: root.expanded
    spacing: Style.space(8)

    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: Model.quickProviders
        Button {
          required property var modelData
          required property int index
          text: modelData.label
          bordered: true
          fontSize: Style.font.caption
          hasCursor: root.cursorActive && root.focusSection === "providers"
                     && root.actionIndex === index
          foreground: root.ui ? root.ui.foreground : Color.foreground
          fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
          onClicked: root.providerPicked(modelData)
        }
      }
    }

    // The one question rclone will not ask, for backends that refuse to start
    // without it — zoho exits "Error: no region set" before its state machine
    // runs, so there is no step to answer it in. Shown under the grid, attached
    // to the button that opened it.
    Column {
      width: parent.width
      visible: root.seedProvider !== null
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: root.seedProvider && root.seedProvider.seed ? root.seedProvider.seed.prompt : ""
        color: root.ui ? root.ui.dim : Color.foreground
        font.family: root.ui ? root.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.seedProvider && root.seedProvider.seed
                 ? root.seedProvider.seed.options : []
          Button {
            required property var modelData
            text: modelData.label
            bordered: true
            fontSize: Style.font.caption
            foreground: root.ui ? root.ui.foreground : Color.foreground
            fontFamily: root.ui ? root.ui.fontFamily : Style.font.family
            onClicked: root.seedPicked(root.seedProvider, modelData.value)
          }
        }
      }
    }

    ActionRow {
      width: parent.width
      ui: root.ui
      glyph: "󰆍"
      title: "Any other provider"
      subtitle: "Opens rclone config in a terminal — all 69 backends"
      hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === 1
      enabledAction: root.installed
      onTriggered: root.otherProviderRequested()
    }
  }
}
