# Pomodoro Art

[English](README.md) | [简体中文](README.zh-CN.md)

A macOS menu bar Pomodoro timer with a tinted glass panel and system notifications.

Requires **macOS 12 or later**. Settings and session history stay on your Mac.

## Install

Install Xcode, then run:

```sh
git clone https://github.com/wireheadz/PomodoroArt.git
cd PomodoroArt
bash scripts/build-app.sh
open dist
```

Move **Pomodoro Art.app** into **Applications** and open it. The build is locally signed, not notarized, and targets your Mac's architecture.

## Use

- Allow notifications on first launch.
- Click the menu bar icon to open the timer. Adjust the sliders, then click the countdown to start or pause.
- When a session ends, the panel expands from the icon. Click **Start break** or **Start focus** to continue.
- Click outside to close the panel while the timer continues. **Reset** resets the stage; the power icon quits the app.

The icon is a circle with a dot while working, a circle with a line while resting, and an empty circle while idle. Completion uses the built-in notification sound.

Both durations have a **10-second minimum** for testing. Focus goes up to 60 minutes; breaks go up to 30 minutes.

## Data and permissions

Settings and history are saved in `~/Library/Application Support/Pomodoro Art/`. Existing records are preserved when updating. Personal data and build artifacts are excluded from Git.

If notifications were denied, **Enable notifications** opens System Settings. Focus mode and sleep can delay notifications.

The existing Obsidian and Mac Live Context file integrations are retained. `POMODORO_OBSIDIAN_VAULT` and `POMODORO_CAPTURE_CONTROL_FILE` override their paths. Log dates use `Asia/Shanghai`.

## Development

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

`Sources/PomodoroArt/` contains the macOS app and local storage; `Resources/` contains its bundled interface. Quit the app before replacing a build.
