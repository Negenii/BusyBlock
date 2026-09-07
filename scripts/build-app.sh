#!/bin/zsh
# Builds build/BusyBlock.app from the SwiftPM package. No Xcode needed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product BusyBlock
APP=build/BusyBlock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BusyBlock "$APP/Contents/MacOS/BusyBlock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R extension "$APP/Contents/Resources/extension"
rm -rf "$APP/Contents/Resources/extension/test" "$APP/Contents/Resources/extension/node_modules"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
