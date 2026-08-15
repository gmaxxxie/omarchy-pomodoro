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

  // The service instance is fetched once and kept in a mutable property; the
  // readonly binding to bar.shell.serviceFor() is a function call and QML
  // cannot track status changes through it. A refresh timer below re-checks
  // status every second so the icon switches stopped<->running correctly.
  property var timerService: null
  property bool svcStopped: true
  property var svcPaused: false
  property string svcPhase: "work"
  property string svcRemaining: "25:00"
  property real svcProgress: 0
  property int svcCompleted: 0
  // AI activity mirror (from the service's probe).
  property bool svcAiActive: false
  property string svcAiTool: ""

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false
  readonly property real openPanelIndicatorWidth: Style.bar.iconCanvas
  readonly property real openPanelIndicatorHeight: Style.bar.iconCanvas

  // Phase label, mirroring the original waybar module.
  readonly property string phaseText: timerService
    ? timerService.phaseLabel
    : "Idle"

  // Same state colors as the waybar CSS:
  //   work       -> urgent (theme alert red)
  //   short break-> accent (theme accent)
  //   long break -> blue-tinted foreground (waybar's blue)
  //   paused     -> amber-tinted foreground (waybar's yellow)
  // Idle color: the theme's bar text color (white on the default theme).
  // NOT bar.barForeground — that one is the wallpaper-sampled color when the
  // bar is transparent, which can come out dark. The user wants the icon to
  // match the other bar icons, which use the theme text color.
  readonly property color idleColor: Color.bar.text
  readonly property color stateColor: {
    if (svcStopped) return idleColor
    if (svcPaused) return Qt.rgba(0.80, 0.63, 0.13, 1.0)
    if (svcPhase === "work") return Color.urgent
    if (svcPhase === "longBreak") return Qt.rgba(0.30, 0.55, 0.85, 1.0)
    return Color.accent
  }

  // Ring sized to the standard bar icon font size (13px default) — small,
  // like a text glyph in the bar.
  readonly property real ringSize: Style.bar.iconFont

  function syncService() {
    var svc = bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
    timerService = svc
    refreshFromService()
    if (svc && typeof svc.configure === "function")
      svc.configure(settings)
    injectPanel()
  }

  // Pull the current status into plain properties so the UI rebinds on every
  // tick. The service's own nested properties (timerState.status) don't
  // trigger QML bindings through the serviceFor() function-call boundary.
  function refreshFromService() {
    if (!timerService) return
    svcStopped = timerService.stopped
    svcPaused = timerService.paused
    svcPhase = timerService.phase
    svcRemaining = timerService.remainingText
    svcProgress = timerService.progress
    svcCompleted = timerService.completedPomodoros
    svcAiActive = timerService.aiActive
    svcAiTool = timerService.aiTool
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

  // Poll the service every second: the status properties live behind a
  // function-call boundary (bar.shell.serviceFor) that QML cannot track, so
  // the ring/time/color rebind from the plain svc* copies instead.
  Timer {
    interval: 1000
    running: root.timerService !== null
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshFromService()
  }

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
    // Idle: the 🍅 emoji; running/paused: countdown ring (no time text).
    //
    // WidgetButton's own `visible` is `hasVisualContent || keepSpace` where
    // hasVisualContent = text !== "", so text must carry the visible content
    // or the whole button (and our Item inside it) hides.
    text: "\uf07c0"
    // The label text above only serves as the content signal; the Item below
    // paints the tomato or the ring, so the built-in label is hidden.
    labelVisible: false
    foreground: root.stateColor
    horizontalMargin: 4
    tooltipText: root.timerService
      ? root.phaseText + " · " + root.svcRemaining +
        " · " + root.svcCompleted + " pomodoros done"
      : "Pomodoro"
    opacity: 1.0

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) {
        // Right click = stop (never start, like the original waybar binding).
        if (root.timerService) root.timerService.stop()
      }
      else if (buttonCode === Qt.MiddleButton) {
        if (root.timerService) root.timerService.skip()
      }
    }

    // Content: the tomato when idle, a small countdown ring when running.
    Item {
      anchors.fill: parent

      // Idle: the full-color 🍅 emoji (Noto Color Emoji renders it). The
      // bar font already falls back to the emoji font for 🍅, so it always
      // shows the real tomato.
      Text {
        anchors.centerIn: parent
        visible: root.svcStopped
        text: "🍅"
        color: "#ffffff"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
      }

      // Running/paused: small countdown ring, no time text. When AI is
      // active, a tiny 🤖 sits inside the ring instead of a corner badge.
      Item {
        anchors.centerIn: parent
        visible: !root.svcStopped
        width: root.ringSize
        height: root.ringSize

        CircularProgress {
          anchors.fill: parent
          progress: root.svcProgress
          trackColor: Color.muted
          fillColor: root.stateColor
          strokeWidth: Math.max(1.5, Style.spaceReal(1.5))
        }

        // Robot centered inside the ring when AI is working.
        Text {
          anchors.centerIn: parent
          visible: root.svcAiActive
          text: "🤖"
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.round(root.ringSize * 0.55)
        }
      }
    }
  }
}
