import QtQuick
import QtQuick.Shapes
import qs.Commons

// A minimal circular progress ring used by the bar icon and the panel face.
// Draws with QtQuick.Shapes so it renders cleanly at any size with no font
// dependency.
Shape {
  id: root

  property real progress: 0
  property color trackColor: Color.muted
  property color fillColor: Color.accent
  property real strokeWidth: Math.max(2, Style.spaceReal(2))

  implicitWidth: Style.bar.iconCanvas
  implicitHeight: Style.bar.iconCanvas

  readonly property real mid: Math.max(1, width / 2)
  readonly property real radius: Math.max(1, mid - root.strokeWidth / 2)

  ShapePath {
    strokeColor: root.trackColor
    strokeWidth: root.strokeWidth
    fillColor: "transparent"
    strokeStyle: ShapePath.SolidLine
    capStyle: ShapePath.RoundCap
    startX: root.mid
    startY: root.mid - root.radius

    PathArc {
      x: root.mid - 0.01
      y: root.mid - root.radius
      radiusX: root.radius
      radiusY: root.radius
      direction: PathArc.Counterclockwise
    }
  }

  ShapePath {
    strokeColor: root.fillColor
    strokeWidth: root.strokeWidth
    fillColor: "transparent"
    strokeStyle: ShapePath.SolidLine
    capStyle: ShapePath.RoundCap
    startX: root.mid
    startY: root.mid - root.radius

    PathArc {
      x: root.mid + (root.mid - 0.01 - root.mid) * Math.cos(2 * Math.PI * root.progress)
           - (root.mid - root.radius - root.mid) * Math.sin(2 * Math.PI * root.progress)
      y: root.mid + (root.mid - 0.01 - root.mid) * Math.sin(2 * Math.PI * root.progress)
           + (root.mid - root.radius - root.mid) * Math.cos(2 * Math.PI * root.progress)
      radiusX: root.radius
      radiusY: root.radius
      direction: PathArc.Counterclockwise
    }
  }
}
