#!/bin/bash
# Runtime smoke test: boot a throwaway Omarchy shell with this plugin,
# confirm it is discovered/enabled, the bar widget renders, and the panel
# can be summoned/hidden/toggled.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ -z ${OMARCHY_PATH:-} || ! -d $OMARCHY_PATH/shell ]]; then
  echo "skipping runtime smoke test (set OMARCHY_PATH to an Omarchy checkout)"
  exit 0
fi

if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
  echo "skipping runtime smoke test (no Wayland compositor)"
  exit 0
fi

for command in quickshell jq rg; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "skipping runtime smoke test ($command is unavailable)"
    exit 0
  fi
done

PLUGIN_ID="io.github.punkpeye.waybar-pomodoro"

tmpdir=$(mktemp -d)
quickshell_pid=""

cleanup() {
  if [[ -n $quickshell_pid ]] && kill -0 "$quickshell_pid" 2>/dev/null; then
    kill "$quickshell_pid" 2>/dev/null || true
    wait "$quickshell_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

test_root="$tmpdir/omarchy"
test_home="$tmpdir/home"
test_state="$test_home/.local/state"
plugin_dir="$test_home/.config/omarchy/plugins/$PLUGIN_ID"
log="$tmpdir/quickshell.log"

mkdir -p "$test_root" "$plugin_dir" "$test_home/.config/omarchy"
cp -a "$OMARCHY_PATH/shell" "$test_root/shell"
ln -s "$OMARCHY_PATH/bin" "$test_root/bin"
ln -s "$OMARCHY_PATH/config" "$test_root/config"
cp "$ROOT/manifest.json" "$ROOT/Service.qml" "$ROOT/TimerModel.js" \
  "$ROOT/BarWidget.qml" "$ROOT/Panel.qml" \
  "$ROOT/PomodoroActionRow.qml" \
  "$plugin_dir/"

jq -n '{
  version: 1,
  idle: { screensaver: 150, lock: 300 },
  bar: {
    position: "top",
    transparent: false,
    centerAnchor: "",
    layout: { left: [], center: [], right: [{ id: "io.github.punkpeye.waybar-pomodoro" }] }
  },
  plugins: []
}' >"$test_home/.config/omarchy/shell.json"

shell_ipc() {
  HOME="$test_home" \
  XDG_STATE_HOME="$test_state" \
  OMARCHY_PATH="$test_root" \
    "$OMARCHY_PATH/bin/omarchy-shell" "$@"
}

fail_with_log() {
  sed -n '1,240p' "$log" >&2
  echo "runtime smoke test failed: $1" >&2
  exit 1
}

HOME="$test_home" \
XDG_STATE_HOME="$test_state" \
OMARCHY_PATH="$test_root" \
PATH="$test_root/bin:$PATH" \
  quickshell -p "$test_root/shell" --no-color >"$log" 2>&1 &
quickshell_pid=$!

for _ in {1..100}; do
  if shell_ipc -q shell ping >/dev/null 2>&1; then
    break
  fi
  kill -0 "$quickshell_pid" 2>/dev/null \
    || fail_with_log "the shell exited before IPC became available"
  sleep 0.1
done

plugins=""
for _ in {1..100}; do
  plugins=$(shell_ipc shell listPlugins 2>/dev/null || true)
  if jq -e 'any(.[]; .id == "io.github.punkpeye.waybar-pomodoro" and .enabled == true)' \
      <<<"$plugins" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$quickshell_pid" 2>/dev/null \
    || fail_with_log "the shell exited while loading the Pomodoro plugin"
  sleep 0.1
done

jq -e 'any(.[]; .id == "io.github.punkpeye.waybar-pomodoro" and .enabled == true)' \
  <<<"$plugins" >/dev/null \
  || fail_with_log "the Pomodoro plugin was not discovered and enabled"

geometry=""
for _ in {1..100}; do
  geometry=$(shell_ipc shell debugBarGeometry 2>/dev/null || true)
  if jq -e 'any(.[]; .id == "io.github.punkpeye.waybar-pomodoro" and .visible == true and .width > 0 and .height > 0)' \
      <<<"$geometry" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$quickshell_pid" 2>/dev/null \
    || fail_with_log "the shell exited before the Pomodoro widget rendered"
  sleep 0.1
done

jq -e 'any(.[]; .id == "io.github.punkpeye.waybar-pomodoro" and .visible == true and .width > 0 and .height > 0)' \
  <<<"$geometry" >/dev/null \
  || fail_with_log "the Pomodoro bar widget did not render"

[[ $(shell_ipc shell summon io.github.punkpeye.waybar-pomodoro) == "ok" ]] \
  || fail_with_log "the panel could not be summoned"
shell_ipc -q shell hide io.github.punkpeye.waybar-pomodoro >/dev/null \
  || fail_with_log "the panel could not be hidden"
shell_ipc -q shell toggle io.github.punkpeye.waybar-pomodoro >/dev/null \
  || fail_with_log "the panel could not be toggled"
shell_ipc -q shell hide io.github.punkpeye.waybar-pomodoro >/dev/null \
  || fail_with_log "the toggled panel could not be hidden"

for _ in {1..50}; do
  [[ -s $test_state/omarchy/pomodoro.json ]] && break
  sleep 0.1
done

jq -e '
  .version == 1 and .status == "stopped" and .phase == "work" and
  .phaseDurationSec == 1500 and .remainingSec == 1500
' "$test_state/omarchy/pomodoro.json" >/dev/null \
  || fail_with_log "the initial timer state was not persisted"

if rg -i '(^|[^a-z])(waybar-pomodoro|pomodoro).*(error|failed)|QQml.*(error|failed)' "$log" >/dev/null; then
  fail_with_log "the shell logged a Pomodoro QML error"
fi

echo "runtime smoke test passed"
