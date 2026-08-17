import Foundation
import Testing
@testable import Birdwatch

/// Real `log show --predicate 'subsystem == "com.apple.cloudkit"'` lines
/// captured from this machine (2026-08-14), sanitized: two in-development
/// third-party bundle ids were renamed to `com.example.*`. Nothing else is
/// altered — spacing, field order and the `<private>` redactions are the
/// system's own.
private nonisolated func logFixture() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/cloudkit-log-sample.txt")
    return try String(contentsOf: url, encoding: .utf8)
}

/// 93 observed containerID ↔ applicationBundleID pairs from the same machine.
private nonisolated func containerBundleFixture() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/cloudkit-container-bundles.txt")
    return try String(contentsOf: url, encoding: .utf8)
}

private nonisolated let fixtureNow = ISO8601DateFormatter().date(from: "2026-08-14T21:00:00-04:00")!

@Suite("CloudKit log parsing")
struct CloudKitLogParserTests {

    @Test("Timestamps parse from the real log column")
    func timestampParsing() {
        let line: Substring = "2026-08-14 15:43:09.855209-0400 0x582a5    Default     0x1f25eb             1031   0    cloudd: hi"
        let date = CloudKitLogParser.timestamp(in: line)
        let expected = ISO8601DateFormatter().date(from: "2026-08-14T15:43:09-04:00")!
        #expect(date != nil)
        #expect(abs(date!.timeIntervalSince(expected) - 0.855209) < 0.001)
    }

    @Test("Non-timestamp lines are ignored, not crashed on", arguments: [
        "", "   ", "Filtering the log data using \"subsystem == \\\"com.apple.cloudkit\\\"\"",
        "Timestamp                       Thread     Type        Activity             PID    TTL",
        "not a log line at all",
    ])
    func garbageLines(line: String) {
        #expect(CloudKitLogParser.timestamp(in: Substring(line)) == nil)
    }

    @Test("Field extraction stops at the right terminator")
    func fieldExtraction() {
        let line: Substring = "TCC approved access for container containerID=com.apple.photos.cloud:Production, applicationID=<CKDApplicationID: 0x1; pushTopic=com.apple.icloud-container.com.apple.photos.cloud, TCC=com.apple.Photos, applicationBundleID=com.apple.cloudphotod>"
        #expect(CloudKitLogParser.value(of: "containerID", in: line) == "com.apple.photos.cloud:Production")
        #expect(CloudKitLogParser.value(of: "applicationBundleID", in: line) == "com.apple.cloudphotod")
        #expect(CloudKitLogParser.normalizeContainer("com.apple.photos.cloud:Production") == "com.apple.photos.cloud")
        #expect(CloudKitLogParser.normalizeContainer("iCloud.com.example.mailapp:Sandbox") == "iCloud.com.example.mailapp")
    }

    @Test("Operation classes collapse client and daemon spellings", arguments: [
        ("Starting <CKDUploadAssetsOperation: 0x1; qos=Utility>", "UploadAssets"),
        ("Starting <CKDDownloadAssetsOperation: 0x1; qos=Utility>", "DownloadAssets"),
        ("Starting <CKDModifyRecordsOperation: 0x1; qos=Utility>", "ModifyRecords"),
        ("Starting operation <CKModifyRecordsOperation: 0x1; container=x>", "ModifyRecords"),
        ("Starting <CKDFetchRecordZoneChangesOperation: 0x1>", "FetchRecordZoneChanges"),
        ("Starting <CKDFetchUserQuotaOperation: 0x1>", "FetchUserQuota"),
    ])
    func operationKinds(pair: (String, String)) {
        #expect(CloudKitLogParser.operationKind(in: Substring(pair.0)) == pair.1)
    }

    @Test("Lines with no operation yield no kind")
    func noOperationKind() {
        #expect(CloudKitLogParser.operationKind(in: "Consulting TCC for access for container <private>...") == nil)
        #expect(CloudKitLogParser.operationKind(in: "<CKDApplicationID: 0x7afb316be0>") == nil)
    }

    @Test("Every fixture container maps to its observed bundle id")
    func containerBundlePairsFromFixture() throws {
        let map = CloudKitLogParser.containerActivity(try logFixture())
        #expect(map["com.apple.photos.cloud"]?.bundleID == "com.apple.cloudphotod")
        #expect(map["com.apple.SafariShared.CloudTabs"]?.bundleID == "com.apple.Safari")
        #expect(map["com.apple.SafariShared.History"]?.bundleID == "com.apple.Safari")
        #expect(map["com.apple.messages.cloud"]?.bundleID == "com.apple.imagent")
        #expect(map["com.apple.clouddocs"]?.bundleID == "com.apple.bird")
        #expect(map["iCloud.company.thebrowser.Browser"]?.bundleID == "company.thebrowser.Browser")
    }

    @Test("The 93-pair capture parses every containerID/bundle pair")
    func fullPairFixture() throws {
        let text = try containerBundleFixture()
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        var parsed = 0
        for line in lines where CloudKitLogParser.value(of: "applicationBundleID", in: line) != nil {
            #expect(CloudKitLogParser.value(of: "containerID", in: line) != nil)
            parsed += 1
        }
        #expect(parsed == lines.count)
        #expect(lines.count == 93)
    }

    @Test("Notes never appears — absence is the signal (the hardcoded row was fabricated)")
    func notesIsAbsent() throws {
        let activities = CloudKitLogParser.parse(try logFixture(), now: fixtureNow)
        #expect(!activities.contains { $0.bundleID.lowercased().contains("notes") })
    }

    @Test("Asset operations are credited through their operation group")
    func assetAttributionViaGroup() throws {
        let map = CloudKitLogParser.containerActivity(try logFixture())
        // cloudd's CKDUploadAssetsOperation lines carry no container at all;
        // only the operationGroupID shared with the client line links them.
        let withAssets = map.values.filter { $0.lastAssetTransfer != nil }
        #expect(!withAssets.isEmpty)
        #expect(withAssets.allSatisfy { $0.bundleID != nil })
    }

    @Test("Empty and garbage output produce an empty list, never a crash", arguments: [
        "", "\n\n\n", "Filtering the log data using \"subsystem\"\n",
        "containerID= applicationBundleID=\n", "<CKDUploadAssetsOperation:>",
    ])
    func garbageTolerance(output: String) {
        #expect(CloudKitLogParser.parse(output, now: fixtureNow).isEmpty)
    }
}

@Suite("Process output throughput")
struct ProcessRunnerThroughputTests {

    /// `log show` emits ~2 MB for a 30-minute CloudKit window. A byte-at-a-time
    /// drain moved ~73 KB/s and blew the 30s timeout on the real machine, so
    /// this fails if the chunked drain ever regresses.
    @Test("A multi-megabyte stdout drains in well under a second")
    func bulkOutputIsFast() async throws {
        let runner = ProcessRunner()
        let start = Date()
        let out = try await runner.run(
            toolPath: "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1048576", "count=4"],
            timeout: .seconds(10)
        )
        #expect(out.utf8.count >= 3 * 1024 * 1024)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite("CloudKit state derivation")
struct CloudKitStateTests {

    private nonisolated func entry(
        upload: TimeInterval? = nil, modify: TimeInterval? = nil, throttle: TimeInterval? = nil
    ) -> CloudKitContainerActivity {
        CloudKitContainerActivity(
            containerID: "c", bundleID: "b", lastActivity: fixtureNow,
            lastAssetTransfer: upload.map { fixtureNow.addingTimeInterval(-$0) },
            lastModifyRecords: modify.map { fixtureNow.addingTimeInterval(-$0) },
            lastFetch: nil,
            lastThrottle: throttle.map { fixtureNow.addingTimeInterval(-$0) }
        )
    }

    @Test("Asset transfer at 4m59s is transferring; at 5m01s it is not")
    func transferBoundary() {
        #expect(CloudKitLogParser.state(for: [entry(upload: 299)], now: fixtureNow) == .transferring)
        #expect(CloudKitLogParser.state(for: [entry(upload: 301)], now: fixtureNow) == .idle)
        #expect(CloudKitLogParser.state(for: [entry(upload: 300)], now: fixtureNow) == .transferring)
    }

    @Test("ModifyRecords inside the window is pushing; outside it is idle")
    func pushBoundary() {
        #expect(CloudKitLogParser.state(for: [entry(modify: 299)], now: fixtureNow) == .pushing)
        #expect(CloudKitLogParser.state(for: [entry(modify: 301)], now: fixtureNow) == .idle)
    }

    @Test("Throttle uses a 10-minute window and loses to active transfer")
    func throttleWindow() {
        #expect(CloudKitLogParser.state(for: [entry(throttle: 599)], now: fixtureNow) == .throttled)
        #expect(CloudKitLogParser.state(for: [entry(throttle: 601)], now: fixtureNow) == .idle)
        #expect(CloudKitLogParser.state(for: [entry(upload: 10, throttle: 10)], now: fixtureNow) == .transferring)
        #expect(CloudKitLogParser.state(for: [entry(modify: 10, throttle: 10)], now: fixtureNow) == .pushing)
    }

    @Test("Future timestamps (clock skew) never count as recent")
    func clockSkew() {
        #expect(CloudKitLogParser.state(for: [entry(upload: -60)], now: fixtureNow) == .idle)
    }

    @Test("Throttle lines are detected and attributed")
    func throttleDetection() {
        // No throttling occurred in 24h of real logs on this machine, so this
        // line is synthesized in the shape cloudd emits.
        let output = """
        2026-08-14 20:59:30.000000-0400 0x1 Default 0x1 1031 0 cloudd: (CloudKitDaemon) [com.apple.cloudkit:CK] TCC approved access for container containerID=com.apple.photos.cloud:Production, applicationID=<CKDApplicationID: 0x1; applicationBundleID=com.apple.cloudphotod>
        2026-08-14 20:59:40.000000-0400 0x1 Default 0x1 1031 0 cloudd: (CloudKitDaemon) [com.apple.cloudkit:CK] Adding operation to container throttle queue for container=com.apple.photos.cloud, retryAfter=42
        """
        let activities = CloudKitLogParser.parse(output, now: fixtureNow)
        #expect(activities.count == 1)
        #expect(activities.first?.state == .throttled)
        #expect(activities.first?.bundleID == "com.apple.cloudphotod")
    }
}

@Suite("CloudKit bundle → app mapping")
struct CloudKitAppMappingTests {

    @Test("Daemons map to their user-facing app", arguments: [
        ("com.apple.cloudphotod", "com.apple.Photos"),
        ("com.apple.imagent", "com.apple.MobileSMS"),
        ("com.apple.imtransferagent", "com.apple.MobileSMS"),
        ("com.apple.remindd", "com.apple.reminders"),
        ("com.apple.Safari", "com.apple.Safari"),
        ("company.thebrowser.Browser", "company.thebrowser.Browser"),
    ])
    func daemonMapping(pair: (String, String)) {
        #expect(CloudKitAppMapping.userFacingBundleID(for: pair.0) == pair.1)
    }

    @Test("bird is skipped — iCloud Drive already has a first-class row")
    func birdIsSkipped() {
        #expect(CloudKitAppMapping.userFacingBundleID(for: "com.apple.bird") == nil)
    }

    @Test("Known apps keep the stable ids the rest of the app addresses")
    func stableIDs() {
        #expect(CloudKitAppMapping.appID(forBundle: "com.apple.Photos") == "photos")
        #expect(CloudKitAppMapping.appID(forBundle: "com.apple.MobileSMS") == "messages")
        #expect(CloudKitAppMapping.appID(forBundle: "com.apple.Safari") == "safari")
        #expect(CloudKitAppMapping.appID(forBundle: "company.thebrowser.Browser") == "ck-company-thebrowser-browser")
    }

    @Test("Tile colors: design palette for known apps, FNV for the rest")
    func tiles() {
        #expect(CloudKitAppMapping.tileColorHex(appID: "photos", name: "Photos") == "fe4f6d")
        #expect(CloudKitAppMapping.tileColorHex(appID: "messages", name: "Messages") == "34c759")
        #expect(CloudKitAppMapping.tileColorHex(appID: "ck-x", name: "Arc")
                == AppContainerSource.tileColorHex(forName: "Arc"))
    }

    @Test("Apple-ness comes from the bundle id")
    func appleFlag() {
        #expect(CloudKitAppMapping.isAppleBundle("com.apple.Photos"))
        #expect(!CloudKitAppMapping.isAppleBundle("company.thebrowser.Browser"))
    }

    @Test("Status lines describe observed state and recency")
    func statusLines() {
        let now = fixtureNow
        #expect(CloudKitAppMapping.statusLine(state: .transferring, lastActivity: now, now: now) == "Transferring now")
        #expect(CloudKitAppMapping.statusLine(state: .pushing, lastActivity: now, now: now) == "Pushing changes")
        #expect(CloudKitAppMapping.statusLine(state: .throttled, lastActivity: now, now: now) == "Throttled by iCloud")
        #expect(CloudKitAppMapping.statusLine(state: .idle, lastActivity: nil, now: now) == "No recent activity")
        #expect(CloudKitAppMapping.statusLine(
            state: .idle, lastActivity: now.addingTimeInterval(-30), now: now) == "Last synced just now")
        #expect(CloudKitAppMapping.statusLine(
            state: .idle, lastActivity: now.addingTimeInterval(-120), now: now) == "Last synced 2m ago")
        #expect(CloudKitAppMapping.statusLine(
            state: .idle, lastActivity: now.addingTimeInterval(-7200), now: now) == "Last synced 2h ago")
    }

    @Test("Rows are honest: never a progress percentage, always a real timestamp")
    func rowShape() {
        let activity = CloudKitAppActivity(
            bundleID: "com.apple.Photos", containers: ["com.apple.photos.cloud"],
            lastActivity: fixtureNow.addingTimeInterval(-60), state: .pushing, operationCount: 12
        )
        let row = CloudKitAppMapping.makeApp(
            activity: activity, bundleID: "com.apple.Photos", displayName: "Photos", now: fixtureNow
        )
        #expect(row.id == "photos")
        #expect(row.backend == .cloudKit)
        #expect(row.status == .upToDate)
        #expect(row.statusLine == "Pushing changes")
        #expect(row.lastActivity == fixtureNow.addingTimeInterval(-60))
        #expect(row.infoCallout?.contains("no public per-item or per-app progress API") == true)
        #expect(row.infoCallout?.contains("com.apple.photos.cloud") == true)
    }
}

@Suite("CloudKit rows in the app list")
struct CloudKitBuildAppsTests {

    @Test("buildApps ships only the observed CloudKit rows")
    func onlyObservedRows() {
        let observed = [
            CloudKitAppMapping.makeApp(
                activity: CloudKitAppActivity(bundleID: "com.apple.Photos", containers: ["com.apple.photos.cloud"],
                                              lastActivity: fixtureNow, state: .idle, operationCount: 1),
                bundleID: "com.apple.Photos", displayName: "Photos", now: fixtureNow),
        ]
        let apps = SystemSyncSource.buildApps(
            status: nil, transfers: [], fileProviderDomains: [], cloudKitApps: observed
        )
        let ck = apps.filter { $0.backend == .cloudKit }
        #expect(ck.map(\.id) == ["photos"])
        #expect(!apps.contains { $0.id == "notes" })      // no observation → no row
    }

    @Test("No observations means no CloudKit rows at all")
    func emptyObservations() {
        let apps = SystemSyncSource.buildApps(status: nil, transfers: [], fileProviderDomains: [])
        #expect(apps.filter { $0.backend == .cloudKit }.isEmpty)
    }
}
