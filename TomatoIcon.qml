import QtQuick
import qs.Commons

// A small, crisp monochrome tomato drawn with Canvas. Quickshell's Canvas
// needs a reasonably sized surface (>= ~20px) to render reliably, so this
// is used at bar-icon sizes, not tiny ones.
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
    var cy = height * 0.6
    var r = Math.min(width, height) * 0.35

    // Body: plump tomato. Drawn as a circle squashed slightly, then a
    // shallow top dip carved out so it reads as a tomato, not a ball.
    ctx.save()
    ctx.scale(1, 0.92)
    ctx.beginPath()
    ctx.arc(cx, cy / 0.92, r, 0, 2 * Math.PI)
    ctx.fill()
    ctx.restore()

    // Calyx: five leaves around the stem, drawn as one continuous stroke so
    // it stays crisp at small sizes.
    ctx.strokeStyle = root.color
    ctx.lineWidth = Math.max(1.6, width * 0.1)
    ctx.lineCap = "round"
    var topY = cy - r * 0.72
    var leafR = r * 0.42
    ctx.beginPath()
    // Left leaf
    ctx.moveTo(cx, topY)
    ctx.quadraticCurveTo(cx - leafR, topY - leafR * 0.6, cx - leafR * 1.3, topY + leafR * 0.15)
    // Upper-left leaf
    ctx.moveTo(cx, topY)
    ctx.quadraticCurveTo(cx - leafR * 0.5, topY - leafR, cx - leafR * 0.3, topY - leafR * 1.1)
    // Stem
    ctx.moveTo(cx, topY)
    ctx.lineTo(cx, topY - leafR * 0.9)
    // Upper-right leaf
    ctx.moveTo(cx, topY)
    ctx.quadraticCurveTo(cx + leafR * 0.5, topY - leafR, cx + leafR * 0.3, topY - leafR * 1.1)
    // Right leaf
    ctx.moveTo(cx, topY)
    ctx.quadraticCurveTo(cx + leafR, topY - leafR * 0.6, cx + leafR * 1.3, topY + leafR * 0.15)
    ctx.stroke()
  }

  onColorChanged: requestPaint()
  onIconOpacityChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  Component.onCompleted: requestPaint()
}
