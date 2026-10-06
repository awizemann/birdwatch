import Foundation
import Testing
@testable import Birdwatch

/// Pause Monitoring vs the FSEvents transfer watcher, asserted on a REAL
/// UbiquityTransferSource watching a temporary directory. The store drives it
/// through its injected `setTransferWatching` (the app's version posts the
/// source's notifications), so parallel tests cannot reach this instance.
@Suite("Transfer watcher vs Pause Monitoring")
struct TransferWatchTests {

    private static func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bw-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func store(
        source: any SyncSource = StubSyncSource(snapshot: .minimal()),
        driving watcher: UbiquityTransferSource,
        mainWindowVisible: Bool
    ) -> SyncStore {
        store(source: source, driving: watcher, window: OnScreenFlag(mainWindowVisible))
    }

    private static func store(
        source: any SyncSource = StubSyncSource(snapshot: .minimal()),
        driving watcher: UbiquityTransferSource,
        window: OnScreenFlag
    ) -> SyncStore {
        SyncStore(
            source: source, notifier: noBanners,
            setTransferWatching: { $0 ? watcher.resume() : watcher.pause() },
            isMainWindowVisible: { window.isOnScreen }
        )
    }

    // Fails on de15c3d: resuming while the window was minimised left the
    // watcher paused, and restoring the window (no onAppear) never resumed it.
    // `syncTransferWatcher()` is what RootView's onChange(of: visibility)
    // calls when the window goes on or off screen.
    @Test("Restoring a minimised window resumes the watcher; minimising pauses it")
    func minimiseAndRestore() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = UbiquityTransferSource(roots: [root.path])
        watcher.start()
        defer { watcher.stop() }
        let window = OnScreenFlag(true)
        let store = Self.store(driving: watcher, window: window)

        store.togglePauseAll()
        window.isOnScreen = false            // minimised while paused
        store.syncTransferWatcher()
        store.togglePauseAll()               // resumed while minimised
        #expect(!watcher.isWatching)

        window.isOnScreen = true             // restored
        store.syncTransferWatcher()
        #expect(watcher.isWatching)

        window.isOnScreen = false            // minimised while monitoring
        store.syncTransferWatcher()
        #expect(!watcher.isWatching)
    }

    // Fails on de15c3d: the first fetch starts the watcher unconditionally,
    // so with nothing on screen it ran for no one.
    @Test("Every fetch re-applies the policy: a first fetch with nothing on screen leaves the watcher off")
    func firstFetchWithNothingOnScreen() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = UbiquityTransferSource(roots: [root.path])
        defer { watcher.stop() }
        let source = LateWatcherSource(watcher: watcher)
        await source.gate.open()
        let store = Self.store(source: source, driving: watcher, mainWindowVisible: false)

        await store.refresh(force: true)
        #expect(watcher.isStarted, "the source started it")
        #expect(!watcher.isWatching, "but no surface is on screen")
    }

    // Fails on de15c3d: paused before the first snapshot, then resumed with
    // nothing on screen — the resume-triggered first fetch started the watcher.
    @Test("Pause before the first snapshot, resume with nothing on screen: the watcher stays off")
    func pausedBeforeFirstSnapshotThenResumed() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = UbiquityTransferSource(roots: [root.path])
        defer { watcher.stop() }
        let source = LateWatcherSource(watcher: watcher)
        await source.gate.open()
        let store = Self.store(source: source, driving: watcher, mainWindowVisible: false)

        store.togglePauseAll()
        store.togglePauseAll()               // schedules the first fetch
        await store.pendingResumeRefresh?.value
        #expect(watcher.isStarted)
        #expect(!watcher.isWatching)

        store.isMenuBarPopoverOpen = true    // a surface appears
        store.syncTransferWatcher()
        #expect(watcher.isWatching)
    }

    // Fails if Pause Monitoring stops only the refresh loop again: the
    // FSEvents watcher + probe ticker kept running while "paused".
    @Test("Pausing monitoring stops the watcher; resuming with the window up restarts it")
    func pauseAndResumeWithWindow() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = UbiquityTransferSource(roots: [root.path])
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.isWatching)

        let store = Self.store(driving: watcher, mainWindowVisible: true)
        store.togglePauseAll()
        #expect(watcher.isPaused)
        #expect(!watcher.isWatching)
        store.togglePauseAll()
        #expect(!watcher.isPaused)
        #expect(watcher.isWatching)
    }

    // Fails on 9959ff4: resuming from the menu with no window or
    // popover on screen restarted FSEvents and the 1 Hz probe for nobody.
    @Test("Resuming with no surface on screen leaves the watcher off until one appears")
    func resumeWithoutSurfaceStaysPaused() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = UbiquityTransferSource(roots: [root.path])
        watcher.start()
        defer { watcher.stop() }

        let store = Self.store(driving: watcher, mainWindowVisible: false)
        store.togglePauseAll()
        store.togglePauseAll()
        #expect(watcher.isPaused, "no surface: nothing to show transfers to")
        #expect(!watcher.isWatching)

        // The popover counts as a surface.
        store.togglePauseAll()
        store.isMenuBarPopoverOpen = true
        store.togglePauseAll()
        #expect(watcher.isWatching)
    }

    // Fails without the post-refresh re-request: ⇧⌘P during the first fetch
    // went out before the source created the watcher, which then started
    // watching under a "paused" UI.
    @Test("A pause during the fetch that creates the watcher still pauses it")
    func pauseDuringFirstFetch() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = UbiquityTransferSource(roots: [root.path])
        defer { watcher.stop() }
        let source = LateWatcherSource(watcher: watcher)
        let store = Self.store(source: source, driving: watcher, mainWindowVisible: true)

        let refresh = Task { await store.refresh(force: true) }
        await source.gate.waitUntilArrived()
        store.togglePauseAll()               // the watcher does not exist yet: a no-op
        #expect(!watcher.isStarted)
        await source.gate.open()
        await refresh.value

        #expect(watcher.isStarted)
        #expect(watcher.isPaused)
        #expect(!watcher.isWatching)
    }
}

/// Whether the fake main window is on screen; flipped by tests to model
/// minimise/restore. MainActor (default isolation), read by the store.
final class OnScreenFlag {
    var isOnScreen: Bool
    init(_ isOnScreen: Bool) { self.isOnScreen = isOnScreen }
}

/// Mimics SystemSyncSource: the watcher is created and started inside the
/// first snapshot — here only after the test opens the gate.
final class LateWatcherSource: SyncSource {
    let gate = SnapshotGate()
    let watcher: UbiquityTransferSource
    init(watcher: UbiquityTransferSource) { self.watcher = watcher }

    func currentSnapshot() async -> SyncSnapshot {
        await gate.pass()
        return await MainActor.run {
            watcher.start()
            return SyncSnapshot.minimal()
        }
    }

    func logStream(appID: String, backend: SyncBackend) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func conflictDetail(issueID: String) async -> ConflictDetail? { nil }
}

/// Holds a caller at `pass()` until `open()`, and lets the test wait for the
/// caller to arrive — ordering by continuations, never by time (C8).
actor SnapshotGate {
    private var arrived = false
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var passer: CheckedContinuation<Void, Never>?

    func pass() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { passer = $0 }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        passer?.resume()
        passer = nil
    }
}

@Suite("Transfer watch policy")
struct TransferWatchPolicyTests {

    // RootView's onDisappear used to post a pause directly, stopping the
    // watcher under an open popover. It now asks the store's rule.
    @MainActor @Test("Closing the window keeps watching while the popover is open")
    func closeWithPopoverOpen() {
        let calls = WatchCalls()
        let store = SyncStore(source: StubSyncSource(snapshot: .minimal()), notifier: noBanners,
                              setTransferWatching: { calls.values.append($0) },
                              isMainWindowVisible: { true })   // NSApp not caught up yet
        store.isMenuBarPopoverOpen = true
        store.syncTransferWatcher(mainWindowOnScreen: false)
        #expect(calls.values == [true])
        store.isMenuBarPopoverOpen = false
        store.syncTransferWatcher(mainWindowOnScreen: false)
        #expect(calls.values == [true, false], "the closing window's own word beats a stale NSApp.windows")
        store.togglePauseAll()
        store.syncTransferWatcher(mainWindowOnScreen: true)
        #expect(calls.values.last == false, "appearing while paused never resumes")
    }

    // A minimised window is not on screen: it must not hold the watcher on,
    // and restoring it (on screen again) must bring the watcher back.
    @Test("The watcher runs only with monitoring on and a surface on screen", arguments: [
        (false, true, false, true),    // window on screen
        (false, false, true, true),    // popover open
        (false, false, false, false),  // window minimised or closed, no popover
        (true, true, false, false),    // paused, window on screen
        (true, false, true, false),    // paused, popover open
    ])
    func shouldWatch(paused: Bool, mainWindowOnScreen: Bool, popoverOpen: Bool, expected: Bool) {
        #expect(TransferWatchPolicy.shouldWatch(
            monitoringPaused: paused, mainWindowOnScreen: mainWindowOnScreen, popoverOpen: popoverOpen
        ) == expected)
    }

    // Alan's rule: no surprise TCC prompt. Without CONFIRMED Full Disk
    // Access nothing reads ~/Desktop or ~/Documents (watcher roots, size
    // walk, breakdown walk all follow this); a grant turns them on.
    @Test("Desktop & Documents are read only with the feature on and FDA granted", arguments: [
        (true, PermissionState?.some(.granted), true),
        (true, PermissionState?.some(.denied), false),
        (true, PermissionState?.some(.unknown), false),
        (true, PermissionState?.none, false),          // not probed yet
        (false, PermissionState?.some(.granted), false),
    ])
    func readsDesktopDocuments(featureOn: Bool, fda: PermissionState?, expected: Bool) {
        #expect(TransferWatchPolicy.readsDesktopDocuments(featureOn: featureOn, fullDiskAccess: fda) == expected)
    }

    // Fails on the old "visible and not an NSPanel" test, which the always-
    // visible NSStatusBarWindow (identifier nil, not a panel) satisfied.
    @Test("Only the visible window identified 'main' counts as the main window")
    func mainWindow() {
        #expect(TransferWatchPolicy.isMainWindow(identifier: "main", isVisible: true, isPanel: false))
        #expect(!TransferWatchPolicy.isMainWindow(identifier: "main", isVisible: false, isPanel: false))
        #expect(!TransferWatchPolicy.isMainWindow(identifier: nil, isVisible: true, isPanel: false),
                "the status item's NSStatusBarWindow")
        #expect(!TransferWatchPolicy.isMainWindow(identifier: "main", isVisible: true, isPanel: true))
        #expect(!TransferWatchPolicy.isMainWindow(identifier: "main-AppWindow-1", isVisible: true, isPanel: false))
    }
}

@MainActor private final class WatchCalls { var values: [Bool] = [] }
