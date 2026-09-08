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
# The stamp covers the spec and the list of source/resource files: XcodeGen
# enumerates files at generate time, so a new .swift file needs a regenerate.
SIG=$( (cat project.yml; find Sources extension Resources -type f | sort) | shasum | cut -c1-40)
if [ ! -f BusyBlock.xcodeproj/project.pbxproj ] || [ "$SIG" != "$(cat "$STAMP" 2>/dev/null)" ]; then
  xcodegen generate --quiet
  echo "$SIG" > "$STAMP"
fi
DEVELOPER_DIR="$DEV" xcodebuild -project BusyBlock.xcodeproj -scheme BusyBlock -configuration "${1:-Debug}" \
  -derivedDataPath build/xcode build 2>&1 | grep -E "error:|warning: .*(sign|entitle)|BUILD" || true
grep -q "BUILD SUCCEEDED" <(DEVELOPER_DIR="$DEV" xcodebuild -project BusyBlock.xcodeproj -scheme BusyBlock -configuration "${1:-Debug}" -derivedDataPath build/xcode build 2>&1 | tail -3) || { echo "BUILD FAILED"; exit 1; }
echo "app: build/xcode/Build/Products/${1:-Debug}/BusyBlock.app"
