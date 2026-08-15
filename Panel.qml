import QtQuick
import qs.Commons
import qs.Ui

// Popup panel for the Pomodoro timer: a countdown ring with the remaining
// time and phase label, a completed-pomodoro counter, and four action rows.
// The rows mirror the original waybar mouse bindings (left toggle, right
// stop, middle skip) as explicit, discoverable buttons, and support full
// keyboard navigation through the shared PanelKeyCatcher.
//
// NOTE: like BarWidget, status is pulled from the service into plain svc*
// properties every second. The service lives behind a function-call boundary
// (bar.shell.serviceFor) that QML cannot track through, so direct bindings to
// timerService.stopped/progress would go stale.
Panel {
  id: root
  moduleName: "io.github.punkpeye.waybar-pomodoro"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var timerService: null
  readonly property var barIdentity: hostWidget || root

  // Mirrors of the service state, refreshed by the timer below.
  property bool svcStopped: true
  property var svcPaused: false
  property string svcPhase: "work"
  property string svcRemaining: "25:00"
  property real svcProgress: 0
  property int svcCompleted: 0
  property string svcPhaseLabel: "Work"
  property bool svcInitialized: false
  // AI activity mirror (from the service's probe).
  property bool svcAiActive: false
  // AI-link toggle state (from the service's configure(settings)).
  property bool svcAiLinked: true

  // Injected by BarWidget.injectPanel(); the widget's shell.json entry.
  property var settings: ({})

  readonly property color foreground: Color.popups.text
  readonly property color activeColor: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property int selectedAction: 0
  property bool cursorActive: true

  readonly property bool canStart: svcInitialized
  readonly property bool canControl: canStart && !svcStopped

  // Enter (and Space via PanelKeyCatcher's activateRequested) run the
  // selected action. PanelKeyCatcher fires returnRequested ONLY on Enter,
  // so a flag tells us whether the activation came from Enter.
  // Space alone (no Enter) is treated as pause/resume — the most common
  // shortcut — instead of running the selected action.
  property bool enterArmed: false

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

  // Pull the current status into plain properties so the UI rebinds. Same
  // reason as BarWidget: service properties don't propagate through the
  // serviceFor() function-call boundary.
  function refreshFromService() {
    if (!timerService) return
    svcStopped = timerService.stopped
    svcPaused = timerService.paused
    svcPhase = timerService.phase
    svcRemaining = timerService.remainingText
    svcProgress = timerService.progress
    svcCompleted = timerService.completedPomodoros
    svcPhaseLabel = timerService.phaseLabel
    svcInitialized = timerService.initialized
    svcAiActive = timerService.aiActive
    svcAiLinked = timerService.aiLinked
  }

  // Persist the AI-link toggle to the widget's shell.json entry, the same
  // pattern the built-in clock panel uses for its settings.
  function setAiLinked(on) {
    svcAiLinked = on
    if (timerService && typeof timerService.configure === "function")
      timerService.configure({ aiLinked: on })

    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.aiLinked = on
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function selectAction(delta) {
    cursorActive = true
    if (!canControl) {
      // Stopped/paused: only the Start row and the AI-link toggle matter.
      if (selectedAction > 4) selectedAction = 4
      return
    }
    // 5 targets: 4 action rows + the AI-link toggle.
    selectedAction = ((selectedAction + delta) % 5 + 5) % 5
  }

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
    else if (selectedAction === 4) root.setAiLinked(!root.svcAiLinked)
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

  // Poll the service while the panel is open, exactly like BarWidget.
  Timer {
    interval: 1000
    running: root.opened && root.timerService !== null
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshFromService()
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
            progress: root.svcProgress
            trackColor: Color.muted
            fillColor: root.activeColor
            strokeWidth: Math.max(5, Style.spaceReal(6))
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(2)

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              // Robot sits inside the ring, left of the countdown, when AI
              // is working.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.svcAiActive && !root.svcStopped
                text: "🤖"
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: !root.svcStopped
                  ? root.svcRemaining
                  : "🍅"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                font.bold: true
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: !root.svcStopped
                ? root.svcPhaseLabel
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

        // ---- AI activity status ----
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.svcInitialized

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.svcAiActive ? "🤖" : "💤"
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.svcAiActive ? "AI working" : "AI idle"
            color: root.svcAiActive ? root.activeColor : Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- AI link toggle ----
        // Lets the user choose whether the pomodoro follows AI activity:
        // AI working -> auto-start, AI idle -> auto-pause the work phase.
        Toggle {
          id: aiLinkToggle
          width: parent.width
          label: "AI 联动"
          description: "AI 运行时自动开始 · 空闲自动暂停"
          checked: root.svcAiLinked
          foreground: root.foreground
          accent: root.activeColor
          fontFamily: root.fontFamily
          hasCursor: root.cursorActive && root.selectedAction === 4
          onHovered: function(value) { root.actionHovered(4, value) }
          onClicked: root.setAiLinked(!root.svcAiLinked)
        }

        // ---- Pomodoro counter ----
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          visible: root.canStart
          text: root.svcCompleted > 0
            ? "🍅".repeat(root.svcCompleted)
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
            enabled: root.canControl && !root.svcPaused
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
