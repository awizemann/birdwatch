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
    /// Optional: sources without real files keep the default no-op.
    func resolveConflict(issueID: String, keepVersionID: String) async
    /// Forgets a retry-queue row whose file the user just moved to the Trash,
    /// so a dump collected before the move cannot resurrect it.
    /// Optional: sources without a cached dump keep the default no-op.
    func forgetRetryQueueItem(id: String) async
}

extension SyncSource {
    /// Default no-op so fixture/stub sources (MockSyncSource, test stubs)
    /// conform without touching the file system.
    func resolveConflict(issueID: String, keepVersionID: String) async {}
    func forgetRetryQueueItem(id: String) async {}
}
