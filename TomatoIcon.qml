import QtQuick
import qs.Commons

// A simple monochrome tomato drawn with Canvas, tinted by `color` — so it
// matches the bar's icon color (white on the default theme) instead of the
// full-color emoji, which cannot be recolored.
Canvas {
  id: root

  property color color: Color.foreground
  property real iconOpacity: 1.0

  implicitWidth: Style.bar.iconCanvas
  implicitHeight: Style.bar.iconCanvas

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    ctx.globalAlpha = root.iconOpacity
    ctx.fillStyle = root.color

    var cx = width / 2
    var cy = height / 2
    var r = Math.min(width, height) * 0.46

    // Body: a plump tomato (slightly wider than tall), drawn with arc + scale
    // since Canvas 2D `ellipse` is not guaranteed in Quickshell.
    ctx.save()
    ctx.scale(1, 0.9)
    ctx.beginPath()
    ctx.arc(cx, cy / 0.9 + r * 0.1, r, 0, 2 * Math.PI)
    ctx.fill()
    ctx.restore()

    // Leaf calyx on top: three short strokes fanning from the top center.
    ctx.strokeStyle = root.color
    ctx.lineWidth = Math.max(1.5, width * 0.09)
    ctx.lineCap = "round"
    var topY = cy - r * 0.55
    ctx.beginPath()
    ctx.moveTo(cx, topY)
    ctx.quadraticCurveTo(cx - r * 0.42, topY - r * 0.35, cx - r * 0.62, topY - r * 0.18)
    ctx.moveTo(cx, topY)
    ctx.quadraticCurveTo(cx, topY - r * 0.5, cx + r * 0.02, topY - r * 0.62)
    ctx.moveTo(cx, topY)
    ctx.quadraticCurveTo(cx + r * 0.42, topY - r * 0.35, cx + r * 0.62, topY - r * 0.18)
    ctx.stroke()

    // Stem: a short line up from the top.
    ctx.beginPath()
    ctx.moveTo(cx, topY)
    ctx.lineTo(cx, topY - r * 0.42)
    ctx.stroke()
  }

  onColorChanged: requestPaint()
  onIconOpacityChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  Component.onCompleted: requestPaint()
}
