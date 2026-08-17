# Birdwatch 0.1.0 — first release

See what iCloud is actually doing. Birdwatch is a native macOS utility that makes iCloud sync visible, built on one rule: it never invents a number.

## What's in it

- **Applications** — every real iCloud app container on your Mac (with its on-this-Mac footprint), CloudKit apps *observed* actually syncing, and File Provider domains. An app appears only when it exists; nothing is assumed.
- **Live transfers & activity** — files in flight as they happen, with real names and paths. This channel is boolean-only, so in-flight items show an indeterminate bar rather than a fabricated percentage.
- **Issues** — file conflicts with side-by-side resolution (keep either version or both, under file coordination), quota warnings, stuck retry items, and iCloud's own health-report and account errors.
- **Diagnostics** — daemon health, sync-engine budgets and counts, the retry queue with real paths recovered from bird's redacted diagnostics, and maintenance actions that actually work.
- **Storage** — account usage that matches System Settings, plus a file-type breakdown of your local iCloud Drive footprint. The per-service split Apple keeps private is shown as one honest remainder.
- **Bandwidth** (estimated, and labeled so), an anonymous **Devices** view, a **menu-bar popover**, keyboard shortcuts (⌘1–9, ⌘R, ⇧⌘P), and full VoiceOver / keyboard support.

## Requirements

macOS 15 or later. Birdwatch runs outside the App Sandbox and asks for Full Disk Access — that's what lets it read the sync daemons' state. Nothing leaves your Mac.

## Known limitations (by design — macOS doesn't expose these)

- No per-file upload/download percentage for iCloud Drive; no per-service storage split; device names are redacted by the system.
- "Pause" pauses Birdwatch's monitoring — macOS offers no supported way to pause iCloud sync itself.
- `brctl diagnose` needs administrator rights, so Birdwatch hands you the command for Terminal instead of running it.

Auto-updates arrive via Sparkle. Source and issue tracker: https://github.com/awizemann/birdwatch
