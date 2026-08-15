#!/bin/bash
# Local install for the waybar-pomodoro Omarchy plugin.
#
# This is a development convenience (like the old ./install.sh) — it links
# the plugin folder into ~/.config/omarchy/plugins, writes it into the bar
# layout, and restarts the shell. For a published plugin the normal path is:
#
#   omarchy plugin add https://github.com/punkpeye/waybar-pomodoro.git --enable
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="io.github.punkpeye.waybar-pomodoro"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "🍅 Installing waybar-pomodoro into Omarchy..."

if [[ -e "$PLUGIN_DIR" || -L "$PLUGIN_DIR" ]]; then
  echo "📂 Plugin folder already exists: $PLUGIN_DIR"
  echo "   Updating it in place (git pull or overwrite as you prefer)."
else
  mkdir -p "$HOME/.config/omarchy/plugins"
  ln -s "$SCRIPT_DIR" "$PLUGIN_DIR"
  echo "🔗 Linked $SCRIPT_DIR -> $PLUGIN_DIR"
fi

echo "✅ Plugin linked"

# Validate the manifest + QML before touching the live config.
if command -v qmllint >/dev/null 2>&1 && [[ -d ${OMARCHY_PATH:-}/shell ]]; then
  qmllint -I "$OMARCHY_PATH/shell" \
    "$SCRIPT_DIR/Service.qml" \
    "$SCRIPT_DIR/CircularProgress.qml" \
    "$SCRIPT_DIR/BarWidget.qml" \
    "$SCRIPT_DIR/Panel.qml" \
    "$SCRIPT_DIR/PomodoroActionRow.qml"
  echo "✅ qmllint passed"
fi

echo "🔁 Rescanning plugins and placing the widget on the right side of the bar..."
omarchy-shell shell rescanPlugins 2>/dev/null || true
omarchy bar put "$PLUGIN_ID" --section right 2>/dev/null || true

echo "🔁 Restarting the shell so the plugin loads..."
omarchy-restart-shell 2>/dev/null || omarchy-shell shell restart 2>/dev/null || true

echo ""
echo "✅ Done. The tomato should now be in the right side of your bar."
echo "   Click it to open the timer panel."
