import QtQuick
import qs.Commons
import qs.Ui

// Popup panel for the Pomodoro timer: a big phase emoji with the remaining
// time and phase label, a completed-pomodoro counter, and four action rows.
// The rows mirror the original waybar mouse bindings (left toggle, right
// stop, middle skip) as explicit, discoverable buttons, and support full
// keyboard navigation through the shared PanelKeyCatcher.
Panel {
  id: root
  moduleName: "io.github.punkpeye.waybar-pomodoro"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var timerService: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: Color.popups.text
  readonly property color activeColor: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property int selectedAction: 0
  property bool cursorActive: true

  readonly property bool canStart: !!timerService && timerService.initialized
  readonly property bool canControl: canStart && !timerService.stopped

  readonly property string phaseIcon: {
    if (!timerService || timerService.stopped) return "🍅"
    if (timerService.phase === "shortBreak") return "☕"
    if (timerService.phase === "longBreak") return "🌴"
    return "🍅"
  }

  function open() {
    selectedAction = 0
    cursorActive = true
    controller.show()
  }

  function close() {
    controller.hide()
  }

  function toggle() {
    if (opened) close()
    else open()
  }

  function selectAction(delta) {
    cursorActive = true
    if (!canControl) {
      selectedAction = 0
      return
    }
    selectedAction = ((selectedAction + delta) % 4 + 4) % 4
  }

  // Enter (and Space via PanelKeyCatcher's activateRequested) run the
  // selected action. PanelKeyCatcher fires returnRequested ONLY on Enter,
  // so a flag tells us whether the activation came from Enter.
  // Space alone (no Enter) is treated as pause/resume — the most common
  // shortcut — instead of running the selected action.
  property bool enterArmed: false

  function activateSelected() {
    if (!canStart) return
    // Space (no Enter): pause/resume regardless of selection.
    if (!root.enterArmed) {
      root.enterArmed = false
      if (canControl) timerService.togglePause()
      return
    }
    root.enterArmed = false
    if (selectedAction === 0) timerService.playOrStop()
    else if (selectedAction === 1 && canControl) timerService.togglePause()
    else if (selectedAction === 2 && canControl) timerService.skip()
    else if (selectedAction === 3 && canControl) timerService.stop()
  }

  function actionHovered(index, hovered) {
    if (!hovered) return
    cursorActive = true
    selectedAction = index
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.selectAction(dx)
        else if (dy !== 0) root.selectAction(dy)
      }
      onActivateRequested: root.activateSelected()
      // Enter fires returnRequested before activateRequested — arm the flag
      // so the activation is treated as Enter (run selection), not Space.
      onReturnRequested: root.enterArmed = true
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.timerService.skip()
        else if (t === "p" || t === "P") root.timerService.togglePause()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // ---- Timer face: countdown ring + remaining time ----
        // The whole face is clickable: when idle, clicking it starts the
        // timer directly (no need to hunt for the Start button).
        Item {
          width: parent.width
          height: Style.space(140)

          // A generous ring — big enough to read the countdown arc clearly.
          CircularProgress {
            id: timerRing
            anchors.centerIn: parent
            width: Math.min(parent.width, Style.space(130))
            height: width
            progress: root.timerService ? root.timerService.progress : 0
            trackColor: Color.muted
            fillColor: root.activeColor
            strokeWidth: Math.max(5, Style.spaceReal(6))
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(2)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.timerService && !root.timerService.stopped
                ? root.timerService.remainingText
                : "🍅"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.timerService && !root.timerService.stopped
                ? root.timerService.phaseLabel
                : "Click to start"
              color: root.activeColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Clicking the face starts (idle) or toggles (running).
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.canStart) root.timerService.playOrStop()
            }
          }
        }

        // ---- Pomodoro counter ----
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          visible: root.canStart
          text: root.timerService && root.timerService.completedPomodoros > 0
            ? "🍅".repeat(root.timerService.completedPomodoros)
            : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        // ---- Actions ----
        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "ACTIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PomodoroActionRow {
            iconText: ""
            labelText: "Start / Resume"
            hintText: "Enter"
            foregroundColor: root.foreground
            accentColor: root.activeColor
            fontFamily: root.fontFamily
            enabled: root.canStart
            hasCursor: root.cursorActive && root.selectedAction === 0
            onHovered: function(value) { root.actionHovered(0, value) }
            onClicked: { if (root.canStart) root.timerService.playOrStop() }
          }

          PomodoroActionRow {
            iconText: ""
            labelText: "Pause"
            hintText: "Space"
            foregroundColor: root.foreground
            accentColor: root.activeColor
            fontFamily: root.fontFamily
            enabled: root.canControl && !root.timerService.paused
            hasCursor: root.cursorActive && root.selectedAction === 1
            onHovered: function(value) { root.actionHovered(1, value) }
            onClicked: { if (root.canControl) root.timerService.togglePause() }
          }

          PomodoroActionRow {
            iconText: ""
            labelText: "Skip phase"
            hintText: "S"
            foregroundColor: root.foreground
            accentColor: root.activeColor
            fontFamily: root.fontFamily
            enabled: root.canControl
            hasCursor: root.cursorActive && root.selectedAction === 2
            onHovered: function(value) { root.actionHovered(2, value) }
            onClicked: { if (root.canControl) root.timerService.skip() }
          }

          PomodoroActionRow {
            iconText: ""
            labelText: "Stop"
            hintText: "Enter"
            foregroundColor: root.foreground
            accentColor: root.activeColor
            fontFamily: root.fontFamily
            // Stop must never start: it is only enabled while running/paused.
            enabled: root.canControl
            hasCursor: root.cursorActive && root.selectedAction === 3
            onHovered: function(value) { root.actionHovered(3, value) }
            onClicked: { if (root.canControl) root.timerService.stop() }
          }
        }
      }
    }
  }
}
