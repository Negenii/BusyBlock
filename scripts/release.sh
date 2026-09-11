#!/bin/zsh
# Builds a signed, notarized BusyBlock.app and packages it as a DMG for a
# GitHub release. Everything lands in build/release/.
#
# One-off setup (see README, "Releasing"):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. A notarytool keychain profile called busyblock.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*"\(.*\)".*/\1/')}"
BUILD="${2:-$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | sed 's/.*"\(.*\)".*/\1/')}"
OUT=build/release          # scratch: wiped on every run
DIST=build/dist            # finished builds: kept, and the appcast is built from it
APP="$OUT/export/BusyBlock.app"
DMG="$DIST/BusyBlock-$VERSION.dmg"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

say() { print -P "%F{blue}==>%f $*"; }
die() { print -P "%F{red}error:%f $*" >&2; exit 1; }

# A dedicated keychain holds the Developer ID key with codesign already allowed
#. It locks on reboot; its password lives
# in the login keychain.
SIGN_KC="$HOME/Library/Keychains/busyblock-signing.keychain-db"
if [[ -f "$SIGN_KC" ]]; then
  kcpw="$(security find-generic-password -a busyblock -s busyblock-signing-keychain -w 2>/dev/null)" \
    && security unlock-keychain -p "$kcpw" "$SIGN_KC"
  unset kcpw
fi

# --- preflight: the two things that can't be scripted for you -----------------
security find-identity -v -p codesigning | grep -q "Developer ID Application" || die \
"no \"Developer ID Application\" certificate in the keychain.
   Xcode → Settings → Accounts → your Apple ID → Manage Certificates → + → Developer ID Application.
   (Needs the paid Apple Developer Program; only the Account Holder can create it.)"

xcrun notarytool history --keychain-profile busyblock >/dev/null 2>&1 || die \
"no notarytool keychain profile called \"busyblock\".
   Create an app-specific password at appleid.apple.com, then run: xcrun notarytool store-credentials busyblock   # see Apple's notarytool documentation"

command -v xcodegen >/dev/null || die "xcodegen is missing: brew install xcodegen"

probe=$(mktemp -d)/probe; cp /bin/echo "$probe"
codesign --force --sign "Developer ID Application" "$probe" >/dev/null 2>&1 || die \
"codesign cannot use the Developer ID key. Grant it access in Keychain Access."

# --- build -------------------------------------------------------------------
say "checks"
swift run busyblock-selftest >/dev/null
node --test tests/extension/*.test.js >/dev/null 2>&1 || die "extension tests failed"

say "version $VERSION ($BUILD)"
rm -rf "$OUT"; mkdir -p "$OUT" "$DIST"
xcodegen generate >/dev/null

# The archive keeps Xcode's automatic development signing; the export step
# re-signs everything with Developer ID. Forcing the identity at archive time
# conflicts with automatic signing.
say "archive"
xcodebuild archive \
  -project BusyBlock.xcodeproj -scheme BusyBlock -configuration Release \
  -archivePath "$OUT/BusyBlock.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates \
  > "$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head; die "archive failed (full log: $OUT/archive.log)"; }

say "export with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$OUT/BusyBlock.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$OUT/export" \
  -allowProvisioningUpdates \
  > "$OUT/export.log" 2>&1 || {
    grep -E "error" "$OUT/export.log" | head
    grep -q errSecInternalComponent "$OUT/export.log" && print -P "%F{yellow}hint:%f codesign cannot use the Developer ID key; grant it access in Keychain Access."
    die "export failed (full log: $OUT/export.log)"; }

say "verify signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
codesign -dv "$APP/Contents/PlugIns/BusyBlock Extension.appex" 2>&1 | grep -E "Authority|Identifier=" | head -3

# --- notarize ----------------------------------------------------------------
say "notarize (a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/BusyBlock.zip"
xcrun notarytool submit "$OUT/BusyBlock.zip" --keychain-profile busyblock --wait | tee "$OUT/notary.log"
grep -q "status: Accepted" "$OUT/notary.log" || die "notarization was not accepted; xcrun notarytool log <id> --keychain-profile busyblock"
xcrun stapler staple "$APP"
spctl -a -vvv -t install "$APP" 2>&1 | tail -2

# --- package -----------------------------------------------------------------
say "dmg"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "BusyBlock" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile busyblock --wait | tee -a "$OUT/notary.log"
xcrun stapler staple "$DMG"

# --- update feed --------------------------------------------------------------
# Sparkle reads appcast.xml from the repository's main branch; the DMG itself is
# served from the GitHub release. The signing key stays out of the login
# keychain on purpose.
SPARKLE_KEY="$HOME/.busyblock-signing/sparkle-ed25519.key"
SPARKLE_BIN="build/tools/bin/generate_appcast"
if [[ -f "$SPARKLE_KEY" && -x "$SPARKLE_BIN" ]]; then
  say "appcast"
  FEED_DIR="$DIST"
  # What the update window shows: this version's CHANGELOG section, nothing else.
  python3 scripts/changelog-section.py "$VERSION" > "$OUT/notes.md"
  [[ -s "$OUT/notes.md" ]] && python3 scripts/md-to-html.py "$OUT/notes.md" > "$FEED_DIR/BusyBlock-$VERSION.html"
  "$SPARKLE_BIN" "$FEED_DIR" \
    --ed-key-file "$SPARKLE_KEY" \
    --download-url-prefix "https://github.com/Negenii/BusyBlock/releases/download/v$VERSION/" \
    --link "https://github.com/Negenii/BusyBlock" \
    --embed-release-notes \
    -o appcast.xml
  grep -q "sparkle:edSignature" appcast.xml || die "appcast has no signature"
  say "appcast.xml written; commit and push it, or nobody is offered the update"
else
  print -P "%F{yellow}warning:%f no Sparkle key or tools, appcast not updated"
fi

say "done: $DMG"
shasum -a 256 "$DMG"
