import Foundation
import Testing
@testable import Birdwatch

/// The soak-test C1 failure: on Alan's Mac 110 scheduled items, each in its
/// own app container whose header matched exactly one real container, but
/// only 10 were placed — header placement matched only the containers the
/// CAPPED candidate walk happened to reach, and the rest were counted on no
/// row at all. A redacted fixture of the same shape (structure from the real
/// capture, synthetic names): five items in five distinct containers, one of
/// them excluded (so it has no row), plus iCloud Drive's own items.
@Suite("Every scheduled item lands on exactly one row")
struct BacklogConservationTests {

    private static func fixture() throws -> BrctlDump {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/brctl-dump-multi-container-excerpt.txt")
        return BrctlDumpParser.parse(try String(contentsOf: url, encoding: .utf8))
    }

    private static let directories = [
        "com~apple~CloudDocs", "com~apple~TextInput",
        "iCloud~com~example~Notes", "iCloud~org~sample~Sketch",
        "iCloud~net~demo~Ledger", "iCloud~app~quick~Board",
        "iCloud~com~example~Other",                 // nothing queued: must stay clean
    ]
    private static let idle = BrctlStatus(clientState: "idle", serverState: "idle", lastSync: nil,
                                          isIdle: true, tokenInfo: "t", apps: [])

    /// Sum of the backlog every row carries.
    private static func carried(_ apps: [AppSyncState]) -> Int {
        apps.reduce(0) { sum, app in
            switch app.status {
            case .notSyncing, .waitingToSync: sum + (app.pendingItems ?? 0)
            default: sum
            }
        }
    }

    @Test("Header placement uses the container list, not the capped candidate walk")
    func placedByHeaderWithoutCandidates() throws {
        let dump = try Self.fixture()
        // The walk reached nothing and stopped at its cap: the old code placed
        // no header-matched item at all in this situation.
        let attribution = BrctlDumpMapper.retryAttribution(
            from: dump, candidates: [], candidatesArePartial: true,
            containerDirectories: Self.directories, homeDirectory: "/h")
        let containers = Self.directories.compactMap { AppContainerSource.makeContainer(directoryName: $0) }
        #expect(containers.count == 5, "CloudDocs and TextInput get no row")
        let apps = SystemSyncSource.buildApps(status: Self.idle, transfers: [], fileProviderDomains: [],
                                              containers: containers, retry: attribution)

        for name in ["iCloud~com~example~Notes", "iCloud~org~sample~Sketch", "iCloud~net~demo~Ledger", "iCloud~app~quick~Board"] {
            let row = try #require(apps.first { $0.id == AppContainerSource.appID(forDirectory: name) })
            #expect(row.pendingItems == 1, "\(row.id): \(row.statusLine)")
        }
        let other = try #require(apps.first { $0.id == AppContainerSource.appID(forDirectory: "iCloud~com~example~Other") })
        #expect(other.status == .upToDate, "a container with nothing queued carries no backlog")

        // The invariant: nothing counted twice, nothing dropped.
        #expect(Self.carried(apps) == attribution.total)
        #expect(attribution.total == BrctlDumpMapper.pendingItems(dump).count)
        let drive = try #require(apps.first { $0.id == "icloud-drive" })
        #expect(drive.statusLine.contains("1 not placed on this Mac"), "the TextInput item, which has no row: \(drive.statusLine)")
    }

    // Soak finding: the Diagnostics list showed 10 items from different
    // containers than the rows flagged. Each listed item now names the row
    // that counts it, from the same attribution the rows use.
    @Test("Each listed retry item names the row that counts it")
    func listNamesItsRow() throws {
        let mapped = SystemSyncSource.MappedDump(try Self.fixture(), containerDirectories: Self.directories)
        let byID = Dictionary(uniqueKeysWithValues: mapped.retryQueue.map { ($0.id, $0.rowName) })
        #expect(byID["documents[201]"] == "Notes")
        #expect(byID["documents[205]"] == "iCloud Drive", "an app with no row of its own counts on iCloud Drive")
        let apps = SystemSyncSource.buildApps(
            status: Self.idle, transfers: [], fileProviderDomains: [],
            containers: Self.directories.compactMap { AppContainerSource.makeContainer(directoryName: $0) },
            retry: mapped.retryAttribution)
        let flagged = Set(apps.filter { if case .notSyncing = $0.status { true } else if case .waitingToSync = $0.status { true } else { false } }.map(\.name))
        for row in mapped.retryQueue {
            #expect(flagged.contains(try #require(row.rowName)), "\(row.id) names a row that carries no backlog")
        }
    }

    @Test("Attempts read as failures, with no invented ceiling")
    func attemptsWording() {
        #expect(DiagnosticsView.attemptsText(0) == "no failed attempts yet")
        #expect(DiagnosticsView.attemptsText(1) == "1 failed attempt")
        #expect(DiagnosticsView.attemptsText(3) == "3 failed attempts")
        #expect(DiagnosticsView.retryScope(shown: 10, total: 10).isEmpty)
        let scope = DiagnosticsView.retryScope(shown: 10, total: 110)
        #expect(scope.contains("Showing 10 of 110"))
        #expect(scope.contains(BrctlDumpMapper.retryRowOrder))
    }

    @Test("With no container list at all, everything still lands — on iCloud Drive, as not placed")
    func conservedWithoutContainers() throws {
        let dump = try Self.fixture()
        let attribution = BrctlDumpMapper.retryAttribution(from: dump, candidates: [], homeDirectory: "/h")
        let apps = SystemSyncSource.buildApps(status: Self.idle, transfers: [], fileProviderDomains: [], retry: attribution)
        #expect(Self.carried(apps) == attribution.total)
        #expect(attribution.total == BrctlDumpMapper.pendingItems(dump).count)
    }
}
