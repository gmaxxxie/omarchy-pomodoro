import QtQuick
import Quickshell
import Quickshell.Io
import "TimerModel.js" as TimerModel

// Headless timer engine for the Pomodoro bar widget.
//
// The service owns the timer state and persists it to
// ~/.local/state/omarchy/pomodoro.json. The bar widget is a thin view over
// it. Unlike the old waybar setup (bash script + /tmp state + polled every
// second), the shell keeps this service alive, so ticking is a 250ms
// in-process Timer instead of a per-second process spawn.
//
// Sleep handling: the original app stopped the timer outright on suspend
// (systemd sleep hook + lid-close monitor). Omarchy's plugin model has no
// hooks for those, and the shell itself is suspended along with the rest of
// the desktop, so the QML timer stalls rather than running. On the next
// tick after a >5s stall, recoverInterrupted() notices the gap and behaves
// like the original hook: a running work phase is reset (idle on return),
// a running break keeps its remaining time, and a work phase whose deadline
// passed while suspended rolls forward.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy"
  readonly property string statePath: stateDir + "/pomodoro.json"
  readonly property string notificationExecutable: omarchyPath !== ""
    ? omarchyPath + "/bin/omarchy-notification-send"
    : "omarchy-notification-send"

  property var config: TimerModel.normalizeConfig({})
  property var timerState: TimerModel.stoppedState(config, Date.now())
  property double nowMs: Date.now()
  property double lastTickMs: 0
  property bool configReady: false
  property bool stateFileLoaded: false
  property bool initialized: false
  property bool stateDirReady: false
  property bool savePending: false
  property string loadedStateText: ""

  readonly property string status: timerState.status
  readonly property string phase: timerState.phase
  readonly property string phaseLabel: TimerModel.phaseLabel(phase)
  readonly property int remainingSeconds: TimerModel.remainingSeconds(timerState, nowMs)
  readonly property string remainingText: TimerModel.formatRemaining(remainingSeconds)
  readonly property real progress: TimerModel.elapsedProgress(timerState, nowMs)
  readonly property bool stopped: status === TimerModel.StatusStopped
  readonly property bool running: status === TimerModel.StatusRunning
  readonly property bool paused: status === TimerModel.StatusPaused
  readonly property int completedPomodoros: Number(timerState.completedPomodoros || 0)

  // Phase completion notifications. The original app played the freedesktop
  // complete/bell sound next to each notification; keep that so the alert
  // still cuts through. No bundled asset exists in the plugin model, so the
  // play is a plain process, and failures are silent.
  readonly property var soundFiles: [
    "/usr/share/sounds/freedesktop/stereo/complete.oga",
    "/usr/share/sounds/freedesktop/stereo/bell.oga",
    "/usr/share/sounds/freedesktop/stereo/message.oga",
    "/usr/share/sounds/Yaru/stereo/complete.oga"
  ]

  function configure(settings) {
    var next = TimerModel.normalizeConfig(settings || {})
    if (JSON.stringify(next) !== JSON.stringify(config)) {
      config = next
      if (initialized && stopped) {
        setState(TimerModel.stoppedState(config, Date.now()), true)
      }
    }
    configReady = true
    initializeIfReady()
  }

  function initializeIfReady() {
    if (initialized || !configReady || !stateFileLoaded) return

    var restored = null
    if (String(loadedStateText || "").trim() !== "") {
      try {
        restored = JSON.parse(loadedStateText)
      } catch (error) {
        console.warn("Pomodoro: ignoring invalid persisted timer state:", error)
      }
    }

    var result = TimerModel.recoverInterrupted(restored, config, Date.now())
    initialized = true
    lastTickMs = Date.now()
    setState(result.state, true)
    if (result.notifyPhase !== "") notifyPhaseStarted(result.notifyPhase)
  }

  function setState(next, persist) {
    timerState = next
    nowMs = Date.now()
    if (persist) scheduleSave()
  }

  // Start a fresh cycle from stopped; stop otherwise.
  function playOrStop() {
    if (!initialized) return
    var now = Date.now()
    if (stopped) setState(TimerModel.startNewCycle(config, now), true)
    else setState(TimerModel.stoppedState(config, now), true)
    lastTickMs = now
  }

  function togglePause() {
    if (!initialized || stopped) return
    var now = Date.now()
    if (running) setState(TimerModel.pause(timerState, now), true)
    else setState(TimerModel.resume(timerState, now), true)
    lastTickMs = now
  }

  // Original waybar binding: middle click = skip phase.
  function skip() {
    if (!initialized || stopped) return
    var now = Date.now()
    setState(TimerModel.advance(timerState, config, now), true)
    lastTickMs = now
  }

  function tick() {
    if (!initialized) return
    var now = Date.now()
    nowMs = now

    if (!running) {
      lastTickMs = now
      return
    }

    // Shell stalled (suspend/sleep/hibernate). Same semantics as the
    // original systemd sleep hook: a running work phase is reset, a
    // running break keeps its remaining time.
    if (lastTickMs > 0 && now - lastTickMs > 5000) {
      var recovered = TimerModel.recoverInterrupted(timerState, config, now)
      setState(recovered.state, true)
      if (recovered.notifyPhase !== "") notifyPhaseStarted(recovered.notifyPhase)
      lastTickMs = now
      return
    }

    if (now >= Number(timerState.deadlineMs || 0)) {
      var next = TimerModel.advance(timerState, config, now)
      setState(next, true)
      notifyPhaseStarted(next.phase)
    }
    lastTickMs = now
  }

  function notifyPhaseStarted(startedPhase) {
    var title = ""
    var description = ""
    var urgency = "normal"
    var glyph = "🍅"

    if (startedPhase === TimerModel.PhaseWork) {
      title = "Work"
      description = "Time to focus!"
      urgency = "critical"
      glyph = "󰄉"
    } else if (startedPhase === TimerModel.PhaseLongBreak) {
      title = "Long Break"
      description = "Time for a long break!"
      glyph = "󰍃"
    } else {
      title = "Short Break"
      description = "Time for a break!"
      glyph = "󰅶"
    }

    // The original app played a sound on every phase change; the freedesktop
    // sounds are the same ones it tried. Play before the notification so the
    // alert lands when the phase lands, not when the toast happens to paint.
    playSound()

    Quickshell.execDetached([
      notificationExecutable,
      "--app-name", "waybar-pomodoro",
      "-g", glyph,
      "-u", urgency,
      title,
      description
    ])
  }

  function playSound() {
    // The sound files are resolved with a tiny shell test rather than an FS
    // API — Quickshell has no File.exists, and plugins avoid extra deps.
    soundCheckProcess.command = ["bash", "-c",
      "for f in " + soundFiles.join(" ") + "; do test -f \"$f\" && { echo \"$f\"; exit 0; }; done; exit 1"]
    soundCheckProcess.running = true
  }

  Process {
    id: soundCheckProcess
    running: false
    stdout: StdioCollector {
      id: soundCheckStdout
      waitForEnd: true
      onStreamFinished: {
        var path = String(soundCheckStdout.text || "").replace(/\s+$/, "")
        if (path !== "") Quickshell.execDetached(["paplay", path])
      }
    }
  }

  function scheduleSave() {
    if (!initialized) return
    savePending = true
    saveTimer.restart()
  }

  function flushState() {
    if (!savePending || !stateDirReady) return
    savePending = false
    var snapshot = TimerModel.serializableState(timerState, Date.now())
    stateFile.setText(JSON.stringify(snapshot, null, 2) + "\n")
  }

  Component.onCompleted: stateDirProcess.running = true

  Timer {
    interval: 250
    repeat: true
    running: root.initialized
    onTriggered: root.tick()
  }

  Timer {
    id: saveTimer
    interval: 100
    repeat: false
    onTriggered: root.flushState()
  }

  Process {
    id: stateDirProcess
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(exitCode) {
      root.stateDirReady = exitCode === 0
      if (!root.stateDirReady) {
        console.warn("Pomodoro: could not create the state directory")
        return
      }
      root.flushState()
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.loadedStateText = text()
      root.stateFileLoaded = true
      root.initializeIfReady()
    }
    onLoadFailed: {
      root.loadedStateText = ""
      root.stateFileLoaded = true
      root.initializeIfReady()
    }
  }
}
