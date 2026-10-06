import Foundation

/// Everything the UI needs, gathered in one Sendable value. In Phase 1 the
/// real sources (brctl, FSEvents + ubiquity flags, log show/stream, ps, nettop) assemble
/// this off-main; the store diffs and publishes it.
struct SyncSnapshot: Sendable {
    var apps: [AppSyncState]
    var transfers: [TransferItem]
    var driveFolders: [DriveFolder]
    var devices: [DeviceItem]
    /// Anonymous per-device item attribution from `brctl dump`. Defaults nil so
    /// fixture sources (which supply real `devices`) opt out.
    var deviceActivity: DeviceActivitySummary? = nil
    var issues: [IssueItem]
    var activity: [ActivityEvent]
    var daemons: [DaemonStat]
    var retryQueue: [RetryQueueItem]
    /// Every item bird has scheduled work for — `retryQueue` is capped to the
    /// rows the card can show, so the card must say what it is a subset of.
    var retryQueueTotal: Int = 0
    var engine: SyncEngineInfo
    var permissions: [PermissionStatus]
    var bandwidth: BandwidthSummary
    var storage: StorageInfo?   // nil when the plan total is unknowable (brctl only reports remaining)
    /// brctl-reported quota remaining — the ONLY storage number the system
    /// exposes when `storage` is nil. Defaults nil so fixture sources opt out.
    var quotaRemainingBytes: Int64? = nil
    var notifications: [AppNotification]
    /// Which producer contributed which issue ids — listing ONLY producers
    /// that have delivered at least one SUCCESSFUL result. The store absorbs
    /// each producer's first delivery silently as that producer's launch
    /// baseline (those issues existed before Birdwatch looked), whenever it
    /// arrives, while producers that already delivered banner normally — so a
    /// slow or failing producer never holds back another's alerts.
    /// nil (the default) means a fixture source: one producer that has
    /// delivered every issue in the snapshot.
    var issueProducers: [IssueProducer: Set<String>]? = nil
    /// What the background scans could say this cycle, so an empty or old
    /// list is labelled instead of passed off as current (C1). All default nil:
    /// a fixture source has no scans and shows no scan notices.
    var cloudKitScan: CloudKitScanState? = nil
    var folderScan: ScanFreshness? = nil
    var containerScan: ScanFreshness? = nil
    /// Set when the conflict scan stopped at its item cap (the cap's value),
    /// so "no conflicts" covers only the part of iCloud Drive it reached.
    var conflictScanCap: Int? = nil
}

/// How fresh a background directory scan's result is (from
/// `SingleFlightScan.Reading`).
nonisolated struct ScanFreshness: Sendable, Hashable {
    /// When the result's scan finished; nil while the FIRST scan is running.
    let completedAt: Date?
    /// A scan is running past its deadline and the result is the previous one.
    let isOverdue: Bool
    /// The last scan could not read the root at all — an empty list is
    /// "couldn't look", not "nothing there".
    var isUnreadable: Bool = false
}

/// The CloudKit section's evidence: nothing read yet, or the last scan's
/// outcome without its rows (the rows travel in `apps`).
nonisolated enum CloudKitScanState: Sendable, Hashable {
    case scanning
    case scanned(outcome: CloudKitScanOutcome, isStale: Bool, observedAt: Date?, isTruncated: Bool)

    init(_ scan: CloudKitScan) {
        self = .scanned(outcome: scan.outcome, isStale: scan.isStale,
                        observedAt: scan.observedAt, isTruncated: scan.isTruncated)
    }
}

/// The independent things that produce issues. Each one's first successful
/// delivery is a separate launch baseline (see `SyncSnapshot.issueProducers`).
nonisolated enum IssueProducer: Sendable, Hashable {
    /// `brctl quota` → the low-quota issue.
    case quota
    /// The background NSFileVersion conflict scan.
    case conflicts
    /// The background `brctl dump` parse.
    case dump
    /// A fixture source (mock, tests): everything, delivered at once.
    case fixture
    /// Store-side: ids in a snapshot that no listed producer claims. Treated
    /// as one more producer, always delivered, so they still get a launch
    /// baseline instead of bypassing it.
    case unclaimed
}

/// What a conflict resolution did.
nonisolated enum ConflictResolveResult: Sendable, Equatable {
    case resolved
    /// The file operation failed; the conflict is still open.
    case failed
    /// The file has a conflict version the user was NOT shown (it arrived
    /// after the screen loaded). Nothing was changed; the source has
    /// refreshed its detail, so the screen must reload and ask again.
    case changed
    /// The source no longer reports this conflict (already resolved, or gone
    /// from the scan). Retrying would never help, so the UI says so.
    case notFound
    /// Store-only: another resolution is already running, so this request
    /// was ignored. Sources never return it; the UI ignores it.
    case busy
}

/// `nonisolated` so actor-backed real sources (and actor test fakes) can conform.
///
/// EXECUTION CONTEXT: this project does NOT enable NonisolatedNonsendingByDefault
/// (SE-0461), so a `nonisolated async` implementation runs on the global
/// concurrent executor, not on the caller's (SyncStore's) MainActor — and
/// anything it reads from MainActor state needs an explicit hop
/// (`MainActor.run`), as SystemSyncSource does. Marking heavy work
/// `@concurrent`, or isolating it to an actor, keeps it off-main even if that
/// upcoming feature is ever turned on, at which point plain `nonisolated async`
/// would start running on the caller's actor.
nonisolated protocol SyncSource: Sendable {
    func currentSnapshot() async -> SyncSnapshot
    /// Streams log lines for one app's backing daemon while a detail view is
    /// open. `backend` picks the daemon, so the console's header (also derived
    /// from the backend) and its stream always name the same thing. The
    /// stream ends with an error when the tool cannot run (launch failure,
    /// non-zero exit) or reaches its lifetime cap (`RunnerError.timeout`).
    func logStream(appID: String, backend: SyncBackend) -> AsyncThrowingStream<LogLine, any Error>
    /// Latest conflict detail for a conflict issue (nil if already resolved).
    func conflictDetail(issueID: String) async -> ConflictDetail?
    /// Resolves a file conflict, keeping the version identified by
    /// `keepVersionID` (see ConflictSource's sentinels for "current"/"both").
    /// `shownVersionIDs` are the versions the user was actually shown: a
    /// keep-current / keep-version choice may only remove those, and any
    /// other unresolved version yields `.changed` with nothing touched.
    /// `.failed` leaves the conflict open; `.notFound` means the source no
    /// longer reports it. Never `.busy` (that is the store's answer).
    /// Optional: sources without real files keep the default no-op.
    func resolveConflict(issueID: String, keepVersionID: String, shownVersionIDs: Set<String>) async -> ConflictResolveResult
    /// Forgets a retry-queue row whose file the user just moved to the Trash,
    /// so a dump collected before the move cannot resurrect it.
    /// Optional: sources without a cached dump keep the default no-op.
    func forgetRetryQueueItem(id: String) async
}

extension SyncSource {
    /// Default no-op so fixture/stub sources (MockSyncSource, test stubs)
    /// conform without touching the file system. A fixture conflict has no
    /// file behind it, so "resolving" it trivially succeeds.
    func resolveConflict(issueID: String, keepVersionID: String, shownVersionIDs: Set<String>) async -> ConflictResolveResult { .resolved }
    func forgetRetryQueueItem(id: String) async {}
}
