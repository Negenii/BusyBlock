# Contributing

Issues and pull requests are welcome. Small fixes need no ceremony; for anything
larger, open an issue first so we don't both write the same thing twice.

By sending a pull request you agree that your contribution goes in under the
project's license, and that the maintainer may also license the project
differently. That keeps a single copyright holder, so the app can ship through
channels whose terms conflict with the GPL.

## Build

One app: the menu-bar helper with the Safari extension inside. Needs Xcode (the
extension is an app extension) and XcodeGen (`brew install xcodegen`); the
project file is generated from `project.yml` and is not in the repository.

```sh
scripts/build-xcode.sh        # -> build/xcode/Build/Products/Debug/BusyBlock.app
open build/xcode/Build/Products/Debug/BusyBlock.app
```

Without Xcode you can still build the helper alone, without the Safari
extension, using the Swift command line tools: `scripts/build-app.sh` →
`build/BusyBlock.app`.

Useful flags while working on the UI: `--settings`, `--onboarding`, `--about`.
`BUSYBLOCK_CONFIG=/path/config.json` points the app at a scratch config instead
of `~/Library/Application Support/BusyBlock/config.json`.

## Checks

```sh
swift run busyblock-selftest              # pure logic in BusyBlockCore
node --test tests/extension/*.test.js     # the extension's shared code
```

There is no XCTest target on purpose: the toolchain here is Command Line Tools
only, where XCTest and Swift Testing don't run. Logic that deserves a test lives
in `BusyBlockCore` and is checked by the self-test executable, and the UI is
AppKit rather than SwiftUI for the same reason.

## Testing without a bar

Needs macOS; the helper builds with the Swift command line tools alone.

```sh
swift build
echo '{"barHost": "127.0.0.1:8090", "autoDiscover": false, "onboardingDone": true,
       "blockedDomains": ["example.com"]}' > /tmp/bb.json
node scripts/fake-bar.js 8090 idle &
BUSYBLOCK_CONFIG=/tmp/bb.json .build/debug/busyblock-helper &
curl -X PUT localhost:8090/scenario -d '{"name":"simple"}'   # the fake timer starts
curl localhost:48321/state                                    # "isBlocking": true
```

Load the extension in any browser and open example.com to see the block page.
Scenarios: `idle`, `simple`, `long` (over an hour), `interval-work`,
`interval-rest`, `paused`, `infinite`.

## Layout

| Path | What lives there |
| --- | --- |
| `Sources/BusyBlockCore` | Logic with no UI: bar protocol, timer maths, config, discovery |
| `Sources/BusyBlock` | The app: menu bar, windows, app hiding, local server |
| `Sources/SafariExtension` | The appex shim that hosts the web extension |
| `extension` | The web extension itself, shared by Safari and Chrome |
| `scripts` | Build, release and the fake bar |

## How it works

- The helper keeps a WebSocket to the bar's `/api/status/ws` on plain sockets,
  not URLSession. The bar pushes timer changes and front-panel frames; the
  helper answers pings and reconnects with backoff. Polling `GET
  /api/busy/snapshot` stays on as a safety net, every 10 s with the stream up,
  every 2 s without.
- Stock firmware serves a cached snapshot that refreshes only on user actions,
  so remaining time is `snapshot_timestamp_ms + time_left`, with the bar's clock
  offset calibrated from the stream envelope in milliseconds, or `/api/time` in
  seconds.
- SIMPLE and INFINITE block while not paused. INTERVAL blocks in even intervals,
  which are work; odd ones are rest and stay open unless "Keep blocking during
  rest phases" is on.
- Apps are hidden with `NSRunningApplication.hide()` and re-hidden whenever they
  launch or come to the front. Note that `hide()` returns false even when it
  worked.
- The helper serves `http://127.0.0.1:48321/state` and `/events`, a Server-Sent
  Events stream of state changes and frame messages, 72×16 RGB888 in base64. The
  extension's worker polls `/state` every second and on every page load; the
  block page and the popup subscribe to `/events` and draw the bar's own screen
  on a canvas. Only the visible tab holds a stream, because browsers cap
  connections per host.
- Chrome redirects to the block page with a declarativeNetRequest rule. Safari
  hangs on that when the address bar started the navigation, leaving a blank tab
  with no URL loading forever, so there the rule only blocks the main frame and
  the worker moves the tab to the block page afterwards. Only the tab in front of
  the person is moved: hidden tabs are Safari's top-hit preloads, and moving one
  makes it preload again in a loop.

## Packaging the extension

```sh
scripts/package-chrome.sh        # -> build/chrome/BusyBlock-chrome-<version>.zip
scripts/package-firefox.sh       # -> build/firefox/BusyBlock-firefox-<version>.zip
```

All three browsers share one `extension` folder, and its manifest is the union of
what they need. Both scripts strip the two permissions only Safari uses,
`nativeMessaging` and `webNavigation`, because the others never call either and
both read alarmingly in the install prompt. The Firefox one also swaps the
background service worker for an event page, which is what Firefox MV3 runs, and
adds the add-on id.

To try the Firefox build without signing anything:

```sh
scripts/package-firefox.sh
npx web-ext run --source-dir build/firefox/BusyBlock --start-url https://youtube.com
```

That opens a throwaway profile with the extension already installed. Verified on
Firefox 146: rules redirect to the block page, the popup and the live bar screen
work, and tabs return to their sites when the timer stops.

## Releases

Releases are built, signed with Developer ID, notarized and published by the
maintainer with `scripts/release.sh`, which also writes the Sparkle feed
(`appcast.xml`) the app reads for updates. Forks will need their own Apple
Developer account and their own signing keys.
