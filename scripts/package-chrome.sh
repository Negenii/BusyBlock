#!/bin/zsh
# Packs the web extension for the Chrome Web Store.
#
# Safari and Chrome share one `extension` folder, and its manifest is the union
# of what both need. Two permissions are Safari-only: `nativeMessaging` (the
# popup asks the containing app to launch) and `webNavigation` (Safari's rules
# only block, so the worker watches navigation to move the tab). Chrome never
# uses either, and both read alarmingly in the install prompt, so they come out
# of the manifest that goes to the store.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(python3 -c 'import json;print(json.load(open("extension/manifest.json"))["version"])')}"
OUT="build/chrome"
STAGE="$OUT/BusyBlock"
ZIP="$OUT/BusyBlock-chrome-$VERSION.zip"

rm -rf "$OUT"; mkdir -p "$STAGE"
cp -R extension/ "$STAGE/"
rm -rf "$STAGE"/**/.DS_Store(N) "$STAGE"/.DS_Store(N)

python3 - "$STAGE/manifest.json" "$VERSION" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
m = json.load(open(path))
m["version"] = version
safari_only = {"nativeMessaging", "webNavigation"}
m["permissions"] = [p for p in m["permissions"] if p not in safari_only]
# Safari loads shared.js through background.scripts; Chrome uses the worker.
m["background"] = {"service_worker": m["background"]["service_worker"]}
json.dump(m, open(path, "w"), indent=2)
print("permissions:", ", ".join(m["permissions"]))
PY

node --test tests/extension/*.test.js >/dev/null 2>&1 || { echo "extension tests failed" >&2; exit 1; }
(cd "$STAGE" && zip -qr "../$(basename "$ZIP")" . -x '.*')
echo "-> $ZIP"
unzip -l "$ZIP" | tail -3
