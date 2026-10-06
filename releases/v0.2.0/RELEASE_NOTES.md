# Birdwatch 0.2.0

A big honesty-and-reliability release, built and tested against macOS 27.

## Important: Full Disk Access is now required

On macOS 27, an app that reads iCloud Drive without Full Disk Access makes macOS ask "allow access to iCloud Drive?" and stalls until you answer. Rather than surprise you with that, Birdwatch now asks for Full Disk Access during setup and touches nothing in iCloud Drive until it is granted. If you turn it off later, Birdwatch stops reading iCloud Drive at once and tells you why.

## Works properly on macOS 27

- **CloudKit apps are back.** macOS 27 stopped logging the line Birdwatch used to tell which app owns a CloudKit container. Birdwatch now works it out from the apps' own activity in the system log, so Photos, Safari and your third-party apps appear again.
- **The Full Disk Access check works** on macOS 27, where Safari moved the file it used to test.
- **Much lighter on your Mac.** Birdwatch no longer asks iCloud's daemon for a slow status report on every refresh (it was timing out and holding up everything behind it). Reading iCloud's sync state is about 80× faster, and the live log view uses about 1% CPU instead of 10–27%.
- **All your iCloud apps are listed**, including the many whose iCloud folders macOS marks hidden.

## Says only what it knows

- No made-up percentages: macOS reports whether a file is uploading or downloading, not how far along it is, so Birdwatch shows "Syncing…" instead of "0%".
- Files iCloud has been stuck on now show on the right app — "N items not syncing" when iCloud has retried them or they have waited more than a day, "waiting to sync" otherwise — instead of "Up to date".
- Estimates are marked "≈": bandwidth, and your iCloud plan size until you confirm it. If your plan setting disagrees with what iCloud reports, Birdwatch says so instead of showing "0 GB used". Stacked plans (e.g. 2 TB + 6 TB) are supported.
- Numbers Birdwatch can't read say so ("Not reported", "Measuring…", "at least …") instead of showing zero.

## Safer conflict resolution

- "Keep both" can no longer delete a version it failed to save.
- "Keep this version" only removes versions you were actually shown; if a new one arrived meanwhile, Birdwatch stops and shows it to you.
- A failed resolution now says so and keeps the conflict open.
- Conflicts are checked in iCloud Drive itself; Desktop & Documents and apps' own iCloud folders aren't scanned yet, and Birdwatch says so.

## Also new

- **Settings window** (⌘,) with the *Share anonymous usage* switch (still also in Diagnostics) and your plan size.
- Looks at home on macOS 26 and later (system glass sidebar, toolbar and menu-bar window); one View menu; minute-accurate relative times.
- Dismissed issues stay dismissed, and notifications no longer repeat for problems that were already there.
- Pause Monitoring now really stops the live log and file watching.
- Updated Sparkle (2.10) with its latest installer security fixes.

## Anonymous usage counts

Birdwatch now also counts which issue buttons are used, how far people get through setup, and whether a daemon restart was confirmed. Every event and value is listed in the [privacy policy](https://awizemann.github.io/birdwatch/privacy.html). Nothing about your files, apps or account is ever sent, and the switch is in Settings and in Diagnostics.

Source and issue tracker: https://github.com/awizemann/birdwatch
