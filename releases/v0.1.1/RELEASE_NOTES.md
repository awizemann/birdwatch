# Birdwatch 0.1.1

A polish release — and the first delivered through Birdwatch's own auto-updater.

## What's new

- **An app icon.** A bird on Birdwatch blue, in the Dock, Cmd-Tab, Finder and the update dialog. The menu-bar icon now uses the same bird mark (as a template, so it matches light and dark menu bars) with a small badge when there are issues or monitoring is paused.
- **More room for content.** Every section uses noticeably more of the window — margins are tighter and the content column is wider.
- **Devices sorted by activity.** Most recently active first. And an honest answer to "can I remove a device here?": no — macOS exposes no way for a third-party app to manage the account's device list, so the view now points you to System Settings › Apple Account, where that lives.
- **Search moved left.** The search field sits at the leading edge of the toolbar with a proper magnifier and inset; notifications and the pause/resume control are on the trailing edge, and pause is now an icon that shows what clicking will do (play when paused).

## Under the hood

- The release pipeline now refuses to ship an iconless build.
- Sparkle auto-update is fully wired: this update is signed and served from the project's own feed.

Source and issue tracker: https://github.com/awizemann/birdwatch
