# Changelog

Notable changes, newest first. Versions follow [semantic versioning](https://semver.org).

## [Unreleased]

- The countdown is written the way the bar writes it: `MM:SS` under an hour,
  `H:MM:SS` over it, where it used to read `90:00`. Menu-bar digits are
  monospaced, so the width no longer shifts every second.

## [0.1.0]

First public release.

- Hides the apps on your list while the BUSY Bar timer runs, and lets them back
  when it stops. Hidden, never quit.
- Blocks the websites on your list in Safari and in Chrome-family browsers. The
  block page mirrors the bar's own screen, live.
- Finds the bar by itself over USB, `busybar.local` and Bonjour, and keeps
  looking if it goes away.
- Follows the bar's phases: work blocks, rest opens up unless you asked
  otherwise, pause opens everything.
- A welcome tour for the first run, and a settings window where apps arrive by
  drag and drop.
