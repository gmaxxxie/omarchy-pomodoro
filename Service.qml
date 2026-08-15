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

  // Stop unconditionally (the panel's Stop button must never start).
  function stop() {
    if (!initialized || stopped) return
    var now = Date.now()
    setState(TimerModel.stoppedState(config, now), true)
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

  // ---- AI activity detection -------------------------------------------
  //
  // "AI is working" = a known AI tool wrote to its session log within the
  // last `aiActiveWindowSec` seconds. The bar widget shows a robot glyph
  // when active, and (optionally) the work phase only counts time while AI
  // is working. Detected tools:
  //   - pi / opencode: ~/.pi/agent/sessions/**/*.jsonl
  //   - codex:         ~/.codex/sessions/**/*.jsonl
  //   - claude:        ~/.claude/projects/**/session.jsonl (if present)
  // The probe is a single `find` that prints the newest mtime; exit 0 with
  // a recent file means active.
  readonly property int aiActiveWindowSec: 180  // 3 min of quiet = idle
  property bool aiActive: false
  property string aiTool: ""          // which tool was seen active
  property double aiLastSeenMs: 0      // when activity was last detected
  property bool aiProbeRunning: false

  readonly property var aiSessionDirs: [
    Quickshell.env("HOME") + "/.pi/agent/sessions",
    Quickshell.env("HOME") + "/.codex/sessions",
    Quickshell.env("HOME") + "/.claude/projects"
  ]

  function probeAi() {
    if (aiProbeRunning) return
    // Probe each session dir: if any *.jsonl/*.json was modified within the
    // last 3 minutes, that AI tool is actively working. Args are passed one
    // per argv element (no shell quoting pitfalls), and the find expression
    // avoids `\(` escapes that JS strings mangle.
    var args = ["bash", "-c",
      "for d; do \n" +
      "  [ -d \"$d\" ] || continue\n" +
      "  f=$(find \"$d\" -type f -mmin -3 \\( -name '*.jsonl' -o -name '*.json' \\) -printf '%f\\n' 2>/dev/null | head -1)\n" +
      "  [ -n \"$f\" ] && { printf '%s' \"$f\"; exit 0; }\n" +
      "done\n" +
      "exit 1", "--"].concat(aiSessionDirs)
    aiProbeProcess.command = args
    aiProbeRunning = true
    aiProbeProcess.running = true
  }

  Process {
    id: aiProbeProcess
    running: false
    stdout: StdioCollector {
      id: aiProbeStdout
      waitForEnd: true
      onStreamFinished: root.onAiProbeResult(String(aiProbeStdout.text || ""))
    }
    onExited: root.aiProbeRunning = false
  }

  function onAiProbeResult(name) {
    var trimmed = String(name || "").replace(/\s+$/, "")
    if (trimmed !== "") {
      aiActive = true
      aiTool = trimmed
      aiLastSeenMs = Date.now()
    } else {
      aiActive = false
      aiTool = ""
    }
  }

  // ---- tick loop ----
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
    // Find the first existing sound file. Quickshell has no File.exists, so
    // probe with `test -f`; passing each path as a separate argv element
    // avoids shell-quoting pitfalls.
    soundCheckArgs = [
      "bash", "-c",
      "for f; do test -f \"$f\" && { printf '%s' \"$f\"; exit 0; }; done; exit 1",
      "--"
    ].concat(soundFiles)
    soundCheckProcess.command = soundCheckArgs
    soundCheckProcess.running = true
  }

  property var soundCheckArgs: []

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
    // Never write before initialization: the default stopped state must not
    // clobber a persisted running/paused state on startup.
    if (!initialized || !savePending || !stateDirReady) return
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

  // AI activity probe — every 30s, starts as soon as the service is up so
  // the bar can show the robot state immediately.
  Timer {
    interval: 30000
    repeat: true
    running: root.initialized
    triggeredOnStart: true
    onTriggered: root.probeAi()
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
      // Do NOT flush here: at startup this runs before the state file has
      // been read, and flushing would overwrite the persisted state with the
      // default stopped state (a race with FileView.onLoaded). Only the
      // scheduled save from setState() after initialization may write.
      if (root.initialized && root.savePending) root.flushState()
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
