import Foundation
import os
import Testing
@testable import Birdwatch

/// Without Full Disk Access nothing may read ~/Desktop or ~/Documents — the
/// transfer watcher, the local size walk and the Storage breakdown walk all
/// take the ONE decision `SystemSyncSource.applyDesktopDocumentsGate` makes.
/// Everything here runs against a temporary home and injected readers: no
/// real permissions probe, no walk of the real home folder.
@MainActor
@Suite("Desktop & Documents gate")
struct DesktopDocumentsGateTests {

    /// A temp "home" with the three roots the watcher may use.
    private static func tempHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appending(path: "bw-home-\(UUID().uuidString)").path
        for sub in ["Library/Mobile Documents", "Desktop", "Documents"] {
            try FileManager.default.createDirectory(atPath: home + "/" + sub, withIntermediateDirectories: true)
        }
        return home
    }

    private static func inFlight(_ path: String) -> UbiquityProbeResult {
        UbiquityProbeResult(path: path, name: (path as NSString).lastPathComponent, sizeBytes: 1,
                            isUbiquitous: true, isUploading: true, isDownloading: false)
    }

    // MARK: Item 4 — narrowing the roots forgets what may no longer be read

    // Fails without the prune: the 1 Hz probe kept calling resourceValues on
    // ~/Desktop files after Full Disk Access was revoked.
    @Test("Turning Desktop & Documents off drops candidates and transfers under them")
    func revokingDropsDesktopDocumentsPaths() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let watcher = UbiquityTransferSource(homeDirectory: home, sweep: { _ in [] })
        watcher.start()
        defer { watcher.stop() }
        watcher.setIncludesDesktopDocuments(true)

        let desk = home + "/Desktop/a.key"
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs/b.pages"
        watcher.ingestForTesting(paths: [desk, drive], at: Date())
        watcher.applyProbeForTesting([Self.inFlight(desk), Self.inFlight(drive)], now: Date())
        #expect(Set(watcher.transfers.map(\.id)) == [desk, drive])

        watcher.setIncludesDesktopDocuments(false)
        #expect(watcher.candidatePathsForTesting == [drive])
        #expect(watcher.transfers.map(\.id) == [drive])

        // A probe (or sweep) that was already in flight is filtered too.
        watcher.applyProbeForTesting([Self.inFlight(desk), Self.inFlight(drive)], now: Date())
        #expect(watcher.transfers.map(\.id) == [drive])
        #expect(!watcher.candidatePathsForTesting.contains(desk))
    }

    @Test("Path containment is by whole components")
    func containment() {
        #expect(UbiquityTransferSource.isUnder("/h/Desktop/x", roots: ["/h/Desktop"]))
        #expect(UbiquityTransferSource.isUnder("/h/Desktop", roots: ["/h/Desktop/"]))
        #expect(!UbiquityTransferSource.isUnder("/h/DesktopOld/x", roots: ["/h/Desktop"]))
    }

    // MARK: Item 5 — a paused watcher serves nothing frozen as live

    // Fails on the old pause, which kept `transfers` (shown as in flight in
    // every snapshot while paused) and, on resume, stamped items that had
    // finished while nobody watched as "completed now".
    @Test("Pause clears in-flight transfers; an item gone after resume is not a completion")
    func pauseDoesNotFreezeOrInventCompletions() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let watcher = UbiquityTransferSource(homeDirectory: home, sweep: { _ in [] })
        watcher.start()
        defer { watcher.stop() }
        let file = home + "/Library/Mobile Documents/com~apple~CloudDocs/c.mov"
        watcher.ingestForTesting(paths: [file], at: Date())
        watcher.applyProbeForTesting([Self.inFlight(file)], now: Date())
        #expect(watcher.transfers.count == 1)

        watcher.pause()
        #expect(watcher.transfers.isEmpty, "nothing frozen is served while paused")

        watcher.resume()
        // It finished while paused: the first probe sees it idle.
        var idle = Self.inFlight(file)
        idle.isUploading = false
        watcher.applyProbeForTesting([idle], now: Date())
        #expect(watcher.transfers.isEmpty, "no 'completed now' entry for a finish nobody saw")
    }

    @Test("The activity feed derives no event across a pause")
    func activityAcrossPause() {
        let log = ActivityLog()
        let a = TransferItem(id: "/a", appID: "icloud-drive", name: "a", location: "", sizeBytes: 1,
                             direction: .upload, progress: 0)
        let b = TransferItem(id: "/b", appID: "icloud-drive", name: "b", location: "", sizeBytes: 1,
                             direction: .upload, progress: 0)
        #expect(log.record([a, b]).count == 2)          // two "Uploading" events
        log.pause()
        log.pause()                                      // idempotent
        // Resumed: `a` is still in flight, `b` finished while paused.
        let after = log.record([a])
        #expect(after.count == 2, "neither a repeated start for a, nor an invented completion for b")
        #expect(log.record([]).count == 3, "a later observed finish is still recorded")
    }

    // MARK: Item 8 — the gate reaches every reader

    private actor Recorder {
        var sizeWalks: [Bool] = []
        var breakdownWalks: [Bool] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func size(_ include: Bool) { sizeWalks.append(include); wake() }
        func breakdown(_ include: Bool) { breakdownWalks.append(include); wake() }
        func waitFor(total: Int) async {
            guard sizeWalks.count + breakdownWalks.count < total else { return }
            await withCheckedContinuation { waiters.append((total, $0)) }
        }
        private func wake() {
            let n = sizeWalks.count + breakdownWalks.count
            let ready = waiters.filter { n >= $0.0 }
            waiters.removeAll { n >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }


    // Reverting the gate in any one reader fails this: each must be told
    // false while Full Disk Access is missing, and true once it is granted.
    @Test("No FDA: watcher, size walk and breakdown walk all exclude Desktop & Documents")
    func gateReachesEveryReader() async throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = Recorder()
        let fda = OSAllocatedUnfairLock(initialState: PermissionState.denied)
        let readers = SystemSyncSource.DesktopDocumentsReaders(
            permissions: { [PermissionStatus(name: "Full Disk Access", state: fda.withLock { $0 })] },
            localSizes: { _, include in await recorder.size(include); return [:] },
            breakdown: { include in await recorder.breakdown(include); return ([:], false) }
        )
        let source = SystemSyncSource(pathCandidates: { [] }, desktopDocumentsReaders: readers)
        let watcher = UbiquityTransferSource(homeDirectory: home, sweep: { _ in [] })
        watcher.start()
        defer { watcher.stop() }
        source.installTransferWatcherForTesting(watcher)

        let t0 = Date()
        let denied = await source.applyDesktopDocumentsGate(featureOn: true, containers: [], now: t0)
        #expect(!denied.readsDesktopDocuments)
        #expect(!watcher.includesDesktopDocuments)
        await recorder.waitFor(total: 2)
        #expect(await recorder.sizeWalks == [false])
        #expect(await recorder.breakdownWalks == [false])

        // Granted, seen on the next permissions re-probe (5-minute cache).
        fda.withLock { $0 = .granted }
        let granted = await source.applyDesktopDocumentsGate(featureOn: true, containers: [], now: t0 + 301)
        #expect(granted.readsDesktopDocuments)
        #expect(watcher.includesDesktopDocuments)
        await recorder.waitFor(total: 4)
        #expect(await recorder.sizeWalks == [false, true])
        #expect(await recorder.breakdownWalks == [false, true])
    }
}

/// The permission answers are cached for 5 minutes; these pin WHEN that cache
/// is dropped early, so an FDA grant reaches the Desktop & Documents gate on
/// the next snapshot instead of up to 5 minutes later.
@Suite("Permission re-probe")
struct PermissionReprobeTests {

    // Without the invalidation the third gate pass inside the TTL serves the
    // cached denial, and this fails.
    @Test("An invalidated cache is re-probed inside the 5-minute TTL; an untouched one is not")
    func invalidationForcesReprobe() async {
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let fda = OSAllocatedUnfairLock(initialState: PermissionState.denied)
        let readers = SystemSyncSource.DesktopDocumentsReaders(
            permissions: {
                probes.withLock { $0 += 1 }
                return [PermissionStatus(name: "Full Disk Access", state: fda.withLock { $0 })]
            },
            localSizes: { _, _ in [:] },
            breakdown: { _ in ([:], false) }
        )
        let source = SystemSyncSource(pathCandidates: { [] }, desktopDocumentsReaders: readers)
        let t0 = Date()

        let first = await source.applyDesktopDocumentsGate(featureOn: true, containers: [], now: t0)
        #expect(first.fullDiskAccess == .denied)
        fda.withLock { $0 = .granted }
        let cached = await source.applyDesktopDocumentsGate(featureOn: true, containers: [], now: t0 + 15)
        #expect(cached.fullDiskAccess == .denied, "a plain 15 s cycle keeps the cache")
        #expect(probes.withLock { $0 } == 1)

        await source.invalidatePermissions()
        let reprobed = await source.applyDesktopDocumentsGate(featureOn: true, containers: [], now: t0 + 30)
        #expect(probes.withLock { $0 } == 2)
        #expect(reprobed.fullDiskAccess == .granted)
        #expect(reprobed.readsDesktopDocuments, "the grant opens the gate on the next snapshot")
    }

    // `force` alone must NOT re-probe: the window's 15 s tick forces every
    // refresh, and dropping the cache on each would defeat it.
    @MainActor
    @Test("⌘R and activation drop the cache; the forced 15 s tick does not")
    func storeDecidesWhenToReprobe() async {
        let source = RecordingSource(snapshot: .minimal())
        let store = SyncStore(source: source, notifier: noBanners)

        await store.refresh(force: true)
        #expect(source.log == ["snapshot"])

        await store.refresh(force: true, reprobePermissions: true)
        #expect(source.log == ["snapshot", "reprobe", "snapshot"], "dropped BEFORE the snapshot that should see it")

        await store.applicationDidBecomeActive()
        #expect(source.log.last == "reprobe")

        // Debounced (inside 60 s): no fetch, but the cache still goes.
        await store.refresh(reprobePermissions: true)
        #expect(Array(source.log.suffix(2)) == ["reprobe", "reprobe"])
    }
}
