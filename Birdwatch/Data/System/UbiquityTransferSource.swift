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
    /// Posted by BOTH transfer-showing surfaces on appear/disappear: RootView's
    /// main window and MenuBarPopoverView. Each pauses only when no other
    /// surface is still visible. Occlusion does NOT drive these — a merely
    /// covered window keeps the watcher running (RootView's occlusion gating
    /// only skips refresh work). Raw notification names are unchanged from the
    /// NSMetadataQuery era.
    nonisolated static let pauseRequest = Notification.Name("com.wizemann.birdwatch.metadataPause")
    nonisolated static let resumeRequest = Notification.Name("com.wizemann.birdwatch.metadataResume")

    /// Roots worth watching: iCloud Drive plus the Desktop & Documents
    /// mirrors, which sync through the same engine but live outside the
    /// container.
    nonisolated static func defaultRoots(
        homeDirectory: String = NSHomeDirectory(),
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

    func setIncludesDesktopDocuments(_ include: Bool) {
        guard include != includesDesktopDocuments else { return }
        includesDesktopDocuments = include
        guard isStarted, !isPaused else { return }
        endWatching()
        beginWatching()
    }

    init() {
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
        guard !isStarted else { return }
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
        isStarted = false
        isPaused = false
    }

    /// Tears down the FSEvents stream and the probe ticker (the whole cost)
    /// while keeping the notification observers, so `resume()` is one call.
    /// `transfers` keeps its last value so a popover opened while paused still
    /// shows something.
    func pause() {
        guard isStarted, !isPaused else { return }
        endWatching()
        isPaused = true
    }

    func resume() {
        guard isStarted, isPaused else { return }
        isPaused = false
        beginWatching()
    }

    // OWNERSHIP CONTRACT: whoever releases this object must call stop() first —
    // Swift 6 forbids touching the non-Sendable observer tokens from a
    // nonisolated deinit, so there is no automatic cleanup. The instance is
    // app-lifetime today (owned by SystemSyncSource).

    // MARK: - Watching

    private func beginWatching() {
        let roots = Self.defaultRoots(includeDesktopDocuments: includesDesktopDocuments)
        guard !roots.isEmpty else {
            logger.warning("no ubiquity roots present; transfer watching disabled")
            return
        }

        // Seed: a transfer already in flight when the app launches produced its
        // FSEvents before we were listening. A shallow, time-boxed sweep of the
        // roots catches it without the >20s cost of a full recursive walk.
        let seedAt = Date()
        Task { [weak self] in
            let seeded = await Self.shallowSeedPaths(roots: roots)
            guard let self, self.isStarted, !self.isPaused else { return }
            self.ingest(paths: seeded, at: seedAt)
        }

        let stream = Self.pathStream(roots: roots, latency: Self.eventLatency)
        watchTask = Task { [weak self] in
            for await batch in stream {
                guard let self else { return }
                self.ingest(paths: batch, at: Date())
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
    }

    private func ingest(paths: [String], at date: Date) {
        candidates = Self.merge(candidates, newPaths: paths, at: date)
    }

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
            return
        }
        let results = await Self.probe(paths: paths)
        guard isStarted, !isPaused else { return }
        let now = Date()
        let inFlight = Self.transferItems(from: results)
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

    // MARK: - Test seams (the probe budget is stateful, so it cannot be pure)

    func ingestForTesting(paths: [String], at date: Date) { ingest(paths: paths, at: date) }
    func probeBatchForTesting() -> [String] { probeBatch() }

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
        homeDirectory: String = NSHomeDirectory()
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
        homeDirectory: String = NSHomeDirectory()
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
    nonisolated static func appID(forPath path: String, homeDirectory: String = NSHomeDirectory()) -> String {
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
    nonisolated static func displayLocation(forPath path: String, homeDirectory: String = NSHomeDirectory()) -> String {
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
    @concurrent nonisolated static func probe(paths: [String]) async -> [UbiquityProbeResult] {
        var out: [UbiquityProbeResult] = []
        out.reserveCapacity(paths.count)
        autoreleasepool {
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: probeKeys) else { continue }
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
        return out
    }

    /// Top-level-only sweep of each root, so a transfer already running at
    /// launch is not invisible until the user touches the file again. Bounded
    /// by construction (no recursion) — the recursive walk measured >20 s.
    @concurrent nonisolated static func shallowSeedPaths(roots: [String]) async -> [String] {
        var out: [String] = []
        for root in roots {
            let url = URL(fileURLWithPath: root)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else {
                logger.debug("seed sweep skipped a root")
                continue
            }
            out.append(contentsOf: children.map(\.path))
        }
        return out
    }

    // MARK: - FSEvents

    /// Coalesced batches of changed file paths under `roots`.
    ///
    /// SIGTRAP hazard: the FSEvents callback fires on a dispatch queue, never
    /// main. It is a C function pointer (captures nothing) and the continuation
    /// travels through the stream's `info` context, so nothing @MainActor is
    /// ever touched off-main.
    nonisolated static func pathStream(roots: [String], latency: CFTimeInterval) -> AsyncStream<[String]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let sink = PathSink(continuation: continuation)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(sink).toOpaque(),
                retain: nil,
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<PathSink>.fromOpaque(pointer).release()
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
                Unmanaged<PathSink>.fromOpaque(context.info!).release()
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

/// Carries the stream continuation into the C callback. @unchecked Sendable:
/// the continuation itself is Sendable and the box is immutable after init —
/// the only reason it exists is to have something to put behind a raw pointer.
private nonisolated final class PathSink: @unchecked Sendable {
    let continuation: AsyncStream<[String]>.Continuation
    init(continuation: AsyncStream<[String]>.Continuation) { self.continuation = continuation }
}

/// Top-level so it stays a capture-free C function pointer.
private nonisolated let fsEventsCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
    guard let info, count > 0 else { return }
    let sink = Unmanaged<PathSink>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes: eventPaths is a CFArray of CFString.
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    sink.continuation.yield(paths)
}
