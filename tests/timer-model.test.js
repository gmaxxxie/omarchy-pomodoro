#!/usr/bin/env node
// Pure-model tests for TimerModel.js — no QML, no shell, runs anywhere.

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "TimerModel.js"), "utf8")
const model = {}
vm.createContext(model)
vm.runInContext(source, model, { filename: "TimerModel.js" })

const config = model.normalizeConfig({
  workMinutes: 25,
  shortBreakMinutes: 5,
  longBreakMinutes: 15,
  pomodorosUntilLong: 4
})

function closeTo(actual, expected, message) {
  assert.ok(Math.abs(actual - expected) < 1e-6, message + ` (${actual} vs ${expected})`)
}

// ---- normalizeConfig ----
assert.deepEqual(JSON.parse(JSON.stringify(model.normalizeConfig({}))), {
  workMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, pomodorosUntilLong: 4
})
assert.equal(model.normalizeConfig({ workMinutes: 999 }).workMinutes, 120)
assert.equal(model.normalizeConfig({ workMinutes: 0 }).workMinutes, 1)

// ---- stoppedState ----
const stopped = model.stoppedState(config, 1000)
assert.equal(stopped.status, "stopped")
assert.equal(stopped.phase, "work")
assert.equal(stopped.phaseDurationSec, 1500)
assert.equal(stopped.remainingSec, 1500)
assert.equal(stopped.completedPomodoros, 0)

// ---- startNewCycle ----
const started = model.startNewCycle(config, 2000)
assert.equal(started.status, "running")
assert.equal(started.phase, "work")
assert.equal(started.deadlineMs, 2000 + 1500 * 1000)
assert.equal(started.completedPomodoros, 0)

// ---- remainingSeconds ----
assert.equal(model.remainingSeconds(started, 2000), 1500)
assert.equal(model.remainingSeconds(started, 2000 + 60000), 1440)
assert.equal(model.remainingSeconds(started, 2000 + 1500 * 1000), 0)
assert.equal(model.remainingSeconds(stopped, 2000), 1500)

// ---- progress ----
closeTo(model.elapsedProgress(started, 2000), 0, "progress at start")
closeTo(model.elapsedProgress(started, 2000 + 750 * 1000), 0.5, "progress halfway")

// ---- pause / resume ----
const paused = model.pause(started, 2000 + 300 * 1000)
assert.equal(paused.status, "paused")
assert.equal(paused.remainingSec, 1200)
const resumed = model.resume(paused, 2000 + 500 * 1000)
assert.equal(resumed.status, "running")
assert.equal(resumed.deadlineMs, 2000 + 500 * 1000 + 1200 * 1000)

// ---- addSeconds ----
const added = model.addSeconds(started, 300, 2000 + 100 * 1000)
assert.equal(added.phaseDurationSec, 1800)
assert.equal(added.remainingSec, 1700)

// ---- advance / long break after 4 work phases ----
let st = model.startNewCycle(config, 0)
for (let i = 1; i <= 3; i++) {
  st = model.advance(st, config, st.deadlineMs)
  assert.equal(st.phase, "shortBreak", `phase after work #${i}`)
  assert.equal(st.completedPomodoros, i)
  st = model.advance(st, config, st.deadlineMs)
  assert.equal(st.phase, "work", `back to work after short break #${i}`)
}
st = model.advance(st, config, st.deadlineMs)
assert.equal(st.phase, "longBreak", "long break after 4th work phase")
assert.equal(st.completedPomodoros, 4)
st = model.advance(st, config, st.deadlineMs)
assert.equal(st.phase, "work", "work after long break")
assert.equal(st.completedPomodoros, 0)

// ---- recoverInterrupted: work over deadline -> work restarted with notify ----
const rec = model.recoverInterrupted(
  { version: 1, status: "running", phase: "work", completedPomodoros: 2,
    phaseDurationSec: 1500, remainingSec: 0, startedAtMs: 0, deadlineMs: 1000, updatedAtMs: 0 },
  config, 999999)
assert.equal(rec.notifyPhase, "work")
assert.equal(rec.state.status, "running")
assert.equal(rec.state.completedPomodoros, 2)

// ---- recoverInterrupted: fresh stopped state ----
const rec2 = model.recoverInterrupted(null, config, 5000)
assert.equal(rec2.notifyPhase, "")
assert.equal(rec2.state.status, "stopped")

// ---- formatRemaining ----
assert.equal(model.formatRemaining(1500), "25:00")
assert.equal(model.formatRemaining(59), "00:59")
assert.equal(model.formatRemaining(0), "00:00")
assert.equal(model.formatRemaining(-5), "00:00")

// ---- pausedByAiLink marker: AI-link pause can auto-resume, manual cannot ----
const running = model.startNewCycle(config, 0)
const aiPaused = model.pauseForAiIdle(running, 10000)
assert.equal(aiPaused.status, "paused")
assert.equal(aiPaused.pausedByAiLink, true, "AI-link pause marks pausedByAiLink")
assert.equal(aiPaused.remainingSec, 1490, "10s elapsed leaves 1490s")

const aiResumed = model.resume(aiPaused, 20000)
assert.equal(aiResumed.status, "running")
assert.equal(aiResumed.pausedByAiLink, undefined, "resume clears the marker")

const manualPaused = model.pause(running, 30000)
assert.equal(manualPaused.pausedByAiLink, false, "manual pause does not mark pausedByAiLink")

// Persisted state round-trip keeps the marker only while paused.
const sanitizedPaused = model.sanitizeState(aiPaused, config, 40000)
assert.equal(sanitizedPaused.pausedByAiLink, true, "sanitize keeps the marker on paused")
const sanitizedResumed = model.sanitizeState(aiResumed, config, 50000)
assert.equal(sanitizedResumed.pausedByAiLink, false, "sanitize clears the marker on running")

// resume() on a plain paused state (no marker) still works and stays clean.
const resumeManual = model.resume(manualPaused, 60000)
assert.equal(resumeManual.status, "running")
assert.equal(resumeManual.pausedByAiLink, undefined)

console.log("timer-model tests passed")
