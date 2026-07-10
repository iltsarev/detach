#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Detach.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/DetachApp" "$APP/Contents/MacOS/Detach"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.tsarev.detach</string>
  <key>CFBundleName</key>
  <string>Detach</string>
  <key>CFBundleDisplayName</key>
  <string>Detach</string>
  <key>CFBundleExecutable</key>
  <string>Detach</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Detach открывает сессии агентов в Terminal.app.</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
printf 'Built %s\nRun: open %s\n' "$APP" "$APP"
