import Foundation
import Stats
import StatsTesting
import Testing
@testable import Birdwatch

// MARK: - Test doubles

/// Records every event the store hands the tracker. `record` is synchronous
/// on the seam, so events are readable the moment the store method returns.
final class RecordingUsageTracker: UsageTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [UsageEvent] = []
    private var _enabled = true

    var events: [UsageEvent] { lock.withLock { _events } }
    func record(_ event: UsageEvent) { lock.withLock { _events.append(event) } }
    func applicationDidBecomeActive() async {}
    func flush() async {}
    func setEnabled(_ enabled: Bool) async { lock.withLock { _enabled = enabled } }
    var isEnabled: Bool { get async { lock.withLock { _enabled } } }
}

private func throwawayDefaults() -> UserDefaults {
    let name = "usage-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func makeStore(
    snapshot: SyncSnapshot = .minimal(),
    tracker: RecordingUsageTracker = RecordingUsageTracker()
) -> (SyncStore, RecordingUsageTracker) {
    (SyncStore(source: StubSyncSource(snapshot: snapshot), defaults: throwawayDefaults(), usage: tracker), tracker)
}

/// Every event case, one instance each. The wire tests iterate this list.
private let allEvents: [UsageEvent] = [
    .onboardingCompleted(fdaGranted: true, notificationsRequested: false),
    .viewShown(.storage, via: .shortcut),
    .appDetailShown(.cloudKit),
    .menubarOpened(issueCount: 3, paused: false),
    .searchUsed(resultKind: .app, resultCount: 7),
    .refreshForced, .monitoringPaused, .monitoringResumed,
    .appMuted(.fileProvider, muted: true),
    .issueDismissed(severity: .conflict),
    .conflictResolved(keptCurrent: false),
    .retryItemRevealed,
    .retryItemTrashed(outcome: .failed),
    .maintenanceRun(.restart_daemon, daemon: "bird", outcome: .failed, errorKind: "daemonNotRunning"),
    .notificationsMarkedRead,
    .planCapSet(cleared: true),
    .snapshotHealth(appsByBackend: [.cloudDocs: 2, .cloudKit: 40], issueCount: 0, daemonsMissing: 1, fdaGranted: true, notificationsGranted: false),
]

/// The compile-time guard: a `switch` with no `default`. Adding a case to
/// `UsageEvent` fails to compile here until it is listed — and the author is
/// then one line away from `allEvents`, which the wire tests iterate.
private func isCovered(_ e: UsageEvent) -> Bool {
    switch e {
    case .onboardingCompleted, .viewShown, .appDetailShown, .menubarOpened, .searchUsed,
         .refreshForced, .monitoringPaused, .monitoringResumed, .appMuted, .issueDismissed,
         .conflictResolved, .retryItemRevealed, .retryItemTrashed, .maintenanceRun,
         .notificationsMarkedRead, .planCapSet, .snapshotHealth:
        return true
    }
}

// MARK: - Wire contract

@Suite("Usage events — wire contract")
struct UsageEventWireTests {

    @Test("Every event name is schema-legal snake_case and not reserved")
    func names() {
        let legal = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]*$")
        for e in allEvents {
            let range = NSRange(e.name.startIndex..., in: e.name)
            #expect(legal.firstMatch(in: e.name, range: range) != nil, "bad name \(e.name)")
            #expect(!e.name.hasPrefix("stats_"), "reserved prefix on \(e.name)")
            #expect(e.name.count <= 64)
        }
    }

    @Test("Prop keys are snake_case and values carry no free text")
    func props() {
        let legal = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]*$")
        // The closed vocabulary every string prop must come from. A new value
        // that is not an enum case, a bucket or a daemon name fails here.
        let vocabulary: Set<String> = Set(
            MonitorView.allCases.map(\.rawValue)
            + ["launch", "sidebar", "shortcut", "search", "menubar", "link"]
            + ["cloudDocs", "cloudKit", "fileProvider"]
            + ["0", "1", "2-5", "6-20", "20+"]
            + ["app", "view", "current", "other", "ok", "failed"]
            + ["restart_daemon", "diagnose_copy_command", "diagnose_open_terminal"]
            + ["warning", "conflict", "error"]
            + ["bird", "cloudd", "fileproviderd", "daemonNotRunning"]
        )
        #expect(allEvents.allSatisfy(isCovered))
        for e in allEvents {
            for (key, value) in e.props {
                let range = NSRange(key.startIndex..., in: key)
                #expect(legal.firstMatch(in: key, range: range) != nil, "bad key \(key) on \(e.name)")
                if case .string(let s) = value {
                    #expect(vocabulary.contains(s), "free text '\(s)' in \(e.name).\(key)")
                }
            }
        }
    }

    @Test("Maintenance error kinds are case names, never the payload")
    func errorKinds() {
        #expect(DiagnosticsView.errorKind(for: MaintenanceError.pathNotAllowed("/Users/x/Secret.pdf")) == "pathNotAllowed")
        #expect(DiagnosticsView.errorKind(for: MaintenanceError.daemonNotRunning("bird")) == "daemonNotRunning")
        #expect(DiagnosticsView.errorKind(for: CocoaError(.fileNoSuchFile)) == "other")
        #expect(!DiagnosticsView.errorKind(for: MaintenanceError.pathNotAllowed("/Users/x/Secret.pdf")).contains("Secret"))
    }

    @Test("Bucketing is coarse and total")
    func buckets() {
        #expect(UsageEvent.bucket(0) == "0")
        #expect(UsageEvent.bucket(1) == "1")
        #expect(UsageEvent.bucket(5) == "2-5")
        #expect(UsageEvent.bucket(20) == "6-20")
        #expect(UsageEvent.bucket(500) == "20+")
    }

    @Test("The real StatsClient accepts every event and delivers it with props intact")
    func throughRealClient() async throws {
        let sink = InMemorySink()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bw-usage-\(UUID().uuidString)")
        let client = StatsClient(configuration: StatsConfiguration(
            appId: "com.wizemann.birdwatch.tests", installIdSalt: UsageAnalytics.installIdSalt, sink: sink,
            flushAt: 1_000, storageDirectory: dir,
            uuidProvider: FixedUUIDProvider(), randomSource: FixedRandomSource()
        ))
        let tracker = StatsUsageTracker(client: client)
        for e in allEvents { tracker.record(e) }
        await client.flush()                     // drains record()'s buffer first
        let sent = await sink.sentEvents
        // If the SDK refused any name (regex / reserved), it would be missing here.
        #expect(sent.map(\.name) == allEvents.map(\.name))
        let health = try #require(sent.last)
        #expect(health.props["apps_cloudkit_bucket"] == .string("20+"))
        #expect(health.props["daemons_missing"] == .int(1))
        #expect(health.props["issue_bucket"] == .string("0"))
        await client.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Gating

@Suite("Usage analytics — gating")
struct UsageAnalyticsGatingTests {
    @Test("No key, placeholder key, --mock and XCTest all yield the no-op")
    func gates() {
        #expect(UsageAnalytics.makeTracker(environment: [:], arguments: [], writeKey: nil) is NoopUsageTracker)
        #expect(UsageAnalytics.makeTracker(environment: [:], arguments: [], writeKey: "") is NoopUsageTracker)
        #expect(UsageAnalytics.makeTracker(environment: [:], arguments: [], writeKey: "$(BW_STATS_WRITE_KEY)") is NoopUsageTracker)
        #expect(UsageAnalytics.makeTracker(environment: [:], arguments: ["--mock"], writeKey: "k") is NoopUsageTracker)
        #expect(UsageAnalytics.makeTracker(environment: ["XCTestConfigurationFilePath": "x"], arguments: [], writeKey: "k") is NoopUsageTracker)
    }

    @Test("A real key in a normal launch builds the swift-stats tracker")
    func realKey() {
        #expect(UsageAnalytics.makeTracker(environment: [:], arguments: [], writeKey: "sk_test") is StatsUsageTracker)
    }
}

// MARK: - Store hooks

@Suite("Usage analytics — store hooks")
@MainActor
struct UsageStoreHookTests {

    @Test("Selecting a view records view_shown once, with the origin when known")
    func viewShown() async {
        let (store, tracker) = makeStore()
        store.selectedView = .devices                    // sidebar binding path
        store.selectedView = .devices                    // no-op: same view
        store.navigate(to: .issues, via: .menubar)
        store.navigate(to: .issues, via: .shortcut)      // no-op, but must not arm the next click
        store.selectedView = .drive                      // plain sidebar click
        let events = tracker.events
        #expect(events == [
            .viewShown(.devices, via: .sidebar),
            .viewShown(.issues, via: .menubar),
            .viewShown(.drive, via: .sidebar),
        ], "got \(events)")
    }

    @Test("Opening a search result records search_used and a search-origin view_shown")
    func search() async {
        let app = AppSyncState.stub(id: "photos", status: .upToDate)
        let (store, tracker) = makeStore(snapshot: .minimal(apps: [app]))
        await store.refresh(force: true)
        store.searchText = "pho"
        store.open(.app(id: "photos"))
        let events = tracker.events
        #expect(events.first == .viewShown(.overview, via: .launch))
        #expect(events.contains(.snapshotHealth(appsByBackend: [.cloudDocs: 1], issueCount: 0, daemonsMissing: 0, fdaGranted: false, notificationsGranted: false)))
        #expect(events.contains(.searchUsed(resultKind: .app, resultCount: 1)))
        #expect(events.contains(.viewShown(.applications, via: .search)))
        #expect(events.contains(.appDetailShown(.cloudDocs)))
        #expect(store.searchText.isEmpty)
    }

    @Test("snapshot_health and the launch view_shown fire once per launch, not per refresh")
    func healthOnce() async {
        let (store, tracker) = makeStore()
        await store.refresh(force: true)
        await store.refresh(force: true)
        store.togglePauseAll()
        let events = tracker.events
        #expect(events == [
            .viewShown(.overview, via: .launch),
            .snapshotHealth(appsByBackend: [:], issueCount: 0, daemonsMissing: 0, fdaGranted: false, notificationsGranted: false),
            .monitoringPaused,
        ], "got \(events)")
    }

    @Test("Pause / mute / dismiss / conflict / notifications record their events")
    func actions() async {
        let app = AppSyncState.stub(id: "notes", status: .upToDate)
        let issue = TestIssues.make(id: "i1", action: .none, title: "", symbolName: "")
        let (store, tracker) = makeStore(snapshot: .minimal(apps: [app], issues: [issue]))
        await store.refresh(force: true)
        store.togglePauseAll()
        store.togglePauseAll()
        store.toggleMute(appID: "notes")
        store.dismissIssue(id: "i1")
        await store.resolveConflict(issueID: "c1")
        store.markAllNotificationsRead()                 // nothing unread → no event
        let events = tracker.events
        #expect(events.dropFirst(2) == [
            .monitoringPaused, .monitoringResumed,
            .appMuted(.cloudDocs, muted: true),
            .issueDismissed(severity: .warning),
            .conflictResolved(keptCurrent: true),
        ])
    }

    @Test("Opt-out flows through to the tracker's master switch")
    func optOut() async {
        let (store, tracker) = makeStore()
        await store.loadUsagePreference()
        #expect(store.usageSharingEnabled)
        store.setUsageSharing(false)
        let deadline = ContinuousClock.now + .seconds(2)
        while await tracker.isEnabled && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(await tracker.isEnabled == false)
        #expect(!store.usageSharingEnabled)
    }
}
