# Pomodoro Art

[English](README.md) | [简体中文](README.zh-CN.md)

A quiet Pomodoro timer for the macOS menu bar, with a tinted glass panel, focus and break sessions, and system notifications. A local web version is included.

Requires **macOS 12 or later**. Settings and session history are saved locally.

## Install

Install Xcode, Node.js, and Python 3, then run:

```sh
git clone https://github.com/wireheadz/PomodoroArt.git
cd PomodoroArt
npm run build:macos
open dist
```

Move **Pomodoro Art.app** into **Applications** and open it. The build includes Node and its non-system libraries, so Node is only needed when building. It builds for your Mac's architecture and is locally signed, not notarized.

The ZIP in `dist` contains the signed bundle before Desktop or iCloud can attach file-provider metadata. If necessary, unzip it outside an iCloud-synced folder before moving it into Applications.

## Setup and use

1. Allow notifications when macOS asks on first launch. If permission was denied, **Enable notifications** opens System Settings.
2. Click the menu bar icon to open the timer. Adjust the focus and break sliders, then click the countdown to start or pause.
3. When a session finishes, the panel automatically expands from the icon with **Start break** or **Start focus**. The next stage waits for your confirmation.

The icon stays simple: a circle with a dot means working, a circle with a line means resting, and an empty circle means idle. Clicking outside closes the panel while the timer continues. Reopening a finished session still shows its completion message.

Focus and break durations start at **10 seconds**, in 10-second steps, for testing. Drag a slider fully left for `00:10`. Maximum durations are 60 minutes for focus and 30 minutes for break. Completion uses the system notification sound; there is no background ambience or separate looping alarm in the Mac app.

Use **Reset** to reset the current stage, or the power icon to quit.

## Web version

```sh
npm start
```

Open http://127.0.0.1:4173. The browser version uses its own completion alarm. Set `POMODORO_PORT` to choose another port.

## Local data and integrations

The Mac app stores settings and history in `~/Library/Application Support/Pomodoro Art/`. The web version uses `data/`. Existing local JSON files seed a Mac build's first launch; a fresh clone uses the default settings and an empty history. Personal data, build output, and caches are ignored by Git.

The existing Obsidian status/activity-log integration and Mac Live Context capture-control integration are retained. `POMODORO_OBSIDIAN_VAULT` overrides the vault path; `POMODORO_CAPTURE_CONTROL_FILE` overrides the shared capture-control file. The default vault is `Personal knowledge library` under Obsidian's iCloud Documents folder. Log dates currently use `Asia/Shanghai`.

## Development

```sh
npm test
npm run build:macos
```

`macos/` contains the native menu bar shell, `index.html` the timer interface, `server.js` the loopback server, and `scripts/` the packaging tools. `POMODORO_NODE_BINARY` selects another Node runtime for a build. Quit the running app before rebuilding it.

## If something goes wrong

- **No notification:** enable Pomodoro Art and notification sounds in System Settings → Notifications. macOS Focus settings and sleep can defer alerts; elapsed time is reconciled on wake.
- **Older interface still appears:** quit the installed copy before replacing it with the latest build.
- **An integration fails:** check its configured path. Mac server errors are saved to `~/Library/Application Support/Pomodoro Art/server.log`.

[Report a problem](https://github.com/wireheadz/PomodoroArt/issues) with your macOS version and the steps to reproduce it.

## Uninstall

Quit Pomodoro Art and move the app to the Trash. Local history remains in its Application Support folder.
