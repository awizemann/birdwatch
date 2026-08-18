import Foundation
import Observation

/// The nine sidebar destinations.
enum MonitorView: String, CaseIterable, Identifiable, Hashable {
    case overview, applications, drive, devices, issues, activity, diagnostics, bandwidth, storage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .applications: "Applications"
        case .drive: "iCloud Drive"
        case .devices: "Devices"
        case .issues: "Issues"
        case .activity: "Activity"
        case .diagnostics: "Diagnostics"
        case .bandwidth: "Bandwidth"
        case .storage: "Storage"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "Everything iCloud is doing right now"
        case .applications: "Per-app sync status across every backend"
        case .drive: "Folders and files syncing through CloudDocs"
        case .devices: "Devices connected to this iCloud account"
        case .issues: "Problems that need your attention"
        case .activity: "A chronological record of sync events"
        case .diagnostics: "Sync daemons, engine state and maintenance"
        case .bandwidth: "Estimated iCloud network usage"
        case .storage: "Your iCloud storage plan and usage"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "gauge"
        case .applications: "square.grid.2x2"
        case .drive: "icloud"
        case .devices: "laptopcomputer"
        case .issues: "exclamationmark.triangle"
        case .activity: "list.bullet"
        case .diagnostics: "waveform.path.ecg"
        case .bandwidth: "arrow.up.arrow.down"
        case .storage: "externaldrive"
        }
    }
}

/// Single owner of app-wide sync state (§3: one observable owner per concern).
/// Views read DTOs from here and never touch the source directly.
@Observable
final class SyncStore {
    // Snapshot data
    private(set) var apps: [AppSyncState] = []
    private(set) var transfers: [TransferItem] = []
    private(set) var driveFolders: [DriveFolder] = []
    private(set) var devices: [DeviceItem] = []
    private(set) var deviceActivity: DeviceActivitySummary?
    private(set) var issues: [IssueItem] = []
    private(set) var activity: [ActivityEvent] = []
    private(set) var daemons: [DaemonStat] = []
    private(set) var retryQueue: [RetryQueueItem] = []
    private(set) var retryQueueTotal = 0
    private(set) var engine: SyncEngineInfo?
    private(set) var permissions: [PermissionStatus] = []
    private(set) var bandwidth: BandwidthSummary?
    private(set) var storage: StorageInfo?
    private(set) var quotaRemainingBytes: Int64?
    private(set) var notifications: [AppNotification] = []
    private(set) var hasLoaded = false

    // Navigation & UI state
    /// Every route into a view lands here (sidebar binding, ⌘-digit, search,
    /// popover, in-view links), so the `view_shown` event is recorded once, in
    /// the setter, and callers that know *how* the user got there set
    /// `pendingNavigationSource` first (see `navigate(to:via:)`).
    var selectedView: MonitorView = .overview {
        didSet {
            // Consume the origin even when nothing changed, or a ⌘1 on the
            // view already showing would label the NEXT sidebar click.
            let via = pendingNavigationSource ?? .sidebar
            pendingNavigationSource = nil
            guard selectedView != oldValue else { return }
            record(.viewShown(selectedView, via: via))
        }
    }
    private var pendingNavigationSource: UsageEvent.NavigationSource?
    var detailAppID: String? {         // non-nil → app detail is shown
        didSet {
            guard let id = detailAppID, id != oldValue, let app = app(withID: id) else { return }
            record(.appDetailShown(app.backend))
        }
    }
    var conflictIssueID: String?      // non-nil → conflict resolution is shown
    var searchText = ""
    var notificationsPanelOpen = false

    // Pause state — honest model (see decisions note): the global flag pauses
    // BIRDWATCH'S MONITORING (macOS has no supported sync-pause API); the
    // per-app set MUTES an app's rows/notifications. Neither claims to touch
    // iCloud sync itself.
    var isGloballyPaused = false
    var pausedAppIDs: Set<String> = []

    private let source: any SyncSource
    private let now: () -> Date     // injected for deterministic debounce tests
    /// System-banner sink (title, body, id). Injected so tests can record
    /// instead of posting real user notifications.
    private let notifier: (String, String, String) -> Void
    /// Injected so plan-cap tests use a throwaway suite instead of the user's.
    private let defaults: UserDefaults
    private var lastRefresh: Date?
    private var inFlightRefresh: Task<Void, Never>?

    /// Usage analytics sink (swift-stats behind `UsageTracking`). Injected:
    /// tests record, `--mock` and keyless builds get a no-op.
    let usage: any UsageTracking
    /// Mirror of the SDK's persisted master switch, for the Diagnostics
    /// toggle. Loaded once in `loadUsagePreference()`; written through
    /// `setUsageSharing(_:)`.
    private(set) var usageSharingEnabled = true

    init(
        source: any SyncSource,
        now: @escaping () -> Date = { Date() },
        notifier: @escaping (String, String, String) -> Void = { title, body, id in
            SystemNotifier.post(title: title, body: body, id: id)
        },
        defaults: UserDefaults = .standard,
        usage: any UsageTracking = NoopUsageTracker()
    ) {
        self.source = source
        self.now = now
        self.notifier = notifier
        self.defaults = defaults
        self.usage = usage
    }

    // MARK: - Usage analytics

    /// Fire-and-forget: the SDK's `track` returns once the event is on disk,
    /// which is not something a button handler should wait for. Each record
    /// waits for the previous one so events reach the SDK — and get their
    /// `seq` — in the order they happened; unstructured Tasks alone don't
    /// promise that.
    func record(_ event: UsageEvent) {
        let previous = recordTail
        recordTail = Task { [usage] in
            await previous?.value
            await usage.track(event)
        }
    }
    private var recordTail: Task<Void, Never>?

    /// Navigation with a known origin, so `view_shown` carries `via`.
    func navigate(to view: MonitorView, via: UsageEvent.NavigationSource) {
        pendingNavigationSource = via
        navigate(to: view)
    }

    func loadUsagePreference() async {
        usageSharingEnabled = await usage.isEnabled
    }

    func setUsageSharing(_ enabled: Bool) {
        guard enabled != usageSharingEnabled else { return }
        usageSharingEnabled = enabled
        // Deliberately not tracked: opting out clears the queue, so an
        // "opted out" event could never leave the machine anyway.
        Task { [usage] in await usage.setEnabled(enabled) }
    }

    // MARK: - Derived facts (single source of truth — never recomputed in views)

    var effectiveApps: [AppSyncState] {
        apps.map { app in
            var app = app
            if isGloballyPaused {
                // Honest overlay: monitoring stopped, so every app keeps its
                // LAST KNOWN status — we never claim the app's sync is paused.
                app.statusLine = "Monitoring paused"
            }
            return app
        }
    }

    /// Per-app mute: rows stay visible but muted; sync state is untouched.
    func isMuted(appID: String) -> Bool { pausedAppIDs.contains(appID) }

    var syncingApps: [AppSyncState] { effectiveApps.filter { $0.status.isSyncing } }
    var issueCount: Int { issues.count }
    var unreadNotificationCount: Int { notifications.filter { !$0.isRead }.count }

    /// Pause-aware (single source of truth — the hero and the popover both
    /// read this; neither re-spells the paused special case).
    var overallProgress: Double {
        if isGloballyPaused { return 0 }
        let syncing = syncingApps
        guard !syncing.isEmpty else { return 1 }
        let total = syncing.reduce(0.0) { sum, app in
            if case .syncing(let p) = app.status { sum + p } else { sum }
        }
        return total / Double(syncing.count)
    }

    var inFlightTransfers: [TransferItem] { transfers.filter { !$0.isDone } }

    /// TRUE when nothing in flight carries an honest percentage, so
    /// `overallProgress` would be a fabricated mean of zeros. The live ubiquity
    /// channel reports a boolean per file (no percent exists on it at all);
    /// fixture/mock data carries real fractions. Heuristic, single source of
    /// truth for every ring/bar: ANY transfer with 0 < progress < 1 → determinate.
    var overallProgressIsIndeterminate: Bool {
        guard !isGloballyPaused else { return false }
        let inFlight = inFlightTransfers
        guard !inFlight.isEmpty else { return false }
        return !inFlight.contains { $0.progress > 0 && $0.progress < 1 }
    }

    /// Same rule scoped to one app's rows.
    func progressIsIndeterminate(appID: String) -> Bool {
        let inFlight = transfers.filter { $0.appID == appID && !$0.isDone }
        guard !inFlight.isEmpty else { return false }
        return !inFlight.contains { $0.progress > 0 && $0.progress < 1 }
    }

    /// Overall condition for headers: paused / syncing / all synced.
    enum OverallState { case paused, syncing(appCount: Int), allSynced }
    var overallState: OverallState {
        if isGloballyPaused { return .paused }
        let count = syncingApps.count
        return count > 0 ? .syncing(appCount: count) : .allSynced
    }

    func transfers(for appID: String) -> [TransferItem] {
        transfers.filter { $0.appID == appID }
    }

    // MARK: - Search (toolbar dropdown)

    struct SearchResult: Identifiable, Hashable {
        enum Target: Hashable {
            case app(id: String)
            case view(MonitorView)
        }
        let id: String
        let title: String
        let subtitle: String
        let symbolName: String
        let target: Target
    }

    /// Live results across apps, files, folders, and activity (§Interactions).
    var searchResults: [SearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }
        var results: [SearchResult] = []
        for app in effectiveApps where app.name.localizedCaseInsensitiveContains(query) {
            results.append(SearchResult(id: "app-\(app.id)", title: app.name, subtitle: app.statusLine, symbolName: "app.badge", target: .app(id: app.id)))
        }
        for t in transfers where t.name.localizedCaseInsensitiveContains(query) {
            results.append(SearchResult(id: "file-\(t.id)", title: t.name, subtitle: t.location, symbolName: "doc", target: .app(id: t.appID)))
        }
        for f in driveFolders where f.name.localizedCaseInsensitiveContains(query) {
            results.append(SearchResult(id: "folder-\(f.id)", title: f.name, subtitle: "\(f.itemCount) items", symbolName: "folder", target: .view(.drive)))
        }
        for e in activity where e.title.localizedCaseInsensitiveContains(query) || e.detail.localizedCaseInsensitiveContains(query) {
            results.append(SearchResult(id: "activity-\(e.id)", title: e.title, subtitle: e.detail, symbolName: "clock", target: .view(.activity)))
        }
        return Array(results.prefix(12))
    }

    func open(_ target: SearchResult.Target) {
        conflictIssueID = nil
        let resultKind: UsageEvent.SearchResultKind
        switch target {
        case .app: resultKind = .app
        case .view: resultKind = .view
        }
        record(.searchUsed(resultKind: resultKind, resultCount: searchResults.count))
        pendingNavigationSource = .search
        switch target {
        case .app(let id):
            selectedView = .applications
            detailAppID = id
        case .view(let view):
            detailAppID = nil
            selectedView = view
        }
        pendingNavigationSource = nil
        searchText = ""
    }

    /// Popover / external navigation to a top-level view: clears any detail
    /// route so the destination is actually visible.
    func navigate(to view: MonitorView) {
        detailAppID = nil
        conflictIssueID = nil
        selectedView = view
    }

    var pendingFileCount: Int { effectiveApps.reduce(0) { $0 + ($1.status.isSyncing ? $1.pendingItems : 0) } }

    func app(withID id: String) -> AppSyncState? {
        // Resolve from the UNFILTERED source (§7) so detail never couples to search state.
        effectiveApps.first { $0.id == id }
    }

    // MARK: - Loading (called from .task, never from init — §6)

    func refresh(force: Bool = false) async {
        // Monitoring paused → truly stop watching: no fetch, even forced.
        // hasLoaded (and all last-known data) is deliberately preserved.
        if isGloballyPaused { return }
        // Coalesce overlapping calls: joining the in-flight task prevents a
        // stale snapshot finishing late from clobbering a newer one (TOCTOU
        // across the suspension).
        // Loop, not a single join: a second generation can be spawned while we
        // were suspended on the first, and returning then would hand the caller
        // a snapshot older than the one still landing.
        while let inFlight = inFlightRefresh {
            await inFlight.value
            // Retire the generation we just joined; if a newer one registered
            // while we were suspended, the loop joins that one too.
            if inFlightRefresh == inFlight { inFlightRefresh = nil }
        }
        if !force, let last = lastRefresh, now().timeIntervalSince(last) < 60 { return }
        let task = Task { [source] in
            let snapshot = await source.currentSnapshot()
            self.apply(snapshot)
            self.lastRefresh = self.now()
            if !self.hasLoaded { self.recordSnapshotHealth() }
            self.hasLoaded = true
        }
        inFlightRefresh = task
        await task.value
        // Only deregister our own task — an overlapped forced refresh may have
        // replaced it already, and clearing that one re-opens the stale-clobber
        // race this coalescing exists to prevent.
        if inFlightRefresh == task { inFlightRefresh = nil }
    }

    /// Once per launch, after the first snapshot lands: how much of the world
    /// Birdwatch can actually see on this Mac. Counts only, bucketed.
    private func recordSnapshotHealth() {
        // `didSet` does not run for the initial value, so the launch view
        // would otherwise never count as shown.
        record(.viewShown(selectedView, via: .launch))
        var byBackend: [SyncBackend: Int] = [:]
        for app in apps { byBackend[app.backend, default: 0] += 1 }
        record(.snapshotHealth(
            appsByBackend: byBackend,
            issueCount: issues.count,
            daemonsMissing: daemons.filter { $0.pid == nil }.count,
            fdaGranted: permissions.first { $0.name.localizedCaseInsensitiveContains("Full Disk") }?.granted ?? false,
            notificationsGranted: permissions.first { $0.name.localizedCaseInsensitiveContains("Notification") }?.granted ?? false
        ))
    }

    private func apply(_ s: SyncSnapshot) {
        deriveNotifications(oldIssues: issues, newIssues: s.issues, fixtures: s.notifications)
        apps = s.apps
        transfers = s.transfers
        driveFolders = s.driveFolders
        devices = s.devices
        deviceActivity = s.deviceActivity
        issues = s.issues
        activity = s.activity
        daemons = s.daemons
        // Rows the user has already trashed must not come back on a snapshot
        // that was ALREADY IN FLIGHT when they did it. On this machine a single
        // `currentSnapshot()` takes ~26s (brctl status times out at 10s every
        // cycle), so there is essentially always one in flight, and it carries a
        // retry queue collected before the folder moved. Filtering here — at the
        // one place every snapshot lands — is what makes the row stay gone.
        let incoming = Set(s.retryQueue.map(\.id))
        // Prune first: once a snapshot stops listing an id, bird has re-scanned
        // and agrees it is gone, so the override has done its job. Keeping it
        // would hide a genuinely new retry that reuses the id.
        forgottenRetryIDs.formIntersection(incoming)
        retryQueue = s.retryQueue.filter { !forgottenRetryIDs.contains($0.id) }
        retryQueueTotal = max(
            max(s.retryQueueTotal, s.retryQueue.count) - forgottenRetryIDs.count,
            retryQueue.count
        )
        engine = s.engine
        permissions = s.permissions
        bandwidth = s.bandwidth
        rawStorage = s.storage
        storage = Self.applyPlanCap(planCapOverride, to: s.storage)
        quotaRemainingBytes = s.quotaRemainingBytes
    }

    // MARK: - iCloud plan cap (user preference beats the derived guess)

    /// UserDefaults keys. The derived cap is only a floor (local footprint +
    /// remaining quota), so the user's own answer always wins.
    nonisolated static let planCapDefaultsKey = "bw_plan_cap_bytes"
    nonisolated static let planConfirmedDefaultsKey = "bw_plan_cap_confirmed"

    /// The snapshot's storage before the override is folded in — kept so
    /// clearing the override restores the derived cap without a refresh.
    private var rawStorage: StorageInfo?

    /// User-chosen plan cap in bytes, or nil when they haven't chosen one.
    var planCapOverride: Int64? {
        let value = defaults.object(forKey: Self.planCapDefaultsKey) as? NSNumber
        return value.map(\.int64Value).flatMap { $0 > 0 ? $0 : nil }
    }

    /// TRUE once the user has answered (or dismissed) the plan question.
    var planCapConfirmed: Bool {
        get { defaults.bool(forKey: Self.planConfirmedDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.planConfirmedDefaultsKey)
            planPreferenceVersion &+= 1
        }
    }

    /// Bumped on every plan-preference write so @Observable views re-render
    /// (UserDefaults itself is not observed).
    private(set) var planPreferenceVersion = 0

    /// Persists (or clears, with nil) the user's plan cap and re-applies it to
    /// the current snapshot immediately.
    func setPlanCap(_ bytes: Int64?) {
        if let bytes, bytes > 0 {
            defaults.set(NSNumber(value: bytes), forKey: Self.planCapDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.planCapDefaultsKey)
        }
        planCapConfirmed = true
        storage = Self.applyPlanCap(planCapOverride, to: rawStorage)
        record(.planCapSet(cleared: planCapOverride == nil))
    }

    /// Pure overlay: a user-chosen cap replaces the derived one, keeping the
    /// measured segments untouched. The account tier is recomputed against the
    /// new cap, since account usage IS cap − remaining.
    nonisolated static func applyPlanCap(_ override: Int64?, to info: StorageInfo?) -> StorageInfo? {
        guard let info else { return nil }
        guard let override, override > 0 else { return info }
        let account = StorageBreakdownSource.accountUsed(
            capBytes: override, remainingBytes: info.remainingBytes
        )
        return StorageInfo(
            totalBytes: override,
            segments: info.segments,
            planName: StorageBreakdownSource.planName(forCap: override),
            planPriceLine: "Set by you",
            capSource: .userChosen,
            remainingBytes: info.remainingBytes,
            accountUsedBytes: account?.bytes,
            isAccountUsedClamped: account?.isClamped ?? false
        )
    }

    /// In-app notifications derive from issue arrivals; fixture sources (mock)
    /// supply theirs directly.
    ///
    /// An issue "arrives" when its id is absent from the PREVIOUS issue list,
    /// so an issue that resolves and later recurs (conflict/quota ids are
    /// stable by design) notifies again: any prior notification with the same
    /// id is REPLACED by a fresh unread one at the top of the list.
    ///
    /// Each arrival also posts a system banner, EXCEPT when the issue is
    /// attributable to an app (`IssueItem.appID` non-nil) that the user has
    /// muted — muted apps still get the in-app row, just no banner.
    private func deriveNotifications(oldIssues: [IssueItem], newIssues: [IssueItem], fixtures: [AppNotification]) {
        guard fixtures.isEmpty else {
            notifications = fixtures
            return
        }
        let known = Set(oldIssues.map(\.id))
        let arrived = newIssues.filter { !known.contains($0.id) && hasLoaded }
        guard !arrived.isEmpty else { return }
        let fresh = arrived.map { issue in
            (issue: issue, notification: AppNotification(
                id: "notif-\(issue.id)", severity: issue.severity,
                title: issue.title, detail: issue.meta, date: now(), isRead: false
            ))
        }
        // Recurrence: drop any stale entry for these ids, then prepend the
        // fresh unread ones (never two rows for one issue id).
        let arrivingIDs = Set(fresh.map(\.notification.id))
        let retained = notifications.filter { !arrivingIDs.contains($0.id) }
        notifications = Array((fresh.map(\.notification) + retained).prefix(50))
        for entry in fresh {
            if let appID = entry.issue.appID, isMuted(appID: appID) { continue }
            notifier(entry.notification.title, entry.notification.detail, entry.notification.id)
        }
    }

    // MARK: - Actions

    func togglePauseAll() {
        isGloballyPaused.toggle()
        record(isGloballyPaused ? .monitoringPaused : .monitoringResumed)
    }

    /// Mute/unmute an app (popover quick action). Does not touch sync.
    func toggleMute(appID: String) {
        let muted: Bool
        if pausedAppIDs.contains(appID) { pausedAppIDs.remove(appID); muted = false } else { pausedAppIDs.insert(appID); muted = true }
        if let backend = app(withID: appID)?.backend { record(.appMuted(backend, muted: muted)) }
    }

    func dismissIssue(id: String) {
        if let issue = issues.first(where: { $0.id == id }) { record(.issueDismissed(severity: issue.severity)) }
        issues.removeAll { $0.id == id }
    }

    /// Resolves the conflict at the source (real file ops for the system
    /// source; no-op for fixtures), then removes the issue and closes the
    /// screen — any choice resolves and returns.
    func resolveConflict(issueID: String, keepVersionID: String = ConflictSource.currentVersionID) async {
        await source.resolveConflict(issueID: issueID, keepVersionID: keepVersionID)
        record(.conflictResolved(keptCurrent: keepVersionID == ConflictSource.currentVersionID))
        issues.removeAll { $0.id == issueID }
        conflictIssueID = nil
    }

    /// What a "Move to Trash" on a retry row actually did. Carries the name so
    /// the view never has to hold the row it just removed, and — on success —
    /// where the item actually landed. That is not cosmetic: items inside
    /// `~/Library/Mobile Documents` go to iCloud Drive's OWN trash
    /// (`~/Library/Mobile Documents/.Trash/…`), not `~/.Trash`, so a bare
    /// "it's in the Trash" sends the user looking in the wrong place.
    enum TrashOutcome: Equatable {
        case moved(name: String, destination: String?)
        case failed(name: String, reason: String)
    }

    /// Ids of rows whose file this session moved to the Trash. Consulted by
    /// `apply` so no snapshot — in-flight, cached or fresh — can resurrect them.
    private var forgottenRetryIDs: Set<String> = []

    /// The source-forget + refresh started by the last successful trash.
    /// Deliberately NOT awaited by the UI (see `trashRetryQueueItem`); exposed
    /// so tests can join it instead of racing it.
    private(set) var pendingRetryRefresh: Task<Void, Never>?

    /// Moves a retry-queue item's file to the Trash and, ONLY on success, drops
    /// the row.
    ///
    /// The whole operation lives here rather than in the view because the order
    /// is the contract: trash first, then forget at the source, then refresh.
    /// A failure must leave the row exactly where it is — the file is still
    /// there, and a row that vanishes anyway is a lie about a delete that did
    /// not happen.
    ///
    /// `trash` is injected so the ordering and the failure path are testable
    /// without touching a real file. It returns where the item landed.
    ///
    /// THE BUG THIS SHAPE FIXES (measured live, 2026-08-15): this used to
    /// `await refresh(force: true)` before returning. `refresh` joins whatever
    /// snapshot is in flight and then runs its own, and on a real account each
    /// snapshot takes ~26 SECONDS (`brctl status` hits its 10s timeout every
    /// cycle — see the log). So the outcome — the green line, the failure
    /// reason, everything the user gets told — did not appear for the better
    /// part of a minute, and the stale in-flight snapshot re-applied a retry
    /// queue that still contained the row. From the outside: nothing happened,
    /// and nothing was said. The file HAD moved the whole time.
    func trashRetryQueueItem(
        _ item: RetryQueueItem,
        trash: (String) throws -> String = { try FileTrasher.trash(path: $0) }
    ) async -> TrashOutcome {
        guard let absolute = item.absolutePath else {
            record(.retryItemTrashed(outcome: .failed))
            return .failed(name: item.name, reason: "Birdwatch has no resolved location for this item")
        }
        let destination: String
        do {
            destination = try trash(absolute)
        } catch {
            record(.retryItemTrashed(outcome: .failed))
            return .failed(name: item.name, reason: FileTrasher.plainReason(for: error))
        }
        record(.retryItemTrashed(outcome: .ok))
        // Synchronous, MainActor-only, no I/O: the row goes and the caller can
        // report the outcome in the same turn the user clicked.
        removeRetryQueueItem(id: item.id)
        // Everything slow happens after the answer. Telling the source to
        // forget the id also clears its dump TTL, so the refresh collects
        // bird's own updated view rather than the cached one.
        pendingRetryRefresh = Task { [source] in
            await source.forgetRetryQueueItem(id: item.id)
            await refresh(force: true)
        }
        return .moved(name: item.name, destination: destination.isEmpty ? nil : destination)
    }

    /// Removes a retry-queue row whose file was just moved to the Trash, and
    /// remembers the id so no snapshot can put it back (see `apply`).
    func removeRetryQueueItem(id: String) {
        forgottenRetryIDs.insert(id)
        retryQueue.removeAll { $0.id == id }
        retryQueueTotal = max(retryQueue.count, retryQueueTotal - 1)
    }

    func markAllNotificationsRead() {
        if notifications.contains(where: { !$0.isRead }) { record(.notificationsMarkedRead) }
        notifications = notifications.map { n in
            var n = n
            n.isRead = true
            return n
        }
    }

    func logStream(appID: String) -> AsyncStream<LogLine> {
        source.logStream(appID: appID)
    }

    func conflictDetail(issueID: String) async -> ConflictDetail? {
        await source.conflictDetail(issueID: issueID)
    }
}
