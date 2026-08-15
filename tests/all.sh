#!/bin/bash
# Full local validation: model unit tests, plugin manifest validation, QML
# lint against the installed shell imports, and a runtime smoke test that
# boots a throwaway Quickshell with a minimal config.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

node "$ROOT/tests/timer-model.test.js"

if [[ -n ${OMARCHY_PATH:-} && -x $OMARCHY_PATH/bin/omarchy ]]; then
  PATH="$OMARCHY_PATH/bin:$PATH" \
    "$OMARCHY_PATH/bin/omarchy" plugin validate "$ROOT"
else
  echo "skipping plugin validation (set OMARCHY_PATH to an Omarchy checkout)"
fi

if command -v qmllint >/dev/null 2>&1 && [[ -n ${OMARCHY_PATH:-} && -d $OMARCHY_PATH/shell ]]; then
  qmllint -I "$OMARCHY_PATH/shell" \
    "$ROOT/Service.qml" \
    "$ROOT/CircularProgress.qml" \
    "$ROOT/TomatoIcon.qml" \
    "$ROOT/BarWidget.qml" \
    "$ROOT/Panel.qml" \
    "$ROOT/PomodoroActionRow.qml"
else
  echo "skipping qmllint (set OMARCHY_PATH to an Omarchy checkout)"
fi

"$ROOT/tests/runtime-smoke.sh"

echo "all tests passed"
