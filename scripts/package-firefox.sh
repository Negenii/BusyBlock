#!/bin/zsh
# Packs the web extension for Firefox.
#
# Differences from the Chrome package: Firefox MV3 runs the background as an
# event page (`background.scripts`), not a service worker, and add-ons need a
# stable id. The Safari-only permissions come out here too.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(python3 -c 'import json;print(json.load(open("extension/manifest.json"))["version"])')}"
OUT="build/firefox"
STAGE="$OUT/BusyBlock"
ZIP="$OUT/BusyBlock-firefox-$VERSION.zip"

rm -rf "$OUT"; mkdir -p "$STAGE"
cp -R extension/ "$STAGE/"
rm -f "$STAGE"/.DS_Store

python3 - "$STAGE/manifest.json" "$VERSION" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
m = json.load(open(path))
m["version"] = version
# Required for new add-ons since November 2025. The extension only talks to the
# BusyBlock app over 127.0.0.1 and sends nothing off the machine.
m["browser_specific_settings"] = {"gecko": {
    "id": "busyblock@negenii.me",
    "strict_min_version": "140.0",
    "data_collection_permissions": {"required": ["none"]},
}}
safari_only = {"nativeMessaging", "webNavigation"}
m["permissions"] = [p for p in m["permissions"] if p not in safari_only]
m["background"] = {"scripts": m["background"]["scripts"]}
json.dump(m, open(path, "w"), indent=2)
print("permissions:", ", ".join(m["permissions"]))
PY

(cd "$STAGE" && zip -qr "../$(basename "$ZIP")" . -x '.*')
echo "-> $ZIP"
