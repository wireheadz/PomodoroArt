# Pomodoro Art

[English](README.md) | [简体中文](README.zh-CN.md)

A quiet Pomodoro timer that lives in your Mac’s menu bar. Focus, take a proper break, and choose when to begin again.

<p align="center"><img src=".github/images/introduction.png" width="380" alt="Pomodoro Art’s glass welcome panel"></p>

## Install

[**Download for macOS**](https://github.com/wireheadz/PomodoroArt/releases/latest/download/Pomodoro-Art-universal.zip) · [All releases](https://github.com/wireheadz/PomodoroArt/releases)

Requires **macOS 12 or later**. The universal app supports Apple Silicon and Intel Macs. Unzip it, move **Pomodoro Art.app** into **Applications**, and open it.

This community build is locally signed, not Apple-notarized. macOS may block its first launch; if you trust this project, use **System Settings → Privacy & Security → Open Anyway**. See [Apple’s instructions](https://support.apple.com/102445), or build it yourself below.

## A little focus. A proper break.

- A short welcome introduces the app on first launch. Click the **Pomodoro** heading to see it again.
- Click the menu bar icon to expand the glass timer. Click the countdown to start or pause.
- Set focus up to **3 hours** and breaks up to **30 minutes**. Both support a **10-second minimum**.
- Drag a bar for whole minutes. **Shift-drag**, scroll, or use arrow keys for 10-second precision.
- When time is up, the panel opens and a system notification sounds. Choose **Start break** or **Start focus** when you’re ready.
- Click outside to close the panel without interrupting the timer. **Reset** resets the stage; the power icon quits.

The icon is a circle with a dot while working, a circle with a line while resting, and an empty circle while idle. It never shows a countdown in the menu bar.

## Private by default

No account, analytics, server, or third-party integrations. Settings and completed cycles are stored only in `~/Library/Application Support/Pomodoro Art/`. Session dates follow your Mac’s local timezone. Existing local history is preserved when updating.

Allow notifications on first launch. If you previously denied them, **Enable notifications** opens System Settings. Focus mode and sleep can delay notification delivery; the countdown catches up on wake.

## Build from source

Install Xcode, then run:

```sh
git clone https://github.com/wireheadz/PomodoroArt.git
cd PomodoroArt
bash scripts/test.sh
bash scripts/build-app.sh
open dist
```

The build needs only Xcode. `Sources/PomodoroArt/` contains the app and local storage, `Resources/` its bundled interface, and `Tests/` the native storage tests. Build output and local data are ignored by Git.

[Report a problem](https://github.com/wireheadz/PomodoroArt/issues) with your macOS version and steps to reproduce it.
