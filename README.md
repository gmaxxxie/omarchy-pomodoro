# 🍅 waybar-pomodoro for Omarchy

A classic Pomodoro timer for the [Omarchy](https://omarchy.org/) bar — a native
[Quattro](https://omarchyplugins.com/develop.html) plugin, ported from the
original waybar custom-module app.

![demo](https://img.shields.io/badge/waybar-pomodoro-red?style=flat-square)

![screenshot-2026-01-27_20-06-33](screenshot-2026-01-27_20-06-33.png)

## Features

- 🍅 **25 / 5 / 15** Pomodoro technique — work, short break, long break after
  every 4 completed pomodoros
- ⏸️ Pause / resume
- ⏭️ Skip phase (and right-click = stop, middle-click = skip, from the bar)
- 🔔 Phase-change notifications with sound
- 🎨 Phase-colored ring in the bar (work = red, short break = green, long
  break = blue, paused = amber) — tinted through the theme so it follows your
  accent instead of hardcoded hex
- 💾 State persisted across shell restarts
- 😴 Sleep-safe: after a suspend/resume a running work phase is reset, a
  running break keeps its remaining time (same behaviour as the old systemd
  sleep/lid hooks)

## Install

From a checkout of this repository:

```bash
./install.sh
```

Or, once published, like any Omarchy plugin:

```sh
omarchy plugin add https://github.com/punkpeye/waybar-pomodoro.git --enable
```

## Use

Click the tomato in the bar to open the timer panel.

| Action | Bar mouse | Panel button | Keyboard |
|--------|-----------|--------------|----------|
| Start / Resume / Stop | Left click (toggle) | ▶ / ■ | Enter / Space |
| Pause / Resume | Left click (toggle) | ⏸ | Space / P |
| Skip phase | Middle click | ⏭ | S |
| Stop | Right click | ■ | Enter |

## Configure

Change the phase lengths and long-break frequency through Omarchy (the
widget's own config UI exposes the same fields):

```bash
omarchy bar plugin set io.github.punkpeye.waybar-pomodoro workMinutes 25 --json
omarchy bar plugin set io.github.punkpeye.waybar-pomodoro shortBreakMinutes 5 --json
omarchy bar plugin set io.github.punkpeye.waybar-pomodoro longBreakMinutes 15 --json
omarchy bar plugin set io.github.punkpeye.waybar-pomodoro pomodorosUntilLong 4 --json
```

New values apply from the next phase onward.

## Keyboard controls

With the panel open: arrows / `h` `j` `k` `l` move between actions, Enter or
Space activates, `s` skips, Escape closes, Tab moves to the next bar panel.

You can also control it from a terminal or keybinding:

```bash
omarchy-shell shell toggle io.github.punkpeye.waybar-pomodoro
```

## Remove

```bash
omarchy plugin remove io.github.punkpeye.waybar-pomodoro
```

## License

MIT — same license as the original [waybar-pomodoro](https://github.com/punkpeye/waybar-pomodoro).
