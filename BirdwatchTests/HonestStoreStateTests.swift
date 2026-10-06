import Foundation
import Testing
@testable import Birdwatch

// Store-level checks: a snapshot assembled by the real row builders goes
// through SyncStore, and the assertions are on what every screen reads.
// Each fails on 437a1fa's behaviour.

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let designLocation = DriveFolder.cloudDocsLocation + "/Design/Assets"
private let obsidianDir = "iCloud~md~obsidian"

private func transfer(_ id: String, app: String, location: String, progress: Double) -> TransferItem {
    TransferItem(id: id, appID: app, name: id, location: location, sizeBytes: 10,
                 direction: .upload, progress: progress)
}

/// What SystemSyncSource assembles for a cycle with these transfers: the
/// built-in iCloud Drive row, one container row, one Drive folder.
private func liveSnapshot(_ transfers: [TransferItem]) -> SyncSnapshot {
    var container = AppContainerSource.makeContainer(directoryName: obsidianDir)!
    container.itemCount = 3
    var snap = SyncSnapshot.minimal(apps: SystemSyncSource.buildApps(
        status: nil, transfers: transfers, fileProviderDomains: [], containers: [container]))
    snap.transfers = transfers
    snap.driveFolders = DriveFolderSource.applying(
        transfers: transfers,
        to: [DriveFolderSource.makeFolder(name: "Design", itemCount: 2, transferLocations: [])])
    return snap
}

private func store(_ snapshot: SyncSnapshot, at date: Date = now) async -> SyncStore {
    let store = SyncStore(source: StubSyncSource(snapshot: snapshot), now: { date }, notifier: noBanners)
    await store.refresh(force: true)
    return store
}

private func cloudKitApp(_ id: String, status: AppSyncStatus, lastActivity: Date?) -> AppSyncState {
    AppSyncState(
        id: id, name: id, tileColorHex: "fe4f6d", backend: .cloudKit, isApple: true,
        status: status, statusLine: status == .active ? "Transferring" : "Last activity in cloudd's log",
        lastActivity: lastActivity, itemCount: nil, pendingItems: nil, localSize: nil, locationPath: ""
    )
}

@MainActor
@Suite("Honest store state")
struct HonestStoreStateTests {

    // MARK: 1. A finished transfer is not "syncing"

    @Test("A finished transfer in its completion grace leaves every surface idle")
    func finishedTransferIsNotSyncing() async {
        let containerID = AppContainerSource.appID(forDirectory: obsidianDir)
        let s = await store(liveSnapshot([
            transfer("done-drive", app: "icloud-drive", location: designLocation, progress: 1),
            transfer("done-obsidian", app: containerID, location: "~", progress: 1),
        ]))
        #expect(s.syncingApps.isEmpty, "was: \"Syncing 100%\" for both rows")
        #expect(s.overallState == .idle, "was: \"Syncing 2 apps / 100% SYNCED\"")
        #expect(s.pendingFileCount == 0)
        #expect(s.app(withID: "icloud-drive")?.pendingItems == 0)
        #expect(s.app(withID: "icloud-drive")?.statusLine.contains("in transfer") == false)
        #expect(s.app(withID: containerID)?.pendingItems == 0)
        #expect(s.driveFolders.first?.status == .upToDate, "was: folder \"Syncing…\"")
    }

    @Test("An in-flight transfer next to a finished one still counts — only the finished one is dropped")
    func inFlightStillCounts() async {
        let s = await store(liveSnapshot([
            transfer("done", app: "icloud-drive", location: designLocation, progress: 1),
            transfer("live", app: "icloud-drive", location: designLocation, progress: 0),
        ]))
        #expect(s.overallState == .syncing(appCount: 1))
        #expect(s.pendingFileCount == 1, "the finished item must not inflate the count")
        #expect(s.app(withID: "icloud-drive")?.status == .syncing(progress: 0), "mean over in-flight only, not (0 + 1) / 2")
        #expect(s.progressIsIndeterminate(appID: "icloud-drive"))
        #expect(s.driveFolders.first?.status.isSyncing == true)
        #expect(s.progressIsIndeterminate(folderName: "Design"))
    }

    // MARK: 4. Active-without-progress is counted everywhere the hero counts it

    @Test("A CloudKit app with work but no progress is an active app on every surface")
    func activeAppsAgree() async {
        let photos = cloudKitApp("photos", status: .active, lastActivity: now.addingTimeInterval(-60))
        let s = await store(.minimal(apps: [photos, cloudKitApp("notes", status: .upToDate, lastActivity: nil)]))
        #expect(s.overallState == .active(appCount: 1))
        #expect(s.activeApps.map(\.id) == ["photos"], "was: Active apps 0, empty transfers card and popover list")
        #expect(s.syncingApps.isEmpty, "no progress → never averaged into a percentage")
        let display = SyncStatusDisplay(status: s.activeApps[0].status, backend: .cloudKit, progressIsIndeterminate: false)
        #expect(display.bar == nil)
        #expect(display.label == "Active")
    }

    // MARK: 5. CloudKit activity ages out against its evidence

    @Test("A CloudKit \"active\" older than the activity window reads as idle, with its real age")
    func staleActivityAgesOut() async {
        let last = now.addingTimeInterval(-(CloudKitLogParser.activeWindow + 60))
        let s = await store(.minimal(apps: [cloudKitApp("photos", status: .active, lastActivity: last)]))
        let photos = s.app(withID: "photos")
        #expect(photos?.status == .upToDate, "was: \"Transferring now\" for up to ~10 minutes")
        #expect(photos?.statusLine == "Last activity in cloudd's log")
        #expect(s.overallState == .idle)
        #expect(s.activeApps.isEmpty)
        let display = SyncStatusDisplay(status: photos!.status, backend: .cloudKit, progressIsIndeterminate: false)
        #expect(display.label == "No activity seen")
    }

    @Test("Fresh CloudKit activity stays active, and with no date it cannot")
    func freshActivityStays() async {
        let fresh = await store(.minimal(apps: [cloudKitApp("photos", status: .active, lastActivity: now.addingTimeInterval(-120))]))
        #expect(fresh.app(withID: "photos")?.status == .active)
        let undated = await store(.minimal(apps: [cloudKitApp("photos", status: .active, lastActivity: nil)]))
        #expect(undated.app(withID: "photos")?.status == .upToDate, "no evidence date → no claim of current work")
    }

    @Test("The detail tile shows the activity's age, never a bare \"Active now\"")
    func detailShowsAge() {
        let photos = cloudKitApp("photos", status: .active, lastActivity: now.addingTimeInterval(-180))
        let tile = AppDetailFacts.lastActivityTile(photos, now: now)
        #expect(tile.label == "Last activity")
        #expect(tile.value != "Active now")
        #expect(tile.value == Format.relative.localizedString(for: now.addingTimeInterval(-180), relativeTo: now))
    }

    // MARK: 8. An unreadable folder is not "Zero KB"

    @Test("A size walk that can't read its folder says \"Couldn't measure\"")
    func unreadableSize() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let size = AppContainerSource.measuredSize(ofDirectory: missing)
        #expect(size.isUnreadable)
        #expect(LocalSizeText.text(size) == "Couldn't measure")
        #expect(AppContainerSource.allocatedSize(ofDirectory: missing) == 0, "the plain byte API is unchanged")
    }

    // MARK: 7. Derived account segments

    @Test("Account-bar segments built on a derived cap are marked as estimates")
    func estimatedAccountParts() {
        func info(_ source: StorageCapSource, accountUsed: Int64) -> StorageInfo {
            StorageInfo(totalBytes: 200, segments: [StorageSegment(name: "Docs", colorHex: "0a84ff", bytes: 50)],
                        planName: "", planPriceLine: "", capSource: source, remainingBytes: 100,
                        accountUsedBytes: accountUsed)
        }
        #expect(StorageCapLabel.estimatedAccountParts(info(.derived, accountUsed: 100)) == (local: false, remainder: true))
        #expect(StorageCapLabel.estimatedAccountParts(info(.derived, accountUsed: 40)) == (local: true, remainder: true),
                "local capped to a derived total is derived too")
        #expect(StorageCapLabel.estimatedAccountParts(info(.userChosen, accountUsed: 100)) == (local: false, remainder: false))
        #expect(StorageCapLabel.accountPartText(1_000, isEstimated: true).hasPrefix("≈ "))
        #expect(StorageCapLabel.accountPartAccessibility(1_000, isEstimated: true).contains("estimated"))
    }
}
