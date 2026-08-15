import QtQuick
import qs.Commons

// A circular countdown ring drawn with Canvas (2d arc), which renders
// deterministically at any size. The track is a full circle; the fill arc
// sweeps clockwise from 12 o'clock by `progress` (0 = empty, 1 = full).
Canvas {
  id: root

  property real progress: 0
  property color trackColor: Color.muted
  property color fillColor: Color.accent
  property real strokeWidth: Math.max(2, Style.spaceReal(2))

  implicitWidth: Style.bar.iconCanvas
  implicitHeight: Style.bar.iconCanvas

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    var mid = width / 2
    var radius = mid - root.strokeWidth / 2
    if (radius <= 0) return

    ctx.lineWidth = root.strokeWidth
    ctx.lineCap = "round"

    // Track: full circle.
    ctx.strokeStyle = root.trackColor
    ctx.beginPath()
    ctx.arc(mid, mid, radius, 0, 2 * Math.PI)
    ctx.stroke()

    // Fill: countdown sweep from 12 o'clock, clockwise.
    if (root.progress > 0) {
      ctx.strokeStyle = root.fillColor
      ctx.beginPath()
      ctx.arc(mid, mid, radius, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * root.progress)
      ctx.stroke()
    }
  }

  onProgressChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
}
