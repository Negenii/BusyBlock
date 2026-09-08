#!/bin/zsh
# Builds build/BusyBlock.app from the SwiftPM package. No Xcode needed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product busyblock-helper
APP=build/BusyBlock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/busyblock-helper "$APP/Contents/MacOS/BusyBlock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R extension "$APP/Contents/Resources/extension"
rm -rf "$APP/Contents/Resources/extension/node_modules"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
