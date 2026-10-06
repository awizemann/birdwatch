import Foundation

/// Every usage event Birdwatch can emit, in one place.
///
/// This is the whole privacy contract for analytics: an event is a case here or
/// it does not exist, and a prop is a value listed here or it is not sent. Props
/// are closed enums, booleans and small bucketed integers only — never an app
/// name, file/folder name, path, device name, byte count, log line or search
/// text (swift-stats schema §2.3 / §13). Backends and error kinds are enum
/// case names, which is the most specific we go.
///
/// Names are snake_case per the schema (`^[a-z][a-z0-9_]*$`).
nonisolated enum UsageEvent: Sendable, Equatable {
    /// How the user got somewhere — the sidebar, a ⌘-digit shortcut, the
    /// search dropdown, the menu-bar popover, or a link inside another view.
    enum NavigationSource: String, Sendable, CaseIterable { case launch, sidebar, shortcut, search, menubar, link }

    enum SearchResultKind: String, Sendable, CaseIterable { case app, view }

    /// Which repair a Diagnostics maintenance row ran.
    enum MaintenanceAction: String, Sendable, CaseIterable { case restart_daemon, diagnose_copy_command, diagnose_open_terminal }

    /// `unconfirmed` is the honest middle a daemon restart can end in: the
    /// signal landed but no new pid was seen inside the poll window (cloudd is
    /// launched on demand). Counting it as `ok` would claim a restart nobody
    /// witnessed — the UI already tints it as a caution.
    enum Outcome: String, Sendable, CaseIterable { case ok, unconfirmed, failed }

    /// Where a System Settings › Apple Account button was pressed. The issue
    /// card's button is counted as `issue_action(manage_storage)` instead.
    enum SettingsOrigin: String, Sendable, CaseIterable { case storage, devices }

    /// Which primary button an issue card offered and the person pressed.
    enum IssueActionKind: String, Sendable, CaseIterable { case review_versions, open_diagnostics, manage_storage }

    /// Which daemon a maintenance action targeted — the closed set
    /// MaintenanceActions can restart, so no other string can travel;
    /// `init?(rawValue:)` is the gate at the boundary.
    enum Daemon: String, Sendable, CaseIterable { case bird, cloudd, fileproviderd }

    /// A maintenance failure's kind: a `MaintenanceError` case name, or
    /// `other` for anything else. Never the error's message (paths, names).
    enum MaintenanceErrorKind: String, Sendable, CaseIterable {
        case unknownDaemon, daemonNotRunning, pathNotAllowed, other
    }

    /// A first-run screen was shown (funnel; completion is the next case).
    case onboardingStepShown(OnboardingStep)
    /// First-run setup finished. Setup cannot finish without Full Disk
    /// Access unless the probe cannot tell, so `fdaGranted` is false only for
    /// an unconfirmed (`.unknown`) grant.
    case onboardingCompleted(fdaGranted: Bool, notificationsRequested: Bool)
    /// A top-level monitor view became the selected one.
    case viewShown(MonitorView, via: NavigationSource)
    /// The per-app detail screen opened. Only the backend is reported.
    case appDetailShown(SyncBackend)
    /// The menu-bar popover opened.
    case menubarOpened(issueCount: Int, paused: Bool)
    /// A search result was chosen. No query text; just what kind of thing.
    case searchUsed(resultKind: SearchResultKind, resultCount: Int)
    /// ⌘R / "Refresh Now".
    case refreshForced
    case monitoringPaused
    case monitoringResumed
    /// An app was muted/unmuted (popover quick action).
    case appMuted(SyncBackend, muted: Bool)
    case issueDismissed(severity: IssueSeverity)
    /// An issue card's primary button was pressed — whether turning an issue
    /// into a next step gets used. Severity only, never the issue's text.
    case issueAction(IssueActionKind, severity: IssueSeverity)
    /// The one real "fix" feature.
    case conflictResolved(keptCurrent: Bool)
    /// Retry-queue row actions. Reveal has no observable outcome.
    case retryItemRevealed
    case retryItemTrashed(outcome: Outcome)
    case maintenanceRun(MaintenanceAction, daemon: Daemon?, outcome: Outcome, errorKind: MaintenanceErrorKind?)
    case notificationsMarkedRead
    case planCapSet(cleared: Bool)
    /// A Storage or Devices button opened System Settings › Apple Account —
    /// whether those views lead anyone to act.
    case accountSettingsOpened(from: SettingsOrigin)
    /// Once per launch, after the first snapshot and a person's first
    /// activation (whichever is later): what the world looks like.
    case snapshotHealth(
        appsByBackend: [SyncBackend: Int], issueCount: Int, daemonsMissing: Int,
        fdaGranted: Bool, notificationsGranted: Bool
    )

    /// Wire name (schema §2.1).
    var name: String {
        switch self {
        case .onboardingStepShown: "onboarding_step_shown"
        case .onboardingCompleted: "onboarding_completed"
        case .viewShown: "view_shown"
        case .appDetailShown: "app_detail_shown"
        case .menubarOpened: "menubar_opened"
        case .searchUsed: "search_used"
        case .refreshForced: "refresh_forced"
        case .monitoringPaused: "monitoring_paused"
        case .monitoringResumed: "monitoring_resumed"
        case .appMuted: "app_muted"
        case .issueDismissed: "issue_dismissed"
        case .issueAction: "issue_action"
        case .conflictResolved: "conflict_resolved"
        case .retryItemRevealed: "retry_item_revealed"
        case .retryItemTrashed: "retry_item_trashed"
        case .maintenanceRun: "maintenance_run"
        case .notificationsMarkedRead: "notifications_marked_read"
        case .planCapSet: "plan_cap_set"
        case .accountSettingsOpened: "account_settings_opened"
        case .snapshotHealth: "snapshot_health"
        }
    }

    /// Flat scalar props (schema §2.3). Values are `UsageValue`, a tiny mirror
    /// of the SDK's `StatsValue` so this file — and every caller — stays free
    /// of the `Stats` import.
    var props: [String: UsageValue] {
        switch self {
        case let .onboardingStepShown(step):
            return ["step": .string(step.rawValue)]
        case let .onboardingCompleted(fda, notifications):
            return ["fda_granted": .bool(fda), "notifications_requested": .bool(notifications)]
        case let .viewShown(view, via):
            return ["view": .string(view.rawValue), "via": .string(via.rawValue)]
        case let .appDetailShown(backend):
            return ["backend": .string(backend.rawValue)]
        case let .menubarOpened(issues, paused):
            return ["issue_bucket": .string(Self.bucket(issues)), "paused": .bool(paused)]
        case let .searchUsed(kind, count):
            return ["result_kind": .string(kind.rawValue), "result_bucket": .string(Self.bucket(count))]
        case .refreshForced, .monitoringPaused, .monitoringResumed, .notificationsMarkedRead, .retryItemRevealed:
            return [:]
        case let .appMuted(backend, muted):
            return ["backend": .string(backend.rawValue), "muted": .bool(muted)]
        case let .issueDismissed(severity):
            return ["severity": .string(severity.rawValue)]
        case let .issueAction(action, severity):
            return ["action": .string(action.rawValue), "severity": .string(severity.rawValue)]
        case let .conflictResolved(keptCurrent):
            return ["kept": .string(keptCurrent ? "current" : "other")]
        case let .retryItemTrashed(outcome):
            return ["outcome": .string(outcome.rawValue)]
        case let .maintenanceRun(action, daemon, outcome, errorKind):
            var p: [String: UsageValue] = ["action": .string(action.rawValue), "outcome": .string(outcome.rawValue)]
            if let daemon { p["daemon"] = .string(daemon.rawValue) }
            if let errorKind { p["error_kind"] = .string(errorKind.rawValue) }
            return p
        case let .planCapSet(cleared):
            return ["cleared": .bool(cleared)]
        case let .accountSettingsOpened(origin):
            return ["from": .string(origin.rawValue)]
        case let .snapshotHealth(byBackend, issues, missing, fda, notifications):
            return [
                "apps_clouddocs_bucket": .string(Self.bucket(byBackend[.cloudDocs, default: 0])),
                "apps_cloudkit_bucket": .string(Self.bucket(byBackend[.cloudKit, default: 0])),
                "apps_fileprovider_bucket": .string(Self.bucket(byBackend[.fileProvider, default: 0])),
                "issue_bucket": .string(Self.bucket(issues)),
                "daemons_missing": .int(missing),
                "fda_granted": .bool(fda),
                "notifications_granted": .bool(notifications),
            ]
        }
    }

    /// Coarse buckets keep counts from becoming a fingerprint while still
    /// answering "is this zero, a few, or a lot".
    static func bucket(_ n: Int) -> String {
        switch n {
        case ..<1: "0"
        case 1: "1"
        case 2...5: "2-5"
        case 6...20: "6-20"
        default: "20+"
        }
    }
}

/// The scalar prop values the schema allows. Mirrors `Stats.StatsValue`
/// one-to-one; converted at the adapter boundary.
nonisolated enum UsageValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
}
