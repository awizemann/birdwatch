import CoreServices
import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "UbiquityTransferSource")

/// One watched path and what the last probe said about it.
nonisolated struct UbiquityCandidate: Sendable, Hashable {
    var path: String
    /// When the path last showed up in an FSEvents batch.
    var lastEventAt: Date
    /// True once a probe has seen the item actually in flight. Used to retire
    /// the candidate the moment the transfer finishes instead of waiting out
    /// the TTL.
    var wasInFlight: Bool = false
}

/// What a single resource-value probe learned about one path. Pure data so the
/// reducer below is testable without touching the filesystem.
nonisolated struct UbiquityProbeResult: Sendable, Hashable {
    var path: String
    var name: String
    var sizeBytes: Int64
    var isUbiquitous: Bool
    var isUploading: Bool
    var isDownloading: Bool

    nonisolated var isInFlight: Bool { isUbiquitous && (isUploading || isDownloading) }
}

/// One probe tick's answers, plus whether any read was refused for lack of
/// permission (EPERM / EACCES) — the sign that Full Disk Access is gone.
nonisolated struct UbiquityProbeBatch: Sendable, Equatable {
    var results: [UbiquityProbeResult]
    var accessDenied = false
}

/// One shallow sweep's paths, plus whether a listing was refused for lack of
/// permission. An array literal is a sweep that was not refused.
nonisolated struct UbiquitySweep: Sendable, Equatable, ExpressibleByArrayLiteral {
    var paths: [String]
    var accessDenied = false
    init(paths: [String], accessDenied: Bool = false) {
        self.paths = paths
        self.accessDenied = accessDenied
    }
    init(arrayLiteral elements: String...) { self.init(paths: elements) }
}

/// Live in-flight iCloud transfers, from FSEvents + per-URL ubiquity resource
/// values.
///
/// WHY NOT NSMetadataQuery (the previous implementation, deleted): its
/// ubiquitous scopes are gated on the iCloud/ubiquity entitlement. Birdwatch is
/// an unsandboxed app with no such entitlement, so the query starts, gathers,
/// and returns **zero results forever** — even with a match-everything
/// predicate. Measured on the live system: a 40/60/80/120 MB file copied into
/// ~/Library/Mobile Documents/com~apple~CloudDocs never appeared in any
/// ubiquitous or path-scoped query. That is why nothing ever showed up in
/// Active Transfers or Activity.
///
/// WHY NOT brctl: `brctl monitor` is itself an entitled NSMetadataQuery wrapper
/// and emitted only its "observing in …" banner across four real uploads.
/// `brctl status <container>` *does* report in-flight items, but it blocks for
/// 15–28 s precisely while a sync is running, so it cannot back a live view.
///
/// WHAT WORKS: `URLResourceKey.ubiquitousItemIsUploading` / `…IsDownloading`
/// read straight off the URL. No entitlement, no Full Disk Access, real file
/// names and sizes. A full recursive walk of CloudDocs is far too slow (>20 s,
/// never completes), so FSEvents supplies the candidate paths and we probe only
/// those.
///
/// @MainActor is deliberate: this is the property surface SystemSyncSource
/// reads synchronously from the store's actor. Every expensive step (the probe)
/// hops off via a `@concurrent` static.
@MainActor
final class UbiquityTransferSource {

    private(set) var transfers: [TransferItem] = []

    private var candidates: [String: UbiquityCandidate] = [:]
    /// Transfers that finished, held briefly so a consumer polling far slower
    /// than the probe (SyncStore refreshes every 15 s) cannot miss them. A
    /// small upload can be in flight for less than one poll interval; without
    /// this the file would sync and leave no trace anywhere in the UI — exactly
    /// the dogfooding symptom this source was written to fix.
    private var recentlyCompleted: [(item: TransferItem, at: Date)] = []
    /// Round-robin position into the sorted candidate table for `probeBatch()`.
    private var probeCursor = 0
    private var watchTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// True between a successful `start()` and `stop()`. `pause()` does NOT
    /// clear it — a paused source is started but not currently watching.
    private(set) var isStarted = false
    private(set) var isPaused = false

    /// Probe cadence. FSEvents tells us when a file *changes*, but never when
    /// its upload *finishes*, so completion is only observable by re-probing.
    /// 1 Hz — inside the ≤2/s coalescing budget.
    nonisolated static let probeInterval: Duration = .seconds(1)
    /// FSEvents coalescing window. Combined with the 1 Hz probe this keeps the
    /// source at ≤2 UI-visible updates per second.
    nonisolated static let eventLatency: CFTimeInterval = 0.5
    /// A candidate that never went in flight is forgotten after this long — a
    /// plain local edit inside CloudDocs must not pin memory forever.
    nonisolated static let candidateTTL: TimeInterval = 120
    /// How long a completed transfer stays visible. Must comfortably exceed
    /// SyncStore's 15 s refresh interval so no completion is ever missed.
    nonisolated static let completionGrace: TimeInterval = 90
    /// Hard ceiling on tracked paths (a `git clone` into CloudDocs can emit
    /// thousands of events in a second). Newest events win.
    nonisolated static let candidateLimit = 2000
    /// Per-tick probe budget — see `probeBatch()`.
    nonisolated static let probeBudget = 256

    /// Store-agnostic signals so a view layer can retire the watcher when no
    /// surface is showing transfers, without reaching through the sync source.
    ///
    /// Posted per `TransferWatchPolicy.shouldWatch` (via
    /// `SyncStore.syncTransferWatcher`, plus RootView's appear/close): the
    /// watcher runs only while monitoring is on and the main window is on
    /// screen (not minimised or fully covered) or the popover is open. Raw
    /// notification names are unchanged from the NSMetadataQuery era.
    nonisolated static let pauseRequest = Notification.Name("com.wizemann.birdwatch.metadataPause")
    nonisolated static let resumeRequest = Notification.Name("com.wizemann.birdwatch.metadataResume")

    /// Roots worth watching: iCloud Drive plus the Desktop & Documents
    /// mirrors, which sync through the same engine but live outside the
    /// container.
    nonisolated static func defaultRoots(
        homeDirectory: String = UserHome.path,
        includeDesktopDocuments: Bool
    ) -> [String] {
        var roots = [homeDirectory + "/Library/Mobile Documents"]
        if includeDesktopDocuments {
            roots += [homeDirectory + "/Desktop", homeDirectory + "/Documents"]
        }
        return roots.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether ~/Desktop and ~/Documents are iCloud-synced (brctl status:
    /// "Desktop & Documents: current=YES"). Starts false so a fresh launch never
    /// touches those folders — and never earns a TCC prompt — until the sync
    /// engine confirms they are iCloud data; flipping it re-arms the watcher
    /// on the wider root set.
    private(set) var includesDesktopDocuments = false
    /// The first seed sweep's candidates have been probed once (or there was
    /// nothing to sweep): from here on an empty `transfers` is a reading, not
    /// a wait. Reset by `stop()` and `pause()`, which clear the list.
    private(set) var hasFirstReading = false
    /// The first seed sweep's paths are in the candidate table (a sweep
    /// whose result was dropped while paused does not count).
    private var hasIngestedSweep = false

    func setIncludesDesktopDocuments(_ include: Bool) {
        guard include != includesDesktopDocuments else { return }
        includesDesktopDocuments = include
        // Turning Desktop & Documents OFF (Full Disk Access revoked, or the
        // feature switched off) must stop every read of those folders NOW:
        // the 1 Hz probe would otherwise keep calling resourceValues on
        // candidates under ~/Desktop — the very TCC prompt the gate prevents.
        if !include { dropPathsOutsideRoots() }
        guard isStarted, !isPaused else { return }
        endWatching()
        beginWatching()
    }

    /// The roots that may be read right now.
    private var currentRoots: [String] {
        rootsOverride ?? Self.defaultRoots(homeDirectory: homeDirectory, includeDesktopDocuments: includesDesktopDocuments)
    }

    /// Forgets candidates, transfers and completions outside `currentRoots`.
    private func dropPathsOutsideRoots() {
        let roots = currentRoots
        candidates = candidates.filter { Self.isUnder($0.key, roots: roots) }
        transfers.removeAll { !Self.isUnder($0.id, roots: roots) }
        recentlyCompleted.removeAll { !Self.isUnder($0.item.id, roots: roots) }
        probeCursor = 0
    }

    /// Path containment by whole components ("/a/Doc" is not under "/a/Do").
    nonisolated static func isUnder(_ path: String, roots: [String]) -> Bool {
        roots.contains { root in
            let base = root.hasSuffix("/") ? String(root.dropLast()) : root
            return path == base || path.hasPrefix(base + "/")
        }
    }

    /// Home directory the default roots hang off — a test seam.
    private let homeDirectory: String

    /// The shallow directory sweep (seed and rescan). Injected only so a test
    /// can hold a sweep open; production always lists the directories.
    private let sweep: @Sendable ([String]) async -> UbiquitySweep

    /// The per-tick resource-value probe. Injected so a test can answer with
    /// a permission error; production reads the files.
    private let probe: @Sendable ([String]) async -> UbiquityProbeBatch

    /// Set once a read was refused for lack of permission (Full Disk Access
    /// revoked mid-session). From then on this watcher reads nothing — not
    /// even on resume — until it is stopped and replaced.
    private(set) var lostAccess = false

    /// Told once, when `lostAccess` is first set: the owner drops its cached
    /// permission answer so the next snapshot re-probes, and releases this
    /// watcher.
    var onAccessDenied: (@MainActor () -> Void)?

    /// Fixed roots instead of `defaultRoots` — a test seam, so pause/resume
    /// can be asserted on a real watcher over a temporary directory.
    private let rootsOverride: [String]?

    /// True while the FSEvents stream and probe ticker are running.
    var isWatching: Bool { watchTask != nil || probeTask != nil }

    init(
        roots: [String]? = nil,
        homeDirectory: String = UserHome.path,
        sweep: @escaping @Sendable ([String]) async -> UbiquitySweep = { await UbiquityTransferSource.shallowSeedPaths(roots: $0) },
        probe: @escaping @Sendable ([String]) async -> UbiquityProbeBatch = { await UbiquityTransferSource.probe(paths: $0) }
    ) {
        rootsOverride = roots
        self.homeDirectory = homeDirectory
        self.sweep = sweep
        self.probe = probe
        // Self-wiring: the instance listens for the app-wide pause/resume
        // signals itself, so no owner has to forward them.
        for (name, isPauseSignal) in [(Self.pauseRequest, true), (Self.resumeRequest, false)] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if isPauseSignal { self?.pause() } else { self?.resume() }
                }
            }
            lifecycleObservers.append(token)
        }
    }

    func start() {
        guard !isStarted, !lostAccess else { return }
        isStarted = true
        isPaused = false
        beginWatching()
    }

    func stop() {
        guard isStarted else { return }
        endWatching()
        for token in lifecycleObservers { NotificationCenter.default.removeObserver(token) }
        lifecycleObservers.removeAll()
        candidates.removeAll()
        // Published state goes too: a source that is started again must not
        // republish transfers (or completions still inside their grace window)
        // that were observed before the stop.
        transfers.removeAll()
        recentlyCompleted.removeAll()
        probeCursor = 0
        hasFirstReading = false
        hasIngestedSweep = false
        isStarted = false
        isPaused = false
    }

    /// Tears down the FSEvents stream and the probe ticker (the whole cost)
    /// while keeping the notification observers, so `resume()` is one call.
    ///
    /// Nothing observed before the pause is served as live (C1): `transfers`
    /// and the completion buffer are cleared — a frozen list would read as
    /// "in flight" in every snapshot taken while paused. Candidates are kept
    /// (so resume can re-probe them) but forget that they were seen in
    /// flight: one that finished while nobody watched is never stamped as
    /// "completed now" on resume; it just ages out. One still in flight is
    /// seen again by the first probe.
    func pause() {
        guard isStarted, !isPaused else { return }
        endWatching()
        isPaused = true
        // The list is cleared: until the resumed watcher has swept and
        // probed again, an empty list is not a reading.
        hasFirstReading = false
        hasIngestedSweep = false
        transfers.removeAll()
        recentlyCompleted.removeAll()
        candidates = candidates.mapValues { var c = $0; c.wasInFlight = false; return c }
        logger.info("transfer watcher paused")
    }

    func resume() {
        guard isStarted, isPaused, !lostAccess else { return }
        isPaused = false
        beginWatching()
        logger.info("transfer watcher resumed")
    }

    // OWNERSHIP CONTRACT: whoever releases this object must call stop() first —
    // Swift 6 forbids touching the non-Sendable observer tokens from a
    // nonisolated deinit, so there is no automatic cleanup. The instance is
    // app-lifetime today (owned by SystemSyncSource).

    // MARK: - Watching

    private func beginWatching() {
        let roots = currentRoots
        guard !roots.isEmpty else {
            logger.warning("no ubiquity roots present; transfer watching disabled")
            hasFirstReading = true      // nothing to read: an empty list is the answer
            return
        }

        // Seed: a transfer already in flight when the app launches produced its
        // FSEvents before we were listening. A shallow, time-boxed sweep of the
        // roots catches it without the >20s cost of a full recursive walk.
        requestSweep(of: roots)

        let feed = Self.eventFeed(roots: roots, latency: Self.eventLatency)
        watchTask = Task { [weak self] in
            // One wake-up may stand for several FSEvents callbacks: the sink
            // accumulates between wakes, so draining it loses nothing.
            for await _ in feed.wakes {
                let batch = feed.sink.drain()
                guard let self else { return }
                self.ingest(paths: batch.paths, at: Date())
                self.rescanIfNeeded(after: batch, roots: roots)
            }
        }

        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.probeInterval)
                } catch {
                    logger.debug("probe ticker cancelled")
                    return
                }
                guard let self else { return }
                await self.probeOnce()
            }
        }
    }

    private func endWatching() {
        watchTask?.cancel()
        watchTask = nil
        probeTask?.cancel()
        probeTask = nil
        // The sweep in flight (if any) is NOT cancelled or forgotten: its GCD
        // block cannot be interrupted, and forgetting it would let a resume
        // queue another behind a hung one. It finishes, its result is
        // dropped while paused, and only then may a new sweep start.
        queuedSweep.removeAll()
    }

    private func ingest(paths: [String], at date: Date) {
        candidates = Self.merge(candidates, newPaths: paths, at: date)
    }

    /// The one shallow sweep in flight (seed or rescan), and directories
    /// asked for while it runs. Single-flight: a hung File Provider listing
    /// holds one GCD thread, never a growing queue of blocks behind it.
    private var sweepTask: Task<Void, Never>?
    private var queuedSweep: Set<String> = []
    /// Test hook: true while a sweep is running.
    var isSweepingForTesting: Bool { sweepTask != nil }
    /// Test hook: waits for the sweep in flight (if any) to land.
    func finishSweepForTesting() async { await sweepTask?.value }
    /// Test hook: one probe tick, as the 1 Hz ticker runs it.
    func probeOnceForTesting() async { await probeOnce() }

    /// FSEvents (or our own accumulator) lost individual events: re-sweep the
    /// affected directories with the same shallow seed sweep used at start.
    ///
    /// SHALLOW ON PURPOSE: only the immediate children of each named
    /// directory become candidates, so a file deeper down whose event was
    /// lost is found only when its next event arrives. A recursive walk of
    /// CloudDocs measured >20 s and never completed, and an overflow names
    /// whole roots — a bounded deep walk would still miss files while
    /// costing far more, so the cheaper, predictable sweep is used and the
    /// gap is logged rather than papered over.
    private func rescanIfNeeded(after batch: FSEventBatch, roots: [String]) {
        let targets = Self.rescanTargets(for: batch, roots: roots)
        guard !targets.isEmpty else { return }
        logger.warning("FSEvents lost events (\(batch.rescanPaths.count, privacy: .public) must-rescan flag(s), accumulator overflow: \(batch.overflowed, privacy: .public)); shallow re-sweep of \(targets.count, privacy: .public) director\(targets.count == 1 ? "y" : "ies", privacy: .public)")
        requestSweep(of: targets)
    }

    private func requestSweep(of directories: [String]) {
        queuedSweep.formUnion(directories)
        guard sweepTask == nil else { return }   // folds into the next sweep
        startQueuedSweep()
    }

    private func startQueuedSweep() {
        let targets = queuedSweep.sorted()
        queuedSweep.removeAll()
        guard !targets.isEmpty else { sweepTask = nil; return }
        let sweptAt = Date()
        let sweep = sweep
        sweepTask = Task { [weak self] in
            let swept = await sweep(targets)
            guard let self else { return }
            self.sweepTask = nil
            if swept.accessDenied {
                self.accessDenied()
                return
            }
            guard self.isStarted, !self.isPaused else { return }
            // The roots may have narrowed while the sweep ran (Desktop &
            // Documents turned off): never ingest what may no longer be read.
            let roots = self.currentRoots
            self.ingest(paths: swept.paths.filter { Self.isUnder($0, roots: roots) }, at: sweptAt)
            self.hasIngestedSweep = true
            self.startQueuedSweep()
        }
    }

    func requestSweepForTesting(_ directories: [String]) { requestSweep(of: directories) }


    /// Paths to probe this tick.
    ///
    /// BUDGET: the candidate table can hold up to `candidateLimit` (2000)
    /// paths, and each probe is a `resourceValues` syscall — at 1 Hz that is
    /// 2000 stats per second for a table that a single `git clone` can fill.
    /// So each tick probes at most `probeBudget` (256) paths, advancing a
    /// round-robin cursor so the whole table is still covered every few ticks
    /// (2000 / 256 ≈ 8 s worst case, well inside the 120 s candidate TTL and
    /// the 90 s completion grace).
    ///
    /// EXCEPTION: anything already seen in flight is probed on EVERY tick,
    /// outside the budget. Completion is only observable by re-probing, so an
    /// in-flight item must never wait its turn — that would stall the
    /// "<name> uploaded" activity event by up to a full sweep. In-flight items
    /// are bounded in practice by how much the engine moves at once.
    private func probeBatch() -> [String] {
        let all = candidates.keys.sorted()   // stable order → the cursor means something
        guard all.count > Self.probeBudget else {
            probeCursor = 0
            return all
        }
        let inFlight = Set(all.filter { candidates[$0]?.wasInFlight == true })
        let start = probeCursor % all.count
        var batch: [String] = []
        batch.reserveCapacity(Self.probeBudget + inFlight.count)
        for offset in 0..<Self.probeBudget {
            batch.append(all[(start + offset) % all.count])
        }
        probeCursor = (start + Self.probeBudget) % all.count
        let picked = Set(batch)
        batch.append(contentsOf: inFlight.subtracting(picked).sorted())
        return batch
    }

    private func probeOnce() async {
        let paths = probeBatch()
        guard !paths.isEmpty else {
            // Nothing tracked, but completions may still be inside their grace
            // window — never blank those out early.
            let now = Date()
            recentlyCompleted.removeAll { now.timeIntervalSince($0.at) > Self.completionGrace }
            let lingering = recentlyCompleted.map(\.item)
            if lingering != transfers { transfers = lingering }
            if hasIngestedSweep { hasFirstReading = true }
            return
        }
        let probed = await probe(paths)
        guard isStarted, !isPaused, !lostAccess else { return }
        if probed.accessDenied {
            accessDenied()
            return
        }
        apply(probed.results, now: Date())
        // The swept candidates have now been probed once: from here on an
        // empty `transfers` is a reading.
        if hasIngestedSweep { hasFirstReading = true }
    }

    private func apply(_ probed: [UbiquityProbeResult], now: Date) {
        // Same rule for a probe that was in flight when the roots narrowed.
        let roots = currentRoots
        let results = probed.filter { Self.isUnder($0.path, roots: roots) }
        let inFlight = Self.transferItems(from: results, homeDirectory: homeDirectory)
        let before = candidates
        candidates = Self.reduce(candidates, results: results, now: now)
        // A candidate that WAS in flight and is now gone from the table
        // completed on this tick.
        let stillTracked = Set(candidates.keys)
        let justFinished = transfers.filter {
            before[$0.id]?.wasInFlight == true && !stillTracked.contains($0.id) && !$0.isDone
        }
        recentlyCompleted = Self.foldCompletions(recentlyCompleted, finished: justFinished, now: now)

        let items = inFlight + recentlyCompleted.map(\.item).filter { done in
            !inFlight.contains { $0.id == done.id }
        }
        // Identity-stable and cheap: skip the publish when nothing moved so the
        // store does not redraw at 1 Hz for no reason.
        if items != transfers { transfers = items }
    }

    /// A read was refused for lack of permission: Full Disk Access was
    /// revoked while watching. Without it the very next read raises macOS
    /// 27's iCloud Drive prompt, so stop everything now — FSEvents stream,
    /// probe ticker, queued sweeps — forget what was seen (nothing here is
    /// current any more), and tell the owner, who re-probes and releases this
    /// watcher. Not "paused": resume() cannot restart it.
    private func accessDenied() {
        guard !lostAccess else { return }
        lostAccess = true
        endWatching()
        candidates.removeAll()
        transfers.removeAll()
        recentlyCompleted.removeAll()
        hasFirstReading = false
        hasIngestedSweep = false
        logger.warning("transfer watcher: a read in iCloud Drive was refused (no permission); stopped until access is re-checked")
        onAccessDenied?()
    }

    // MARK: - Test seams (the probe budget is stateful, so it cannot be pure)

    func ingestForTesting(paths: [String], at date: Date) { ingest(paths: paths, at: date) }
    var candidatePathsForTesting: Set<String> { Set(candidates.keys) }
    func probeBatchForTesting() -> [String] { probeBatch() }
    /// One probe tick with injected results (no file system).
    func applyProbeForTesting(_ results: [UbiquityProbeResult], now: Date) { apply(results, now: now) }

    // MARK: - Pure state machine (nonisolated for headless tests)

    /// Folds a batch of FSEvents paths into the candidate table. Newest events
    /// win when the limit bites; directories are not filtered here (the probe
    /// discards them), so this stays a pure string fold.
    nonisolated static func merge(
        _ existing: [String: UbiquityCandidate],
        newPaths: [String],
        at date: Date,
        limit: Int = candidateLimit
    ) -> [String: UbiquityCandidate] {
        var out = existing
        for path in newPaths {
            if var found = out[path] {
                found.lastEventAt = date
                out[path] = found
            } else {
                out[path] = UbiquityCandidate(path: path, lastEventAt: date)
            }
        }
        guard out.count > limit else { return out }
        let keep = out.values.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.path, $0) })
    }

    /// Applies probe results: marks candidates that are in flight, retires the
    /// ones that just finished (in flight → no longer in flight) and the ones
    /// that never became interesting within the TTL.
    ///
    /// Retiring a finished item is what makes it *disappear* from `transfers`,
    /// which is exactly the signal ActivityLog.diff turns into an
    /// "<name> uploaded" event — the completion path has no other observable.
    nonisolated static func reduce(
        _ existing: [String: UbiquityCandidate],
        results: [UbiquityProbeResult],
        now: Date,
        ttl: TimeInterval = candidateTTL
    ) -> [String: UbiquityCandidate] {
        let byPath = Dictionary(results.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [String: UbiquityCandidate] = [:]
        out.reserveCapacity(existing.count)
        for (path, candidate) in existing {
            var candidate = candidate
            if let result = byPath[path] {
                if result.isInFlight {
                    candidate.wasInFlight = true
                    out[path] = candidate
                    continue
                }
                // Finished (or never ubiquitous): drop it now if we ever saw it
                // in flight, otherwise let the TTL decide.
                if candidate.wasInFlight { continue }
            }
            if now.timeIntervalSince(candidate.lastEventAt) < ttl { out[path] = candidate }
        }
        return out
    }

    /// Folds this tick's completions into the grace-window buffer and expires
    /// entries older than the grace period.
    ///
    /// DE-DUPLICATION IS THE POINT: `TransferItem.id` is the file's path, so
    /// the same file completing twice inside one grace window (edit → sync →
    /// edit → sync — routine while a document is open) would otherwise stack
    /// two entries carrying the SAME id. Duplicate ids break `ForEach`
    /// identity in every list that renders transfers. The later completion
    /// wins and its timestamp restarts the grace window.
    nonisolated static func foldCompletions(
        _ existing: [(item: TransferItem, at: Date)],
        finished: [TransferItem],
        now: Date,
        grace: TimeInterval = completionGrace
    ) -> [(item: TransferItem, at: Date)] {
        var out = existing
        for item in finished {
            var done = item
            done.progress = 1
            out.removeAll { $0.item.id == done.id }
            out.append((done, now))
        }
        out.removeAll { now.timeIntervalSince($0.at) > grace }
        return out
    }

    /// Probe results → the DTOs the store consumes. Deterministic order (by
    /// path) so equality checks and the activity diff are stable.
    nonisolated static func transferItems(
        from results: [UbiquityProbeResult],
        homeDirectory: String = UserHome.path
    ) -> [TransferItem] {
        results
            .filter(\.isInFlight)
            .sorted { $0.path < $1.path }
            .map {
                makeTransferItem(
                    path: $0.path,
                    name: $0.name,
                    sizeBytes: $0.sizeBytes,
                    isUploading: $0.isUploading,
                    homeDirectory: homeDirectory
                )
            }
    }

    // MARK: - Pure mapping (nonisolated for headless tests)

    nonisolated static func makeTransferItem(
        path: String,
        name: String,
        sizeBytes: Int64,
        isUploading: Bool,
        homeDirectory: String = UserHome.path
    ) -> TransferItem {
        return TransferItem(
            id: path,
            appID: appID(forPath: path, homeDirectory: homeDirectory),
            name: name,
            location: displayLocation(forPath: path, homeDirectory: homeDirectory),
            sizeBytes: sizeBytes,
            direction: isUploading ? .upload : .download,
            // HONESTY: this channel reports a boolean, not a percentage. The
            // percent-uploaded resource keys are unavailable on modern macOS
            // (they redirect to the entitled NSMetadataQuery), so there is no
            // progress figure to show. 0 == "in flight, amount unknown"; an
            // item reaching completion leaves the list rather than hitting 1.
            progress: 0
        )
    }

    /// Desktop & Documents sync is a distinct user-facing feature from iCloud Drive.
    nonisolated static func appID(forPath path: String, homeDirectory: String = UserHome.path) -> String {
        if path.hasPrefix(homeDirectory + "/Desktop/") || path.hasPrefix(homeDirectory + "/Documents/") {
            return "desktop-documents"
        }
        // Per-app ubiquity containers attribute to their own app row (Phase 5A).
        if let containerID = AppContainerSource.appID(forPath: path, homeDirectory: homeDirectory) {
            return containerID
        }
        return "icloud-drive"
    }

    /// Home-relative, "~"-abbreviated display path of the item's parent folder.
    nonisolated static func displayLocation(forPath path: String, homeDirectory: String = UserHome.path) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == homeDirectory { return "~" }
        if parent.hasPrefix(homeDirectory + "/") {
            return "~" + parent.dropFirst(homeDirectory.count)
        }
        return parent
    }

    // MARK: - Filesystem I/O (off the main actor)

    nonisolated static let probeKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsDownloadingKey,
        .isDirectoryKey,
        .fileSizeKey,
        .nameKey,
    ]

    /// Reads ubiquity resource values for the given paths. Per-item fault
    /// tolerance: an unreadable or vanished path yields nothing and never
    /// aborts the batch.
    @concurrent nonisolated static func probe(paths: [String]) async -> UbiquityProbeBatch {
        var out: [UbiquityProbeResult] = []
        var denied = false
        out.reserveCapacity(paths.count)
        autoreleasepool {
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: probeKeys)
                } catch {
                    // A vanished file is ordinary churn; a refused read is
                    // lost access — stop at once, every further read would
                    // be refused (or prompt) too.
                    if isAccessDenied(error) {
                        denied = true
                        break
                    }
                    continue
                }
                guard values.isDirectory != true else { continue }
                out.append(UbiquityProbeResult(
                    path: path,
                    name: values.name ?? url.lastPathComponent,
                    sizeBytes: Int64(values.fileSize ?? 0),
                    isUbiquitous: values.isUbiquitousItem ?? false,
                    isUploading: values.ubiquitousItemIsUploading ?? false,
                    isDownloading: values.ubiquitousItemIsDownloading ?? false
                ))
            }
        }
        return UbiquityProbeBatch(results: out, accessDenied: denied)
    }

    /// EPERM / EACCES, directly or as the underlying POSIX error of a Cocoa
    /// read error (NSFileReadNoPermissionError) — what a read without the
    /// needed privacy grant fails with.
    nonisolated static func isAccessDenied(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isAccessDenied(underlying) }
        return false
    }

    /// Top-level-only sweep of each root, so a transfer already running at
    /// launch is not invisible until the user touches the file again. Bounded
    /// by construction (no recursion) — the recursive walk measured >20 s.
    /// Also the rescan after FSEvents drops events, so it runs on its own
    /// serial queue via `BlockingWork` (a cold-placeholder listing blocks).
    nonisolated static func shallowSeedPaths(roots: [String]) async -> UbiquitySweep {
        await BlockingWork.run(on: seedQueue) { listChildren(of: roots) }
    }

    nonisolated static let seedQueue = DispatchQueue(label: "com.wizemann.birdwatch.scan.ubiquity-seed", qos: .utility)

    /// The immediate children of each root, minus dot-files.
    ///
    /// WHY NOT `.skipsHiddenFiles`: macOS sets the hidden flag on most iCloud
    /// container directories under ~/Library/Mobile Documents, so that option
    /// dropped most of the seed roots — a transfer already running in such a
    /// container at launch stayed invisible until its next event. Dot-files
    /// are filtered by name instead, as AppContainerSource does.
    nonisolated static func listChildren(of roots: [String]) -> UbiquitySweep {
        var out: [String] = []
        for root in roots {
            let url = URL(fileURLWithPath: root)
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            } catch {
                let ns = error as NSError
                logger.debug("seed sweep skipped a root: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) at \(root, privacy: .private)")
                // Refused for lack of permission: stop listing, report it.
                if isAccessDenied(error) { return UbiquitySweep(paths: out, accessDenied: true) }
                continue
            }
            out.append(contentsOf: children.filter { !$0.lastPathComponent.hasPrefix(".") }.map(\.path))
        }
        return UbiquitySweep(paths: out)
    }

    // MARK: - FSEvents

    /// FSEvents flags meaning "individual events under this path were lost —
    /// rescan it": the kernel or fseventsd dropped events, or coalesced a
    /// subtree into one must-scan event.
    nonisolated static let mustRescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
    )

    /// One callback's events, split into ordinary changed paths and
    /// directories FSEvents says must be rescanned. Pure, so the flag handling
    /// is testable without a live stream.
    nonisolated static func classify(paths: [String], flags: [FSEventStreamEventFlags]) -> FSEventBatch {
        var batch = FSEventBatch()
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & mustRescanFlags != 0 {
                batch.rescanPaths.append(path)
            } else {
                batch.paths.append(path)
            }
        }
        return batch
    }

    /// Directories to re-sweep after `batch`. An accumulator overflow lost
    /// paths we cannot name, so every root is swept. A must-rescan path inside
    /// a root is swept itself; one ABOVE a root (a kernel drop can name the
    /// volume) stands for that root. Anything else is outside what we watch.
    nonisolated static func rescanTargets(for batch: FSEventBatch, roots: [String]) -> [String] {
        if batch.overflowed { return roots.sorted() }
        var targets: Set<String> = []
        for raw in batch.rescanPaths {
            let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            for root in roots {
                if path == root || path.hasPrefix(root + "/") {
                    targets.insert(path)
                } else if path == "/" || root.hasPrefix(path + "/") {
                    targets.insert(root)
                }
            }
        }
        return targets.sorted()
    }

    /// Changed paths under `roots`, delivered through an accumulating sink.
    ///
    /// WHY NOT a buffered AsyncStream of batches: a bounded buffer
    /// (`bufferingNewest(32)` before) silently discards batches whenever the
    /// main actor falls behind a burst. The callback now merges into the sink
    /// and only posts a coalesced wake-up; the consumer drains everything that
    /// accumulated. The sink is capped — past the cap it keeps the newest
    /// paths and flags `overflowed`, which triggers a rescan of every root.
    ///
    /// SIGTRAP hazard: the FSEvents callback fires on a dispatch queue, never
    /// main. It is a C function pointer (captures nothing) and the sink
    /// travels through the stream's `info` context, so nothing @MainActor is
    /// ever touched off-main.
    nonisolated static func eventFeed(roots: [String], latency: CFTimeInterval) -> FSEventFeed {
        let sink = FSEventSink()
        let wakes = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            sink.attach(continuation)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(sink).toOpaque(),
                retain: nil,
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<FSEventSink>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let stream = FSEventStreamCreate(
                nil, fsEventsCallback, &context, roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else {
                logger.error("FSEventStreamCreate failed")
                // Balance the passRetained above: no stream means no release
                // callback will ever run.
                Unmanaged<FSEventSink>.fromOpaque(context.info!).release()
                continuation.finish()
                return
            }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            guard FSEventStreamStart(stream) else {
                logger.error("FSEventStreamStart failed")
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                continuation.finish()
                return
            }
            let handle = StreamHandle(stream)
            continuation.onTermination = { _ in handle.tearDown() }
        }
        return FSEventFeed(wakes: wakes, sink: sink)
    }
}

/// What the watcher drains from `FSEventSink` per wake-up.
nonisolated struct FSEventBatch: Sendable, Equatable {
    /// Changed paths (candidates for the ubiquity probe).
    var paths: [String] = []
    /// Directories FSEvents flagged must-rescan (MustScanSubDirs /
    /// UserDropped / KernelDropped): their individual events are gone.
    var rescanPaths: [String] = []
    /// The sink hit its cap and discarded older paths it cannot name.
    var overflowed = false

    var isEmpty: Bool { paths.isEmpty && rescanPaths.isEmpty && !overflowed }
}

/// A started FSEvents stream: coalesced wake-ups plus the sink to drain.
nonisolated struct FSEventFeed: Sendable {
    let wakes: AsyncStream<Void>
    let sink: FSEventSink
}

/// Accumulates FSEvents callbacks between consumer wake-ups, so a slow
/// consumer coalesces batches instead of losing them.
/// Sendable: all mutable state lives in an OSAllocatedUnfairLock.
nonisolated final class FSEventSink: Sendable {
    /// Matches the candidate table's own limit: anything past it would be
    /// evicted by `merge` anyway, so beyond this the rescan is the record.
    static let pathLimit = UbiquityTransferSource.candidateLimit

    private struct State {
        var pending = FSEventBatch()
        var continuation: AsyncStream<Void>.Continuation?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let limit: Int

    init(limit: Int = FSEventSink.pathLimit) { self.limit = limit }

    func attach(_ continuation: AsyncStream<Void>.Continuation) {
        state.withLock { $0.continuation = continuation }
    }

    /// Called from the FSEvents queue. Merges, caps, then wakes the consumer
    /// (a wake-up that coalesces with an unconsumed one loses nothing — the
    /// data is here, not in the stream).
    func accumulate(_ batch: FSEventBatch) {
        let continuation = state.withLock { state -> AsyncStream<Void>.Continuation? in
            state.pending.paths.append(contentsOf: batch.paths)
            state.pending.rescanPaths.append(contentsOf: batch.rescanPaths)
            state.pending.overflowed = state.pending.overflowed || batch.overflowed
            if state.pending.paths.count > limit {
                state.pending.paths.removeFirst(state.pending.paths.count - limit)
                state.pending.overflowed = true
            }
            if state.pending.rescanPaths.count > limit {
                state.pending.rescanPaths.removeAll()
                state.pending.overflowed = true
            }
            return state.continuation
        }
        continuation?.yield(())
    }

    /// Everything accumulated since the last drain.
    func drain() -> FSEventBatch {
        state.withLock { state in
            defer { state.pending = FSEventBatch() }
            return state.pending
        }
    }
}

/// Carries the raw FSEventStreamRef across the @Sendable onTermination closure.
/// @unchecked Sendable: the pointer is immutable after init and `tearDown()` is
/// called exactly once, by AsyncStream's own single-shot termination path.
private nonisolated final class StreamHandle: @unchecked Sendable {
    private let stream: FSEventStreamRef
    init(_ stream: FSEventStreamRef) { self.stream = stream }
    func tearDown() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)   // triggers the context release callback
        FSEventStreamRelease(stream)
    }
}

/// Top-level so it stays a capture-free C function pointer.
private nonisolated let fsEventsCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
    guard let info, count > 0 else { return }
    let sink = Unmanaged<FSEventSink>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes: eventPaths is a CFArray of CFString.
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
    sink.accumulate(UbiquityTransferSource.classify(paths: paths, flags: flags))
}
