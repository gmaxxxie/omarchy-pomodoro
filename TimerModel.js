// Pure timer-state helpers shared by QML and the Node test suite.
//
// Semantics carried over from the original bash waybar-pomodoro:
//   - 25/5/15 minutes, long break every 4 completed work phases
//   - pause/resume keep the phase's remaining time
//   - a completed work phase is counted once, and the count is what
//     decides long-vs-short break
//   - phases auto-advance; the phase that *starts* is notified

var StateVersion = 1
var StatusStopped = "stopped"
var StatusRunning = "running"
var StatusPaused = "paused"
var PhaseWork = "work"
var PhaseShortBreak = "shortBreak"
var PhaseLongBreak = "longBreak"

function finiteNumber(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : fallback
}

function boundedInteger(value, fallback, minimum, maximum) {
  var parsed = Math.round(finiteNumber(value, fallback))
  return Math.max(minimum, Math.min(maximum, parsed))
}

function normalizeConfig(settings) {
  var values = settings || {}
  return {
    workMinutes: boundedInteger(values.workMinutes, 25, 1, 120),
    shortBreakMinutes: boundedInteger(values.shortBreakMinutes, 5, 1, 60),
    longBreakMinutes: boundedInteger(values.longBreakMinutes, 15, 1, 120),
    pomodorosUntilLong: boundedInteger(values.pomodorosUntilLong, 4, 1, 12)
  }
}

function isPhase(value) {
  return value === PhaseWork || value === PhaseShortBreak || value === PhaseLongBreak
}

function isStatus(value) {
  return value === StatusStopped || value === StatusRunning || value === StatusPaused
}

function phaseLabel(phase) {
  if (phase === PhaseShortBreak) return "Short Break"
  if (phase === PhaseLongBreak) return "Long Break"
  return "Work"
}

function durationSeconds(phase, config) {
  var values = normalizeConfig(config)
  if (phase === PhaseShortBreak) return values.shortBreakMinutes * 60
  if (phase === PhaseLongBreak) return values.longBreakMinutes * 60
  return values.workMinutes * 60
}

function stoppedState(config, nowMs) {
  var duration = durationSeconds(PhaseWork, config)
  return {
    version: StateVersion,
    status: StatusStopped,
    phase: PhaseWork,
    completedPomodoros: 0,
    phaseDurationSec: duration,
    remainingSec: duration,
    startedAtMs: 0,
    deadlineMs: 0,
    updatedAtMs: finiteNumber(nowMs, 0)
  }
}

function runningPhase(phase, completedPomodoros, durationSec, nowMs) {
  var now = finiteNumber(nowMs, 0)
  var duration = Math.max(1, finiteNumber(durationSec, 1))
  return {
    version: StateVersion,
    status: StatusRunning,
    phase: isPhase(phase) ? phase : PhaseWork,
    completedPomodoros: Math.max(0, Math.round(finiteNumber(completedPomodoros, 0))),
    phaseDurationSec: duration,
    remainingSec: duration,
    startedAtMs: now,
    deadlineMs: now + duration * 1000,
    updatedAtMs: now
  }
}

function startNewCycle(config, nowMs) {
  return runningPhase(PhaseWork, 0, durationSeconds(PhaseWork, config), nowMs)
}

function restartWork(state, config, nowMs) {
  var completed = state ? state.completedPomodoros : 0
  return runningPhase(PhaseWork, completed, durationSeconds(PhaseWork, config), nowMs)
}

function remainingMilliseconds(state, nowMs) {
  if (!state) return 0
  if (state.status === StatusRunning)
    return Math.max(0, finiteNumber(state.deadlineMs, 0) - finiteNumber(nowMs, 0))
  return Math.max(0, finiteNumber(state.remainingSec, 0) * 1000)
}

function remainingSeconds(state, nowMs) {
  return Math.ceil(remainingMilliseconds(state, nowMs) / 1000)
}

function elapsedProgress(state, nowMs) {
  if (!state) return 0
  var totalMs = Math.max(1000, finiteNumber(state.phaseDurationSec, 1) * 1000)
  var elapsed = totalMs - remainingMilliseconds(state, nowMs)
  return Math.max(0, Math.min(1, elapsed / totalMs))
}

function pause(state, nowMs) {
  if (!state || state.status !== StatusRunning) return state
  var now = finiteNumber(nowMs, 0)
  var remaining = remainingMilliseconds(state, now) / 1000
  var next = cloneState(state)
  next.status = StatusPaused
  next.remainingSec = Math.max(0, remaining)
  next.deadlineMs = 0
  next.updatedAtMs = now
  return next
}

function resume(state, nowMs) {
  if (!state || state.status !== StatusPaused) return state
  var now = finiteNumber(nowMs, 0)
  var remaining = Math.max(1, finiteNumber(state.remainingSec, 1))
  var total = Math.max(remaining, finiteNumber(state.phaseDurationSec, remaining))
  var next = cloneState(state)
  next.status = StatusRunning
  next.phaseDurationSec = total
  next.remainingSec = remaining
  next.startedAtMs = now - (total - remaining) * 1000
  next.deadlineMs = now + remaining * 1000
  next.updatedAtMs = now
  return next
}

function addSeconds(state, seconds, nowMs) {
  if (!state || state.status === StatusStopped) return state
  var addition = Math.max(0, finiteNumber(seconds, 0))
  if (addition === 0) return state
  var now = finiteNumber(nowMs, 0)
  var next = cloneState(state)
  next.phaseDurationSec = Math.max(1, finiteNumber(next.phaseDurationSec, 1) + addition)
  if (next.status === StatusRunning) {
    next.deadlineMs = Math.max(now, finiteNumber(next.deadlineMs, now)) + addition * 1000
    next.remainingSec = remainingMilliseconds(next, now) / 1000
  } else {
    next.remainingSec = Math.max(0, finiteNumber(next.remainingSec, 0)) + addition
  }
  next.updatedAtMs = now
  return next
}

function nextPhaseInfo(state, config) {
  var values = normalizeConfig(config)
  var completed = Math.max(0, Math.round(finiteNumber(state && state.completedPomodoros, 0)))
  var phase = state && isPhase(state.phase) ? state.phase : PhaseWork

  if (phase === PhaseWork) {
    completed++
    if (completed >= values.pomodorosUntilLong)
      return { phase: PhaseLongBreak, completedPomodoros: completed }
    return { phase: PhaseShortBreak, completedPomodoros: completed }
  }

  if (phase === PhaseLongBreak) completed = 0
  return { phase: PhaseWork, completedPomodoros: completed }
}

function advance(state, config, nowMs) {
  var next = nextPhaseInfo(state, config)
  return runningPhase(next.phase, next.completedPomodoros,
                      durationSeconds(next.phase, config), nowMs)
}

// Recover after a sleep/suspend/hibernate gap (tick lag > 5s): running work
// restarts the work phase (like the original lid/sleep hook), running breaks
// keep their remaining time, and a work phase whose deadline passed rolls
// into the next phase. Returns { state, notifyPhase } where notifyPhase is
// the phase that just started, or "".
function recoverInterrupted(state, config, nowMs) {
  var now = finiteNumber(nowMs, 0)
  var clean = sanitizeState(state, config, now)
  if (clean.status === StatusStopped)
    return { state: stoppedState(config, now), notifyPhase: "" }
  if (clean.status === StatusPaused)
    return { state: clean, notifyPhase: "" }

  if (clean.phase === PhaseWork)
    return { state: restartWork(clean, config, now), notifyPhase: PhaseWork }

  if (finiteNumber(clean.deadlineMs, 0) > now) {
    clean.remainingSec = remainingMilliseconds(clean, now) / 1000
    clean.updatedAtMs = now
    return { state: clean, notifyPhase: "" }
  }

  var nextWork = advance(clean, config, now)
  return { state: nextWork, notifyPhase: PhaseWork }
}

function sanitizeState(raw, config, nowMs) {
  var now = finiteNumber(nowMs, 0)
  if (!raw || Number(raw.version) !== StateVersion || !isStatus(raw.status) || !isPhase(raw.phase))
    return stoppedState(config, now)

  var phase = raw.phase
  var fallbackDuration = durationSeconds(phase, config)
  var duration = Math.max(1, finiteNumber(raw.phaseDurationSec, fallbackDuration))
  var remaining = Math.max(0, Math.min(duration, finiteNumber(raw.remainingSec, duration)))
  var status = raw.status
  if (status === StatusPaused && remaining <= 0) remaining = 1

  return {
    version: StateVersion,
    status: status,
    phase: phase,
    completedPomodoros: Math.max(0, Math.round(finiteNumber(raw.completedPomodoros, 0))),
    phaseDurationSec: duration,
    remainingSec: status === StatusRunning
      ? Math.max(0, finiteNumber(raw.remainingSec, duration))
      : remaining,
    startedAtMs: Math.max(0, finiteNumber(raw.startedAtMs, 0)),
    deadlineMs: status === StatusRunning ? Math.max(0, finiteNumber(raw.deadlineMs, 0)) : 0,
    updatedAtMs: Math.max(0, finiteNumber(raw.updatedAtMs, now))
  }
}

function serializableState(state, nowMs) {
  var next = cloneState(state)
  var now = finiteNumber(nowMs, 0)
  if (next.status === StatusRunning)
    next.remainingSec = remainingMilliseconds(next, now) / 1000
  next.updatedAtMs = now
  return next
}

function formatRemaining(seconds) {
  var value = Math.max(0, Math.ceil(finiteNumber(seconds, 0)))
  var minutes = Math.floor(value / 60)
  var remainder = value % 60
  return String(minutes).padStart(2, "0") + ":" + String(remainder).padStart(2, "0")
}

function cloneState(state) {
  var copy = {}
  for (var key in state) copy[key] = state[key]
  return copy
}
