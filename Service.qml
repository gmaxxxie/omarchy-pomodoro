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
    var values = settings || {}
    // AI-link toggle lives in the widget's shell.json entry.
    if (typeof values.aiLinked === "boolean") {
      var turningOn = values.aiLinked && !aiLinked
      aiLinked = values.aiLinked
      // Re-enabling the link must not resurrect a phase whose session is
      // gone: when turning the link back on, forget the ownership of any
      // phase paused by the link while it was off.
      if (turningOn) {
        aiPausedPath = ""
      }
    }

    var next = TimerModel.normalizeConfig(values)
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
    // Manual start/stop: the timer is under explicit user control again —
    // it must not auto-start/resume on the next AI probe.
    aiPausedPath = ""
    lastTickMs = now
  }

  // Stop unconditionally (the panel's Stop button must never start).
  function stop() {
    if (!initialized || stopped) return
    var now = Date.now()
    setState(TimerModel.stoppedState(config, now), true)
    // Clearing the paused-path marks the work phase as user-stopped: the AI
    // link must not auto-start it again just because the same session is
    // still writing.
    aiPausedPath = ""
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
  // "AI is working" = a known AI tool is ALIVE as a process AND its session
  // log was written within the last `aiActiveWindowSec` seconds. Detected
  // tools:
  //   - pi / opencode: ~/.pi/agent/sessions/**/*.jsonl
  //   - codex:         ~/.codex/sessions/**/*.jsonl
  //   - claude:        ~/.claude/projects/**/session.jsonl (if present)
  //
  // Two signals, one fast and one safe:
  //  - alive: the tool process is still running (pgrep). When a session
  //    genuinely ends, the process exits and `aiAlive` flips false within
  //    one probe tick (~2s), so the work phase pauses quickly (~5s).
  //  - fresh: the session file is recent. pi writes session logs
  //    intermittently — measured gaps of 50s+ mid-think are normal — so a
  //    short write window would pause a working AI constantly. 60s of
  //    silence is the fallback for tools whose process we cannot name.
  //
  // A process can be alive yet idle for a long time (idle agent waiting for
  // a message): the fresh-write signal keeps the robot honest in that case.
  // The probe prints the *full path* of the newest recently-written file
  // ("<mtime> <path>"), plus a process-alive check, in one bash call.
  readonly property int aiActiveWindowSec: 60  // fallback: 1 min of quiet
  property bool aiAlive: false          // any known AI process is running
  property bool aiActive: false         // alive && wrote within the window
  property string aiTool: ""            // which tool was seen active
  property string aiLastSeenPath: ""    // full path of the last active file
  property double aiLastSeenMs: 0        // when activity was last detected
  property bool aiProbeRunning: false

  // Probe frequency: find the newest write every `aiProbeIntervalSec`.
  // Must stay comfortably below aiActiveWindowSec so the window is
  // actually observed.
  readonly property int aiProbeIntervalSec: 2

  readonly property var aiSessionDirs: [
    Quickshell.env("HOME") + "/.pi/agent/sessions",
    Quickshell.env("HOME") + "/.codex/sessions",
    Quickshell.env("HOME") + "/.claude/projects"
  ]

  function probeAi() {
    if (aiProbeRunning) return
    // Two signals in one bash call:
    //  1. alive: `pgrep -x` for each known tool name. The process name is
    //     the reliable "AI running" signal — a tool that exits flips this
    //     off within one probe tick (~2s), so the work phase pauses fast.
    //  2. fresh: the newest recently-written session file, as
    //     "<mtime> <path>". Sorting the mtimes in-process
    //     (`sort -rn | head -1`) keeps the whole session directory as the
    //     universe, so the newest file across all tools wins
    //     deterministically. The full path is the session fingerprint used
    //     for auto-resume/auto-stop decisions.
    var cutoffSec = Math.floor(Date.now() / 1000) - aiActiveWindowSec
    var args = ["bash", "-c",
      "alive=0\n" +
      "for n in pi opencode codex claude; do pgrep -x \"$n\" >/dev/null 2>&1 && alive=1 && break; done\n" +
      "printf 'ALIVE=%s\\n' \"$alive\"\n" +
      "for d; do \n" +
      "  [ -d \"$d\" ] || continue\n" +
      "  f=$(find \"$d\" -type f -newermt \"@" + cutoffSec + "\" \\( -name '*.jsonl' -o -name '*.json' \\) -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -1)\n" +
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

  // `onStreamFinished` fires when the process ends and all stdout has been
  // read, so the stdout content is complete here. The probe prints
  // "ALIVE=<0|1>\n<mtime> <path>" (the <mtime> <path> part only when a
  // fresh file exists).
  function onAiProbeResult(raw) {
    var text = String(raw || "")
    var trimmed = text.replace(/\s+$/, "")
    var alive = /(?:^|\n)ALIVE=1(?:\n|$)/.test(text)
    aiAlive = alive
    // "ALIVE=<n>\n<mtime> <path>" — the file line is the LAST line, and
    // only counts when it is a real file entry (not the ALIVE marker
    // itself). When no session file was fresh, the output is just
    // "ALIVE=<n>", which must NOT be mistaken for a file (otherwise a
    // running pi with no fresh writes would auto-start the timer).
    var parts = trimmed.split(/\n/)
    var fileLine = parts.length > 1 ? parts[parts.length - 1] : ""
    var path = ""
    if (fileLine !== "" && fileLine.indexOf("ALIVE=") !== 0) {
      // "<mtime> <path>" — the mtime is decorative, the path is the
      // fingerprint.
      var space = fileLine.indexOf(" ")
      path = space > 0 ? fileLine.substring(space + 1) : fileLine
    }
    if (path !== "") {
      var stale = aiLastSeenPath !== "" && aiLastSeenPath !== path
      aiActive = true
      aiTool = aiToolName(path)
      aiLastSeenPath = path
      aiLastSeenMs = Date.now()
      // A DIFFERENT session than the one we were following means the
      // previous AI session genuinely ended and a new one started: do not
      // auto-resume the old one, and if the timer is idle let the new
      // session start fresh. The old session's file is still fresh within
      // the window, so without this check the timer would keep restarting
      // forever ("timer keeps running after AI stopped").
      if (stale) {
        aiPausedPath = ""
      }
      maybeAutoStart()
    } else {
      aiActive = false
      aiTool = ""
    }
  }

  // Fast "AI stopped" signal: the tool process that was writing the session
  // is no longer alive. aiAlive flips false within one probe tick (~2s) of
  // the process exiting, so the work phase pauses within ~5s instead of
  // waiting out the 60s write window. When the process is alive but just
  // quiet, this stays true and the write window remains the fallback.
  function aiProcessStopped() {
    if (!aiAlive) return true
    // The process we last saw could be a different one than the tool that
    // owns the current work phase; the write window still applies.
    return false
  }

  // Map a session file path back to the tool name shown in the UI. The
  // probe only has the path, not the originating tool.
  function aiToolName(path) {
    var p = String(path || "")
    if (p.indexOf("/.pi/agent/sessions/") !== -1) return "pi"
    if (p.indexOf("/.codex/sessions/") !== -1) return "codex"
    if (p.indexOf("/.claude/") !== -1) return "claude"
    return "ai"
  }

  // ---- AI-linked pomodoro ----------------------------------------------
  //
  // When enabled, the work phase follows AI activity:
  //   - idle + AI working      -> auto-start a work phase
  //   - running work + AI process gone -> auto-pause within ~5s
  //   - running work + AI quiet for the window -> auto-pause (fallback)
  //   - AI-paused work + same session working again -> auto-resume
  // Pauses caused by the AI link are marked (pausedByAiLink) so they can
  // auto-resume; manual pauses stay paused until you resume.
  //
  // The link only *follows* the timer: it never stops it when disabled. A
  // session change (see onAiProbeResult) clears the paused-path, so an old
  // session can never keep the timer alive forever.
  // Controlled by the "AI link" toggle in the panel (settings.aiLinked).
  property bool aiLinked: true

  // Full path of the session we auto-paused FOR (the work phase runs while
  // that session is active). Auto-resume only happens for the same session;
  // a different session starting does not resume this phase.
  property string aiPausedPath: ""

  // Called from tick while running; returns true when the deadline advanced.
  function handleAiLink() {
    if (!aiLinked) return false

    // Fast path: the AI process we were following exited (or the whole
    // tool is gone) -> the session is over, pause the work phase right
    // away instead of waiting out the write window. This is the "AI
    // stopped -> timer pauses within seconds" behaviour.
    if (running && phase === TimerModel.PhaseWork && aiProcessStopped()) {
      if (aiLastSeenMs > 0 && Date.now() - aiLastSeenMs > 2500) {
        setState(TimerModel.pauseForAiIdle(timerState, Date.now()), true)
        aiPausedPath = aiLastSeenPath
        return true
      }
    }

    // Fallback: the process is alive but went quiet for the full write
    // window (idle agent waiting for input) -> pause a running work phase.
    if (running && phase === TimerModel.PhaseWork && !aiActive) {
      // Only pause once the quiet window has actually passed AND we have
      // seen AI activity at least once. aiLastSeenMs starts at 0 (never
      // probed yet) — Date.now() - 0 would be huge and instantly pause a
      // fresh start on shell boot before the first probe runs.
      if (aiLastSeenMs > 0 && Date.now() - aiLastSeenMs > aiActiveWindowSec * 1000) {
        setState(TimerModel.pauseForAiIdle(timerState, Date.now()), true)
        // Remember which session we are waiting for: only that session
        // may auto-resume this phase.
        aiPausedPath = aiLastSeenPath
        return true
      }
    }
    return false
  }

  // Auto-start when AI begins working and the timer is idle. Called from
  // onAiProbeResult.
  function maybeAutoStart() {
    if (!aiLinked || !initialized || !aiActive) return
    if (stopped) {
      var now = Date.now()
      setState(TimerModel.startNewCycle(config, now), true)
      lastTickMs = now
      return
    }
    // A work phase that the AI link auto-paused (AI went idle) resumes
    // automatically now that the SAME session is working again. Manual
    // pauses are left alone — the user explicitly stopped the timer.
    if (paused && phase === TimerModel.PhaseWork &&
        timerState.pausedByAiLink === true &&
        aiPausedPath !== "" && aiPausedPath === aiLastSeenPath) {
      setState(TimerModel.resume(timerState, Date.now()), true)
      lastTickMs = Date.now()
      aiPausedPath = ""
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

    // AI-linked pause (work + AI idle).
    if (root.handleAiLink()) {
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

  // AI activity probe — every `aiProbeIntervalSec`, starts as soon as the
  // service is up so the bar can show the robot state immediately.
  Timer {
    interval: root.aiProbeIntervalSec * 1000
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
