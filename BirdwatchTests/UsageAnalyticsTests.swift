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
    private var _calls: [String] = []
    private var _enabled = true

    var events: [UsageEvent] { lock.withLock { _events } }
    /// Activations and events interleaved, in call order.
    var calls: [String] { lock.withLock { _calls } }
    func record(_ event: UsageEvent) { lock.withLock { _events.append(event); _calls.append(event.name) } }
    func applicationDidBecomeActive() async { lock.withLock { _calls.append("didBecomeActive") } }
    func flush() async {}
    // Tests await the write `setUsageSharing` returns, never poll this (C8).
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
    (SyncStore(source: StubSyncSource(snapshot: snapshot), notifier: noBanners, defaults: throwawayDefaults(), usage: tracker), tracker)
}

/// Every event case, one instance each. The wire tests iterate this list.
private let allEvents: [UsageEvent] = [
    .onboardingStepShown(.grantAccess),
    .onboardingCompleted(fdaGranted: true, notificationsRequested: false),
    .viewShown(.storage, via: .shortcut),
    .appDetailShown(.cloudKit),
    .menubarOpened(issueCount: 3, paused: false),
    .searchUsed(resultKind: .app, resultCount: 7),
    .refreshForced, .monitoringPaused, .monitoringResumed,
    .appMuted(.fileProvider, muted: true),
    .issueDismissed(severity: .conflict),
    .issueAction(.manage_storage, severity: .warning),
    .conflictResolved(keptCurrent: false),
    .retryItemRevealed,
    .retryItemTrashed(outcome: .failed),
    .maintenanceRun(.restart_daemon, daemon: .bird, outcome: .failed, errorKind: .daemonNotRunning),
    .maintenanceRun(.restart_daemon, daemon: .cloudd, outcome: .unconfirmed, errorKind: nil),
    .notificationsMarkedRead,
    .planCapSet(cleared: true),
    .accountSettingsOpened(from: .devices),
    .snapshotHealth(appsByBackend: [.cloudDocs: 2, .cloudKit: 40], issueCount: 0, daemonsMissing: 1, fdaGranted: true, notificationsGranted: false),
]

/// Every case of every enum that becomes a string prop, built from `allCases`,
/// so a value no single `allEvents` entry happens to use is still checked.
private let everyPropValue: [UsageEvent] = {
    var e: [UsageEvent] = []
    e += MonitorView.allCases.map { .viewShown($0, via: .sidebar) }
    e += UsageEvent.NavigationSource.allCases.map { .viewShown(.overview, via: $0) }
    e += SyncBackend.allCases.map { .appDetailShown($0) }
    e += UsageEvent.SearchResultKind.allCases.map { .searchUsed(resultKind: $0, resultCount: 0) }
    e += IssueSeverity.allCases.map { .issueDismissed(severity: $0) }
    e += UsageEvent.IssueActionKind.allCases.map { .issueAction($0, severity: .warning) }
    e += UsageEvent.Outcome.allCases.map { .retryItemTrashed(outcome: $0) }
    e += UsageEvent.MaintenanceAction.allCases.map { .maintenanceRun($0, daemon: nil, outcome: .ok, errorKind: nil) }
    e += UsageEvent.Daemon.allCases.map { .maintenanceRun(.restart_daemon, daemon: $0, outcome: .ok, errorKind: nil) }
    e += UsageEvent.MaintenanceErrorKind.allCases.map { .maintenanceRun(.restart_daemon, daemon: nil, outcome: .failed, errorKind: $0) }
    e += UsageEvent.SettingsOrigin.allCases.map { .accountSettingsOpened(from: $0) }
    e += OnboardingStep.allCases.map { .onboardingStepShown($0) }
    e += [0, 1, 3, 10, 50].map { .menubarOpened(issueCount: $0, paused: false) }
    e += [true, false].map { .conflictResolved(keptCurrent: $0) }
    return e
}()

/// The compile-time guard: a `switch` with no `default`. Adding a case to
/// `UsageEvent` fails to compile here until it is listed — and the author is
/// then one line away from `allEvents`, which the wire tests iterate.
private func isCovered(_ e: UsageEvent) -> Bool {
    switch e {
    case .onboardingStepShown, .onboardingCompleted, .viewShown, .appDetailShown, .menubarOpened, .searchUsed,
         .refreshForced, .monitoringPaused, .monitoringResumed, .appMuted, .issueDismissed, .issueAction,
         .conflictResolved, .retryItemRevealed, .retryItemTrashed, .maintenanceRun,
         .notificationsMarkedRead, .planCapSet, .accountSettingsOpened, .snapshotHealth:
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
        // The closed vocabulary every string prop must come from, written out
        // literally: a new value, or a renamed case in ANY file (views and
        // models own some of these raw values), fails here.
        let vocabulary: Set<String> = Set(
            ["overview", "applications", "drive", "devices", "issues", "activity", "diagnostics", "bandwidth", "storage"]
            + ["launch", "sidebar", "shortcut", "search", "menubar", "link"]
            + ["cloudDocs", "cloudKit", "fileProvider"]
            + ["0", "1", "2-5", "6-20", "20+"]
            + ["app", "view", "current", "other", "ok", "unconfirmed", "failed"]
            + ["unknownDaemon", "pathNotAllowed"]
            + ["restart_daemon", "diagnose_copy_command", "diagnose_open_terminal"]
            + ["warning", "conflict", "error"]
            + ["review_versions", "open_diagnostics", "manage_storage"]
            + ["welcome", "grant_access"]
            + ["bird", "cloudd", "fileproviderd", "daemonNotRunning"]
        )
        #expect(allEvents.allSatisfy(isCovered))
        var sent: Set<String> = []
        for e in allEvents + everyPropValue {
            for (key, value) in e.props {
                let range = NSRange(key.startIndex..., in: key)
                #expect(legal.firstMatch(in: key, range: range) != nil, "bad key \(key) on \(e.name)")
                if case .string(let s) = value {
                    #expect(vocabulary.contains(s), "free text '\(s)' in \(e.name).\(key)")
                    sent.insert(s)
                }
            }
        }
        // Both ways: every listed value is still reachable, so the list
        // cannot quietly go stale.
        #expect(sent == vocabulary, "unreachable: \(vocabulary.subtracting(sent)), unlisted: \(sent.subtracting(vocabulary))")
    }

    // The public privacy page promises it is the complete list. Fails if an
    // event, detail or value is added to (or renamed in) UsageEvent without
    // the page, or if the page still names one that no longer exists.
    @Test("The privacy page lists exactly the events, details and values UsageEvent sends")
    func privacyPageMatchesContract() throws {
        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("site/privacy.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        let start = try #require(html.range(of: "<!-- usage-events"))
        let end = try #require(html.range(of: "<!-- /usage-events -->"))
        let section = String(html[start.upperBound..<end.lowerBound])
        let code = try NSRegularExpression(pattern: "<code>([^<]+)</code>")
        let listed = Set(code.matches(in: section, range: NSRange(section.startIndex..., in: section)).map {
            String(section[Range($0.range(at: 1), in: section)!])
        })

        var sent: Set<String> = []
        for e in allEvents + everyPropValue {
            sent.insert(e.name)
            for (key, value) in e.props {
                sent.insert(key)
                if case .string(let s) = value { sent.insert(s) }
            }
        }
        #expect(listed == sent, "not on the page: \(sent.subtracting(listed)), on the page but never sent: \(listed.subtracting(sent))")
    }

    @Test("Maintenance error kinds are case names, never the payload")
    func errorKinds() {
        #expect(DiagnosticsView.errorKind(for: MaintenanceError.pathNotAllowed("/Users/x/Secret.pdf")) == .pathNotAllowed)
        #expect(DiagnosticsView.errorKind(for: MaintenanceError.daemonNotRunning("bird")) == .daemonNotRunning)
        #expect(DiagnosticsView.errorKind(for: CocoaError(.fileNoSuchFile)) == .other)
        #expect(DiagnosticsView.errorKind(for: RunnerError.nonZeroExit(code: 1, stderr: "/Users/x/Secret.pdf")) == .other)
    }

    // The props are typed enums now; this pins their wire spelling so a rename
    // of a case can't silently change what dashboards receive.
    @Test("Maintenance daemon and error-kind props keep their wire values")
    func maintenanceWireValues() {
        #expect(UsageEvent.Daemon.allCases.map(\.rawValue) == ["bird", "cloudd", "fileproviderd"])
        #expect(UsageEvent.MaintenanceErrorKind.allCases.map(\.rawValue)
                == ["unknownDaemon", "daemonNotRunning", "pathNotAllowed", "other"])
        let props = UsageEvent.maintenanceRun(.restart_daemon, daemon: .cloudd, outcome: .failed, errorKind: .other).props
        #expect(props["daemon"] == .string("cloudd"))
        #expect(props["error_kind"] == .string("other"))
    }

    @Test("A restart the poll never witnessed is unconfirmed, not ok")
    func restartOutcomes() {
        #expect(DiagnosticsView.restartEvent(daemon: .bird, result: .success("Restarted (new pid 42)"))
                == .maintenanceRun(.restart_daemon, daemon: .bird, outcome: .ok, errorKind: nil))
        // Both unwitnessed endings: the poll ran and saw no new pid, and the
        // poll itself failed. Neither is a confirmed restart.
        #expect(DiagnosticsView.restartEvent(daemon: .cloudd, result: .success(MaintenanceActions.respawnNotObserved))
                == .maintenanceRun(.restart_daemon, daemon: .cloudd, outcome: .unconfirmed, errorKind: nil))
        #expect(DiagnosticsView.restartEvent(daemon: .bird, result: .success(MaintenanceActions.restartNotConfirmed))
                == .maintenanceRun(.restart_daemon, daemon: .bird, outcome: .unconfirmed, errorKind: nil))
        #expect(DiagnosticsView.restartEvent(daemon: .bird, result: .failure(MaintenanceError.daemonNotRunning("bird")))
                == .maintenanceRun(.restart_daemon, daemon: .bird, outcome: .failed, errorKind: .daemonNotRunning))
    }

    @Test("A daemon name outside the closed set never reaches the props")
    func unknownDaemonOmitted() {
        let event = DiagnosticsView.restartEvent(
            daemon: UsageEvent.Daemon(rawValue: "someprivated"),
            result: .failure(MaintenanceError.unknownDaemon("someprivated")))
        #expect(event.props["daemon"] == nil)
        #expect(event.props["error_kind"] == .string("unknownDaemon"))
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

// MARK: - Install identity

@Suite("Usage analytics — install identity")
struct UsageInstallIdentityTests {
    /// The shipping configuration grants `.identity` (decision 2026-08-18), so
    /// one install keeps one `installId` across a relaunch. If consent ever
    /// loses `.identity`, install counts silently become session counts —
    /// this is the test that notices. The probe runs isolated (fresh app id
    /// suffix, temp storage) and swaps in an in-memory sink.
    @Test("The shipping configuration keeps one installId across a relaunch")
    func stableAcrossRelaunch() async throws {
        let configuration = UsageAnalytics.configuration(sink: InMemorySink())
        #expect(configuration.consent.contains(.identity))
        let probe = try #require(await RelaunchProbe.installIDsAcrossRelaunch(configuration: configuration))
        #expect(probe.isInstallIdStable, "installId changed across relaunch: \(probe)")
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
        await store.applicationDidBecomeActive()
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

    @Test("Appearance events wait for a person: held before activation, sent in order after")
    func attendedEventsHeld() async {
        let (store, tracker) = makeStore()
        store.recordWhenAttended(.onboardingStepShown(.welcome))
        store.recordWhenAttended(.onboardingStepShown(.grantAccess))
        #expect(tracker.calls.isEmpty, "nothing may start a session before activation")
        await store.applicationDidBecomeActive()
        store.recordWhenAttended(.onboardingStepShown(.welcome))      // after activation: immediate
        await store.applicationDidBecomeActive()                     // held list already drained
        #expect(tracker.calls == [
            "didBecomeActive", "onboarding_step_shown", "onboarding_step_shown",
            "onboarding_step_shown", "didBecomeActive",
        ], "got \(tracker.calls)")
        #expect(tracker.events == [
            .onboardingStepShown(.welcome), .onboardingStepShown(.grantAccess), .onboardingStepShown(.welcome),
        ])
    }

    @Test("Each onboarding step counts once per launch, however often it is shown")
    func onboardingStepDeduped() async {
        let (store, tracker) = makeStore()
        await store.applicationDidBecomeActive()
        store.recordOnboardingStepShown(.welcome)
        store.recordOnboardingStepShown(.grantAccess)
        store.recordOnboardingStepShown(.welcome)          // Back
        store.recordOnboardingStepShown(.grantAccess)      // Get Started again
        #expect(tracker.events == [.onboardingStepShown(.welcome), .onboardingStepShown(.grantAccess)])
    }

    @Test("account_settings_opened is recorded only when the pane actually opened")
    func accountSettingsOnlyWhenOpened() {
        let (store, tracker) = makeStore()
        AppleAccountSettings.open(from: .storage, store: store, opener: { _ in false })
        AppleAccountSettings.open(from: .devices, store: store, opener: { _ in true })
        #expect(tracker.events == [.accountSettingsOpened(from: .devices)])
    }

    @Test("Turning sharing back on reopens the session; turning it off does not")
    func reenableReactivates() async {
        let (store, tracker) = makeStore()
        await store.loadUsagePreference()
        await store.setUsageSharing(false)?.value
        #expect(!tracker.calls.contains("didBecomeActive"))
        await store.setUsageSharing(true)?.value
        #expect(tracker.calls == ["didBecomeActive"])
    }

    @Test("Once known, the switch is never re-read over the store's own value")
    func loadOnlyOnce() async {
        let (store, tracker) = makeStore()
        await store.loadUsagePreference()
        await tracker.setEnabled(false)                    // a stale/other answer the SDK might give
        await store.loadUsagePreference()                  // second Diagnostics visit
        #expect(store.usageSharingEnabled == true)
    }

    @Test("An issue button records issue_action with its kind and the card's severity")
    func issueAction() async {
        let conflict = TestIssues.make(id: "c1", action: .reviewVersions, severity: .conflict)
        let stuck = TestIssues.make(id: "s1", action: .openDiagnostics, severity: .error)
        let (store, tracker) = makeStore(snapshot: .minimal(issues: [conflict, stuck]))
        await store.refresh(force: true)
        IssuePrimaryAction.reviewVersions.perform(on: store, issue: conflict)
        IssuePrimaryAction.openDiagnostics.perform(on: store, issue: stuck)
        #expect(tracker.events == [
            .issueAction(.review_versions, severity: .conflict),
            .issueAction(.open_diagnostics, severity: .error),
            .viewShown(.diagnostics, via: .link),
        ], "got \(tracker.events)")
        #expect(IssuePrimaryAction.openAppleAccountSettings.usageKind == .manage_storage)
    }

    @Test("snapshot_health reports the right permission for each prop, and unknown counts as not granted")
    func healthPermissionsByKind() async {
        var snapshot = SyncSnapshot.minimal()
        snapshot.permissions = [
            PermissionStatus(kind: .notifications, state: .unknown),
            PermissionStatus(kind: .fullDiskAccess, state: .granted),
        ]
        let (store, tracker) = makeStore(snapshot: snapshot)
        await store.applicationDidBecomeActive()
        await store.refresh(force: true)
        #expect(tracker.events.last == .snapshotHealth(
            appsByBackend: [:], issueCount: 0, daemonsMissing: 0, fdaGranted: true, notificationsGranted: false))
    }

    @Test("snapshot_health and the launch view_shown fire once per launch, not per refresh")
    func healthOnce() async {
        let (store, tracker) = makeStore()
        await store.applicationDidBecomeActive()
        await store.refresh(force: true)
        await store.refresh(force: true)
        await store.applicationDidBecomeActive()         // a later activation re-sends nothing
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
        await store.applicationDidBecomeActive()
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

    // An unattended login-item launch: snapshots land, nobody ever activates
    // the app. Fails on the old store, which recorded view_shown(.launch) +
    // snapshot_health right after the first snapshot — and swift-stats opens
    // a session on any captured event.
    @Test("Launch events are held until a real activation, then sent exactly once and after it")
    func launchEventsWaitForActivation() async {
        let (store, tracker) = makeStore()
        await store.refresh(force: true)
        await store.refresh(force: true)
        #expect(tracker.calls.isEmpty, "an unattended launch records nothing: got \(tracker.calls)")

        await store.applicationDidBecomeActive()
        #expect(tracker.calls == ["didBecomeActive", "view_shown", "snapshot_health"], "got \(tracker.calls)")
        #expect(tracker.events.first == .viewShown(.overview, via: .launch))
    }

    @Test("Opening the popover before any activation releases the launch events ahead of menubar_opened")
    func menuBarReleasesLaunchEvents() async {
        let (store, tracker) = makeStore()
        await store.refresh(force: true)
        await store.menuBarOpened()
        #expect(tracker.calls == ["didBecomeActive", "view_shown", "snapshot_health", "menubar_opened"],
                "got \(tracker.calls)")
    }

    @Test("Opening the menu-bar popover activates the session before recording the open")
    func menuBarOpenedActivatesFirst() async {
        let (store, tracker) = makeStore()
        await store.menuBarOpened()
        #expect(tracker.calls == ["didBecomeActive", "menubar_opened"], "got \(tracker.calls)")
        #expect(tracker.events == [.menubarOpened(issueCount: 0, paused: false)])
    }

    @Test("Opt-out flows through to the tracker's master switch")
    func optOut() async {
        let (store, tracker) = makeStore()
        #expect(store.usageSharingEnabled == nil, "unknown until loaded, never a guessed true")
        #expect(store.setUsageSharing(false) == nil, "no write before the stored value is known")
        await store.loadUsagePreference()
        #expect(store.usageSharingEnabled == true)
        await store.setUsageSharing(false)?.value
        #expect(await tracker.isEnabled == false)
        #expect(store.usageSharingEnabled == false)
    }

    /// Pins the contract (call order, final SDK state = last value shown)
    /// with a slow first write. It cannot force the old overtake: that race
    /// depends on the scheduler, and C8 rules out provoking it. The ordering
    /// itself is by construction — each write awaits the one before it.
    @Test("Toggles made while a write is slow land in call order and end on the value shown", .timeLimit(.minutes(1)))
    func togglesAreOrdered() async {
        let tracker = SlowWriteUsageTracker()
        let store = SyncStore(source: StubSyncSource(snapshot: .minimal()), notifier: noBanners, defaults: throwawayDefaults(), usage: tracker)
        await store.loadUsagePreference()
        store.setUsageSharing(false)
        await tracker.firstWriteEntered()         // the first write is now parked
        let last = store.setUsageSharing(true)
        tracker.releaseFirstWrite()
        await last?.value
        #expect(tracker.writes == [false, true])
        #expect(await tracker.isEnabled == true)
        #expect(store.usageSharingEnabled == true)
    }

    // Fails if a flip is accepted while the first read is suspended (the read
    // would then land its old answer over it), or if a later load re-reads
    // the SDK and puts an old answer back over a flip.
    @Test("No flip lands during the first read, and a later load never re-reads", .timeLimit(.minutes(1)))
    func loadDoesNotOverwriteFlip() async {
        let tracker = GatedReadUsageTracker()
        let store = SyncStore(source: StubSyncSource(snapshot: .minimal()), notifier: noBanners,
                              defaults: throwawayDefaults(), usage: tracker)
        let load = Task { await store.loadUsagePreference() }
        await tracker.waitUntilReadStarted()          // the load holds its answer
        #expect(store.setUsageSharing(false) == nil, "nothing to flip while the value is unknown")
        #expect(store.usageSharingEnabled == nil)
        tracker.releaseRead(answer: true)
        await load.value
        #expect(store.usageSharingEnabled == true)

        await store.setUsageSharing(false)?.value
        await store.loadUsagePreference()             // e.g. Settings opened after the flip
        #expect(store.usageSharingEnabled == false)
        #expect(tracker.reads == 1, "the stored value is read once per launch")
    }

    @Test("With analytics gated off the switch is unavailable and does not move")
    func gatedOffSwitchIsInert() async {
        let store = SyncStore(source: StubSyncSource(snapshot: .minimal()), notifier: noBanners,
                              defaults: throwawayDefaults(), usage: NoopUsageTracker())
        #expect(!store.usageSharingAvailable)
        await store.loadUsagePreference()
        #expect(store.usageSharingEnabled == false, "a no-op tracker reports sharing off")
        #expect(store.setUsageSharing(true) == nil)
        #expect(store.usageSharingEnabled == false)
        #expect(makeStore().0.usageSharingAvailable, "a configured tracker keeps the switch")
    }
}

/// A tracker whose FIRST `setEnabled` parks until released — the slow write a
/// rapid second toggle must not overtake.
final class SlowWriteUsageTracker: UsageTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var isFirst = true
    private var _writes: [Bool] = []
    private var _enabled = true

    var writes: [Bool] { lock.withLock { _writes } }
    func record(_ event: UsageEvent) {}
    func applicationDidBecomeActive() async {}
    func flush() async {}
    var isEnabled: Bool { get async { lock.withLock { _enabled } } }

    func setEnabled(_ enabled: Bool) async {
        let park = lock.withLock { defer { isFirst = false }; return isFirst }
        if park {
            await withCheckedContinuation { c in
                let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    parked = c; didEnter = true
                    defer { entered = nil }
                    return entered
                }
                waiter?.resume()
            }
        }
        lock.withLock { _writes.append(enabled); _enabled = enabled }
    }

    /// Returns once the first write is parked.
    func firstWriteEntered() async {
        await withCheckedContinuation { c in
            let already = lock.withLock { () -> Bool in
                if didEnter { return true }
                entered = c
                return false
            }
            if already { c.resume() }
        }
    }

    func releaseFirstWrite() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { parked = nil }; return parked }?.resume()
    }
}

/// A tracker whose FIRST `isEnabled` read waits until the test releases it,
/// so a flip can be attempted while a load is suspended — ordering by
/// continuation, not by sleeping. Later reads answer `true` at once, so a
/// regression that re-reads shows up as a wrong value, not a hang.
final class GatedReadUsageTracker: UsageTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var pending: CheckedContinuation<Bool, Never>?
    private var _reads = 0

    var reads: Int { lock.withLock { _reads } }
    func record(_ event: UsageEvent) {}
    func applicationDidBecomeActive() async {}
    func flush() async {}
    func setEnabled(_ enabled: Bool) async {}
    var isEnabled: Bool {
        get async {
            let first = lock.withLock { () -> Bool in _reads += 1; return _reads == 1 }
            guard first else { return true }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                    pending = continuation
                    didStart = true
                    defer { started = nil }
                    return started
                }
                waiter?.resume()
            }
        }
    }

    func waitUntilReadStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = lock.withLock {
                if didStart { return true }
                started = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }

    func releaseRead(answer: Bool) {
        let continuation = lock.withLock { defer { pending = nil }; return pending }
        continuation?.resume(returning: answer)
    }
}
