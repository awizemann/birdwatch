import Foundation
import os
import Testing
@testable import Birdwatch

/// Full Disk Access revoked MID-SESSION. The permissions cache can be five
/// minutes old, so the gate alone would keep reading iCloud Drive (and raise
/// macOS 27's prompt) until it expires. These pin the three faster paths:
/// a refused read stops the watcher at once, activation re-probes before it
/// refreshes, and background work re-checks access before each step.
@Suite("Access revoked mid-session", .timeLimit(.minutes(1)))
struct AccessRevocationTests {

    // MARK: (a) a refused read stops the watcher

    @Test("Permission errors are recognised, other read errors are not")
    func classifiesErrors() {
        #expect(UbiquityTransferSource.isAccessDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(UbiquityTransferSource.isAccessDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(UbiquityTransferSource.isAccessDenied(CocoaError(.fileReadNoPermission)))
        #expect(UbiquityTransferSource.isAccessDenied(NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        #expect(!UbiquityTransferSource.isAccessDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        #expect(!UbiquityTransferSource.isAccessDenied(CocoaError(.fileReadNoSuchFile)))
    }

    // Real file system: a folder this process may not read answers EACCES,
    // which is what a revoked grant looks like to the listing and the probe.
    @Test("A refused listing and a refused probe both report lost access")
    func realRefusals() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bw-denied-\(UUID().uuidString)")
        let locked = root.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data().write(to: locked.appending(path: "f.pages"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(UbiquityTransferSource.listChildren(of: [locked.path]).accessDenied)
        #expect(!UbiquityTransferSource.listChildren(of: [root.path]).accessDenied)
        #expect(!UbiquityTransferSource.listChildren(of: [root.path + "/missing"]).accessDenied, "a missing root is not a refusal")
    }

    @MainActor
    @Test("The watcher stops on the first refused probe, tells its owner, and will not resume")
    func watcherStopsOnRefusal() async {
        let watcher = UbiquityTransferSource(
            roots: ["/nonexistent-bw-root"], sweep: { _ in [] },
            probe: { _ in UbiquityProbeBatch(results: [], accessDenied: true) })
        var told = 0
        watcher.onAccessDenied = { told += 1 }
        watcher.start()
        defer { watcher.stop() }
        watcher.ingestForTesting(paths: ["/nonexistent-bw-root/a.pages"], at: Date())
        #expect(watcher.isWatching)

        await watcher.probeOnceForTesting()
        #expect(watcher.lostAccess)
        #expect(!watcher.isWatching, "FSEvents stream and probe ticker are gone")
        #expect(watcher.candidatePathsForTesting.isEmpty)
        #expect(told == 1)

        watcher.pause()
        watcher.resume()
        #expect(!watcher.isWatching, "a pause/resume cycle cannot restart it")
    }

    @MainActor
    @Test("The source releases the watcher, drops the cached grant and stops trusting it")
    func sourceReactsToRefusal() async {
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let made = OSAllocatedUnfairLock<Int>(initialState: 0)
        let readers = SystemSyncSource.Readers.testing(
            permissions: {
                probes.withLock { $0 += 1 }
                return [PermissionStatus(kind: .fullDiskAccess, state: .granted)]
            },
            makeTransferWatcher: {
                made.withLock { $0 += 1 }
                return UbiquityTransferSource(
                    roots: ["/nonexistent-bw-root"], sweep: { _ in [] },
                    probe: { _ in UbiquityProbeBatch(results: [], accessDenied: true) })
            })
        let source = SystemSyncSource(brctlRunner: RecordingBrctlRunner(), systemRunner: RecordingBrctlRunner(),
                                      pathCandidates: { [] }, readers: readers)
        _ = await source.currentSnapshot()
        let watcher = source.transferWatcherForTesting
        #expect(watcher != nil)
        #expect(probes.withLock { $0 } == 1)

        watcher?.ingestForTesting(paths: ["/nonexistent-bw-root/a.pages"], at: Date())
        await watcher?.probeOnceForTesting()
        #expect(source.transferWatcherForTesting == nil)
        #expect(source.accessForTesting == .notProbed, "background steps claimed earlier now stop")

        _ = await source.currentSnapshot()
        #expect(probes.withLock { $0 } == 2, "the next snapshot re-probes instead of serving the cached grant")
    }

    // MARK: (b) activation re-probes before it refreshes

    @MainActor
    @Test("Activation drops the cache, re-probes, applies the answer, and only then refreshes")
    func activationIsOrdered() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var granted = SyncSnapshot.minimal()
        granted.permissions = [PermissionStatus(kind: .fullDiskAccess, state: .granted)]
        let source = RecordingSource(snapshot: granted)
        let store = SyncStore(source: source, now: { clock }, notifier: noBanners,
                              isMainWindowVisible: { true })
        await store.refresh(force: true)
        #expect(store.iCloudDriveAccess == .granted)

        source.recheckAnswer = [PermissionStatus(kind: .fullDiskAccess, state: .denied)]
        clock += 61                                   // past the activation debounce
        await store.applicationActivated()
        #expect(source.log == ["snapshot", "reprobe", "recheck", "snapshot"], "got \(source.log)")
        #expect(store.iCloudDriveAccess.blocksMainWindow)

        // Inside the debounce the refresh is skipped — the re-probe is not.
        source.recheckAnswer = [PermissionStatus(kind: .fullDiskAccess, state: .granted)]
        clock += 5
        await store.applicationActivated()
        #expect(Array(source.log.suffix(2)) == ["reprobe", "recheck"])
        #expect(store.iCloudDriveAccess == .granted, "a revocation or re-grant is seen without waiting out the debounce")
    }

    // MARK: (c) background work re-checks before each step

    @Test("A dump refresh claimed under access does nothing once access is gone")
    func dumpRefreshStopsBeforeStarting() async {
        let runner = RecordingBrctlRunner()
        let walks = OSAllocatedUnfairLock(initialState: 0)
        let source = SystemSyncSource(brctlRunner: runner, pathCandidates: { walks.withLock { $0 += 1 }; return [] })
        source.setAccessForTesting(.granted)
        #expect(source.claimDumpRefresh(now: Date()))
        source.setAccessForTesting(.denied)      // revoked after the claim
        await source.performDumpRefresh()
        #expect(runner.events.isEmpty, "no brctl at all: got \(runner.events)")
        #expect(walks.withLock { $0 } == 0)
        #expect(source.claimDumpRefresh(now: Date() + 3600), "the claim was released")
    }

    @Test("Access lost while the dump runs: no path walk and no brctl status after it")
    func dumpRefreshStopsMidway() async {
        let runner = RecordingBrctlRunner()
        let walks = OSAllocatedUnfairLock(initialState: 0)
        let source = SystemSyncSource(brctlRunner: runner, pathCandidates: { walks.withLock { $0 += 1 }; return [] })
        runner.afterDump.withLock { $0 = { await MainActor.run { source.setAccessForTesting(.denied) } } }
        source.setAccessForTesting(.granted)
        #expect(source.claimDumpRefresh(now: Date()))
        await source.performDumpRefresh()
        #expect(runner.events == ["start dump", "end dump"], "got \(runner.events)")
        #expect(walks.withLock { $0 } == 0, "the redacted-path walk did not start")
    }

    // MARK: Nothing read before a denial is served after a re-grant

    // Review finding: after a re-grant an hours-old dump (and the conflict
    // and size caches) were served as current, and producers baselined from
    // them. Fails if any iCloud-derived cache survives the denial.
    @Test("A denial clears every iCloud-derived cache; the re-grant reads afresh")
    func denialClearsCaches() async {
        let fda = OSAllocatedUnfairLock(initialState: PermissionState.granted)
        let runner = RecordingBrctlRunner()
        let source = SystemSyncSource(
            brctlRunner: runner, systemRunner: RecordingBrctlRunner(), pathCandidates: { [] },
            readers: .testing(permissions: { [PermissionStatus(kind: .fullDiskAccess, state: fda.withLock { $0 })] }))
        let t0 = Date()
        _ = await source.fullDiskAccessGate(now: t0)

        // Caches as a granted session leaves them.
        #expect(source.claimDumpRefresh(now: t0))
        await source.performDumpRefresh()
        #expect(source.hasCachedDumpForTesting)
        let claim = source.claimConflictScan(now: t0)
        source.completeConflictScan([ConflictSource.FoundConflict(
            issue: TestIssues.make(id: "conflict-a", action: .reviewVersions, severity: .conflict),
            detail: ConflictDetail(fileName: "a", location: "", versions: []))], resolvedBeforeScan: claim ?? [])
        #expect(await source.conflictDetail(issueID: "conflict-a") != nil)

        fda.withLock { $0 = .denied }
        _ = await source.fullDiskAccessGate(now: t0 + 301)
        #expect(!source.hasCachedDumpForTesting)
        #expect(await source.conflictDetail(issueID: "conflict-a") == nil)
        #expect(source.statusCacheForTesting == CloudDocsStatusCache())

        // Re-granted: the first cycle is free to read again (no pacing left
        // over), and no producer delivers anything from before the denial.
        fda.withLock { $0 = .granted }
        _ = await source.fullDiskAccessGate(now: t0 + 602)
        #expect(source.claimDumpRefresh(now: t0 + 602), "the dump is due at once")
        #expect(source.claimConflictScan(now: t0 + 602) != nil, "the conflict scan is due at once")
    }

    // MARK: Item 9: a stale "denied" in flight cannot undo a re-grant

    @MainActor
    @Test("A snapshot that probed before a re-grant does not bring the blocking screen back")
    func staleDenialInFlight() async {
        var denied = SyncSnapshot.minimal()
        denied.permissions = [PermissionStatus(kind: .fullDiskAccess, state: .denied)]
        let source = HeldSnapshotSource(snapshot: denied)
        let store = SyncStore(source: source, notifier: noBanners)
        let inFlight = Task { await store.refresh(force: true) }
        await source.waitUntilFetching()              // probed "denied", not landed yet
        store.togglePauseAll()                        // paused: the re-grant fetches nothing of its own
        await store.fullDiskAccessProbed(.granted)
        #expect(store.iCloudDriveAccess == .granted)
        source.release()
        await inFlight.value
        #expect(store.iCloudDriveAccess == .granted, "the older probe's answer was not applied over the newer one")
    }
}

/// A source whose first snapshot is held until the test releases it.
private nonisolated final class HeldSnapshotSource: SyncSource, @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var fetching: CheckedContinuation<Void, Never>?
    private var isFetching = false
    private let snapshot: SyncSnapshot

    init(snapshot: SyncSnapshot) { self.snapshot = snapshot }

    func currentSnapshot() async -> SyncSnapshot {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                held = c
                isFetching = true
                defer { fetching = nil }
                return fetching
            }
            waiter?.resume()
        }
        return snapshot
    }

    func waitUntilFetching() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if isFetching { return true }
                fetching = c
                return false
            }
            if already { c.resume() }
        }
    }

    func release() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { held = nil }; return held }?.resume() }

    func logStream(appID: String, backend: SyncBackend) -> AsyncThrowingStream<LogLine, any Error> { AsyncThrowingStream { $0.finish() } }
    func conflictDetail(issueID: String) async -> ConflictDetail? { nil }
}
