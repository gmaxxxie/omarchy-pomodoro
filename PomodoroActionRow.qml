import QtQuick
import qs.Ui
import qs.Commons

// One action row in the Pomodoro panel: icon + label + optional key hint,
// highlighted through the shared CursorSurface chrome (mouse hover and the
// panel's keyboard cursor share one highlight), clickable end to end.
CursorSurface {
  id: root

  property string iconText: ""
  property string labelText: ""
  property string hintText: ""
  property bool enabled: true
  property string fontFamily: Style.font.family
  property color foregroundColor: Color.foreground
  property color accentColor: Color.accent

  signal clicked()
  signal hovered(bool isHovered)

  implicitWidth: parent ? parent.width : 0
  implicitHeight: Style.space(44)

  foreground: root.foregroundColor
  accent: root.accentColor

  opacity: root.enabled ? 1.0 : 0.35

  Item {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(14)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(14)
    anchors.verticalCenter: parent.verticalCenter
    height: Math.max(iconText.implicitHeight, labelText.implicitHeight, hintText.implicitHeight)

    Text {
      id: iconText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.iconText
      color: root.enabled ? root.foregroundColor : Qt.darker(root.foregroundColor, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Text {
      id: labelText
      anchors.left: iconText.right
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelText
      color: root.enabled ? root.foregroundColor : Qt.darker(root.foregroundColor, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      width: Math.max(0, parent.width - iconText.width - Style.space(12) - (hintText.visible ? hintText.width + Style.space(12) : 0))
    }

    Text {
      id: hintText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.hintText !== ""
      text: root.hintText
      color: Qt.darker(root.foregroundColor, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton
    enabled: root.enabled
    onEntered: root.hovered(true)
    onExited: root.hovered(false)
    onClicked: root.clicked()
  }
}
