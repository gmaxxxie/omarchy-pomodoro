import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar entry point for the Pomodoro timer. A small pill showing a progress
// ring and the remaining time, colored by phase (the original waybar module
// used the same color coding: work red, short break green, long break blue,
// paused yellow — here it is tinted through the theme accent instead of
// hardcoded hex, so it follows Omarchy's accent).
//
// Click behaviour follows the original waybar bindings:
//   Left   -> toggle start/pause
//   Right  -> stop
//   Middle -> skip phase
// A plain click on the panel rows below does the same, so the whole thing
// is also reachable without a middle button.
BarWidget {
  id: root
  moduleName: "io.github.punkpeye.waybar-pomodoro"

  readonly property var timerService: bar && bar.shell
    ? bar.shell.serviceFor(moduleName)
    : null

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false
  readonly property real openPanelIndicatorWidth: Style.bar.iconCanvas
  readonly property real openPanelIndicatorHeight: Style.bar.iconCanvas

  // Same state colors as the waybar CSS, expressed through theme roles so a
  // light or themed accent still reads correctly:
  //   work       -> urgent (the theme's alert red)
  //   short break-> accent (theme accent, usually green in Omarchy)
  //   long break -> blue-tinted foreground (matches waybar's blue)
  //   paused     -> amber-tinted foreground (matches waybar's yellow)
  readonly property color stateColor: {
    if (!timerService || timerService.stopped) return Color.foreground
    if (timerService.paused) return Qt.rgba(0.80, 0.63, 0.13, 1.0)
    if (timerService.phase === "work") return Color.urgent
    if (timerService.phase === "longBreak") return Qt.rgba(0.30, 0.55, 0.85, 1.0)
    return Color.accent
  }

  function syncService() {
    if (timerService && typeof timerService.configure === "function")
      timerService.configure(settings)
    injectPanel()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("timerService" in target) target.timerService = root.timerService
  }

  // ---- Panel lifecycle, for shell summon/hide/toggle routing. The shape
  //      contract is the same one the built-in clock uses.
  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: Qt.callLater(syncService)
  onSettingsChanged: Qt.callLater(syncService)
  onTimerServiceChanged: Qt.callLater(syncService)
  Component.onCompleted: Qt.callLater(syncService)

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.syncService)
    }
  }

  // The timer service is instantiated by the shell before bar widgets are
  // built, so the bar can drive the icon directly.
  Connections {
    target: root.timerService
    enabled: !!root.timerService
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontSize: Style.font.caption
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    text: root.timerService
      ? root.timerService.remainingText
      : "25:00"
    foreground: root.stateColor
    horizontalMargin: 6.5
    tooltipText: root.timerService
      ? root.timerService.phaseLabel + " · " + root.timerService.remainingText +
        " · " + root.timerService.completedPomodoros + " pomodoros done"
      : "Pomodoro"
    // Paused shows the same ring, dimmed, with the time — matching the
    // original paused class (yellow + ⏸).
    opacity: root.timerService && root.timerService.paused ? 0.8 : 1.0

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) {
        if (root.timerService) root.timerService.playOrStop()
      }
      else if (buttonCode === Qt.MiddleButton) {
        if (root.timerService) root.timerService.skip()
      }
    }

    Row {
      anchors.fill: parent
      spacing: 4

      CircularProgress {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        progress: root.timerService ? root.timerService.progress : 0
        trackColor: Color.muted
        fillColor: root.stateColor
        strokeWidth: Math.max(2, Style.spaceReal(2))
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.timerService ? root.timerService.remainingText : "25:00"
        color: root.stateColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
