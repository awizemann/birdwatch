import Foundation

/// Everything the UI needs, gathered in one Sendable value. In Phase 1 the
/// real sources (brctl, NSMetadataQuery, log stream, ps sampling) assemble
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
/// EXECUTION CONTEXT (SE-0461, load-bearing for Phase 1): `nonisolated` async
/// requirements run on the CALLER's actor — which is SyncStore's MainActor.
/// A real implementation that spawns brctl / samples ps in a plain
/// `nonisolated func … async` would block the UI. Implementations doing real
/// work MUST either mark the method `@concurrent` or implement it
/// actor-isolated (no `nonisolated` on the conformance) so calls hop to the
/// source actor.
nonisolated protocol SyncSource: Sendable {
    func currentSnapshot() async -> SyncSnapshot
    /// Streams log lines for one app's backing daemon while a detail view is open.
    func logStream(appID: String) -> AsyncStream<LogLine>
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
