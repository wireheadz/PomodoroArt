#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pomodoro-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/Pomodoro Art.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NODE_BINARY="${POMODORO_NODE_BINARY:-$(command -v node)}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web/data" "$PROJECT_DIR/.build/module-cache"
xcrun swiftc -swift-version 5 -O -module-cache-path "$PROJECT_DIR/.build/module-cache" -framework AppKit -framework WebKit -framework UserNotifications "$PROJECT_DIR/macos/main.swift" -o "$APP/Contents/MacOS/PomodoroArt"
if [ -f "$APP/Contents/Resources/node" ]; then chmod u+w "$APP/Contents/Resources/node"; fi
cp -L "$NODE_BINARY" "$APP/Contents/Resources/node"
chmod u+w "$APP/Contents/Resources/node"
python3 "$PROJECT_DIR/scripts/bundle-node.py" "$APP/Contents/Resources/node" "$NODE_BINARY"
cp "$PROJECT_DIR/index.html" "$PROJECT_DIR/server.js" "$APP/Contents/Resources/web/"
python3 - "$APP/Contents/Resources/web/index.html" <<'PY'
import pathlib
import re
import sys
page = pathlib.Path(sys.argv[1])
page.write_text(re.sub(r'<audio id="alarm-audio"[^>]*></audio>', '<audio id="alarm-audio"></audio>', page.read_text()))
PY
for data_file in "$PROJECT_DIR/data/"*.json; do
  if [ -f "$data_file" ]; then cp "$data_file" "$APP/Contents/Resources/web/data/"; fi
done
mkdir -p "$APP/Contents/Resources/web/assets"
cp "$PROJECT_DIR/assets/"*.png "$APP/Contents/Resources/web/assets/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pomodoro Art</string>
<key>CFBundleDisplayName</key><string>Pomodoro Art</string>
<key>CFBundleIdentifier</key><string>local.tomo.pomodoro-art</string>
<key>CFBundleExecutable</key><string>PomodoroArt</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.7.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
xattr -cr "$APP"
if [ -d "$APP/Contents/Resources/lib" ]; then
  for library in "$APP/Contents/Resources/lib/"*.dylib; do
    codesign --force --sign - "$library"
  done
fi
codesign --force --sign - "$APP/Contents/Resources/node"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$PROJECT_DIR/dist"
ditto -c -k --keepParent "$APP" "$PROJECT_DIR/dist/Pomodoro Art.zip"
rm -rf "$PROJECT_DIR/dist/Pomodoro Art.app"
ditto "$APP" "$PROJECT_DIR/dist/Pomodoro Art.app"
printf 'Built %s\n' "$PROJECT_DIR/dist/Pomodoro Art.app"
