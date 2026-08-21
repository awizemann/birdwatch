import Testing
@testable import Birdwatch
import Foundation

// MARK: - Test doubles

/// Minimal fixture-proof source: holds an injected snapshot and counts calls,
/// so tests state their own data and can assert the fetch contract directly.
final class StubSyncSource: SyncSource, @unchecked Sendable {
    // Synchronization: tests drive the store on the MainActor serially; the
    // stub is never touched concurrently.
    var snapshot: SyncSnapshot
    private(set) var snapshotCallCount = 0
    /// Every resolveConflict forwarded by the store, in order: (issueID, keepVersionID).
    private(set) var resolvedCalls: [(String, String)] = []

    init(snapshot: SyncSnapshot) { self.snapshot = snapshot }

    func currentSnapshot() async -> SyncSnapshot {
        snapshotCallCount += 1
        return snapshot
    }

    /// Overrides the protocol's default no-op so the store's forwarding
    /// contract is observable (the default would swallow the call silently).
    func resolveConflict(issueID: String, keepVersionID: String) async {
        resolvedCalls.append((issueID, keepVersionID))
    }

    func logStream(appID: String) -> AsyncStream<LogLine> {
        AsyncStream { $0.finish() }
    }

    func conflictDetail(issueID: String) async -> ConflictDetail? { nil }
}

extension SyncSnapshot {
    static func minimal(apps: [AppSyncState] = [], issues: [IssueItem] = []) -> SyncSnapshot {
        SyncSnapshot(
            apps: apps, transfers: [], driveFolders: [], devices: [], issues: issues,
            activity: [], daemons: [], retryQueue: [],
            engine: SyncEngineInfo(serverState: "", clientState: "", lastSyncToken: "", pushBudget: "", pushThrottled: false, metadataIndex: "", metadataHealthy: true),
            permissions: [], bandwidth: BandwidthSummary(uploadedTodayBytes: 0, downloadedTodayBytes: 0, currentRateBytesPerSec: 0, hours: []),
            storage: StorageInfo(totalBytes: 1, segments: [], planName: "", planPriceLine: ""),
            notifications: []
        )
    }
}

extension AppSyncState {
    static func stub(id: String, status: AppSyncStatus, statusLine: String = "", pending: Int = 0) -> AppSyncState {
        AppSyncState(
            id: id, name: id, tileColorHex: "0a84ff", backend: .cloudDocs, isApple: true,
            status: status, statusLine: statusLine, lastActivity: nil,
            itemsIndexed: 0, pendingItems: pending, localSizeBytes: 0, locationPath: ""
        )
    }
}

/// A source whose `currentSnapshot` blocks until the test releases it, and
/// which records the peak number of simultaneously in-flight snapshot fetches.
final class GatedSyncSource: SyncSource, @unchecked Sendable {
    var snapshot: SyncSnapshot
    private(set) var snapshotCallCount = 0
    private(set) var maxConcurrentSnapshots = 0
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: SyncSnapshot) { self.snapshot = snapshot }

    func currentSnapshot() async -> SyncSnapshot {
        snapshotCallCount += 1
        inFlight += 1
        maxConcurrentSnapshots = max(maxConcurrentSnapshots, inFlight)
        await withCheckedContinuation { waiters.append($0) }
        inFlight -= 1
        return snapshot
    }

    /// Lets every currently-blocked fetch finish.
    func releaseAll() {
        let pending = waiters
        waiters = []
        for w in pending { w.resume() }
    }

    func logStream(appID: String) -> AsyncStream<LogLine> { AsyncStream { $0.finish() } }
    func conflictDetail(issueID: String) async -> ConflictDetail? { nil }
}

private func makeStore(apps: [AppSyncState] = [], issues: [IssueItem] = [],
                       now: @escaping () -> Date = { Date() }) async -> (SyncStore, StubSyncSource) {
    let source = StubSyncSource(snapshot: .minimal(apps: apps, issues: issues))
    let store = SyncStore(source: source, now: now)
    await store.refresh(force: true)
    return (store, source)
}

private func issue(id: String, severity: IssueSeverity = .warning, appID: String? = nil) -> IssueItem {
    IssueItem(id: id, severity: severity, title: id, meta: "", reason: "", action: .openDiagnostics, symbolName: "circle", appID: appID)
}

/// Records banner posts instead of hitting UNUserNotificationCenter, so the
/// suite never posts real system notifications.
final class NotifierRecorder: @unchecked Sendable {
    // Tests drive the store serially on the MainActor; never touched concurrently.
    private(set) var posted: [(title: String, body: String, id: String)] = []
    var record: (String, String, String) -> Void {
        { [self] title, body, id in posted.append((title, body, id)) }
    }
}

// MARK: - Tests

@Suite("SyncStore derived facts")
struct SyncStoreTests {

    @Test("overallProgress: mean of syncing apps, 1 when all synced, 0 when paused")
    func overallProgress() async {
        let (store, _) = await makeStore(apps: [
            .stub(id: "a", status: .syncing(progress: 0.2)),
            .stub(id: "b", status: .syncing(progress: 0.8)),
            .stub(id: "c", status: .upToDate),
        ])
        #expect(store.overallProgress == 0.5)
        store.togglePauseAll()
        #expect(store.overallProgress == 0, "paused shows an empty bar, not a full one")
        store.togglePauseAll()
        #expect(store.overallProgress == 0.5)
    }

    @Test("overallProgressIsIndeterminate: boolean-only transfers never render a fake mean")
    func indeterminateHeuristic() async {
        func transfer(_ id: String, progress: Double, appID: String = "a") -> TransferItem {
            TransferItem(id: id, appID: appID, name: id, location: "", sizeBytes: 1,
                         direction: .upload, progress: progress)
        }
        func store(_ transfers: [TransferItem]) async -> SyncStore {
            var snap = SyncSnapshot.minimal(apps: [.stub(id: "a", status: .syncing(progress: 0))])
            snap.transfers = transfers
            let store = SyncStore(source: StubSyncSource(snapshot: snap))
            await store.refresh(force: true)
            return store
        }

        // Live ubiquity channel: every in-flight row is progress 0.
        let live = await store([transfer("t1", progress: 0), transfer("t2", progress: 0)])
        #expect(live.overallProgressIsIndeterminate)
        #expect(live.progressIsIndeterminate(appID: "a"))
        #expect(live.inFlightTransfers.count == 2)

        // One real fraction anywhere → the exact math is honest, keep it.
        let mixed = await store([transfer("t1", progress: 0), transfer("t2", progress: 0.42)])
        #expect(!mixed.overallProgressIsIndeterminate)

        // Fixture/mock data with real percents stays determinate.
        let fixture = await store([transfer("t1", progress: 0.72)])
        #expect(!fixture.overallProgressIsIndeterminate)

        // A done-grace row (progress 1) is not in flight and cannot make the
        // ring indeterminate on its own.
        let doneOnly = await store([transfer("t1", progress: 1)])
        #expect(!doneOnly.overallProgressIsIndeterminate)
        #expect(!doneOnly.progressIsIndeterminate(appID: "a"))

        // Nothing in flight at all → determinate (the ring shows "up to date").
        let idle = await store([])
        #expect(!idle.overallProgressIsIndeterminate)

        // Paused: monitoring stopped, so we make no claim about progress.
        let paused = await store([transfer("t1", progress: 0)])
        paused.togglePauseAll()
        #expect(!paused.overallProgressIsIndeterminate)

        // Per-app scoping: another app's boolean rows don't infect this one.
        let scoped = await store([transfer("t1", progress: 0, appID: "b"),
                                  transfer("t2", progress: 0.5, appID: "a")])
        #expect(scoped.progressIsIndeterminate(appID: "b"))
        #expect(!scoped.progressIsIndeterminate(appID: "a"))
    }

    @Test("Search matches apps and files, requires 2+ characters, and open() routes and clears")
    func search() async {
        var snap = SyncSnapshot.minimal(apps: [.stub(id: "photos", status: .upToDate)])
        snap.transfers = [TransferItem(id: "t1", appID: "photos", name: "Report.pages", location: "Documents", sizeBytes: 1, direction: .upload, progress: 0.5)]
        let source = StubSyncSource(snapshot: snap)
        let store = SyncStore(source: source)
        await store.refresh(force: true)

        store.searchText = "p"
        #expect(store.searchResults.isEmpty, "single character never matches")
        store.searchText = "repo"
        #expect(store.searchResults.count == 1)
        #expect(store.searchResults.first?.title == "Report.pages")

        store.open(.app(id: "photos"))
        #expect(store.detailAppID == "photos")
        #expect(store.selectedView == .applications)
        #expect(store.searchText.isEmpty, "opening a result clears the query")
    }

    // Honest-pause semantics: pausing pauses BIRDWATCH'S MONITORING, never the
    // apps' sync. Statuses are last-known and preserved; only the status line
    // says monitoring stopped.
    @Test("Monitoring pause preserves every last-known status; statusLine says monitoring paused")
    func monitoringPauseOverlay() async {
        let (store, _) = await makeStore(apps: [
            .stub(id: "erroring", status: .issue("quota"), statusLine: "Out of space"),
            .stub(id: "idle", status: .upToDate, statusLine: "Up to date"),
            .stub(id: "busy", status: .syncing(progress: 0.5), statusLine: "Uploading"),
        ])
        store.togglePauseAll()
        // Statuses are never rewritten to .paused — that would claim the app's
        // sync is paused, which Birdwatch cannot do.
        #expect(store.app(withID: "erroring")?.status == .issue("quota"))
        #expect(store.app(withID: "idle")?.status == .upToDate)
        #expect(store.app(withID: "busy")?.status == .syncing(progress: 0.5))
        for id in ["erroring", "idle", "busy"] {
            #expect(store.app(withID: id)?.statusLine == "Monitoring paused")
        }
        store.togglePauseAll()
        #expect(store.app(withID: "busy")?.statusLine == "Uploading", "resume restores the real status line")
    }

    @Test("Pausing monitoring stops refresh entirely (even forced) and keeps hasLoaded")
    func pauseStopsFetching() async {
        let source = StubSyncSource(snapshot: .minimal())
        let store = SyncStore(source: source)
        await store.refresh(force: true)
        #expect(source.snapshotCallCount == 1)
        #expect(store.hasLoaded)

        store.togglePauseAll()
        await store.refresh(force: true)
        await store.refresh()
        #expect(source.snapshotCallCount == 1, "paused monitoring never fetches")
        #expect(store.hasLoaded, "last-known data survives the pause")

        store.togglePauseAll()
        await store.refresh(force: true)
        #expect(source.snapshotCallCount == 2, "resume restores fetching")
    }

    // Audit P3. The window's `.task` fires `refresh()` exactly once; if
    // monitoring is already paused when it runs (paused from the menu bar
    // before the window was ever opened), the fetch is skipped, `hasLoaded`
    // stays false, and the UI's `!hasLoaded` spinner had nothing left to
    // resolve it — resuming did not refetch. Fails on the pre-fix store.
    @Test("Pausing before the first load ever completes still resolves the loading state on resume")
    func pauseBeforeFirstLoadResolves() async {
        let source = StubSyncSource(snapshot: .minimal(apps: [.stub(id: "docs", status: .upToDate)]))
        let store = SyncStore(source: source)

        store.togglePauseAll()
        await store.refresh(force: true)
        #expect(source.snapshotCallCount == 0, "paused monitoring never fetches — that part is correct")
        #expect(!store.hasLoaded)
        // The honest state the UI must render instead of a spinner (C1):
        // nothing is loading, because monitoring is off.
        #expect(store.isPausedBeforeFirstLoad)

        store.togglePauseAll()          // resume
        await store.pendingResumeRefresh?.value

        #expect(store.hasLoaded, "resume must kick the first load — otherwise the spinner is permanent")
        #expect(!store.isPausedBeforeFirstLoad)
        #expect(source.snapshotCallCount == 1)
        #expect(store.apps.count == 1)
    }

    // The other half of P3: pausing while the FIRST fetch is already in flight
    // must still land that snapshot — the work is done, dropping it would
    // strand the loading state with no data to show.
    @Test("Pausing during an in-flight first refresh still lands that snapshot")
    func pauseDuringFirstRefreshStillLands() async {
        let source = GatedSyncSource(snapshot: .minimal(apps: [.stub(id: "docs", status: .upToDate)]))
        let store = SyncStore(source: source)

        let first = Task { await store.refresh(force: true) }
        // Deterministic hand-off, not a sleep: yield until the gated source
        // has actually entered currentSnapshot.
        while source.snapshotCallCount == 0 { await Task.yield() }
        #expect(!store.hasLoaded)

        store.togglePauseAll()          // pause mid-flight
        source.releaseAll()
        await first.value

        #expect(store.hasLoaded, "an in-flight first snapshot is never dropped by a pause")
        #expect(!store.isPausedBeforeFirstLoad)
        #expect(store.apps.count == 1)
        // And a resume must not double-fetch: something already loaded.
        store.togglePauseAll()
        #expect(store.pendingResumeRefresh == nil)
    }

    @Test("pendingFileCount reports last-known pending items, unchanged by a monitoring pause")
    func pendingFileCount() async {
        let (store, _) = await makeStore(apps: [
            .stub(id: "busy", status: .syncing(progress: 0.3), pending: 42),
            .stub(id: "stalled", status: .paused, pending: 6),
        ])
        #expect(store.pendingFileCount == 42, "only syncing apps' pending items count")
        store.togglePauseAll()
        #expect(store.pendingFileCount == 42, "pausing monitoring doesn't erase last-known facts")
    }

    @Test("Per-app mute never touches status and is independent of monitoring pause")
    func perAppMute() async {
        let (store, _) = await makeStore(apps: [
            .stub(id: "a", status: .syncing(progress: 0.1), statusLine: "Uploading"),
            .stub(id: "b", status: .syncing(progress: 0.9)),
        ])
        store.toggleMute(appID: "a")
        #expect(store.isMuted(appID: "a"))
        #expect(!store.isMuted(appID: "b"))
        #expect(store.app(withID: "a")?.status == .syncing(progress: 0.1), "mute is presentation-only")
        #expect(store.app(withID: "a")?.statusLine == "Uploading")
        store.togglePauseAll()   // global monitoring pause on top
        store.togglePauseAll()   // resume
        #expect(store.isMuted(appID: "a"), "mute survives a pause/resume cycle")
        store.toggleMute(appID: "a")
        #expect(!store.isMuted(appID: "a"))
        #expect(store.app(withID: "ghost") == nil)
    }

    @Test("Refresh debounces inside a 60s window, refetches after it, and force always fetches")
    func debounce() async {
        var fakeNow = Date(timeIntervalSinceReferenceDate: 0)
        let source = StubSyncSource(snapshot: .minimal())
        let store = SyncStore(source: source, now: { fakeNow })
        await store.refresh(force: true)
        #expect(source.snapshotCallCount == 1)
        fakeNow.addTimeInterval(59)
        await store.refresh()
        #expect(source.snapshotCallCount == 1, "59s: inside the window, skipped")
        fakeNow.addTimeInterval(2)
        await store.refresh()
        #expect(source.snapshotCallCount == 2, "61s: outside the window, refetched")
        await store.refresh(force: true)
        #expect(source.snapshotCallCount == 3, "force bypasses the window")
    }

    @Test("Resolving a conflict removes exactly that issue and closes the screen")
    func resolveConflict() async {
        let (store, _) = await makeStore(issues: [
            issue(id: "other"), issue(id: "conflict", severity: .conflict), issue(id: "third"),
        ])
        store.conflictIssueID = "conflict"
        await store.resolveConflict(issueID: "conflict")
        #expect(store.issueCount == 2)
        #expect(store.issues.allSatisfy { $0.id != "conflict" })
        #expect(store.issues.contains { $0.id == "other" } && store.issues.contains { $0.id == "third" })
        #expect(store.conflictIssueID == nil)
    }

    @Test("Notifications derive from issue arrivals after first load, without duplicates")
    func notificationDerivation() async {
        let source = StubSyncSource(snapshot: .minimal())
        let recorder = NotifierRecorder()
        let store = SyncStore(source: source, notifier: recorder.record)
        await store.refresh(force: true)
        #expect(store.notifications.isEmpty, "first load never spams notifications")

        source.snapshot = .minimal(issues: [issue(id: "quota-low")])
        await store.refresh(force: true)
        #expect(store.notifications.count == 1)
        #expect(store.unreadNotificationCount == 1)
        #expect(store.notifications.first?.id == "notif-quota-low")
        #expect(recorder.posted.map(\.id) == ["notif-quota-low"])

        await store.refresh(force: true)
        #expect(store.notifications.count == 1, "re-detecting the same issue does not duplicate")
        #expect(recorder.posted.count == 1, "a still-present issue does not re-post")
    }

    @Test("A recurring issue re-notifies: same id, one row, unread again")
    func notificationRecurrence() async {
        let source = StubSyncSource(snapshot: .minimal())
        let recorder = NotifierRecorder()
        let store = SyncStore(source: source, notifier: recorder.record)
        await store.refresh(force: true)

        source.snapshot = .minimal(issues: [issue(id: "quota-low")])
        await store.refresh(force: true)
        #expect(store.unreadNotificationCount == 1)

        store.markAllNotificationsRead()
        #expect(store.unreadNotificationCount == 0)

        // The issue resolves…
        source.snapshot = .minimal()
        await store.refresh(force: true)
        #expect(store.issues.isEmpty)
        #expect(store.notifications.count == 1, "the historical row stays until it recurs")

        // …and later comes back under the SAME (stable, by design) id.
        source.snapshot = .minimal(issues: [issue(id: "quota-low")])
        await store.refresh(force: true)
        #expect(store.unreadNotificationCount == 1, "a recurrence must alert again")
        #expect(store.notifications.filter { $0.id == "notif-quota-low" }.count == 1,
                "the fresh notification replaces the old one — never two rows for one id")
        #expect(store.notifications.first?.id == "notif-quota-low", "and it returns to the top")
        #expect(recorder.posted.count == 2, "the recurrence posts a second banner")
    }

    @Test("A muted app's issue records in-app but posts no banner; unmuted posts one")
    func mutedIssueSkipsBanner() async {
        let source = StubSyncSource(snapshot: .minimal())
        let recorder = NotifierRecorder()
        let store = SyncStore(source: source, notifier: recorder.record)
        await store.refresh(force: true)
        store.toggleMute(appID: "icloud-drive")

        source.snapshot = .minimal(issues: [
            issue(id: "conflict-a", severity: .conflict, appID: "icloud-drive"),
            issue(id: "conflict-b", severity: .conflict, appID: "desktop-documents"),
            issue(id: "quota-low"),   // account-level: appID nil, never muted
        ])
        await store.refresh(force: true)

        #expect(store.notifications.count == 3, "muting silences the banner, not the in-app row")
        #expect(recorder.posted.map(\.id).sorted() == ["notif-conflict-b", "notif-quota-low"])
    }

    // Fails if the 2-character minimum is ever applied to the RAW text instead
    // of the trimmed query — "  a  " is 5 characters raw but one real one, and
    // matching on it would dump most of the snapshot into the dropdown.
    @Test("Search applies the 2-character minimum AFTER trimming whitespace")
    func searchTrimsBeforeCountingCharacters() async {
        var snap = SyncSnapshot.minimal(apps: [.stub(id: "Alpha", status: .upToDate)])
        snap.driveFolders = [DriveFolder(id: "d1", name: "Archive", itemCount: 3, status: .upToDate)]
        let store = SyncStore(source: StubSyncSource(snapshot: snap))
        await store.refresh(force: true)

        store.searchText = "  a  "
        #expect(store.searchResults.isEmpty, "one real character never matches")
        store.searchText = "   "
        #expect(store.searchResults.isEmpty)
        store.searchText = "  ar  "
        #expect(store.searchResults.map(\.title) == ["Archive"], "the trimmed query is what matches")
    }

    // Fails if a search ever becomes case- or diacritic-sensitive: users type
    // lowercase, file names are capitalised.
    @Test("Search is case-insensitive across every result kind, and routes each kind correctly")
    func searchCaseInsensitivityAndTargets() async {
        var snap = SyncSnapshot.minimal(apps: [.stub(id: "Photos", status: .upToDate)])
        snap.driveFolders = [DriveFolder(id: "d1", name: "PHOTO Archive", itemCount: 7, status: .upToDate)]
        snap.activity = [ActivityEvent(id: "e1", kind: .upload, title: "Uploaded photo.heic",
                                       detail: "Camera Roll", date: Date(timeIntervalSinceReferenceDate: 0),
                                       symbolName: "arrow.up")]
        let store = SyncStore(source: StubSyncSource(snapshot: snap))
        await store.refresh(force: true)

        store.searchText = "photo"
        let byID = Dictionary(uniqueKeysWithValues: store.searchResults.map { ($0.id, $0) })
        #expect(byID["app-Photos"]?.target == .app(id: "Photos"), "lowercase query matches 'Photos'")
        #expect(byID["folder-d1"]?.target == .view(.drive), "a folder hit routes to iCloud Drive")
        #expect(byID["activity-e1"]?.target == .view(.activity), "an activity hit routes to Activity")
        #expect(byID["folder-d1"]?.subtitle == "7 items")

        // An activity hit can come from the DETAIL text too, not just the title.
        store.searchText = "camera"
        #expect(store.searchResults.map(\.id) == ["activity-e1"])
    }

    // Fails if the dropdown cap is removed or raised — the popover is a fixed
    // size and an uncapped list scrolls off-screen with no way back.
    @Test("Search results are capped at 12 even when far more match")
    func searchResultCap() async {
        var snap = SyncSnapshot.minimal()
        snap.transfers = (0..<13).map {
            TransferItem(id: "t\($0)", appID: "icloud-drive", name: "Report-\($0).pages",
                         location: "Documents", sizeBytes: 1, direction: .upload, progress: 0.5)
        }
        let store = SyncStore(source: StubSyncSource(snapshot: snap))
        await store.refresh(force: true)
        store.searchText = "report"
        #expect(store.searchResults.count == 12, "13 matches, 12 shown")
        #expect(Set(store.searchResults.map(\.id)).count == 12, "no duplicate ids in the cap")
    }

    // Fails if opening a VIEW result leaves a stale app-detail route behind —
    // the detail sheet would stay on screen and the user would think the click
    // did nothing.
    @Test("open(.view) clears the app-detail route; open(.app) sets it")
    func openViewClearsDetail() async {
        let (store, _) = await makeStore(apps: [.stub(id: "photos", status: .upToDate)])
        store.open(.app(id: "photos"))
        #expect(store.detailAppID == "photos")

        store.conflictIssueID = "conflict-1"
        store.open(.view(.drive))
        #expect(store.detailAppID == nil, "a view destination must not keep an app detail open")
        #expect(store.conflictIssueID == nil)
        #expect(store.selectedView == .drive)
        #expect(store.searchText.isEmpty)
    }

    // Fails if the store ever resolves locally without telling the source (the
    // file would stay conflicted on disk while the UI claims it is fixed), or
    // drops the user's chosen version id on the way through.
    @Test("resolveConflict forwards issueID and keepVersionID to the source before removing the issue")
    func resolveConflictForwardsToSource() async {
        let (store, source) = await makeStore(issues: [
            issue(id: "conflict-a", severity: .conflict),
            issue(id: "conflict-b", severity: .conflict),
        ])
        await store.resolveConflict(issueID: "conflict-a", keepVersionID: "version-abc")
        #expect(source.resolvedCalls.count == 1)
        #expect(source.resolvedCalls.first?.0 == "conflict-a")
        #expect(source.resolvedCalls.first?.1 == "version-abc")
        #expect(store.issues.map(\.id) == ["conflict-b"])

        // The default keeps the on-disk file — the sentinel, not an empty string.
        await store.resolveConflict(issueID: "conflict-b")
        #expect(source.resolvedCalls.last?.1 == ConflictSource.currentVersionID)
    }

    // Overlapping refresh (audit: "coalescing defends only one generation").
    // What the while-loop join guarantees, and what this pins:
    //   1. Snapshots never overlap — a second caller joins the in-flight task
    //      instead of starting a concurrent fetch.
    //   2. The later caller's data wins: it returns only after ITS generation
    //      landed, so a stale snapshot can never clobber a newer one.
    // Fails if the join is dropped (maxConcurrentSnapshots would hit 2).
    @Test("Overlapping forced refreshes never run concurrently; the later one lands last")
    func overlappingRefreshesSerialize() async {
        let first = SyncSnapshot.minimal(apps: [.stub(id: "old", status: .upToDate)])
        let source = GatedSyncSource(snapshot: first)
        let store = SyncStore(source: source)

        let a = Task { await store.refresh(force: true) }
        while source.snapshotCallCount < 1 { await Task.yield() }
        // Refresh #1 is now suspended inside currentSnapshot. Start #2; it must
        // join #1 rather than fetch alongside it.
        let b = Task { await store.refresh(force: true) }
        for _ in 0..<20 { await Task.yield() }
        #expect(source.snapshotCallCount == 1, "the second caller joins instead of fetching in parallel")

        source.snapshot = SyncSnapshot.minimal(apps: [.stub(id: "new", status: .upToDate)])
        source.releaseAll()
        // #2 leaves the join and starts its own generation — release that too.
        while source.snapshotCallCount < 2 { await Task.yield(); source.releaseAll() }
        source.releaseAll()
        await a.value
        await b.value

        #expect(source.maxConcurrentSnapshots == 1, "no two snapshots are ever in flight at once")
        #expect(store.apps.map(\.id) == ["new"], "the later generation's data is what survives")
        #expect(store.hasLoaded)
    }

    // Non-forced overlap collapses entirely: the joiner falls inside the 60s
    // debounce window once #1 lands, so it never spawns a second fetch.
    @Test("A non-forced refresh overlapping an in-flight one coalesces to a single fetch")
    func overlappingNonForcedRefreshCoalesces() async {
        let source = GatedSyncSource(snapshot: .minimal())
        let store = SyncStore(source: source)

        let a = Task { await store.refresh(force: true) }
        while source.snapshotCallCount < 1 { await Task.yield() }
        let b = Task { await store.refresh() }
        for _ in 0..<20 { await Task.yield() }
        source.releaseAll()
        await a.value
        await b.value

        #expect(source.snapshotCallCount == 1)
        #expect(source.maxConcurrentSnapshots == 1)
    }

    @Test("Notification read state round trip")
    func notifications() async {
        let source = StubSyncSource(snapshot: .minimal())
        var snap = SyncSnapshot.minimal()
        snap.notifications = [
            AppNotification(id: "n1", severity: .warning, title: "", detail: "", date: Date(timeIntervalSinceReferenceDate: 0), isRead: false),
            AppNotification(id: "n2", severity: .warning, title: "", detail: "", date: Date(timeIntervalSinceReferenceDate: 0), isRead: true),
        ]
        source.snapshot = snap
        let store = SyncStore(source: source)
        await store.refresh(force: true)
        #expect(store.unreadNotificationCount == 1)
        store.markAllNotificationsRead()
        #expect(store.unreadNotificationCount == 0)
    }
}

@Suite("Pure decision logic")
struct PureLogicTests {
    @Test("cpuTint thresholds: green below 15, amber 15..<30, red at 30+")
    func cpuThresholds() {
        #expect(cpuTint(14.99) == Palette.success)
        #expect(cpuTint(15) == Palette.warning)
        #expect(cpuTint(29.99) == Palette.warning)
        #expect(cpuTint(30) == Palette.error)
    }

    @Test("Storage math sums segments and derives availability")
    func storageMath() {
        let info = StorageInfo(
            totalBytes: 100,
            segments: [
                StorageSegment(name: "a", colorHex: "0a84ff", bytes: 60),
                StorageSegment(name: "b", colorHex: "34c759", bytes: 15),
            ],
            planName: "", planPriceLine: ""
        )
        #expect(info.usedBytes == 75)
        #expect(info.availableBytes == 25)
    }
}
