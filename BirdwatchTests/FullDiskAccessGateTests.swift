import Foundation
import os
import Testing
@testable import Birdwatch

/// Full Disk Access is required (macOS 27: reading iCloud Drive without it
/// raises tccd's iCloud Drive prompt and stalls the read). These pin the one
/// decision, `TransferWatchPolicy.iCloudDriveAccess`, and that every iCloud
/// Drive reader on the snapshot path follows it. Everything runs against
/// stub runners and readers: no brctl, ps, log or real filesystem walk.
@Suite("Full Disk Access gate")
struct FullDiskAccessGateTests {

    // MARK: The decision

    @Test("iCloud Drive is read only with access granted or unconfirmed", arguments: [
        (PermissionState?.none, ICloudDriveAccess.notProbed, false, false),
        (PermissionState?.some(.granted), ICloudDriveAccess.granted, true, false),
        (PermissionState?.some(.unknown), ICloudDriveAccess.unconfirmed, true, false),
        (PermissionState?.some(.denied), ICloudDriveAccess.denied, false, true),
    ])
    func decision(fda: PermissionState?, access: ICloudDriveAccess, reads: Bool, blocks: Bool) {
        let decided = TransferWatchPolicy.iCloudDriveAccess(fullDiskAccess: fda)
        #expect(decided == access)
        #expect(decided.readsICloudDrive == reads)
        #expect(decided.blocksMainWindow == blocks, "only a denial replaces the main window; not-probed is first load")
    }

    // An unconfirmed grant opens iCloud Drive but never Desktop & Documents:
    // that rule (no Desktop/Documents prompt without a confirmed grant)
    // predates this one and is not loosened by it.
    @Test("Desktop & Documents still need a confirmed grant")
    func desktopDocumentsNarrower() {
        #expect(TransferWatchPolicy.readsDesktopDocuments(featureOn: true, fullDiskAccess: .granted))
        #expect(!TransferWatchPolicy.readsDesktopDocuments(featureOn: true, fullDiskAccess: .unknown))
        #expect(!TransferWatchPolicy.readsDesktopDocuments(featureOn: true, fullDiskAccess: .denied))
    }

    @Test("The status-row note warns on an unconfirmed grant and asks for a denied one")
    func notes() {
        #expect(FullDiskAccessCopy.note(for: nil) == nil)
        #expect(FullDiskAccessCopy.note(for: .granted) == nil)
        #expect(FullDiskAccessCopy.note(for: .denied)?.contains("System Settings") == true)
        #expect(FullDiskAccessCopy.note(for: .unknown)?.contains("macOS may ask") == true)
    }

    // MARK: The blocking screen sees a re-grant even while paused

    // Fails if a re-grant seen by the screen's probe waits for monitoring
    // to resume (refresh refuses while paused), or if the source's cached
    // denial is not dropped — the next snapshot would put the screen back.
    @Test("A re-grant clears the blocking screen while paused, without fetching")
    func regrantWhilePaused() async {
        var snapshot = SyncSnapshot.minimal()
        snapshot.permissions = [PermissionStatus(kind: .fullDiskAccess, state: .denied),
                                PermissionStatus(kind: .notifications, state: .granted)]
        let source = RecordingSource(snapshot: snapshot)
        let store = SyncStore(source: source, notifier: noBanners)
        await store.refresh(force: true)
        #expect(store.iCloudDriveAccess.blocksMainWindow)
        store.togglePauseAll()
        #expect(store.isGloballyPaused)

        await store.fullDiskAccessProbed(.denied)
        #expect(store.iCloudDriveAccess == .denied, "a denial changes nothing")
        #expect(source.log == ["snapshot"])

        await store.fullDiskAccessProbed(.granted)
        #expect(store.iCloudDriveAccess == .granted)
        #expect(!store.iCloudDriveAccess.blocksMainWindow)
        #expect(source.log == ["snapshot", "reprobe"], "cache dropped, nothing fetched while paused")
        #expect(store.permissions.state(of: .notifications) == .granted, "other rows untouched")
    }

    @Test("Unpaused, a re-grant also fetches a fresh snapshot")
    func regrantUnpaused() async {
        var snapshot = SyncSnapshot.minimal()
        snapshot.permissions = [PermissionStatus(kind: .fullDiskAccess, state: .denied)]
        let source = RecordingSource(snapshot: snapshot)
        let store = SyncStore(source: source, notifier: noBanners)
        await store.refresh(force: true)
        source.snapshot.permissions = [PermissionStatus(kind: .fullDiskAccess, state: .granted)]
        await store.fullDiskAccessProbed(.granted)
        #expect(source.log == ["snapshot", "reprobe", "snapshot"])
        #expect(store.iCloudDriveAccess == .granted)
    }

    @Test("Setting the Full Disk Access row replaces it, or adds one")
    func settingRow() {
        let replaced = SyncStore.permissions([PermissionStatus(kind: .fullDiskAccess, state: .denied)], settingFullDiskAccess: .granted)
        #expect(replaced.map(\.state) == [.granted])
        let added = SyncStore.permissions([PermissionStatus(kind: .notifications, state: .denied)], settingFullDiskAccess: .unknown)
        #expect(added.state(of: .fullDiskAccess) == .unknown)
        #expect(added.count == 2)
    }

    // MARK: The snapshot path follows it

    /// Records every spawn; answers every tool with empty output.
    private actor RecordingRunner: ProcessRunning {
        private(set) var calls: [String] = []
        nonisolated func run(toolPath: String, arguments: [String], timeout: Duration) async throws -> String {
            await record(([(toolPath as NSString).lastPathComponent] + arguments.prefix(1)).joined(separator: " "))
            return ""
        }
        private func record(_ call: String) { calls.append(call) }
    }

    /// Counts every gated reader call.
    private nonisolated final class Counts: Sendable {
        let state = OSAllocatedUnfairLock(initialState: [String: Int]())
        func hit(_ name: String) { state.withLock { $0[name, default: 0] += 1 } }
        var all: [String: Int] { state.withLock { $0 } }
    }

    private struct Rig {
        let source: SystemSyncSource
        let brctl: RecordingRunner
        let counts: Counts
        let fda: OSAllocatedUnfairLock<PermissionState?>
    }

    private static func rig(fda initial: PermissionState?) -> Rig {
        let counts = Counts()
        let fda = OSAllocatedUnfairLock<PermissionState?>(initialState: initial)
        let readers = SystemSyncSource.Readers(
            permissions: {
                fda.withLock { $0 }.map { [PermissionStatus(kind: .fullDiskAccess, state: $0)] } ?? []
            },
            localSizes: { _, _ in counts.hit("sizes"); return [:] },
            breakdown: { _ in counts.hit("breakdown"); return ([:], false) },
            folders: { counts.hit("folders"); return [] },
            containers: { counts.hit("containers"); return [] },
            conflicts: { counts.hit("conflicts"); return ([], false) },
            makeTransferWatcher: {
                counts.hit("watcher")
                return UbiquityTransferSource(roots: [], sweep: { _ in [] })
            },
            fileProviderDomains: { [] }
        )
        let brctl = RecordingRunner()
        let source = SystemSyncSource(
            brctlRunner: brctl, systemRunner: RecordingRunner(),
            pathCandidates: { counts.hit("paths"); return [] }, readers: readers)
        return Rig(source: source, brctl: brctl, counts: counts, fda: fda)
    }

    // Fails if any iCloud Drive reader (brctl, the transfer watcher, the
    // folder / container / conflict / size / breakdown walks, the dump) is
    // reached before the gate, or if the snapshot serves anything that would
    // have needed one.
    @Test("Denied: the snapshot touches nothing in iCloud Drive", arguments: [PermissionState?.some(.denied), nil])
    func deniedTouchesNothing(fda: PermissionState?) async {
        let rig = Self.rig(fda: fda)
        let snapshot = await rig.source.currentSnapshot()

        #expect(rig.counts.all.isEmpty, "gated readers called: \(rig.counts.all)")
        let spawned = await rig.brctl.calls
        #expect(spawned.isEmpty, "brctl spawned: \(spawned)")
        // Nothing was even claimed for a background start.
        #expect(rig.source.claimDumpRefresh(now: Date()), "no dump refresh was claimed")
        #expect(rig.source.claimConflictScan(now: Date()) != nil, "no conflict scan was claimed")
        #expect(rig.source.transferWatcherForTesting == nil)

        #expect(snapshot.transfers.isEmpty && snapshot.issues.isEmpty && snapshot.driveFolders.isEmpty)
        #expect(snapshot.quotaRemainingBytes == nil && snapshot.storage == nil)
        #expect(snapshot.issueProducers == [:], "no producer delivered, so none takes its baseline from this")
        let drive = snapshot.apps.first { $0.id == "icloud-drive" }
        #expect(drive?.needsFullDiskAccess == true)
        #expect(drive?.status == .unknown)
        #expect(!snapshot.apps.contains { $0.id == "desktop-documents" })
    }

    // Fails if a grant is not picked up on the next (re-probed) snapshot, or
    // if a revocation leaves the watcher running.
    @Test("Granted starts the readers; a later denial stops the watcher on that snapshot")
    func grantThenRevoke() async {
        let rig = Self.rig(fda: .denied)
        _ = await rig.source.currentSnapshot()
        #expect(rig.counts.all.isEmpty)

        rig.fda.withLock { $0 = .granted }
        await rig.source.invalidatePermissions()
        let granted = await rig.source.currentSnapshot()
        let counts = rig.counts.all
        #expect(counts["watcher"] == 1)
        #expect(counts["folders"] == 1 && counts["containers"] == 1)
        let spawned = await rig.brctl.calls
        #expect(spawned.contains("brctl quota"), "got \(spawned)")
        #expect(!rig.source.claimDumpRefresh(now: Date()), "the dump refresh was claimed")
        #expect(rig.source.claimConflictScan(now: Date()) == nil, "the conflict scan was claimed")
        let watcher = rig.source.transferWatcherForTesting
        #expect(watcher?.isStarted == true)
        #expect(granted.apps.first { $0.id == "icloud-drive" }?.needsFullDiskAccess == false)

        rig.fda.withLock { $0 = .denied }
        await rig.source.invalidatePermissions()
        let revoked = await rig.source.currentSnapshot()
        #expect(watcher?.isStarted == false, "stopped, not just paused")
        #expect(rig.source.transferWatcherForTesting == nil)
        #expect(rig.counts.all["folders"] == 1, "no folder scan after the denial")
        #expect(revoked.apps.first { $0.id == "icloud-drive" }?.needsFullDiskAccess == true)
    }

    // The probe can't tell (no probe file): reads go ahead, but Desktop &
    // Documents stay closed.
    @Test("Unconfirmed: iCloud Drive is read, Desktop & Documents are not")
    func unconfirmedReads() async {
        let rig = Self.rig(fda: .unknown)
        _ = await rig.source.currentSnapshot()
        #expect(rig.counts.all["watcher"] == 1)
        #expect(rig.counts.all["folders"] == 1)
        #expect(rig.source.transferWatcherForTesting?.includesDesktopDocuments == false)
    }

    // Resolving a conflict opens the file's versions in iCloud Drive. The
    // denial clears the conflict cache (AccessRevocationTests), so this
    // models the one way an entry can still be there: a listing put in the
    // cache after the gate denied (here directly, through the test seam).
    // Only the gate answers .notFound AND leaves the cache alone: a resolve
    // that reached the file answers .failed / .changed, or .notFound after
    // dropping the entry from the cache.
    @Test("A cached conflict is not resolved once access is denied")
    func resolveGated() async {
        let rig = Self.rig(fda: .denied)
        _ = await rig.source.currentSnapshot()
        let claim = rig.source.claimConflictScan(now: Date())
        rig.source.completeConflictScan([ConflictSource.FoundConflict(
            issue: TestIssues.make(id: "conflict-x", action: .reviewVersions, severity: .conflict),
            detail: ConflictDetail(fileName: "x", location: "", versions: [],
                                   fileURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.pages"))
        )], resolvedBeforeScan: claim ?? [])
        #expect(await rig.source.resolveConflict(issueID: "conflict-x", keepVersionID: "current", shownVersionIDs: [])
                == .notFound)
        #expect(await rig.source.conflictDetail(issueID: "conflict-x") != nil, "the file was never reached")
    }
}
