import Foundation
import Testing
@testable import Birdwatch

/// `--mock` is how the honest states get looked at without waiting for a real
/// Mac to be in them, so the fixture must (1) contain each of them and (2)
/// contain nothing a real backend cannot produce. Every test here fails on
/// the pre-change mock (CloudKit/File Provider percentages, every row
/// confirmed or paused, no scan notice, no unobserved hours, named devices).
@Suite("Mock honest states")
struct MockHonestStatesTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let snapshot = MockSyncSource.snapshot(now: now)

    private func app(_ predicate: (AppSyncState) -> Bool) throws -> AppSyncState {
        let match = Self.snapshot.apps.first(where: predicate)
        return try #require(match)
    }

    @Test("Only CloudDocs rows carry a progress figure; CloudKit work is .active")
    func noInventedPercentages() throws {
        for app in Self.snapshot.apps where app.backend != .cloudDocs {
            #expect(!app.status.isSyncing, "\(app.name): \(app.backend) reports no progress")
        }
        let photos = try app { $0.name == "Photos" }
        #expect(photos.backend == .cloudKit)
        #expect(photos.status == .active)
    }

    @Test("No row is in a state no backend produces (paused, issue)")
    func noImpossibleRowStates() {
        for app in Self.snapshot.apps {
            switch app.status {
            case .paused, .issue: Issue.record("\(app.name) is \(app.status)")
            default: break
            }
        }
        #expect(!Self.snapshot.driveFolders.contains { $0.status == .paused })
    }

    @Test("Desktop & Documents is on but unwatched without Full Disk Access")
    func desktopDocumentsNeedsFDA() throws {
        let dd = try app { $0.id == "desktop-documents" }
        #expect(dd.needsFullDiskAccess)
        #expect(dd.status == .unknown)
        #expect(!Self.snapshot.transfers.contains { $0.appID == "desktop-documents" })
        #expect(Self.snapshot.permissions.first { $0.name == "Full Disk Access" }?.state == .unknown, "not confirmed, so Desktop & Documents is not read")
    }

    @Test("File Provider rows are .unknown and a container row reads \"No activity seen\"")
    func unknownAndUnconfirmedRows() throws {
        let fp = Self.snapshot.apps.filter { $0.backend == .fileProvider }
        #expect(!fp.isEmpty)
        #expect(fp.allSatisfy { $0.status == .unknown })
        let container = try app(\.isAppContainer)
        #expect(SyncStatusDisplay(app: container, progressIsIndeterminate: false).label == "No activity seen")
    }

    @Test("A CloudKit scan notice is shown: fallback window, truncated")
    func cloudKitScanNotice() throws {
        let state = try #require(Self.snapshot.cloudKitScan)
        let text = try #require(CloudKitNotice.text(state, now: Self.now))
        #expect(text.contains("2m ago"))
        #expect(text.contains("too large to read in full"))
    }

    @Test("The plan cap is an estimate derived from bird's remaining quota")
    func estimatedPlanCap() throws {
        let storage = try #require(Self.snapshot.storage)
        #expect(storage.capSource == .derived)
        #expect(storage.remainingBytes == Self.snapshot.quotaRemainingBytes)
        // Apple publishes no per-service split: segments are file types.
        let categories = Set(StorageCategory.allCases.map(\.displayName))
        #expect(storage.segments.allSatisfy { categories.contains($0.name) })
    }

    @Test("Hours never sampled are marked unobserved and add nothing to the totals")
    func unobservedBandwidthHours() {
        let hours = Self.snapshot.bandwidth.hours
        #expect(hours.contains { !$0.isObserved })
        let observedUp = hours.filter(\.isObserved).reduce(Int64(0)) { $0 + $1.uploadedBytes }
        #expect(Self.snapshot.bandwidth.uploadedTodayBytes == observedUp)
    }

    // The old mock drew hours 7–23 whatever the time: bars before its own
    // launch and in hours still to come, under "since Birdwatch started".
    @Test("The mock chart covers only launch hour through the current hour")
    func mockBandwidthRespectsLaunch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6)))
        let launch = day.addingTimeInterval(9 * 3_600 + 1_200)      // 09:20
        let now = day.addingTimeInterval(13 * 3_600 + 300)          // 13:05
        let observed = MockSyncSource.bandwidth(now: now, launchedAt: launch, calendar: calendar)
            .hours.filter(\.isObserved).map(\.hour)
        #expect(observed == [9, 10, 11, 12, 13])

        let justLaunched = MockSyncSource.bandwidth(now: launch, launchedAt: launch, calendar: calendar)
        #expect(justLaunched.hours.filter(\.isObserved).map(\.hour) == [9])

        let yesterday = MockSyncSource.bandwidth(now: now, launchedAt: launch - 86_400, calendar: calendar)
        #expect(yesterday.hours.filter(\.isObserved).map(\.hour) == Array(0...13), "today starts at midnight")
    }

    // Fails on the old mock: a hand-written engine card ("Reachable ·
    // api.icloud.com", "Throttled — next window in 4m", a Δ token) that no
    // builder can produce, and that disagreed with the rows' bird state.
    @Test("The engine card is what the live builder makes from the mock's dump, and agrees with the rows")
    func engineFromDump() throws {
        let engine = Self.snapshot.engine
        let status = MockSyncSource.birdStatus(now: Self.now)
        #expect(status.clientState != nil, "the dump's container line parsed")
        let expected = SystemSyncSource.engine(
            reading: .init(state: status, dumpAge: 60, dumpHasContainer: true),
            mapped: .init(BrctlDumpParser.parse(MockSyncSource.dumpText(now: Self.now)), cloudDocsState: status),
            dumpFailure: nil, fullDiskAccess: .unknown)
        #expect(engine == expected)
        // The same bird state the rows were built from.
        #expect(engine.clientState == status.clientState)
        #expect(engine.serverState == status.serverState)
        #expect(engine.lastSyncToken == status.tokenInfo)
        let drive = try app { $0.id == "icloud-drive" }
        #expect(drive.lastActivity == status.lastSync)
        // Built from the dump's own figures, not invented ones.
        #expect(engine.metadataIndex.contains("71,489") || engine.metadataIndex.contains("71489"))
        #expect(!engine.pushThrottled, "the captured budget line says budget available")
        for invented in ["api.icloud.com", "next window", "Δ", "Healthy"] {
            #expect(![engine.serverState, engine.clientState, engine.lastSyncToken,
                      engine.pushBudget, engine.metadataIndex].joined().contains(invented))
        }
    }

    @Test("Only the permissions the real probe checks")
    func probedPermissionsOnly() {
        #expect(Self.snapshot.permissions.map(\.name) == ["Full Disk Access", "Notifications"])
    }

    @Test("Devices are bird's anonymous attribution, never names")
    func noDeviceNames() throws {
        #expect(Self.snapshot.devices.isEmpty)
        #expect(try #require(Self.snapshot.deviceActivity).devices.count > 0)
    }
}
