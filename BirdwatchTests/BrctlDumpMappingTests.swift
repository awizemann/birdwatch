import Foundation
import Testing
@testable import Birdwatch

/// Same hand-redacted `brctl dump -i` capture the parser suite uses. These
/// tests cover the LAYER ABOVE the parser: what the UI is allowed to say about
/// it.
private nonisolated func dumpFixture() throws -> BrctlDump {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/brctl-dump-excerpt.txt")
    return BrctlDumpParser.parse(try String(contentsOf: url, encoding: .utf8))
}

/// A minimal container section carrying one item plus one operation line.
private nonisolated func dump(withOperation operation: String, uploadState: String = "needs-sync-up") -> BrctlDump {
    BrctlDumpParser.parse("""
    1 containers matching '*'
    -----------------------------------------------------
        r:1 i:<ITEM1> al:1 up:\(uploadState) uv:0 st{p:<root[1]> n:"a{3}b.pdf" doc}
        \(operation)
    """)
}

@Suite("brctl dump → UI mapping")
struct BrctlDumpMappingTests {

    // MARK: - Retry queue

    @Test("Retry queue keeps non-idle items plus idle items that carry a live retry")
    func retryQueueMembership() throws {
        let queue = BrctlDumpMapper.retryQueue(from: try dumpFixture())

        // The three non-idle items, plus the idle item whose `apply` retry is
        // live. The two idle `{[1 old]}` bookkeeping items never appear.
        #expect(queue.map(\.id).sorted()
            == ["15478C83", "E0A2E171", "documents[148]", "documents[171]"])
        // Highest attempt count first — that is the row worth reading.
        #expect(queue.first?.id == "documents[148]")
        #expect(queue.first?.attempt == 3)
    }

    @Test("Row names are the file type only — never bird's redacted name pattern")
    func retryQueueNames() throws {
        let queue = BrctlDumpMapper.retryQueue(from: try dumpFixture())
        let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })

        #expect(byID["E0A2E171"]?.name == ".bin file")     // n:"REDACTED-1.bin"
        #expect(byID["documents[171]"]?.name == "Folder")  // dir, no extension
        #expect(byID["15478C83"]?.name == ".txt file")
        // Nothing leaks bird's `x{5}y` redaction pattern into the UI.
        #expect(!queue.contains { $0.name.contains("{") })
    }

    @Test("Rows carry the real wait and the card knows the true total")
    func retryQueueWaitAndTotal() throws {
        let dump = try dumpFixture()
        let queue = BrctlDumpMapper.retryQueue(from: dump)
        let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })

        #expect(byID["documents[171]"]?.lastAttemptAgo == 1_805.75 * 3_600)
        #expect(byID["E0A2E171"]?.lastAttemptAgo == 7.56)
        // Equal attempt counts (0) tie-break on the longest wait, because on a
        // healthy account that is the only thing that differs between rows.
        let zeroAttempts = queue.filter { $0.attempt == 0 }.map(\.id)
        #expect(zeroAttempts == ["documents[171]", "E0A2E171"])
        #expect(BrctlDumpMapper.retryQueueTotal(from: dump) == 4)
    }

    // MARK: - Stuck items

    @Test("Stuck threshold is 24h: 23h59m is not stuck, 24h01m is")
    func stuckBoundary() {
        let justUnder = dump(withOperation: "> sync-up{[zone:1 sync-up-scheduled attempts:0 last:23.983h ago next:ready]}")
        #expect(BrctlDumpMapper.stuckIssue(from: justUnder) == nil)

        let justOver = dump(withOperation: "> sync-up{[zone:1 sync-up-scheduled attempts:0 last:24.017h ago next:ready]}")
        let issue = try! #require(BrctlDumpMapper.stuckIssue(from: justOver))
        #expect(issue.id == "issue-stuck-items")
        #expect(issue.severity == .warning)
        #expect(issue.appID == "icloud-drive")
        // attempts:0 still counts as stuck — a first try that never happened
        // in 24h is exactly the symptom the user cares about.
        #expect(issue.title == "1 item hasn't synced in 1 day")
    }

    @Test("Stuck issue counts items and reports the oldest age in days")
    func stuckAggregate() throws {
        let issue = try #require(BrctlDumpMapper.stuckIssue(from: try dumpFixture()))
        // One sync-up item last attempted 1805.75h ago (≈75 days); the other
        // sync-up (12.5m), the `apply` (3.83m) and the active upload (7.56s)
        // are all recent enough not to count.
        #expect(issue.title == "1 item hasn't synced in 75 days")
    }

    // MARK: - Issues

    @Test("SyncHealthReport slots and the account error become error issues")
    func issueMapping() throws {
        let issues = BrctlDumpMapper.issues(from: try dumpFixture())
        let byID = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })

        let health = try #require(byID["issue-synchealth-syncUpError"])
        #expect(health.severity == .error)
        #expect(health.title == "Sync up error reported by bird")
        #expect(health.reason.contains("throttled"))
        // `none` slots are not issues.
        #expect(byID["issue-synchealth-uploadError"] == nil)

        let account = try #require(byID["issue-account-session"])
        #expect(account.severity == .error)
        #expect(account.meta.contains("BRCloudDocsErrorDomain:116"))
        #expect(account.reason.contains("Can't get persona"))
    }

    @Test("The account UUID in bird's error text is redacted before display")
    func redactsAccountIdentifier() {
        let redacted = BrctlDumpMapper.redact(
            "Can't get persona for accountID 049437CE-DE02-4816-9330-3013C7D65A56"
        )
        #expect(redacted == "Can't get persona for accountID «account id»")
    }

    // MARK: - Engine

    @Test("Engine enrichment uses the PERCENT budget spelling and the real item counts")
    func engineEnrichment() throws {
        let base = SyncEngineInfo(
            serverState: "idle", clientState: "idle", lastSyncToken: "—",
            pushBudget: "Not measured", pushThrottled: false,
            metadataIndex: "Reachable via brctl", metadataHealthy: true
        )
        let engine = BrctlDumpMapper.enrich(base, with: try dumpFixture())

        // `m:0.0% (0.5)` — 0.0 is the percent; 0.5 is bird's raw budget value
        // in its own units and must never be shown as a percentage.
        #expect(engine.pushBudget == "Used 0%/min · 0%/hr · 0%/day")
        #expect(!engine.pushBudget.contains("0.5"))
        #expect(!engine.pushBudget.contains("98.7"))
        // The fixture's syncUpError is "throttled", so the row goes amber.
        #expect(engine.pushThrottled == true)

        #expect(engine.metadataIndex.contains("133,111"))
        #expect(engine.metadataIndex.contains("133,000"))
        #expect(engine.metadataIndex.contains("truncated"))
        #expect(engine.globalProgressLine?.hasPrefix("57%") == true)
    }

    @Test("A dump with no global progress leaves the row hidden rather than showing 0%")
    func noGlobalProgress() {
        let base = SyncEngineInfo(
            serverState: "", clientState: "", lastSyncToken: "", pushBudget: "Not measured",
            pushThrottled: false, metadataIndex: "", metadataHealthy: false
        )
        let engine = BrctlDumpMapper.enrich(base, with: BrctlDumpParser.parse("global progress {none}"))
        #expect(engine.globalProgressLine == nil)
    }

    // MARK: - Devices

    @Test("Device summary is anonymous, excludes device:0, and is ordered by activity")
    func deviceSummary() throws {
        let summary = try #require(BrctlDumpMapper.deviceSummary(from: try dumpFixture()))

        #expect(!summary.devices.contains { $0.index == 0 }, "device:0 is bird's placeholder, not a device")
        // Device 30's newest item is later than device 11's, so it leads.
        #expect(summary.devices.map(\.index) == [30, 11])
        #expect(summary.devices == summary.devicesByActivity)
        #expect(summary.countsArePartial, "bird truncated its item dump")
        // The registry lists five devices; only two authored an item in the
        // (truncated) tree — the headline must use the larger, real number.
        #expect(summary.registeredDeviceCount == 5)

        // "Active since" is a real last-write comparison, not a guess: device
        // 30's newest item (mt 1780242579) is later than device 11's.
        let deviceThirty = Date(timeIntervalSince1970: 1_780_242_579)
        #expect(summary.activeCount(since: Date(timeIntervalSince1970: 1_773_707_197)) == 2)
        #expect(summary.activeCount(since: deviceThirty) == 1)
        #expect(summary.activeCount(since: deviceThirty.addingTimeInterval(1)) == 0)
    }

    @Test("No device attribution at all yields no summary, so the empty state stays")
    func noDeviceActivity() {
        #expect(BrctlDumpMapper.deviceSummary(from: BrctlDump()) == nil)
    }

    @Test("Activity sort: newest write first, undated devices last, ties by item count")
    func activitySortOrder() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let items = [
            DeviceActivityItem(index: 1, itemCount: 99, lastModified: nil),
            DeviceActivityItem(index: 2, itemCount: 1, lastModified: old),
            DeviceActivityItem(index: 3, itemCount: 5, lastModified: new),
            DeviceActivityItem(index: 4, itemCount: 50, lastModified: nil),
            DeviceActivityItem(index: 5, itemCount: 7, lastModified: new),
        ]
        // 3 and 5 share the newest date, so the larger item count wins; the two
        // undated devices sort last, again by item count.
        #expect(DeviceActivitySummary.sortedByActivity(items).map(\.index) == [5, 3, 2, 1, 4])
    }

    @Test("Activity sort is stable and total for fully tied devices")
    func activitySortTies() {
        let date = Date(timeIntervalSince1970: 500)
        let items = [
            DeviceActivityItem(index: 9, itemCount: 3, lastModified: date),
            DeviceActivityItem(index: 2, itemCount: 3, lastModified: date),
        ]
        #expect(DeviceActivitySummary.sortedByActivity(items).map(\.index) == [2, 9])
    }
}

/// bird's retry queue → which row each scheduled item keeps from reading
/// "Up to date". Driven by the real-shape dump excerpt and candidates laid
/// out as they are on disk (built directly: the resolver is pure).
@MainActor
@Suite("Retry backlog attribution")
struct RetryBacklogAttributionTests {
    private static let home = "/Users/bw-test"
    private static let root = home + "/Library/Mobile Documents"

    private static func candidate(_ relative: String, isDirectory: Bool = false) -> PathCandidate {
        let path = root + "/" + relative
        return PathCandidate(
            path: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory,
            sizeBytes: nil, containerDirectoryName: String(relative.split(separator: "/")[0]))
    }

    /// The four scheduled items of the fixture: two in CloudDocs (one at the
    /// root, one in a folder) and one in each of two app containers.
    private static let candidates = [
        candidate("com~apple~CloudDocs/REDACTED-1.bin"),
        candidate("com~apple~CloudDocs/Projects", isDirectory: true),
        candidate("com~apple~CloudDocs/Projects/REDACTED-6.txt"),
        candidate("iCloud~com~microsoft~Office~Excel/Documents", isDirectory: true),
        candidate("iCloud~com~feedbacks~chatapp/Documents", isDirectory: true),
    ]

    private static func attribution() throws -> RetryAttribution {
        BrctlDumpMapper.retryAttribution(from: try dumpFixture(), candidates: candidates, homeDirectory: home)
    }

    @Test("Each scheduled item is placed by its container header, and by path inside CloudDocs")
    func placement() throws {
        let attribution = try Self.attribution()
        #expect(attribution.total == 4)
        #expect(attribution.locations["E0A2E171"] == .driveRootFile)
        #expect(attribution.locations["15478C83"] == .driveFolder("Projects"))
        #expect(attribution.locations["documents[171]"] == .app("container-icloud-com-microsoft-office-excel"))
        #expect(attribution.locations["documents[148]"] == .app("container-icloud-com-feedbacks-chatapp"))
        #expect(attribution.unplacedForFolders == 0)
        // What the fixture's operation lines say: E0A2E171 is an active upload
        // tried 7.56 s ago (queued work); documents[171] was last tried
        // 1805.75 h ago (old); documents[148] and 15478C83 have failed
        // (attempts:3 / attempts:1).
        #expect(attribution.stuckIDs == ["documents[171]", "documents[148]", "15478C83"])

        let bare = BrctlDumpMapper.retryAttribution(from: try dumpFixture(), candidates: [], homeDirectory: Self.home)
        #expect(bare.total == 4)
        #expect(bare.unplacedForFolders == 4, "nothing on disk to match: placed nowhere, never guessed")
    }

    // The soak-test bug: "Up to date · Sync engine idle", "Pending: None"
    // and "1 app up to date" beside "110 items haven't synced". Review fix:
    // iCloud Drive carried EVERY app's items (the popover counted them
    // twice) and called ordinary queued uploads "not syncing".
    @Test("Each row carries only its own items, split into not syncing and waiting")
    func rowsCarryTheBacklog() throws {
        let attribution = try Self.attribution()
        let idle = BrctlStatus(clientState: "idle", serverState: "idle", lastSync: nil, isIdle: true, tokenInfo: "t", apps: [])
        var excel = try #require(AppContainerSource.makeContainer(directoryName: "iCloud~com~microsoft~Office~Excel"))
        excel.itemCount = 3
        let apps = SystemSyncSource.buildApps(
            status: idle, transfers: [], fileProviderDomains: [], containers: [excel], retry: attribution)

        // Drive: its own two (the failed Projects item, the queued root file),
        // plus the failed chat-app item, whose container has no row here — so
        // no other row carries it, and it is labelled as not placed.
        let drive = try #require(apps.first { $0.id == "icloud-drive" })
        #expect(drive.status == .notSyncing(items: 2))
        #expect(drive.pendingItems == 3)
        #expect(drive.statusLine == "In bird's retry queue · 1 more waiting · 1 not placed on this Mac")
        #expect(AppDetailFacts.pendingValue(drive) == "3 items")
        let display = SyncStatusDisplay(app: drive, progressIsIndeterminate: true)
        #expect(display.label == "2 items not syncing")
        #expect(display.tone == .warning)

        let excelRow = try #require(apps.first { $0.id == excel.id })
        #expect(excelRow.status == .notSyncing(items: 1))

        let line = PopoverSummary.idleAppsLine(apps) ?? ""
        #expect(!line.contains("up to date"), "got \(line)")
        #expect(line.contains("2 apps with items not syncing"), "got \(line)")

        // Only queued work: neutral "waiting", never a warning.
        let queued = RetryAttribution(locations: ["q": .driveRootFile])
        let waiting = try #require(SystemSyncSource.buildApps(
            status: idle, transfers: [], fileProviderDomains: [], retry: queued).first { $0.id == "icloud-drive" })
        #expect(waiting.status == .waitingToSync(items: 1))
        #expect(SyncStatusDisplay(app: waiting, progressIsIndeterminate: true).tone == .neutral)
        #expect(PopoverSummary.idleAppsLine([waiting]) == "1 app with items waiting to sync")

        // Items no row could be found for land on iCloud Drive, labelled.
        let lost = RetryAttribution(locations: ["x": .unplaced], stuckIDs: ["x"])
        let lostRow = try #require(SystemSyncSource.buildApps(
            status: idle, transfers: [], fileProviderDomains: [], retry: lost).first { $0.id == "icloud-drive" })
        #expect(lostRow.status == .notSyncing(items: 1))
        #expect(lostRow.statusLine == "In bird's retry queue · 1 not placed on this Mac")

        // Review fix: an item attributed to a container that has NO row
        // (excluded, past the container cap) counted on no row at all. It
        // lands on iCloud Drive, labelled like any unplaced item; an item
        // whose container does have a row stays on that row only.
        let obsidian = try #require(AppContainerSource.makeContainer(directoryName: "iCloud~md~obsidian"))
        let orphaned = RetryAttribution(
            locations: ["o": .app("container-no-row"), "k": .app(obsidian.id)], stuckIDs: ["o", "k"])
        let rows = SystemSyncSource.buildApps(
            status: idle, transfers: [], fileProviderDomains: [], containers: [obsidian], retry: orphaned)
        let orphanDrive = try #require(rows.first { $0.id == "icloud-drive" })
        #expect(orphanDrive.status == .notSyncing(items: 1))
        #expect(orphanDrive.statusLine == "In bird's retry queue · 1 not placed on this Mac")
        #expect(rows.first { $0.id == obsidian.id }?.status == .notSyncing(items: 1))
        #expect(SystemSyncSource.backlogWithoutRow(orphaned, rowIDs: Set(rows.map(\.id))).total == 1)

        // A busy engine (.active) or a transfer (.syncing) keeps its own status.
        let busy = BrctlStatus(clientState: "busy", serverState: "idle", lastSync: nil, isIdle: false, tokenInfo: "t", apps: [])
        let busyDrive = SystemSyncSource.buildApps(
            status: busy, transfers: [], fileProviderDomains: [], retry: attribution).first { $0.id == "icloud-drive" }
        #expect(busyDrive?.status == .active)

        // No backlog: the engine's own idle still reads up to date.
        let clean = SystemSyncSource.buildApps(status: idle, transfers: [], fileProviderDomains: [], retry: RetryAttribution())
        #expect(clean.first { $0.id == "icloud-drive" }?.status == .upToDate)
    }

    @Test("Drive folders: own items say so; an item that could be anywhere leaves none green")
    func folders() throws {
        let folders = [DriveFolder(id: "Projects", name: "Projects", itemCount: 2, status: .upToDate),
                       DriveFolder(id: "Notes", name: "Notes", itemCount: 5, status: .upToDate)]
        let placed = DriveFolderSource.applying(transfers: [], to: folders, retry: try Self.attribution())
        #expect(placed.map(\.status) == [.notSyncing(items: 1), .upToDate])

        let queued = DriveFolderSource.applying(
            transfers: [], to: folders, retry: RetryAttribution(locations: ["q": .driveFolder("Notes")]))
        #expect(queued.map(\.status) == [.upToDate, .waitingToSync(items: 1)])

        var unplaced = try Self.attribution()
        unplaced.locations["mystery"] = .unplaced
        let uncertain = DriveFolderSource.applying(transfers: [], to: folders, retry: unplaced)
        #expect(uncertain.map(\.status) == [.notSyncing(items: 1), .unknown])
    }

    // L7: with no header, an "exact" match against a list that stopped at
    // its cap may be the wrong file — the right one was never listed.
    @Test("A header-less item matched against a capped candidate list stays unplaced")
    func partialCandidatesDontPlace() {
        let dump = BrctlDumpParser.parse("""
        1 containers matching '*'
        -----------------------------------------------------
            r:1 i:<ITEM1> al:1 up:needs-upload uv:0 st{p:<root[1]> n:"REDACTED-9.txt" doc}
        """)
        let found = [Self.candidate("com~apple~CloudDocs/Notes/REDACTED-9.txt")]
        let complete = BrctlDumpMapper.retryAttribution(from: dump, candidates: found, homeDirectory: Self.home)
        #expect(complete.locations["ITEM1"] == .driveFolder("Notes"))
        let partial = BrctlDumpMapper.retryAttribution(
            from: dump, candidates: found, candidatesArePartial: true, homeDirectory: Self.home)
        #expect(partial.locations["ITEM1"] == .unplaced)
    }
}
