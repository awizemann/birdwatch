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
    private(set) var apps: [AppSyncState] = [] {
        didSet { recomputeEffectiveApps() }
    }
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
    // Scan evidence (see SyncSnapshot): lets a screen say "still scanning",
    // "results from 12 min ago" or "couldn't tell" instead of an empty list.
    private(set) var cloudKitScan: CloudKitScanState?
    private(set) var folderScan: ScanFreshness?
    private(set) var containerScan: ScanFreshness?
    /// The conflict scan's item cap when the last scan stopped at it.
    private(set) var conflictScanCap: Int?
    /// The transfer watcher has finished its first sweep, so an empty
    /// transfer list means "nothing transferring", not "not looked yet".
    private(set) var transferWatchReady = false
    /// Issue producers that have delivered a successful result (see
    /// `SyncSnapshot.issueProducers`); nil for a fixture source, which
    /// delivers everything at once.
    private(set) var deliveredIssueProducers: Set<IssueProducer>?
    // Per-snapshot indeterminate decisions, computed once in `apply` so a row
    // is a set lookup instead of a scan over every transfer.
    private var indeterminateAppIDs: Set<String> = []
    private var indeterminateFolderNames: Set<String> = []

    /// Monitoring was paused before the first snapshot ever landed: nothing is
    /// loading and nothing will until monitoring resumes. Distinct from
    /// `!hasLoaded` alone — a spinner here would claim work that is not
    /// happening (C1), so the UI must say "paused" instead.
    var isPausedBeforeFirstLoad: Bool { isGloballyPaused && !hasLoaded }

    /// The refresh a resume kicks off when nothing has ever loaded. Exposed so
    /// tests can await it deterministically instead of sleeping (C8).
    private(set) var pendingResumeRefresh: Task<Void, Never>?

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
    var isGloballyPaused = false {
        didSet { recomputeEffectiveApps() }
    }
    var pausedAppIDs: Set<String> = []

    private let source: any SyncSource
    private let now: () -> Date     // injected for deterministic debounce tests
    /// System-banner sink (title, body, id). Deliberately NOT defaulted: every
    /// construction says where banners go, so a test cannot post a real user
    /// notification by forgetting an argument. The app passes `SystemNotifier`.
    private let notifier: (String, String, String) -> Void
    /// Injected so plan-cap tests use a throwaway suite instead of the user's.
    private let defaults: UserDefaults
    /// When the last snapshot landed — the age every "Updated … ago" shows.
    private(set) var lastRefresh: Date?
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
        notifier: @escaping (String, String, String) -> Void,
        defaults: UserDefaults = .standard,
        usage: any UsageTracking = NoopUsageTracker(),
        setTransferWatching: @escaping @MainActor (Bool) -> Void = { _ in },
        isMainWindowVisible: @escaping @MainActor () -> Bool = { false }
    ) {
        self.source = source
        self.now = now
        self.notifier = notifier
        self.defaults = defaults
        self.usage = usage
        self.setTransferWatching = setTransferWatching
        self.isMainWindowVisible = isMainWindowVisible
    }

    /// Drives the FSEvents transfer watcher (true = watch). The app passes a
    /// closure posting UbiquityTransferSource's pause/resume requests; the
    /// default is inert so stores built in tests never signal app-wide.
    private let setTransferWatching: @MainActor (Bool) -> Void
    /// Whether the main window is on screen (the app checks NSApp.windows).
    private let isMainWindowVisible: @MainActor () -> Bool
    /// Set by the menu-bar popover while it is open — the other surface that
    /// shows transfers. Not UI state, so not observed.
    @ObservationIgnored var isMenuBarPopoverOpen = false

    /// Runs or stops the transfer watcher per `TransferWatchPolicy.shouldWatch`.
    /// Called on pause/resume, after every fetch, and by the surfaces when
    /// they open, close, minimise or restore.
    /// - Parameter mainWindowOnScreen: what the caller knows for certain
    ///   (the window's own appear/disappear), when NSApp.windows may not have
    ///   caught up yet; nil asks `isMainWindowVisible`.
    func syncTransferWatcher(mainWindowOnScreen: Bool? = nil) {
        setTransferWatching(TransferWatchPolicy.shouldWatch(
            monitoringPaused: isGloballyPaused,
            mainWindowOnScreen: mainWindowOnScreen ?? isMainWindowVisible(),
            popoverOpen: isMenuBarPopoverOpen
        ))
    }

    // MARK: - Usage analytics

    /// Synchronous hand-off (swift-stats `record()` is ordered and never
    /// suspends), so a button handler never waits on the analytics queue.
    func record(_ event: UsageEvent) {
        usage.record(event)
    }

    /// A person activated the app (NSApplication didBecomeActive, driven by
    /// `UsageLifecycle`). Starts or continues the session — idempotent within
    /// one — and releases the launch events if the first snapshot is in.
    /// Coming back to the app is when a Full Disk Access grant made in System
    /// Settings lands, so the cached permission answers are dropped too: the
    /// next snapshot (the activation refresh or the next 15 s tick) re-probes.
    func applicationDidBecomeActive() async {
        await reprobePermissions()
        await usage.applicationDidBecomeActive()
        hasActivated = true
        recordLaunchEventsIfDue()
    }

    /// The popover can open without the app ever becoming active, so opening
    /// it is itself the "a person is here" signal: activate first, then record
    /// the open, so `menubar_opened` lands in a session that has its `app_open`.
    func menuBarOpened() async {
        await applicationDidBecomeActive()
        record(.menubarOpened(issueCount: issueCount, paused: isGloballyPaused))
    }

    /// The launch events (`view_shown` via launch + `snapshot_health`) are
    /// HELD until a person is actually here. Recording them at the first
    /// snapshot opened a session on every unattended login-item launch —
    /// swift-stats starts a session on any captured event.
    private var hasActivated = false
    /// Set once, when the first snapshot lands; cleared when the events go.
    private var launchEventsDue = false

    private func recordLaunchEventsIfDue() {
        guard hasActivated, launchEventsDue else { return }
        launchEventsDue = false
        recordSnapshotHealth()
    }

    /// Navigation with a known origin, so `view_shown` carries `via`.
    func navigate(to view: MonitorView, via: UsageEvent.NavigationSource) {
        pendingNavigationSource = via
        navigate(to: view)
    }

    /// FALSE when analytics is gated off for this launch (no write key,
    /// `--mock`, tests): there is nothing to opt out of, so the toggle is
    /// disabled rather than flipping and silently reverting.
    var usageSharingAvailable: Bool { usage.isConfigured }

    /// Bumped by every user flip. A load that started before a flip must not
    /// overwrite it with the value it read before the flip landed.
    private var usagePreferenceGeneration = 0

    func loadUsagePreference() async {
        let generation = usagePreferenceGeneration
        let enabled = await usage.isEnabled
        guard generation == usagePreferenceGeneration else { return }
        usageSharingEnabled = enabled
    }

    func setUsageSharing(_ enabled: Bool) {
        guard usageSharingAvailable, enabled != usageSharingEnabled else { return }
        usagePreferenceGeneration &+= 1
        usageSharingEnabled = enabled
        // Deliberately not tracked: opting out clears the queue, so an
        // "opted out" event could never leave the machine anyway.
        Task { [usage] in await usage.setEnabled(enabled) }
    }

    // MARK: - Derived facts (single source of truth — never recomputed in views)

    /// The apps as screens show them: CloudKit activity aged against the
    /// clock and the paused overlay applied. Stored, not computed — every
    /// derived fact below and several views read it, and rebuilding it per
    /// read cost 6–7 passes per body. Recomputed when `apps` or the pause
    /// flag changes, and on the freshness tick (`reageApps(now:)`).
    private(set) var effectiveApps: [AppSyncState] = []

    private func recomputeEffectiveApps(now date: Date? = nil) {
        let next = Self.effectiveApps(apps, paused: isGloballyPaused, now: date ?? self.now())
        if next != effectiveApps { effectiveApps = next }
    }

    /// Called on the 15 s freshness tick that Overview and the popover
    /// already run: a CloudKit `.active` row ages out while a surface stays
    /// open, not only when the next snapshot lands.
    func reageApps(now date: Date) { recomputeEffectiveApps(now: date) }

    static func effectiveApps(_ apps: [AppSyncState], paused: Bool, now date: Date) -> [AppSyncState] {
        apps.map { app in
            var app = agingCloudKitActivity(app, now: date)
            if paused {
                // Honest overlay: monitoring stopped, so every app keeps its
                // LAST KNOWN status — we never claim the app's sync is paused.
                app.statusLine = "Monitoring paused"
            }
            return app
        }
    }

    /// A CloudKit `.active` row is evidence from a log scan that can be ~5 min
    /// old, about activity up to 5 min before that. Once its last activity is
    /// older than the parser's own activity window, "active" is no longer
    /// what the evidence says — it reads as idle (with its real age shown
    /// beside it), never as a stale "Transferring" for ten minutes (C1).
    static func agingCloudKitActivity(_ app: AppSyncState, now: Date) -> AppSyncState {
        guard app.backend == .cloudKit, app.status == .active else { return app }
        if let last = app.lastActivity, now.timeIntervalSince(last) <= CloudKitLogParser.activeWindow { return app }
        var aged = app
        aged.status = .upToDate
        aged.statusLine = CloudKitAppMapping.statusLine(state: .idle, lastActivity: app.lastActivity, now: now)
        return aged
    }

    /// Per-app mute: rows stay visible but muted; sync state is untouched.
    func isMuted(appID: String) -> Bool { pausedAppIDs.contains(appID) }

    var syncingApps: [AppSyncState] { effectiveApps.filter { $0.status.isSyncing } }
    /// Every app doing work — with progress (`.syncing`) or without (`.active`).
    /// What "Active apps", the transfers card and the popover list count.
    var activeApps: [AppSyncState] { effectiveApps.filter { $0.status.isActive } }
    /// Apps whose sync state has not been read yet — neutral, neither idle
    /// nor an issue (the hero's idle claim names them). Rows Birdwatch is
    /// deliberately not watching (no Full Disk Access) are counted apart.
    /// File Provider rows are counted apart too (`unreportedAppCount`):
    /// "not read yet" would promise a read that never comes.
    var unknownStateAppCount: Int {
        effectiveApps.filter { UnknownRowKind(of: $0) == .notReadYet }.count
    }
    /// Rows whose sync status macOS never reports to Birdwatch (File
    /// Provider): unknown for good, not pending.
    var unreportedAppCount: Int {
        effectiveApps.filter { UnknownRowKind(of: $0) == .notReported }.count
    }
    /// Rows not watched because Full Disk Access is missing.
    var unwatchedApps: [AppSyncState] { effectiveApps.filter(\.needsFullDiskAccess) }

    /// Full Disk Access as the permissions probe last saw it (nil: not probed).
    var fullDiskAccess: PermissionState? {
        permissions.first { $0.name.localizedCaseInsensitiveContains("Full Disk") }?.state
    }
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
        return TransferItem.progressIsIndeterminate(inFlightTransfers)
    }

    /// Same rule scoped to one app's rows (precomputed per snapshot).
    func progressIsIndeterminate(appID: String) -> Bool {
        indeterminateAppIDs.contains(appID)
    }

    /// Same rule scoped to one iCloud Drive folder's rows (the folder's
    /// status comes from the same transfers, by the same location rule).
    func progressIsIndeterminate(folderName: String) -> Bool {
        indeterminateFolderNames.contains(folderName)
    }

    /// The per-app and per-folder indeterminate sets for one transfer list.
    static func indeterminateGroups(_ transfers: [TransferItem]) -> (appIDs: Set<String>, folderNames: Set<String>) {
        let inFlight = transfers.filter { !$0.isDone }
        let byApp = Dictionary(grouping: inFlight, by: \.appID)
        let byFolder = Dictionary(grouping: inFlight.compactMap { t in
            DriveFolder.folderName(containing: t.location).map { ($0, t) }
        }, by: \.0).mapValues { $0.map(\.1) }
        return (
            Set(byApp.filter { TransferItem.progressIsIndeterminate($0.value) }.keys),
            Set(byFolder.filter { TransferItem.progressIsIndeterminate($0.value) }.keys)
        )
    }

    /// Overall condition for headers. `.active`: no file is transferring, but
    /// some apps report work without any progress (CloudKit). `.idle` is only
    /// "nothing detected" — Birdwatch cannot prove every app is synced.
    /// `.syncing` carries the apps with no progress too (`alsoActive`), so
    /// every header counts the same apps as the "Active apps" tile and the
    /// popover list: "Syncing 1 app · activity in 2 more".
    enum OverallState: Equatable {
        case paused, syncing(appCount: Int, alsoActive: Int = 0), active(appCount: Int), idle
    }
    var overallState: OverallState {
        if isGloballyPaused { return .paused }
        let count = syncingApps.count
        let active = effectiveApps.filter { $0.status == .active }.count
        if count > 0 { return .syncing(appCount: count, alsoActive: active) }
        return active > 0 ? .active(appCount: active) : .idle
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
            results.append(SearchResult(id: "folder-\(f.id)", title: f.name, subtitle: f.itemCountText, symbolName: "folder", target: .view(.drive)))
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

    var pendingFileCount: Int { effectiveApps.reduce(0) { $0 + ($1.status.isSyncing ? ($1.pendingItems ?? 0) : 0) } }

    func app(withID id: String) -> AppSyncState? {
        // Resolve from the UNFILTERED source (§7) so detail never couples to search state.
        effectiveApps.first { $0.id == id }
    }

    // MARK: - Loading (called from .task, never from init — §6)

    /// Drops the source's cached permission answers so the next snapshot
    /// probes them afresh (see `SyncSource.invalidatePermissions`). No fetch
    /// of its own.
    func reprobePermissions() async {
        await source.invalidatePermissions()
    }

    /// `reprobePermissions`: a grant may just have changed (⌘R is what
    /// someone presses right after granting access), so the source's cached
    /// permission answers are dropped first. NOT implied by `force` — the
    /// window's 15 s tick forces every refresh, and re-probing on each would
    /// defeat the cache. Dropped even when paused or debounced, so the next
    /// snapshot that does run sees the new answer.
    func refresh(force: Bool = false, reprobePermissions reprobe: Bool = false) async {
        if reprobe { await reprobePermissions() }
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
            self.fetchGeneration += 1
            let generation = self.fetchGeneration
            let snapshot = await source.currentSnapshot()
            // The source creates and STARTS the watcher on its first snapshot,
            // whatever the policy says — and monitoring or a surface may have
            // changed while this fetch was in flight. Re-apply the policy
            // after every fetch (pause/resume are idempotent).
            self.syncTransferWatcher()
            self.apply(snapshot, fetchedAt: generation)
            self.lastRefresh = self.now()
            if !self.hasLoaded {
                self.launchEventsDue = true
                self.recordLaunchEventsIfDue()
            }
            self.hasLoaded = true
        }
        inFlightRefresh = task
        await task.value
        // Only deregister our own task — an overlapped forced refresh may have
        // replaced it already, and clearing that one re-opens the stale-clobber
        // race this coalescing exists to prevent.
        if inFlightRefresh == task { inFlightRefresh = nil }
    }

    /// Once per launch, once the first snapshot has landed AND the app has
    /// been activated (whichever comes second): how much of the world
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
            // Booleans by design: a permission the probe can't tell (`.unknown`) counts as false.
            fdaGranted: fullDiskAccess == .granted,
            notificationsGranted: permissions.first { $0.name.localizedCaseInsensitiveContains("Notification") }?.granted ?? false
        ))
    }

    private func apply(_ s: SyncSnapshot, fetchedAt generation: Int) {
        // Presence is tracked on what the SOURCE reports, before suppression.
        let arrivedIDs = recentIssueIDs.observe(Set(s.issues.map(\.id)))
        // A dismissed id is released once the source has stopped reporting
        // it for the whole absence window (same rule as an arrival), so a
        // genuine recurrence shows again but a one-cycle blip does not.
        dismissedIssueIDs = dismissedIssueIDs.filter(recentIssueIDs.contains)
        // A resolved id is hidden only from snapshots whose fetch began before
        // the resolve finished; later ones come from a source that already
        // dropped it, so a listing there is a real (re)occurrence.
        resolvedAtGeneration = resolvedAtGeneration.filter { $0.value >= generation }
        let visibleIssues = s.issues.filter {
            !dismissedIssueIDs.contains($0.id) && resolvedAtGeneration[$0.id] == nil
        }
        deriveNotifications(
            arrivals: visibleIssues.filter { arrivedIDs.contains($0.id) },
            baseline: absorbFirstDeliveries(s),
            fixtures: s.notifications
        )
        apps = s.apps
        transfers = s.transfers
        driveFolders = s.driveFolders
        devices = s.devices
        deviceActivity = s.deviceActivity
        issues = visibleIssues
        activity = s.activity
        daemons = s.daemons
        // Rows the user has already trashed must not come back on a snapshot
        // that was ALREADY IN FLIGHT when they did it. A snapshot can take
        // seconds (system scans are time-boxed at 5s each) and it serves the
        // cached dump, so it can carry a retry queue collected before the
        // folder moved. Filtering here — at the
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
        cloudKitScan = s.cloudKitScan
        folderScan = s.folderScan
        containerScan = s.containerScan
        conflictScanCap = s.conflictScanCap
        transferWatchReady = s.transferWatchReady
        deliveredIssueProducers = s.issueProducers.map { Set($0.keys) }
        (indeterminateAppIDs, indeterminateFolderNames) = Self.indeterminateGroups(s.transfers)
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
            planCapBelowRemaining: account == .capBelowRemaining,
            planIsAmbiguous: false
        )
    }

    // MARK: - Issue arrivals and suppression

    /// Ids the source reported recently — the memory arrivals are judged by.
    private var recentIssueIDs = RecentIssueIDs()
    /// Ids the user dismissed. The source keeps reporting a dismissed issue,
    /// so it is filtered out of every snapshot in `apply` until the source
    /// stops reporting it — the same pattern as `forgottenRetryIDs`.
    private var dismissedIssueIDs: Set<String> = []
    /// Resolved conflict id → the `fetchGeneration` current when the resolve
    /// finished. Only snapshots fetched at or before that generation can
    /// still carry it (they started before the source dropped it); anything
    /// later is authoritative, so the source's own pruning decides — a store
    /// rule here would hide a genuine quick recurrence.
    private var resolvedAtGeneration: [String: Int] = [:]
    /// Bumped as each snapshot fetch starts.
    private var fetchGeneration = 0
    /// Issue producers whose first successful delivery has been absorbed.
    private var baselinedProducers: Set<IssueProducer> = []

    /// Per-producer launch baseline. Returns the ids a producer delivered on
    /// its FIRST successful result — those existed before Birdwatch looked,
    /// so they are listed without a banner, whenever that result lands.
    /// Producers already baselined banner normally, so a slow or failing
    /// producer can never hold back another's alerts.
    ///
    /// Ids no listed producer claims form an implicit `.unclaimed` producer
    /// (always delivered), so they cannot bypass the baseline.
    ///
    /// A producer that STOPS delivering (its stale result aged out, its
    /// tool started failing) loses its baseline: Birdwatch could not see
    /// meanwhile, so what it reports on recovery is a fresh baseline, not a
    /// burst of "new" banners for things that may have been there all along.
    /// The cost: an issue that first appears exactly on a recovery is listed
    /// without a banner.
    private func absorbFirstDeliveries(_ s: SyncSnapshot) -> Set<String> {
        var delivered = s.issueProducers ?? [.fixture: Set(s.issues.map(\.id))]
        if s.issueProducers != nil {
            let claimed = delivered.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            delivered[.unclaimed] = Set(s.issues.map(\.id)).subtracting(claimed)
        }
        baselinedProducers.formIntersection(delivered.keys)
        var baseline: Set<String> = []
        for (producer, ids) in delivered where !baselinedProducers.contains(producer) {
            baselinedProducers.insert(producer)
            baseline.formUnion(ids)
        }
        return baseline
    }

    /// In-app notifications derive from issue arrivals; fixture sources (mock)
    /// supply theirs directly.
    ///
    /// An issue "arrives" when the source has not reported its id recently
    /// (`RecentIssueIDs`): an issue that resolves and later recurs
    /// (conflict/quota ids are stable by design) notifies again, and any prior
    /// notification with the same id is REPLACED by a fresh unread one at the
    /// top of the list. One that drops out for a cycle or two does not, and
    /// neither does a producer's launch baseline (`absorbFirstDeliveries`).
    ///
    /// Each arrival also posts a system banner, EXCEPT when the issue is
    /// attributable to an app (`IssueItem.appID` non-nil) that the user has
    /// muted — muted apps still get the in-app row, just no banner.
    private func deriveNotifications(arrivals: [IssueItem], baseline: Set<String>, fixtures: [AppNotification]) {
        guard fixtures.isEmpty else {
            notifications = fixtures
            return
        }
        let arrived = arrivals.filter { !baseline.contains($0.id) }
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
        // Pausing must stop the FSEvents watcher + probe ticker too, not just
        // the refresh loop (the Overview footnote promises it). Resuming
        // brings it back only if a surface is on screen; otherwise the next
        // one to appear does. (The live log console stops on its own: it keys
        // its task on `isGloballyPaused`.)
        syncTransferWatcher()
        // Audit P3: monitoring paused BEFORE the first snapshot ever landed
        // leaves `hasLoaded` false, and nothing else fetches again — the
        // window's `.task` already ran, so resuming from the toolbar left the
        // loading state stuck forever. Resume is the trigger in that one case.
        // Not on every resume: an already-loaded store keeps its debounce and
        // whatever refresh the caller chooses to run.
        if !isGloballyPaused && !hasLoaded {
            pendingResumeRefresh = Task { [weak self] in
                await self?.refresh(force: true)
            }
        }
    }

    /// Mute/unmute an app (popover quick action). Does not touch sync.
    func toggleMute(appID: String) {
        let muted: Bool
        if pausedAppIDs.contains(appID) { pausedAppIDs.remove(appID); muted = false } else { pausedAppIDs.insert(appID); muted = true }
        if let backend = app(withID: appID)?.backend { record(.appMuted(backend, muted: muted)) }
    }

    func dismissIssue(id: String) {
        if let issue = issues.first(where: { $0.id == id }) { record(.issueDismissed(severity: issue.severity)) }
        dismissedIssueIDs.insert(id)
        issues.removeAll { $0.id == id }
    }

    /// True while a conflict resolution is running. The resolution screen
    /// disables its Keep buttons on it, and a second call is refused, so one
    /// conflict can never be resolved twice concurrently.
    private(set) var isResolvingConflict = false

    /// Resolves the conflict at the source (real file ops for the system
    /// source; trivially succeeds for fixtures). `shownVersionIDs` are the
    /// versions on the user's screen — the source refuses (`.changed`) to
    /// remove any version outside them.
    ///
    /// - `.resolved`: record, remove the row, close the screen — the screen
    ///   only if it still shows THIS conflict (the user may have moved on).
    /// - `.notFound`: the source no longer has it; remove the row so Review
    ///   cannot loop on it until the next snapshot. Nothing is recorded.
    /// - `.failed` / `.changed`: the conflict is still open and the row stays.
    ///   If the user already left its screen, nobody would see the outcome,
    ///   so it is noted in the notifications panel (no banner: it is the
    ///   answer to the user's own click, not a new problem).
    /// - `.busy`: another resolve was running; this one was ignored.
    @discardableResult
    func resolveConflict(
        issueID: String, keepVersionID: String, shownVersionIDs: Set<String>
    ) async -> ConflictResolveResult {
        guard !isResolvingConflict else { return .busy }
        isResolvingConflict = true
        defer { isResolvingConflict = false }
        let issue = issues.first { $0.id == issueID }
        let result = await source.resolveConflict(
            issueID: issueID, keepVersionID: keepVersionID, shownVersionIDs: shownVersionIDs
        )
        switch result {
        case .resolved, .notFound:
            if result == .resolved {
                record(.conflictResolved(keptCurrent: keepVersionID == ConflictSource.currentVersionID))
            }
            resolvedAtGeneration[issueID] = fetchGeneration
            issues.removeAll { $0.id == issueID }
            if result == .resolved, conflictIssueID == issueID { conflictIssueID = nil }
        case .failed, .changed:
            if conflictIssueID != issueID { noteUnseenResolveOutcome(result, issueID: issueID, issue: issue) }
        case .busy:
            break
        }
        return result
    }

    /// An in-panel line (unread, no banner) for a resolve outcome the user
    /// was no longer on screen to see. One row per conflict, replaced.
    private func noteUnseenResolveOutcome(_ result: ConflictResolveResult, issueID: String, issue: IssueItem?) {
        let title = result == .changed
            ? "Conflict not resolved: a new version arrived"
            : "Couldn't resolve a sync conflict"
        let id = "notif-unresolved-\(issueID)"
        let note = AppNotification(
            id: id, severity: .conflict, title: title,
            detail: issue?.meta ?? "It is still listed in Issues.", date: now(), isRead: false
        )
        notifications = Array(([note] + notifications.filter { $0.id != id }).prefix(50))
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
    /// snapshot took ~26 SECONDS (`brctl status` then ran on the snapshot path
    /// and hit its 10s timeout every cycle; it no longer does). So the outcome — the green line, the failure
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

    func logStream(appID: String, backend: SyncBackend) -> AsyncThrowingStream<LogLine, any Error> {
        source.logStream(appID: appID, backend: backend)
    }

    func conflictDetail(issueID: String) async -> ConflictDetail? {
        await source.conflictDetail(issueID: issueID)
    }
}

/// Which issue ids the source reported recently, for arrival detection.
///
/// An id is forgotten only after it has been missing from
/// `absenceThreshold` CONSECUTIVE snapshots. Sources drop issues for a
/// cycle when one call fails (a single failed `brctl` quota read removes
/// the low-quota issue), and judging arrivals against only the previous
/// snapshot turned every such blip into a fresh unread notification and a
/// banner. The issue LIST still shows the blip — Birdwatch never invents a
/// value to paper over it (C1); only the alert waits.
nonisolated struct RecentIssueIDs: Sendable {
    static let absenceThreshold = 3

    /// id → consecutive snapshots it has been missing (0 = present now).
    private var missedSnapshots: [String: Int] = [:]

    func contains(_ id: String) -> Bool { missedSnapshots[id] != nil }

    /// Folds one snapshot's ids in and returns the ones not seen recently.
    mutating func observe(_ present: Set<String>) -> Set<String> {
        let arrivals = present.filter { missedSnapshots[$0] == nil }
        var next: [String: Int] = [:]
        for (id, missed) in missedSnapshots where !present.contains(id) && missed + 1 < Self.absenceThreshold {
            next[id] = missed + 1
        }
        for id in present { next[id] = 0 }
        missedSnapshots = next
        return arrivals
    }
}
