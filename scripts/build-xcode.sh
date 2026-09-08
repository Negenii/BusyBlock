#!/bin/zsh
# Builds build/xcode/Build/Products/Debug/BusyBlock.app (helper + Safari extension) with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
[ -d "$DEV" ] || DEV=$(xcode-select -p)
# Regenerate the project only when the spec changed: a regenerated project makes
# Xcode rebuild and re-sign the Safari extension, and Safari then reinstalls it
# (new UUID, stale redirect rules until its background wakes up).
STAMP=build/xcode/project.yml.sha
mkdir -p build/xcode
if [ ! -f BusyBlock.xcodeproj/project.pbxproj ] || [ "$(shasum project.yml | cut -c1-40)" != "$(cat "$STAMP" 2>/dev/null)" ]; then
  xcodegen generate --quiet
  shasum project.yml | cut -c1-40 > "$STAMP"
fi
DEVELOPER_DIR="$DEV" xcodebuild -project BusyBlock.xcodeproj -scheme BusyBlock -configuration "${1:-Debug}" \
  -derivedDataPath build/xcode build 2>&1 | grep -E "error:|warning: .*(sign|entitle)|BUILD" || true
echo "app: build/xcode/Build/Products/${1:-Debug}/BusyBlock.app"
