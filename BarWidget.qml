import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar entry point for the Pomodoro timer.
//
// Renders exactly like the original waybar module: an emoji per phase
// (🍅 work / ☕ short break / 🌴 long break) plus the remaining time,
// colored by state (work red, short break green, long break blue, paused
// amber). No custom drawing — just text, so it always renders correctly
// and picks up the bar's font (which already falls back to the color
// emoji font for 🍅/☕/🌴).
//
// Click behaviour follows the original waybar bindings:
//   Left   -> toggle start/pause
//   Right  -> stop
//   Middle -> skip phase
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

  // Phase icon and label, mirroring the original waybar module.
  readonly property string phaseIcon: {
    if (!timerService || timerService.stopped) return "🍅"
    if (timerService.phase === "shortBreak") return "☕"
    if (timerService.phase === "longBreak") return "🌴"
    return "🍅"
  }

  readonly property string phaseText: timerService
    ? timerService.phaseLabel
    : "Idle"

  // Same state colors as the waybar CSS:
  //   work       -> urgent (theme alert red)
  //   short break-> accent (theme accent)
  //   long break -> blue-tinted foreground (waybar's blue)
  //   paused     -> amber-tinted foreground (waybar's yellow)
  readonly property color idleColor: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color stateColor: {
    if (!timerService || timerService.stopped) return idleColor
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

  // ---- Panel lifecycle, for shell summon/hide/toggle routing.
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

  // A subtle dark pill behind the whole widget. The bar is transparent and
  // the wallpaper behind it can clash with the tomato emoji's colors, so a
  // translucent dark capsule keeps the icon legible on any wallpaper — the
  // same trick many bars use for icon buttons.
  Rectangle {
    anchors.fill: parent
    anchors.margins: Math.max(1, Style.spaceReal(1))
    radius: Style.cornerRadius > 0 ? Math.min(height / 2, Style.cornerRadius) : 0
    color: Qt.rgba(0, 0, 0, 0.45)

    Behavior on color { ColorAnimation { duration: 120 } }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontSize: Style.font.body
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    // The emoji is drawn by Noto Color Emoji with its own colors, so the
    // button text color only tints the countdown digits — the tomato stays
    // red/green and visible even when the wallpaper behind the transparent
    // bar is reddish. That matches the original waybar module, which colored
    // only the time text and let the emoji stay full-color.
    //
    // When the timer is idle (not started), show only the tomato, dimmed —
    // the original waybar CSS did exactly this (idle: opacity 0.6, no
    // countdown). The time only appears once a phase is running.
    text: root.timerService && !root.timerService.stopped
      ? (root.timerService.paused
          ? root.phaseIcon + " " + root.timerService.remainingText + " ⏸"
          : root.phaseIcon + " " + root.timerService.remainingText)
      : "🍅"
    foreground: root.stateColor
    horizontalMargin: 6.5
    tooltipText: root.timerService
      ? root.phaseText + " · " + root.timerService.remainingText +
        " · " + root.timerService.completedPomodoros + " pomodoros done"
      : "Pomodoro"
    opacity: root.timerService && root.timerService.stopped
      ? 0.6
      : (root.timerService && root.timerService.paused ? 0.85 : 1.0)

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) {
        if (root.timerService) root.timerService.playOrStop()
      }
      else if (buttonCode === Qt.MiddleButton) {
        if (root.timerService) root.timerService.skip()
      }
    }
  }
}
