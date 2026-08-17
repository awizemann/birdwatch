# Swift Audit — Birdwatch (macOS 15, 2026-08-14)

## Executive summary

Birdwatch's architecture is healthy: the Sendable-DTO boundary, single-owner store, SE-0461 actor layering, and process hygiene all survived adversarial review, and the Phase 0/1 remediations held. Three themes need work before ship. **(1) Data safety:** conflict resolution mutates actively-synced iCloud files without `NSFileCoordinator`, and the notification engine permanently suppresses recurring issues — the app's core alerting goes silent on exactly the problems it exists to surface. **(2) Long-run energy:** five process spawns every 15s continue while the window is occluded, and the NSMetadataQuery rebuilds forever after the window closes; for an app that lives for weeks this is the dominant cost. **(3) Keyboard/VoiceOver completeness:** search results are effectively mouse-only past the first item, maintenance outcomes are announced to no one, and the app ships zero Commands/keyboard shortcuts on a keyboard-first platform. Fix data safety first, then energy, then the interaction sweep.

## Scorecard

| Domain | Specialist | P1/P2/P3 | Verdict |
|---|---|---|---|
| SwiftUI | swiftui-specialist | 0/5/4 | needs attention (keyboard/commands, dead buttons) |
| Accessibility | mobile-a11y-specialist | 2/3/5 | needs attention (search, action feedback) |
| Concurrency | concurrency-specialist | 0/2/5 | solid core; file-coordination gap |
| Performance | performance-specialist | 0/2(High)/4 | needs attention (occlusion, query lifetime) |
| Security | swift-security-specialist | 0/1/4 | solid (log privacy leak to fix) |
| Testing | testing-specialist | 2/3/2 | needs attention (untested destructive path) |

## P1 — Fix now

1. **Recurring issues never re-notify** — `SyncStore.deriveNotifications` (SyncStore.swift:252-273) dedupes against all past notification ids; an issue that resolves and later recurs (stable ids are the *design* for conflicts/quota) is silently dropped. Fix: on arrival, replace any prior same-id notification with a fresh unread one. Effort S.
2. **Conflict resolution lacks file coordination** — ConflictSource.swift:150-195: `replaceItem`/`removeOtherVersions`/copy/`isResolved` run uncoordinated on ubiquitous files while bird may be mid-write; worst case loses the version the user chose to keep. Fix: wrap mutations in `NSFileCoordinator` coordinated writes (detection in coordinated reads). Effort S-M.
3. **Search results unreachable by keyboard/VoiceOver beyond item 1** — ToolbarContent.swift:63-114: no arrow-key navigation, no results announcement, query wiped on popover dismissal. Effort M.
4. **Maintenance action outcomes silent for VoiceOver** — DiagnosticsView.swift:91-99: success/failure line never announced and auto-clears in 5s. Effort S.
5. **`ConflictSource.resolve` is fully untested destructive file ops** — the only path that can lose user data has zero coverage; `conflictedCopyURL` numbering untested. Effort M.

## P2 — Fix soon

- **Occlusion/energy:** gate the 15s loop on window occlusion (RootView.swift:23-32); stop the NSMetadataQuery when only the menu-bar extra remains (SystemSyncSource.swift:37-48); serve cached snapshot to the popover and skip the conflict scan on popover-initiated refreshes; skip (not queue) periodic refresh when one is in flight; merge the two `ps` spawns per cycle.
- **Log privacy:** `error.localizedDescription` logged `.public` embeds user file names (6 sites: ConflictSource 41/65/177, DriveFolderSource 33/45, SystemSyncSource 230); DiagnosticsView logs tool stdout/stderr `.public` (81-111). Make them `.private`.
- **No Commands / keyboard shortcuts anywhere**; confirm sheet has no Return/default-action or initial focus; notifications popover has no ScrollView (50 rows can exceed the screen); log/diagnostic text unselectable.
- **Dead buttons:** Reveal in Finder, Force sync, Reset retry counters, Re-run setup…, Upgrade to 2 TB, onboarding optional toggles — wire or remove per the project's own dead-button rule.
- **Mute doesn't gate banners** (comment claims it does; `IssueItem` has no appID to gate on) — wire or fix the doc; inject the notifier so tests stop posting real system notifications.
- **Untested pure assembly:** `buildApps`/`deriveIssues`/`engineInfo`; MaintenanceActions error mapping + private `archivePath`; BandwidthSource empty-readings re-baseline and duplicate-pid merge semantics.
- Refresh coalescing defends only one generation (multi-window / future forced callers); conflict-scan results can resurrect a just-resolved issue for ≤5 min.

## P3 — Modernize when touching

Log console batching (per-line state writes under log storms); SIGTERM-only, no SIGKILL escalation; DaemonStatsSource bypasses ProcessRunner; `MaintenanceActions` recreated per view init and its tasks never cancelled; SystemNotifier re-requests authorization per post and unorders batches; ActivityLog stamps downloads `.upload` kind; PermissionsProbe comment says 5s, code sleeps 1.5s; log console header claims `brctl log -w` but streams `log stream` (honesty); `com.birdwatch.app` logger subsystem outlier; MenuBarExtra label unnamed/stateless; sparkline invisible to AT; muted rows opacity-only; no PrivacyInfo.xcprivacy; help tooltips/context menus absent; storage bar color-only mapping; keep-both TOCTOU litter on races; pause-during-first-load leaves a permanent spinner.

## Quick wins

Announcement on maintenance status (S) · notification-recurrence fix (S) · privacy `.private` sweep (S) · notifications popover ScrollView (S) · textSelection on logs/tokens (S) · confirm-sheet defaultAction+focus (S) · popover bar label (S) · MenuBarExtra label (S) · logger subsystem unification (S) · PermissionsProbe comment (S) · ActivityLog download kind (S).

## Open questions (human ruling wanted)

1. Pause-while-monitoring zeroes the hero ring to 0% — keep, or show last-known progress dimmed?
2. Destructive confirm deliberately off Return? (Recommend: yes, keep; give Cancel initial focus.)
3. Newest-at-top log insertion vs VoiceOver cursor stability — accepted tradeoff?
4. BandwidthSource re-baseline after an idle/missing sample undercounts — accept as "estimated," or merge baselines?
5. `pendingFileCount` hides a paused app's backlog — product choice to pin either way.

## Clean bill

Process reaping and cancellation (all spawns terminate on cancel/timeout; no accumulation) · buffer caps everywhere (activity 200, notifications 50, console 25, stream 64) · no timing-dependent tests, exemplary injected-clock debounce test · fixture discipline against real captured output · no predicate injection (fixed literals), fixed absolute tool paths, no shell, clean hardened-runtime posture · Sendable-DTO boundary and single-owner store intact · prior audit fixes unregressed · reduce-motion, combined a11y elements, scaledFont system holding.

## Suggested remediation order

1. **Batch A — data & store correctness (Opus):** P1 #1, #2; mute/notifier injection + `IssueItem.appID`; coalescing generation loop; resolve-vs-scan cache generation; SystemNotifier memoized auth + ordered batch; ActivityLog kind fix; privacy sweep (ConflictSource/DriveFolderSource/SystemSyncSource); PermissionsProbe drift.
2. **Batch B — energy & process layer (Opus):** occlusion gating, metadata query stop/start, popover cached-first + scan skip, skip-not-queue, ps merge, DaemonStats→ProcessRunner, SIGKILL escalation, MenuBarExtra state label, Commands menu + shortcuts.
3. **Batch C — views/a11y sweep (Sonnet):** P1 #3, #4; confirm-sheet focus/Return; notifications scroll; textSelection; dead buttons wired or removed; console batching + header honesty + subsystem; tooltips/context menus; dialog header trait; sparkline value; muted-row cue; storage segment .help.
4. **Batch D — tests (Opus, after A):** P1 #5 + the five specified missing tests + StubSyncSource recording + overlapping-refresh test.
