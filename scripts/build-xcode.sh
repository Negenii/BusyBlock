#!/bin/zsh
# Builds build/xcode/Build/Products/Debug/BusyBlock.app (helper + Safari extension) with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
[ -d "$DEV" ] || DEV=$(xcode-select -p)
xcodegen generate --quiet
DEVELOPER_DIR="$DEV" xcodebuild -project BusyBlock.xcodeproj -scheme BusyBlock -configuration "${1:-Debug}" \
  -derivedDataPath build/xcode build 2>&1 | grep -E "error:|warning: .*(sign|entitle)|BUILD" || true
echo "app: build/xcode/Build/Products/${1:-Debug}/BusyBlock.app"
