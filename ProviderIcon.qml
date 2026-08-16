import QtQuick
import QtQuick.Shapes
import qs.Commons
import "Model.js" as Model

// One icon for a backend type, by whichever means suits that type.
//
// Three tiers, in order of preference:
//   1. a DRAWN mark, for types with a shape worth drawing (box, s3, sftp…)
//   2. a font glyph, where the Nerd Font already has a good, distinct one
//      (Google Drive, Dropbox, OneDrive)
//   3. a MONOGRAM badge — the type's initial in a rounded square
//
// Tier 3 is what makes this maintainable: rclone supports 69 backends and the
// font has brand icons for a handful, so the previous mapping silently gave
// box, s3, pcloud and zoho the SAME default cloud. A monogram is never wrong
// and never needs new art, so a backend nobody anticipated still gets a
// distinguishable icon.
//
// Drawn rather than shipped as SVG assets because that is the house pattern —
// the first-party Dropbox plugin draws its own logo with Shape/ShapePath — and
// it inherits the theme colour for free.
Item {
  id: root

  property string type: ""
  property real iconSize: Style.font.icon
  property color color: Color.foreground

  readonly property string kind: {
    var t = String(type || "").toLowerCase()
    if (t === "box") return "box"
    if (t === "s3" || t === "b2" || t === "swift" || t === "gcs") return "bucket"
    if (t === "sftp" || t === "ftp" || t === "webdav" || t === "http") return "server"
    if (t === "crypt") return "lock"
    if (t === "local" || t === "alias") return "folder"
    if (t === "drive") return "glyph"
    if (t === "dropbox") return "glyph"
    if (t === "onedrive" || t === "sharepoint") return "glyph"
    return "monogram"
  }

  readonly property string glyphText: {
    var t = String(type || "").toLowerCase()
    if (t === "drive") return "󰊶"
    if (t === "dropbox") return "󰇣"
    return "󰏊" // onedrive / sharepoint
  }

  // Types of the other remotes on screen, so the badge can be made unique
  // against what is actually configured rather than against all 69 backends.
  property var siblingTypes: []

  readonly property string monogram: Model.monogramFor(type, siblingTypes)

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // ---- tier 2: font glyph ---------------------------------------------------
  Text {
    anchors.centerIn: parent
    visible: root.kind === "glyph"
    text: root.glyphText
    color: root.color
    font.family: Style.font.family
    font.pixelSize: root.iconSize
  }

  // ---- tier 3: monogram badge -----------------------------------------------
  Rectangle {
    anchors.fill: parent
    visible: root.kind === "monogram"
    radius: root.iconSize * 0.25
    color: "transparent"
    border.width: Math.max(1, root.iconSize * 0.08)
    border.color: root.color

    Text {
      anchors.centerIn: parent
      text: root.monogram
      color: root.color
      font.family: Style.font.family
      font.pixelSize: root.iconSize * (root.monogram.length > 1 ? 0.44 : 0.58)
      font.bold: true
    }
  }

  // ---- tier 1: drawn marks --------------------------------------------------
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    visible: root.kind === "box"

    // An isometric cube: top face, then the two visible sides in lighter tones
    // so the form reads at 16px.
    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.width * 0.5;  startY: root.height * 0.08
      PathLine { x: root.width * 0.94; y: root.height * 0.30 }
      PathLine { x: root.width * 0.5;  y: root.height * 0.52 }
      PathLine { x: root.width * 0.06; y: root.height * 0.30 }
      PathLine { x: root.width * 0.5;  y: root.height * 0.08 }
    }
    ShapePath {
      fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.55)
      strokeWidth: 0
      startX: root.width * 0.06; startY: root.height * 0.30
      PathLine { x: root.width * 0.5;  y: root.height * 0.52 }
      PathLine { x: root.width * 0.5;  y: root.height * 0.94 }
      PathLine { x: root.width * 0.06; y: root.height * 0.72 }
      PathLine { x: root.width * 0.06; y: root.height * 0.30 }
    }
    ShapePath {
      fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.3)
      strokeWidth: 0
      startX: root.width * 0.94; startY: root.height * 0.30
      PathLine { x: root.width * 0.94; y: root.height * 0.72 }
      PathLine { x: root.width * 0.5;  y: root.height * 0.94 }
      PathLine { x: root.width * 0.5;  y: root.height * 0.52 }
      PathLine { x: root.width * 0.94; y: root.height * 0.30 }
    }
  }

  // A storage bucket: trapezoid body with an elliptical lip.
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    visible: root.kind === "bucket"

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.width * 0.16; startY: root.height * 0.28
      PathLine { x: root.width * 0.84; y: root.height * 0.28 }
      PathLine { x: root.width * 0.72; y: root.height * 0.90 }
      PathLine { x: root.width * 0.28; y: root.height * 0.90 }
      PathLine { x: root.width * 0.16; y: root.height * 0.28 }
    }
    ShapePath {
      fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.55)
      strokeWidth: 0
      startX: root.width * 0.10; startY: root.height * 0.22
      PathArc {
        x: root.width * 0.90; y: root.height * 0.22
        radiusX: root.width * 0.40; radiusY: root.height * 0.13
        useLargeArc: false
      }
      PathArc {
        x: root.width * 0.10; y: root.height * 0.22
        radiusX: root.width * 0.40; radiusY: root.height * 0.13
        useLargeArc: false
      }
    }
  }

  // Stacked server bars.
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    visible: root.kind === "server"

    Bar { top: root.height * 0.14 }
    Bar { top: root.height * 0.42 }
    Bar { top: root.height * 0.70 }
  }

  // A padlock: body plus shackle.
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    visible: root.kind === "lock"

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.width * 0.18; startY: root.height * 0.44
      PathLine { x: root.width * 0.82; y: root.height * 0.44 }
      PathLine { x: root.width * 0.82; y: root.height * 0.92 }
      PathLine { x: root.width * 0.18; y: root.height * 0.92 }
      PathLine { x: root.width * 0.18; y: root.height * 0.44 }
    }
    ShapePath {
      strokeColor: root.color
      strokeWidth: Math.max(1, root.iconSize * 0.11)
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      startX: root.width * 0.31; startY: root.height * 0.44
      PathArc {
        x: root.width * 0.69; y: root.height * 0.44
        radiusX: root.width * 0.19; radiusY: root.height * 0.19
        useLargeArc: true
      }
    }
  }

  // A folder with a tab.
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    visible: root.kind === "folder"

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.width * 0.08; startY: root.height * 0.24
      PathLine { x: root.width * 0.44; y: root.height * 0.24 }
      PathLine { x: root.width * 0.52; y: root.height * 0.36 }
      PathLine { x: root.width * 0.92; y: root.height * 0.36 }
      PathLine { x: root.width * 0.92; y: root.height * 0.84 }
      PathLine { x: root.width * 0.08; y: root.height * 0.84 }
      PathLine { x: root.width * 0.08; y: root.height * 0.24 }
    }
  }

  component Bar: ShapePath {
    property real top: 0
    fillColor: root.color
    strokeWidth: 0
    startX: root.width * 0.12; startY: top
    PathLine { x: root.width * 0.88; y: top }
    PathLine { x: root.width * 0.88; y: top + root.height * 0.16 }
    PathLine { x: root.width * 0.12; y: top + root.height * 0.16 }
    PathLine { x: root.width * 0.12; y: top }
  }
}
