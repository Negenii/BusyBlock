# Privacy policy

BusyBlock, the macOS app and its browser extension. Last updated 17 September 2026.

## The short version

BusyBlock has no account, no analytics and no server of ours. Nothing about you
or your browsing is collected, sold or shared. Your block list, your settings and
everything the extension sees stay on your Mac.

## What the app holds, and where

Your settings, the list of apps to hide and the list of websites to block live in
a file on your own Mac:

```
~/Library/Application Support/BusyBlock/config.json
```

A log file sits next to it and records what the app is doing: how many
blocking rules the browser extension has, and, in Safari, the addresses of
blocked pages you tried to open. It never leaves your Mac. Both files are yours;
deleting the app's folder removes everything it keeps.

## What the extension sees, and why

The extension reads the address of the page you are opening to decide whether it
is on your block list. That happens inside your browser, on your machine. The
address never leaves your Mac. It isn't stored either, except that in Safari a
blocked page's address is noted in the local log described above.

It asks for access to every website because it cannot know in advance which site
you are about to open. It uses that access for one thing only: comparing an
address against the list you typed yourself.

The extension talks to the BusyBlock app over `http://127.0.0.1`, which never
leaves your computer, to ask whether a timer is running and how much of it is
left.

## What leaves your Mac

Three things:

1. **Your BUSY Bar.** The app talks to your bar over USB or over your local
   network, to read the timer and the screen. Your bar is a device in your room,
   not a service.
2. **Update checks.** Once a day the app asks GitHub whether a newer version of
   BusyBlock exists, by fetching one small file. The request carries what any
   web request carries: your IP address and the version you run. No identifier
   of you, no usage data. You can switch it off in Settings.
3. **Website icons.** To show a site's icon next to it in the settings window and
   on the block page, the app asks that website for its icon. For sites that
   serve none, it falls back to Google's and DuckDuckGo's public icon services.
   Those requests carry a domain name from the list you typed. They carry nothing
   else: no identifier, no page address, no information about you. Neither service
   is told who is asking or why.

That is the complete list. There is nowhere else for data to go.

## Children

BusyBlock is not directed at children and collects nothing from anyone.

## Changes

Changes to this policy are recorded in this file's history in the public
repository, so you can see exactly what changed and when.

## Contact

Questions go to the issue tracker:
https://github.com/negenii/BusyBlock/issues
