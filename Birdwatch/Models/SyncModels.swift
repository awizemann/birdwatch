import Foundation

// MARK: - Backend fidelity

/// Which system service syncs an app's data, and therefore how much detail we can honestly show.
enum SyncBackend: String, Sendable, Hashable, Codable {
    case cloudDocs      // `bird` — per-file in-flight flags (no percentage), engine state
    case cloudKit       // `cloudd` — activity seen in the system log only
    case fileProvider   // `fileproviderd` — listed from ~/Library/CloudStorage, no status

    var badgeLabel: String {
        switch self {
        case .cloudDocs: "CloudDocs"
        case .cloudKit: "CloudKit"
        case .fileProvider: "File Provider"
        }
    }

    var daemonName: String {
        switch self {
        case .cloudDocs: "bird"
        case .cloudKit: "cloudd"
        case .fileProvider: "fileproviderd"
        }
    }

    /// What the backend says about progress. CloudDocs' unentitled channel
    /// is a per-file boolean (in flight or not) — never a percentage.
    var progressDetail: String {
        switch self {
        case .cloudDocs: "In flight / done only (no percentage)"
        case .cloudKit: "Activity only (no progress)"
        case .fileProvider: "Not reported"
        }
    }
}

// MARK: - App sync state

enum AppSyncStatus: Sendable, Hashable {
    case upToDate
    case syncing(progress: Double)   // 0...1
    /// The backend reports work in progress (CloudKit transferring, pushing or
    /// throttled) but no progress of any kind — no percentage, no file count.
    /// Distinct from `.syncing` so nothing averages it into a percentage, and
    /// from `.upToDate` so nothing calls it synced (C1).
    case active
    case paused
    case issue(String)
    /// Nothing has been read yet that says what the engine is doing (e.g. the
    /// first `brctl dump -i` has not landed). Neutral: neither a problem nor
    /// "up to date" — it is not counted as idle, active or an issue (C1).
    case unknown
    /// bird has this many items scheduled and not yet synced (its retry
    /// queue, from `brctl dump`) and nothing is transferring. Never "Up to
    /// date", never green — and not a red error either: a backlog bird is
    /// still holding is a warning (C1).
    case notSyncing(items: Int)

    var isSyncing: Bool { if case .syncing = self { true } else { false } }
    /// Syncing with or without progress — anything that is doing work.
    var isActive: Bool {
        switch self {
        case .syncing, .active: true
        case .upToDate, .paused, .issue, .unknown, .notSyncing: false
        }
    }
}

/// How many items an app holds, and what KIND of count it is — an engine's
/// index and a shallow directory listing are different facts and must not
/// share a label.
nonisolated enum AppItemCount: Sendable, Hashable {
    /// The sync engine's own count of indexed items.
    case indexed(Int)
    /// Visible top-level entries of the app's container (one shallow listing).
    /// `isCapped`: the listing stopped at the cap, so the figure is a floor.
    case topLevel(Int, isCapped: Bool)
}

/// Allocated bytes an app keeps on this Mac.
nonisolated struct LocalSize: Sendable, Hashable {
    let bytes: Int64
    /// The walk hit its entry cap, so `bytes` is a floor ("at least").
    var isPartial: Bool = false
    /// The folder could not be read at all: `bytes` is not a measurement.
    var isUnreadable: Bool = false
}

struct AppSyncState: Sendable, Hashable, Identifiable {
    let id: String                   // stable slug, e.g. "photos"
    let name: String
    let tileColorHex: String
    let backend: SyncBackend
    let isApple: Bool
    var status: AppSyncStatus
    var statusLine: String           // e.g. "Uploading 234 of 1,024 photos"
    var lastActivity: Date?

    // Detail-view fields. nil means the backend does not report it (or, for
    // `localSize`, it has not been measured yet) — never a placeholder zero.
    var itemCount: AppItemCount?
    var pendingItems: Int?
    var localSize: LocalSize?
    var locationPath: String
    var queueBreakdown: [(String, Int)]? { queueLabels.isEmpty ? nil : Array(zip(queueLabels, queueCounts)) }
    var queueLabels: [String] = []
    var queueCounts: [Int] = []
    var infoCallout: String?         // backend-limits explainer shown in detail
    var retryWarning: String?        // e.g. "3 items stuck — attempt 12 of 62"
    /// The recency tile's label when "Last synced" would be wrong — e.g. a
    /// container row's date is the directory's modification time.
    var lastActivityLabel: String? = nil
    /// Qualifies `lastActivity` when it comes from a last-known (not
    /// current) read: "last-known, brctl dump 4 min ago".
    var lastActivityNote: String? = nil
    /// Birdwatch deliberately isn't reading this app's folders until Full
    /// Disk Access is granted (Desktop & Documents); the detail view offers
    /// the settings deep link.
    var needsFullDiskAccess = false
    /// A per-app iCloud Drive container row (`AppContainerSource`). Its idle
    /// state is only "no transfer seen in this folder" — bird's engine state
    /// covers the CloudDocs zone, not these containers, so an unentitled
    /// observer cannot confirm one is synced (`SyncStatusDisplay`).
    var isAppContainer = false
    // Equatable/Hashable are synthesized over EVERY stored field: a custom
    // == that ignored size, counts, callouts or backend let SwiftUI skip a
    // real change.
}

// MARK: - Transfers

nonisolated // nonisolated conformance: compared inside nonisolated diff/mapping code.
enum TransferDirection: Sendable, nonisolated Hashable { case upload, download }

struct TransferItem: Sendable, Hashable, Identifiable {
    let id: String
    let appID: String                // owning app (AppSyncState.id)
    let name: String
    let location: String             // parent folder display path
    let sizeBytes: Int64
    let direction: TransferDirection
    var progress: Double             // 0...1; 1 == Done
    nonisolated var isDone: Bool { progress >= 1 }
    /// TRUE when this row carries no honest percentage. The live ubiquity
    /// channel reports a BOOLEAN (`ubiquitousItemIsUploading`), so an in-flight
    /// item sits at 0 until it completes — rendering "0%" or an empty bar would
    /// be fabricating a measurement. Fixture/mock rows carry real fractions
    /// (0 < progress < 1) and stay determinate.
    nonisolated var isIndeterminate: Bool { progress <= 0 }

    /// TRUE when a set of in-flight rows carries no honest percentage at all,
    /// so any mean over them would be a fabricated zero. Heuristic, the one
    /// rule for every bar: ANY row with 0 < progress < 1 → determinate.
    nonisolated static func progressIsIndeterminate(_ inFlight: [TransferItem]) -> Bool {
        guard !inFlight.isEmpty else { return false }
        return !inFlight.contains { $0.progress > 0 && $0.progress < 1 }
    }
}

// MARK: - iCloud Drive folders

struct DriveFolder: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    /// Top-level entries; nil when the folder could not be read.
    let itemCount: Int?
    var status: AppSyncStatus
    /// The count stopped at the scan's cap, so it is a floor ("500+").
    var itemCountIsCapped: Bool = false

    /// Display location of the iCloud Drive root, as transfers report it.
    nonisolated static let cloudDocsLocation = "~/Library/Mobile Documents/com~apple~CloudDocs"

    /// The top-level iCloud Drive folder a transfer's display location falls
    /// in, or nil when it is outside one. The one rule both a folder's status
    /// and the store's per-folder progress decision use.
    nonisolated static func folderName(containing location: String) -> String? {
        let prefix = cloudDocsLocation + "/"
        guard location.hasPrefix(prefix) else { return nil }
        let name = location.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first
        return name.map(String.init)
    }
}

// MARK: - Devices

struct DeviceItem: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let kind: String                 // "MacBook Pro", "iPhone", "Web session"
    let osVersion: String
    let tileColorHex: String
    let isCurrentDevice: Bool
    var statusLabel: String          // "Syncing now" / "Last seen 26m ago"
    var isActive: Bool
    var lastChange: String
}

/// Anonymous, partial device attribution derived from `brctl dump`'s item
/// tree (`device:N` + `mt:`). bird permanently length-redacts device NAMES, so
/// a row can only ever be "Device 30" — never a model, OS or user-visible name.
/// Counts are lower bounds: bird truncates its own item dump.
struct DeviceActivityItem: Sendable, Hashable, Identifiable {
    var id: String { "device-\(index)" }
    let index: Int
    let itemCount: Int
    let lastModified: Date?
}

struct DeviceActivitySummary: Sendable, Hashable {
    /// device:0 (bird's placeholder for not-yet-uploaded items) is excluded.
    let devices: [DeviceActivityItem]
    /// Entries in the dump's `devices:` registry — usually more than the
    /// devices that actually authored an item in the (truncated) tree.
    let registeredDeviceCount: Int
    /// Item counts are lower bounds because bird truncated its item dump.
    let countsArePartial: Bool

    func activeCount(since: Date) -> Int {
        devices.filter { ($0.lastModified ?? .distantPast) >= since }.count
    }

    /// Devices ordered the way the UI shows them: most recently active first.
    nonisolated var devicesByActivity: [DeviceActivityItem] {
        Self.sortedByActivity(devices)
    }

    /// Pure activity ordering: most recent `lastModified` first, undated
    /// devices last, ties broken by item count (desc) then index (asc) so the
    /// order is total and stable.
    nonisolated static func sortedByActivity(_ items: [DeviceActivityItem]) -> [DeviceActivityItem] {
        items.sorted { lhs, rhs in
            switch (lhs.lastModified, rhs.lastModified) {
            case let (l?, r?) where l != r: return l > r
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
            if lhs.itemCount != rhs.itemCount { return lhs.itemCount > rhs.itemCount }
            return lhs.index < rhs.index
        }
    }
}

// MARK: - Issues

enum IssueSeverity: String, Sendable, Hashable {
    case warning, conflict, error
}

/// What an issue's primary button DOES.
///
/// Typed, not free text. The button used to be keyed on a derived label
/// string, so a source could invent a label, compile cleanly, and silently
/// render either no button or one that did nothing. A case here is a promise
/// Birdwatch can keep. The button's TITLE is the view layer's business
/// (`IssuePrimaryAction`); no display copy lives in this model.
nonisolated enum IssueAction: Sendable, Hashable, CaseIterable {
    case reviewVersions
    case openDiagnostics
    case manageStorage
    /// No button at all — the honest answer when Birdwatch cannot act on the
    /// issue itself. A button that does nothing would claim a capability that
    /// does not exist (C1).
    case none
}

struct IssueItem: Sendable, Hashable, Identifiable {
    let id: String
    let severity: IssueSeverity
    let title: String
    let meta: String                 // "Photos · 12 minutes ago"
    let reason: String               // plain-language paragraph
    /// Non-optional and with NO default on purpose: a new issue-producing site
    /// that forgets to say what its button does fails to COMPILE instead of
    /// shipping a silently actionless issue.
    let action: IssueAction
    let symbolName: String
    /// The app this issue belongs to (`AppSyncState.id`), when the issue is
    /// attributable to one. nil means account-level (e.g. low quota), which
    /// per-app mute deliberately cannot silence.
    var appID: String? = nil
    var isConflict: Bool { severity == .conflict }

    /// Whether to show a primary button at all.
    var hasPrimaryAction: Bool { action != .none }
}

/// The two sides of a file conflict (Issues → Review versions).
struct ConflictVersion: Sendable, Hashable, Identifiable {
    let id: String
    let deviceName: String
    let tileColorHex: String
    let modified: Date
    let sizeBytes: Int64
    let changeNote: String
}

struct ConflictDetail: Sendable, Hashable {
    let fileName: String
    let location: String
    let versions: [ConflictVersion]
    /// The conflicted file on disk (nil for fixture sources with no real file).
    var fileURL: URL? = nil
}

// MARK: - Activity

enum ActivityKind: Sendable, Hashable { case upload, done, warning, conflict, info }

struct ActivityEvent: Sendable, Hashable, Identifiable {
    let id: String
    let kind: ActivityKind
    let title: String
    let detail: String
    let date: Date
    let symbolName: String
}

// MARK: - Diagnostics

struct DaemonStat: Sendable, Hashable, Identifiable {
    var id: String { name }
    let name: String                 // "bird"
    let role: String                 // "CloudDocs sync engine"
    var cpuPercent: Double
    var memoryMB: Double
    var pid: Int32?
}

struct RetryQueueItem: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    var attempt: Int
    let maxAttempts: Int             // 62 — items that hit this stop retrying
    /// Seconds since bird last tried this item. Often the ONLY moving part:
    /// a `sync-up-scheduled` item sits at attempts:0 for months.
    var lastAttemptAgo: TimeInterval? = nil
    /// Home-relative (`~/Library/Mobile Documents/…`) path of the real file or
    /// folder on THIS disk that fits bird's redaction pattern. Never bird's
    /// redacted string — nil means we found no honest answer.
    /// When `matchConfidence` is `.ambiguous`, this is the shared parent folder.
    var path: String? = nil
    /// Absolute path for `Reveal in Finder`; nil whenever `path` is nil.
    var absolutePath: String? = nil
    var matchConfidence: PathMatchConfidence = .none
    /// Whether bird described the stuck item as a folder. Drives the wording
    /// ("Empty folder" vs a plain size) and the Trash button's phrasing.
    var isDirectory: Bool = false
    /// Allocated bytes of the resolved item, measured on OUR disk during the
    /// background dump refresh. nil until measured (or when the path vanished).
    var sizeBytes: Int64? = nil
    /// SHALLOW child count for a resolved folder; nil for a file. `0` is the
    /// meaningful case — an empty folder bird has been retrying for months is
    /// the one a user can safely throw away.
    var itemCount: Int? = nil
    /// The deep size walk hit its entry cap, so `sizeBytes` is a floor.
    var sizeIsPartial: Bool = false
}

struct SyncEngineInfo: Sendable, Hashable {
    var serverState: String
    var clientState: String
    var lastSyncToken: String
    var pushBudget: String           // amber when throttled
    var pushThrottled: Bool
    var metadataIndex: String
    var metadataHealthy: Bool
    /// `global progress {f:… uc:…}` from `brctl dump`, when bird is reporting
    /// one. nil (the common case, `{none}`) hides the row rather than showing 0%.
    var globalProgressLine: String? = nil
}

/// What a permission probe could establish. `.unknown` is its own answer —
/// the probe had nothing to test, or the system didn't reply in time — and is
/// never shown as "Not granted" (C1).
nonisolated enum PermissionState: Sendable, Hashable {
    case granted, denied, unknown
}

struct PermissionStatus: Sendable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    var state: PermissionState
    /// True only for a confirmed grant; `.unknown` reads as false here.
    var granted: Bool { state == .granted }
}

// MARK: - Log

enum LogLevel: String, Sendable, Hashable { case debug = "DBG", info = "INFO", warn = "WARN", error = "ERR" }

struct LogLine: Sendable, Hashable, Identifiable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let message: String
}

// MARK: - Bandwidth & storage

struct BandwidthHourSample: Sendable, Hashable, Identifiable {
    var id: Int { hour }
    let hour: Int                    // 0...23
    let uploadedBytes: Int64
    let downloadedBytes: Int64
    /// FALSE for hours Birdwatch never sampled successfully (before launch,
    /// still to come, or every sample failed). Their zeros are not data.
    var isObserved: Bool = true
}

struct BandwidthSummary: Sendable, Hashable {
    var uploadedTodayBytes: Int64
    var downloadedTodayBytes: Int64
    var currentRateBytesPerSec: Int64
    var hours: [BandwidthHourSample]
    /// FALSE when `currentRateBytesPerSec` is not a measurement: the first
    /// sample only sets a baseline, and a failed sample measures nothing.
    var rateIsMeasured: Bool = true
    /// The latest sample failed (nettop or ps did not answer).
    var lastSampleFailed: Bool = false
}

struct StorageSegment: Sendable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let colorHex: String
    let bytes: Int64
}

/// File-type buckets for the local iCloud footprint breakdown. Fixed set: the
/// palette, the legend order and the bar order all key off `allCases`.
nonisolated enum StorageCategory: String, Sendable, nonisolated Hashable, CaseIterable, Codable {
    case documents, images, video, audio, archives, codeData, appsPackages, other

    var displayName: String {
        switch self {
        case .documents: "Documents"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .archives: "Archives"
        case .codeData: "Code & Data"
        case .appsPackages: "Apps & Packages"
        case .other: "Other"
        }
    }

    /// Fixed 8-colour palette (design handoff storage segments). Lives on the
    /// model because segments are built off-main; `Palette.storageCategory(_:)`
    /// is the view-facing spelling of the same values.
    var colorHex: String {
        switch self {
        case .documents: "0a84ff"
        case .images: "fe4f6d"
        case .video: "5e5ce6"
        case .audio: "34c759"
        case .archives: "ff9f0a"
        case .codeData: "30b0c7"
        case .appsPackages: "af52de"
        case .other: "8e8e93"
        }
    }
}

/// Where the plan cap in `StorageInfo.totalBytes` came from. Drives the honesty
/// footnote and whether Storage asks the user to confirm their plan.
nonisolated enum StorageCapSource: String, Sendable, nonisolated Hashable {
    /// Snapped from local footprint + brctl's remaining quota.
    case derived
    /// The user picked a plan (persisted in `bw_plan_cap_bytes`).
    case userChosen
    /// No remaining quota reported — no cap can be stated.
    case unknown
}

/// What the sidebar footer states. Account usage when the quota makes it
/// knowable (it matches System Settings), else the local measurement.
nonisolated enum StorageFooterFigure: Sendable, nonisolated Hashable {
    case account(used: Int64, cap: Int64)
    case local(used: Int64, cap: Int64)
    case localOnly(used: Int64)

    /// Bar fill, 0…1. nil when there is no cap to divide by.
    var progress: Double? {
        switch self {
        case let .account(used, cap), let .local(used, cap):
            cap > 0 ? min(1, max(0, Double(used) / Double(cap))) : nil
        case .localOnly:
            nil
        }
    }
}

struct StorageInfo: Sendable, Hashable {
    /// Plan cap. nil when it cannot be derived and the user hasn't chosen one —
    /// the bar then scales to the measured total, never to an invented cap.
    let totalBytes: Int64?
    let segments: [StorageSegment]
    let planName: String             // "iCloud+ · 200 GB plan"
    let planPriceLine: String
    var capSource: StorageCapSource = .derived

    // MARK: Account tier (whole iCloud account, not just this Mac)

    /// Live account-wide remaining bytes as reported by `brctl quota`, when
    /// available. This is the only account-scoped number Apple exposes.
    var remainingBytes: Int64? = nil
    /// TRUE account usage = cap − remaining. Non-nil only when BOTH the plan cap
    /// and the live remaining quota are known AND agree; this is the figure
    /// that matches System Settings → iCloud.
    var accountUsedBytes: Int64? = nil
    /// TRUE when iCloud reports more remaining than the plan cap — the plan
    /// setting is too small (e.g. a stacked plan). No usage is computed and
    /// the cap is not used as a denominator anywhere (`trustedCapBytes`).
    var planCapBelowRemaining: Bool = false

    /// No cap could be derived because several purchasable plans fit the
    /// quota (and the user hasn't chosen one): account usage is unknown and
    /// the plan question is asked.
    var planIsAmbiguous: Bool = false

    /// The cap, unless the live quota contradicts it.
    var trustedCapBytes: Int64? { planCapBelowRemaining ? nil : totalBytes }

    /// The account headline is only shown when both halves of the sum are known.
    var hasAccountTier: Bool { accountUsedBytes != nil && totalBytes != nil }

    /// Local footprint as drawn in the ACCOUNT bar — never larger than account
    /// usage itself (Family sharing and rounding can push the local measurement
    /// past the account figure).
    var accountLocalSegmentBytes: Int64? {
        accountUsedBytes.map { min(usedBytes, $0) }
    }

    /// Everything the account holds that isn't iCloud Drive files on this Mac:
    /// Photos, Messages, backups, other devices. One honest remainder — Apple
    /// publishes no per-service split to third-party apps.
    var accountRemainderBytes: Int64? {
        accountUsedBytes.map { max(0, $0 - min(usedBytes, $0)) }
    }

    /// TRUE when the local measurement exceeds account usage, so the local
    /// segment had to be capped. Surfaced as a note rather than hidden.
    var localExceedsAccount: Bool {
        guard let accountUsedBytes else { return false }
        return usedBytes > accountUsedBytes
    }

    /// Sidebar footer selection: prefer the account figure so the footer agrees
    /// with System Settings; fall back to the local measurement.
    var footerFigure: StorageFooterFigure {
        if let accountUsedBytes, let totalBytes = trustedCapBytes {
            return .account(used: accountUsedBytes, cap: totalBytes)
        }
        if let totalBytes = trustedCapBytes { return .local(used: usedBytes, cap: totalBytes) }
        return .localOnly(used: usedBytes)
    }

    // MARK: Local tier

    /// LOCAL footprint: allocated bytes on this Mac. Evicted files, Photos and
    /// device backups are not part of this number.
    var usedBytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }
    var availableBytes: Int64? { trustedCapBytes.map { $0 - usedBytes } }
    /// Denominator for the LOCAL bar. When the account tier is on screen the
    /// local card is its own scale (the cap belongs to the account bar);
    /// otherwise the cap when known, else the measured total.
    var barDenominator: Int64 {
        max(hasAccountTier ? usedBytes : (trustedCapBytes ?? usedBytes), 1)
    }
}

// MARK: - Notifications panel

struct AppNotification: Sendable, Hashable, Identifiable {
    let id: String
    let severity: IssueSeverity
    let title: String
    let detail: String
    let date: Date
    var isRead: Bool
}
