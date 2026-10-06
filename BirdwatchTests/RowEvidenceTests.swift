import Foundation
import Testing
@testable import Birdwatch

/// Each app row may claim only what something actually read about it (C1).
/// "No transfer seen" is not "synced": only a row whose idle comes from
/// bird's own engine state may read green "Up to date".
@Suite("Per-row status evidence")
struct RowEvidenceTests {

    private static let idleBird = BrctlStatus(clientState: "idle", serverState: "idle", lastSync: nil,
                                              isIdle: true, tokenInfo: nil, apps: [])

    private static func rows(fileProviderDomains: [String] = []) -> [AppSyncState] {
        var container = AppContainerSource.makeContainer(directoryName: "iCloud~md~obsidian")!
        container.itemCount = 3
        return SystemSyncSource.buildApps(status: idleBird, transfers: [],
                                          fileProviderDomains: fileProviderDomains, containers: [container])
    }

    // Fails on the old presentation: a container row with no transfer was
    // .upToDate on the CloudDocs backend, so it read green "Up to date".
    @Test("An idle per-app container row reads \"No activity seen\", not green \"Up to date\"")
    func containerIdleIsNotConfirmed() throws {
        let container = try #require(Self.rows().first { $0.id.hasPrefix("container-") })
        #expect(container.isAppContainer)
        #expect(container.status == .upToDate, "the source still says nothing is in flight")
        let display = SyncStatusDisplay(app: container, progressIsIndeterminate: false)
        #expect(display.label == "No activity seen")
        #expect(display.tone == .neutral)
    }

    // The control: bird's engine state DOES cover iCloud Drive.
    @Test("iCloud Drive idle on bird's word is still \"Up to date\"")
    func driveIdleIsConfirmed() throws {
        let drive = try #require(Self.rows().first { $0.id == "icloud-drive" })
        #expect(!drive.isAppContainer)
        let display = SyncStatusDisplay(app: drive, progressIsIndeterminate: false)
        #expect(display.label == "Up to date")
        #expect(display.tone == .confirmed)
    }

    @Test("A container row with a transfer in flight still reads as syncing")
    func containerSyncingUnchanged() throws {
        var container = AppContainerSource.makeContainer(directoryName: "iCloud~md~obsidian")!
        container.itemCount = 3
        let transfer = TransferItem(id: "t", appID: container.id, name: "n", location: "x",
                                    sizeBytes: 1, direction: .upload, progress: 0)
        let row = try #require(AppContainerSource.makeApps(containers: [container], transfers: [transfer]).first)
        let display = SyncStatusDisplay(app: row, progressIsIndeterminate: true)
        #expect(display.label == "Syncing…")
        #expect(display.tone == .working)
    }

    @Test("The popover's idle line counts container rows as no activity seen")
    func popoverLineMatchesRows() {
        #expect(PopoverSummary.idleAppsLine(Self.rows()) == "1 app up to date · 1 with no activity seen")
    }

    // Fails on the first unknown-row change: the File Provider row was counted
    // as "not read yet", promising a read that never comes.
    @Test("A File Provider unknown row is never \"not read yet\"")
    func fileProviderUnknownIsNotPending() async throws {
        let apps = Self.rows(fileProviderDomains: ["Dropbox"]).filter { !$0.isAppContainer }
        let store = SyncStore(source: StubSyncSource(snapshot: .minimal(apps: apps)), notifier: noBanners)
        await store.refresh(force: true)
        #expect(store.unknownStateAppCount == 0)
        #expect(store.unreportedAppCount == 1)
        let hero = OverviewHeroDisplay(state: store.overallState, progress: 1, progressIsIndeterminate: false,
                                       inFlightCount: 0, pendingFileCount: 0,
                                       unknownAppCount: store.unknownStateAppCount,
                                       unwatchedAppCount: store.unwatchedApps.count,
                                       unreportedAppCount: store.unreportedAppCount)
        #expect(!hero.subtitle.contains("not read yet"))
        #expect(hero.subtitle.contains("1 app whose sync status macOS doesn't report"))
        let line = try #require(PopoverSummary.idleAppsLine(store.effectiveApps))
        #expect(!line.contains("state unknown"))
        #expect(line == "1 app up to date · 1 whose status macOS doesn't report")
    }

    // The control: a CloudDocs row waiting on the dump is still "not read yet".
    @Test("A CloudDocs unknown row is still \"not read yet\"")
    func cloudDocsUnknownIsPending() {
        let drive = AppSyncState(id: "icloud-drive", name: "iCloud Drive", tileColorHex: "30b0c7",
                                 backend: .cloudDocs, isApple: true, status: .unknown,
                                 statusLine: "", lastActivity: nil, locationPath: "")
        #expect(UnknownRowKind(of: drive) == .notReadYet)
    }

    // Fails on the old source: every ~/Library/CloudStorage folder was
    // hard-coded .upToDate although nothing about its sync was read.
    @Test("File Provider rows claim no state: nothing is read for them")
    func fileProviderRowsAreUnknown() throws {
        let fp = try #require(Self.rows(fileProviderDomains: ["Dropbox"]).first { $0.backend == .fileProvider })
        #expect(fp.status == .unknown)
        let display = SyncStatusDisplay(app: fp, progressIsIndeterminate: false)
        #expect(display.tone == .neutral)
        #expect(display.label != "Up to date")
        #expect(display.label != "No activity seen", "not even an activity claim — nothing was watched")
    }
}
