import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar entry point for the Pomodoro timer.
//
// Idle: just the tomato emoji, dimmed, on the transparent bar — no countdown
// (matches the original waybar CSS `#custom-pomodoro.idle`).
// Running/paused: a small circular countdown ring only — no time text, sized
// to the standard bar icon slot (Style.bar.iconSlot) so it matches every
// other icon in the bar.
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

  // Progress goes 0 -> 1 as the phase elapses (the ring fills up as time
  // runs down — a countdown display).
  readonly property real progress: timerService ? timerService.progress : 0

  // Ring sized to the standard bar icon font size (13px default) — small,
  // like a text glyph in the bar.
  readonly property real ringSize: Style.bar.iconFont

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    // Idle: tomato only, dimmed, on the transparent bar (no background).
    // Running/paused: countdown ring only (no time text).
    //
    // WidgetButton's own `visible` is `hasVisualContent || keepSpace` where
    // hasVisualContent = text !== "", so text must carry the visible content
    // or the whole button (and our Row inside it) hides. The Row below draws
    // the ring; this text is just the content signal.
    text: "🍅"
    // The label text above only serves as the content signal; the Row below
    // paints the tomato or the ring, so the built-in label is hidden.
    labelVisible: false
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

    // Content: the tomato when idle, a small countdown ring when running.
    Item {
      anchors.fill: parent

      // Idle: just the tomato, dimmed.
      Text {
        anchors.centerIn: parent
        visible: !root.timerService || root.timerService.stopped
        text: root.phaseIcon
        color: root.idleColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        // Icon-sized, matching the other bar icons.
        font.pixelSize: Style.bar.iconFont
        opacity: 0.6
      }

      // Running/paused: small countdown ring, no time text.
      CircularProgress {
        id: ring
        anchors.centerIn: parent
        visible: root.timerService && !root.timerService.stopped
        width: root.ringSize
        height: root.ringSize
        progress: root.progress
        trackColor: Color.muted
        fillColor: root.stateColor
        strokeWidth: Math.max(1.5, Style.spaceReal(1.5))
      }
    }
  }
}
