#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pomodoro-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/Pomodoro Art.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PROJECT_DIR/.build/module-cache"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx12.0" -module-cache-path "$PROJECT_DIR/.build/module-cache" -framework AppKit -framework WebKit -framework UserNotifications "$PROJECT_DIR/Sources/PomodoroArt/AppStorage.swift" "$PROJECT_DIR/Sources/PomodoroArt/main.swift" -o "$APP/Contents/MacOS/PomodoroArt"
cp "$PROJECT_DIR/Resources/"* "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pomodoro Art</string>
<key>CFBundleDisplayName</key><string>Pomodoro Art</string>
<key>CFBundleIdentifier</key><string>local.tomo.pomodoro-art</string>
<key>CFBundleExecutable</key><string>PomodoroArt</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$PROJECT_DIR/dist"
ditto -c -k --keepParent "$APP" "$PROJECT_DIR/dist/Pomodoro Art.zip"
rm -rf "$PROJECT_DIR/dist/Pomodoro Art.app"
ditto "$APP" "$PROJECT_DIR/dist/Pomodoro Art.app"
printf 'Built %s\n' "$PROJECT_DIR/dist/Pomodoro Art.app"
