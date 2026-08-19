# Birdwatch 0.1.2

A small release with one change worth being upfront about: Birdwatch now counts how it gets used.

## Anonymous usage counts — and the switch to turn them off

Birdwatch now sends a handful of usage events to our own analytics endpoint so we can learn which screens and actions actually earn their place. It uses [swift-stats](https://github.com/awizemann/swift-stats), an open-source, privacy-first library we also maintain.

**What is sent:** which screen was opened, which action was taken (for example "monitoring paused", "daemon restarted" and whether it worked), coarse counts such as "2–5 issues", the Birdwatch and macOS versions, device model and locale, and a random install identifier that is hashed before it leaves your Mac and cannot be tied to you, your Apple ID or your hardware.

**What is never sent:** file or folder names, paths, app names, device names, storage sizes, log lines, search text, your iCloud account, or anything you type. No advertising identifier, no fingerprinting, no cross-app tracking. Raw events are kept for 90 days; only daily totals are kept longer.

**Turning it off:** Diagnostics → *Share anonymous usage*. The switch persists, and while it is off nothing is collected or sent.

The [privacy policy](https://awizemann.github.io/birdwatch/privacy.html), README and first-run copy have all been updated to say exactly this.

## Under the hood

- The app now ships a privacy manifest declaring the two data categories above (product interaction and diagnostics — not linked to identity, not used for tracking).
- The release pipeline verifies the analytics key and the privacy manifest made it into the built app.

Source and issue tracker: https://github.com/awizemann/birdwatch
