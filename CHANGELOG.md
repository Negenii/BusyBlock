# Changelog

Notable changes, newest first. Versions follow [semantic versioning](https://semver.org).

## [Unreleased]

## [1.0.1] — 2026-09-17

- BusyBlock now updates itself. It checks once a day, shows what changed and
  installs the new version in one click. Switch it off in Settings if you would
  rather not.
- The welcome tour opens the Chrome Web Store and addons.mozilla.org pages of
  the extension directly, instead of a store search.

## [1.0.0] — 2026-09-17

First public release.

- Hides the apps on your list while the BUSY Bar timer runs, and lets them back
  when it stops. Hidden, never quit.
- Blocks the websites on your list in Safari, Firefox and Chrome-family
  browsers. The block page mirrors the bar's own screen, live.
- Finds the bar by itself over USB, `busybar.local` and Bonjour, and keeps
  looking if it goes away.
- Follows the bar's phases: work blocks, rest opens up unless you asked
  otherwise, pause opens everything.
- Shows the countdown the way the bar does, `MM:SS` or `H:MM:SS`, optionally
  in the menu bar.
- A welcome tour for the first run, a settings window where apps arrive by drag
  and drop, and an About panel with the credits.
- Signed with Developer ID and notarized by Apple. The Safari extension ships
  inside the app.
