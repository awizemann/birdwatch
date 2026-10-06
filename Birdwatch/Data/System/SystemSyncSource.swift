import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "system-source")

/// Phase 1 composite source: assembles the live snapshot from the real system
/// services. Honesty rules apply — data a backend cannot provide is absent or
/// explicitly labeled, never invented (see the product-shape memory note).
///
/// Isolation: this class is nonisolated, and NonisolatedNonsendingByDefault
/// (SE-0461) is not enabled, so its `async` SyncSource requirements run on the
/// global concurrent executor, not on the caller's (SyncStore's) MainActor.
/// The type only orchestrates — every expensive step hops to its owning actor
/// (CloudDocsSource / DaemonStatsSource run brctl and ps on their executors;
/// blocking scans go through SingleFlightScan / @concurrent functions) — and
/// every read of its MainActor state (the caches below, UbiquityTransferSource,
/// ActivityLog) is an explicit `await MainActor.run` hop.
final class SystemSyncSource: SyncSource {
    private let cloudDocs: CloudDocsSource
    private let daemonStats = DaemonStatsSource()
    // Blocking directory scans (see SingleFlightScan): one in flight each, on
    // their own queues, late results kept for the next cycle.
    private let folderScan = SingleFlightScan(label: "drive-folders") { DriveFolderSource.scanFolders() }
    private let containerScan = SingleFlightScan(label: "app-containers") { AppContainerSource.scanContainers() }
    private let bandwidthSource = BandwidthSource()
    @MainActor private var metadata: UbiquityTransferSource?
    @MainActor private var activityLog: ActivityLog?
    // Conflict scan cache: enumerating CloudDocs + NSFileVersion probing is
    // too heavy for every 15s refresh. 5-minute TTL like cachedPermissions.
    @MainActor private var cachedConflicts: (found: [ConflictSource.FoundConflict], at: Date)?
    // Issue ids the user resolved while a scan may have been in flight. A scan
    // that started before the resolve would otherwise resurrect the issue when
    // it lands, so completed scans are filtered against this set before
    // caching — and then PRUNED (see `stillSuppressedConflictIDs`), or a new
    // conflict on the same file (same id) would stay hidden until relaunch.
    @MainActor private var resolvedConflictIDs: Set<String> = []
    // The last successful conflict scan stopped at its item cap.
    @MainActor private(set) var conflictScanCapped = false
    // Guarded by MainActor (read and written only inside MainActor.run hops).
    // Cached because the notifications probe races a 1.5s timeout — paying that
    // on every 15s refresh (or on first paint) is wasted latency. 5-minute TTL
    // so a grant made mid-session (e.g. FDA flipped in System Settings) shows
    // up without a relaunch.
    @MainActor private var cachedPermissions: (values: [PermissionStatus], at: Date)?
    @MainActor private var conflictScanInFlight = false
    @MainActor private var lastConflictScanAttempt: Date?
    // Per-app local footprint (allocated bytes). A deep walk over every
    // container is far too heavy for the 15s cycle, so it NEVER runs on the
    // snapshot path: 5-minute TTL, single-flight, results served from cache and
    // folded into the next snapshot's rows.
    // `includedDesktopDocuments` records the flag the walk ran with: a cache
    // from before the Desktop & Documents flag was known (or changed) is
    // stale regardless of age and is re-measured on the next cycle.
    @MainActor private var cachedLocalSizes: (values: [String: LocalSize], at: Date, includedDesktopDocuments: Bool)?
    @MainActor private var sizeScanInFlight = false
    // File-type breakdown of the local footprint (Storage view). Deep walk over
    // every container + Desktop/Documents — same rule as the size pass: 5-minute
    // TTL, single-flight, never on the paint path. Same flag rule as above.
    @MainActor private var cachedBreakdown: (
        totals: [StorageCategory: Int64], isPartial: Bool, at: Date, includedDesktopDocuments: Bool
    )?
    @MainActor private var breakdownScanInFlight = false
    // Observed CloudKit apps (from cloudd's unified log). `log show` costs ~2s,
    // so it follows the same rule as the size/conflict scans: 5-minute TTL,
    // single-flight, never on the paint path — rows appear on a later cycle.
    private let cloudKitApps = CloudKitAppSource()
    @MainActor private var cachedCloudKitApps: (scan: CloudKitScan, at: Date)?
    @MainActor private var cloudKitScanInFlight = false
    // `brctl dump -i` is a ~2s spawn plus a multi-megabyte parse — far too
    // heavy for the 15s cycle and never allowed to gate paint. Same discipline
    // as the scans above, with a shorter 60s TTL because the retry queue and
    // engine internals it feeds are the diagnostics the user is watching.
    private let dumpSource: BrctlDumpSource
    /// Redacted-path candidates for the retry queue (a capped filesystem
    /// walk). Injected so a test can drive the dump refresh without one.
    private let pathCandidates: @Sendable () -> [PathCandidate]
    /// The retry-queue path walk and size measurement are blocking
    /// filesystem work: they run here, never on the cooperative pool.
    private static let dumpMappingQueue = DispatchQueue(label: "com.wizemann.birdwatch.scan.dump-mapping", qos: .utility)
    @MainActor private var cachedDump: (value: BrctlDump, mapped: MappedDump, at: Date)?
    @MainActor private var dumpScanInFlight = false
    @MainActor private var lastDumpAttempt: Date?
    // No dump may be claimed before this: set when a brctl read timed out,
    // because bird keeps serving the killed request for its remaining 15–28 s
    // and the next read would queue behind it. Separate from the pacing
    // clock, so shortening the pacing (forgetRetryQueueItem) keeps it.
    @MainActor private var dumpHoldUntil: Date?
    // Why the most recent dump refresh failed (nil after a success), and how
    // many in a row — the engine card says "timed out", not "check FDA", and
    // a dump that keeps failing backs off (see `dumpRetryInterval`).
    @MainActor private var lastDumpFailure: BrctlReadFailure?
    @MainActor private var dumpConsecutiveFailures = 0
    // `brctl status`, read ONLY on the dump refresh Task, after the dump, so
    // the two never contend for bird (see CloudDocsSource.statusTimeout).
    // Source of the Desktop & Documents flag; keeps the last good read.
    @MainActor private var statusCache = CloudDocsStatusCache()
    // Retry-queue rows whose file this session moved to the Trash. The cached
    // dump is up to 60s old and an in-flight one may be older still, so without
    // this the row reappears seconds after the user threw the folder away — and
    // a FRESH dump resurrects it just as surely, because bird keeps listing the
    // item until its own next scan. Applied to EVERY mapped dump, and pruned
    // only once a dump stops listing the item naturally (see
    // `applyingForgotten`), so a genuinely re-appearing item can show again.
    @MainActor private var forgottenRetryIDs: Set<String> = []
    static let dumpTTL: TimeInterval = 60

    /// Everything `BrctlDumpMapper` derives from one dump, computed ONCE when
    /// the dump lands (on the background refresh Task) instead of on every 15s
    /// snapshot. The mapping walks every pending item in a multi-megabyte dump
    /// — several times over, once per output — so recomputing it per snapshot
    /// put that whole cost on the paint path for data that only changes when
    /// the 60s dump refresh succeeds.
    nonisolated struct MappedDump: Sendable {
        var retryQueue: [RetryQueueItem]
        var retryQueueTotal: Int
        var issues: [IssueItem]
        var deviceSummary: DeviceActivitySummary?
        /// Kept so `enrich` can be applied to the *current* cycle's engine
        /// base. `enrich` itself is O(1) — it reads a handful of scalar
        /// fields — so there is nothing to memoize about it beyond holding
        /// the dump.
        var dump: BrctlDump
        /// The dump's CloudDocs container line (client/server state, last
        /// sync, token) — what the snapshot used to pay `brctl status` for.
        var cloudDocsState: BrctlStatus?

        init(
            _ dump: BrctlDump, cloudDocsState: BrctlStatus? = nil,
            candidates: [PathCandidate] = [], measureSizes: Bool = false
        ) {
            self.cloudDocsState = cloudDocsState
            let rows = BrctlDumpMapper.retryQueue(from: dump, candidates: candidates)
            // Sizing walks the filesystem, so it happens HERE — on the same
            // background dump-refresh Task that already paid for `candidates` —
            // and never on a snapshot or paint path.
            retryQueue = measureSizes ? BrctlDumpMapper.measured(rows) : rows
            retryQueueTotal = BrctlDumpMapper.retryQueueTotal(from: dump)
            issues = BrctlDumpMapper.issues(from: dump)
            deviceSummary = BrctlDumpMapper.deviceSummary(from: dump)
            self.dump = dump
        }
    }

    /// Cheap by design — no I/O before first snapshot (§6). `brctlRunner`
    /// is the spawn seam for every brctl call (status, quota, dump); tests
    /// pass a recording stub.
    nonisolated init(
        brctlRunner: any ProcessRunning = ProcessRunner(),
        pathCandidates: @escaping @Sendable () -> [PathCandidate] = { RedactedPathResolver.candidates() },
        desktopDocumentsReaders: DesktopDocumentsReaders = .live
    ) {
        cloudDocs = CloudDocsSource(runner: brctlRunner)
        dumpSource = BrctlDumpSource(runner: brctlRunner)
        self.pathCandidates = pathCandidates
        self.readers = desktopDocumentsReaders
    }

    /// Everything on the snapshot path that can read ~/Desktop or ~/Documents
    /// (plus the permissions probe that gates it), injectable so a test can
    /// prove the Full Disk Access gate reaches every one of them.
    nonisolated struct DesktopDocumentsReaders: Sendable {
        var permissions: @Sendable () async -> [PermissionStatus]
        var localSizes: @Sendable ([AppContainerSource.Container], Bool) async -> [String: LocalSize]
        var breakdown: @Sendable (Bool) async -> (totals: [StorageCategory: Int64], isPartial: Bool)

        static let live = DesktopDocumentsReaders(
            permissions: { await PermissionsProbe.currentPermissions() },
            localSizes: { await AppContainerSource.localSizes(containers: $0, includeDesktopDocuments: $1) },
            breakdown: { await StorageBreakdownSource.currentTotals(includeDesktopDocuments: $0) }
        )
    }
    private let readers: DesktopDocumentsReaders

    /// Test seam: the transfer watcher the gate drives (normally created
    /// lazily by the first snapshot).
    @MainActor func installTransferWatcherForTesting(_ watcher: UbiquityTransferSource) { metadata = watcher }

    func currentSnapshot() async -> SyncSnapshot {
        // Lazily start the metadata query on first use (needs the main runloop).
        let (transfers, activity) = await MainActor.run { () -> ([TransferItem], [ActivityEvent]) in
            if metadata == nil {
                let m = UbiquityTransferSource()
                m.start()
                metadata = m
            }
            if activityLog == nil { activityLog = ActivityLog() }
            let transfers = metadata?.transfers ?? []
            // Feed the fresh snapshot; the log diffs against the previous one.
            // While the watcher is paused its (cleared) list is not news.
            let activity: [ActivityEvent]
            if metadata?.isPaused == true {
                activityLog?.pause()
                activity = activityLog?.events ?? []
            } else {
                activity = activityLog?.record(transfers) ?? []
            }
            return (transfers, activity)
        }

        // No `brctl status` here: it blocks bird for 15–28 s (a charter
        // non-goal on this path). Client/server state comes from the cached
        // dump; the Desktop & Documents flag from `statusCache`, which the
        // background dump refresh keeps current.
        async let quotaTask = cloudDocs.quotaRemaining()
        // One ps spawn per cycle, shared by daemon stats and bandwidth (audit:
        // the two independent spawns walked the whole process table twice).
        // Both consumers go through `sampleProcessStats` — the single place
        // that owns that guarantee, and the one a test can pin.
        async let processStatsTask = Self.sampleProcessStats(
            daemonStats: daemonStats, bandwidth: bandwidthSource
        )
        // §6: time-box system scans — a cold-metadata CloudDocs enumeration
        // (getattrlistbulk on placeholders) blocked first paint for tens of
        // seconds. Single-flight on its own queue: a slow scan serves the last
        // result (empty only before the first one lands), never a pool thread.
        async let foldersTask = folderScan.reading(within: 5)
        let (quota, processStats, folderReading) =
            await (quotaTask, processStatsTask, foldersTask)
        let (daemons, bandwidth) = processStats
        // value: nil = no scan finished yet; .some(nil) = the root was unreadable.
        let folders = DriveFolderSource.applying(transfers: transfers, to: (folderReading.value ?? nil) ?? [])
        // One hop for everything the background dump refresh maintains.
        // Read the MAPPED result, not the dump: the mapping (retry queue sort,
        // issue derivation, device rollup) walks every pending item in a
        // multi-megabyte dump and is computed once, in the refresh Task.
        let (mapped, dumpAt, statusRead, dumpFailure) = await MainActor.run {
            (cachedDump?.mapped, cachedDump?.at, statusCache, lastDumpFailure)
        }
        let cloudDocsRead = Self.cloudDocsReading(
            mapped: mapped, dumpAt: dumpAt, dumpFailure: dumpFailure, statusRead: statusRead, now: Date())
        let status = cloudDocsRead.state
        // Desktop & Documents are only iCloud data when the sync feature is on;
        // brctl status says so. Nothing reads those folders (or earns a TCC
        // prompt) until it does. Starts false; flips once a status read
        // confirms it, and a later FAILED read keeps the last-known answer
        // instead of flapping the watcher.
        let desktopDocumentsSynced = statusRead.desktopDocumentsSynced
        // Containers first: the footprint walks below need them.
        // One capped, shallow container enumeration, time-boxed like every other
        // system scan (§6) and single-flight on its own queue like the folder
        // scan: on timeout the last completed result is served.
        let containerReading = await containerScan.reading(within: 5)
        let containers = containerReading.value ?? []
        let gate = await applyDesktopDocumentsGate(
            featureOn: desktopDocumentsSynced, containers: containers, now: Date())
        let permissions = gate.permissions
        let fullDiskAccess = gate.fullDiskAccess
        let readsDesktopDocuments = gate.readsDesktopDocuments
        let localSizes = gate.localSizes
        let breakdownCache = gate.breakdownCache

        let conflicts: [ConflictSource.FoundConflict]
        let cachedC = await MainActor.run(body: { usableConflictCache(now: Date()) })
        if let cachedC, Date().timeIntervalSince(cachedC.at) < Self.conflictTTL {
            conflicts = cachedC.found
        } else {
            // Never gate paint on the scan (it probes NSFileVersion per file —
            // tens of seconds on cold metadata). Serve stale-or-empty now and
            // refresh the cache in the background; issues land next cycle.
            conflicts = cachedC?.found ?? []
            // One-hop claim: test-and-set in a SINGLE MainActor.run. The old
            // two-hop form (read the flag, await, then set it) let two
            // concurrent snapshots both observe `false` and both launch the
            // scan — the guard did not actually guard.
            if let resolvedBeforeScan = await MainActor.run(body: { claimConflictScan(now: Date()) }) {
                Task { [weak self] in
                    let scanned = await ConflictSource.scanConflicts()
                    guard let self else { return }
                    await MainActor.run {
                        self.completeConflictScan(scanned?.found, resolvedBeforeScan: resolvedBeforeScan,
                                                  isCapped: scanned?.isCapped ?? false)
                    }
                }
            }
        }

        // Observed CloudKit apps: same stale-or-empty, single-flight, 5-minute
        // discipline as the size pass — `log show` is a ~2s spawn and must
        // never gate first paint. Empty on the first cycle; real rows next.
        let ckCache = await MainActor.run(body: { cachedCloudKitApps })
        let observedCloudKit = ckCache?.scan.apps ?? []
        if ckCache == nil || Date().timeIntervalSince(ckCache!.at) >= 300 {
            let claimed = await MainActor.run { () -> Bool in
                guard !cloudKitScanInFlight else { return false }
                cloudKitScanInFlight = true
                return true
            }
            if claimed {
                Task { [weak self] in
                    // The whole scan, not just its rows: the outcome is what
                    // tells "nothing syncs" from "couldn't tell" (C1).
                    guard let observed = await self?.cloudKitApps.scan() else { return }
                    guard let self else { return }
                    await MainActor.run {
                        self.cachedCloudKitApps = (observed, Date())
                        self.cloudKitScanInFlight = false
                    }
                }
            }
        }

        // brctl dump (+ status when due): stale-or-nil now (`mapped`, read
        // above), refreshed in the background at most once a minute. Retry
        // queue / devices / engine internals appear on a later cycle rather
        // than delaying first paint by ~2s.
        if await MainActor.run(body: { claimDumpRefresh(now: Date()) }) {
            Task { [weak self] in await self?.performDumpRefresh() }
        }

        let apps = Self.buildApps(
            status: status,
            transfers: transfers,
            fileProviderDomains: await Self.fileProviderDomains(),
            containers: containers,
            localSizes: localSizes,
            cloudKitApps: observedCloudKit,
            stateNote: cloudDocsRead.staleNote,
            desktopDocuments: statusRead.desktopDocuments(now: Date()),
            desktopDocumentsReadable: readsDesktopDocuments
        )

        // Per-producer delivery (see SyncSnapshot.issueProducers). Only a
        // SUCCESSFUL result counts: quota read, a conflict scan that could
        // look (failed scans never reach the cache), a dump that parsed
        // (failed dumps never reach the cache). Each is judged on its own, so
        // a stalled conflict scan cannot hold back quota or dump alerts.
        let quotaIssues = Self.deriveIssues(quotaRemaining: quota)
        var producers: [IssueProducer: Set<String>] = [:]
        if quota != nil { producers[.quota] = Set(quotaIssues.map(\.id)) }
        if cachedC != nil { producers[.conflicts] = Set(conflicts.map(\.issue.id)) }
        if let mapped { producers[.dump] = Set(mapped.issues.map(\.id)) }
        // Only meaningful while a scan result is being served.
        let conflictsCapped = cachedC != nil ? await MainActor.run(body: { conflictScanCapped }) : false
        let folderRootUnreadable: Bool = if case .some(.none) = folderReading.value { true } else { false }

        return SyncSnapshot(
            apps: apps,
            transfers: transfers,
            driveFolders: folders,
            devices: [],                          // names are permanently redacted by bird
            deviceActivity: mapped?.deviceSummary,
            issues: quotaIssues
                + conflicts.map(\.issue)
                + (mapped?.issues ?? []),
            activity: activity,
            daemons: daemons,
            retryQueue: mapped?.retryQueue ?? [],
            retryQueueTotal: mapped?.retryQueueTotal ?? 0,
            engine: Self.engine(
                reading: cloudDocsRead, mapped: mapped, dumpFailure: dumpFailure,
                fullDiskAccess: fullDiskAccess
            ),
            permissions: permissions,
            bandwidth: bandwidth,                 // nettop deltas — estimated
            // Local file-type footprint (nil until the background pass lands).
            // The plan cap here is only ever DERIVED — the user's override is
            // applied by SyncStore, which owns the persisted preference.
            storage: breakdownCache.flatMap {
                StorageBreakdownSource.makeStorageInfo(
                    totals: $0.totals, remainingBytes: quota,
                    // A breakdown walked without Desktop & Documents while the
                    // feature is on is missing data — partial until re-measured.
                    planCapOverride: nil,
                    isPartial: $0.isPartial || $0.includedDesktopDocuments != desktopDocumentsSynced
                )
            },
            quotaRemainingBytes: quota,           // brctl quota — remaining only
            notifications: [],
            issueProducers: producers,
            cloudKitScan: ckCache.map { CloudKitScanState($0.scan) } ?? .scanning,
            folderScan: ScanFreshness(completedAt: folderReading.completedAt, isOverdue: folderReading.isOverdue,
                                      isUnreadable: folderRootUnreadable),
            containerScan: ScanFreshness(completedAt: containerReading.completedAt, isOverdue: containerReading.isOverdue),
            conflictScanCap: conflictsCapped ? ConflictSource.maxItemsVisited : nil
        )
    }

    nonisolated func logStream(appID: String, backend: SyncBackend) -> AsyncThrowingStream<LogLine, any Error> {
        LogStreamSource.stream(backend: backend)
    }

    func conflictDetail(issueID: String) async -> ConflictDetail? {
        await MainActor.run { usableConflictCache(now: Date())?.found.first { $0.issue.id == issueID }?.detail }
    }

    func resolveConflict(issueID: String, keepVersionID: String, shownVersionIDs: Set<String>) async -> ConflictResolveResult {
        let detail = await MainActor.run { usableConflictCache(now: Date())?.found.first { $0.issue.id == issueID }?.detail }
        guard let fileURL = detail?.fileURL else {
            // Not "failed": the scan no longer lists it, so a retry can never
            // succeed and the UI must not suggest one (C1).
            logger.info("resolveConflict: no cached conflict for issue \(issueID, privacy: .public)")
            return .notFound
        }
        let result = await ConflictSource.resolve(
            fileURL: fileURL, keepVersionID: keepVersionID, shownVersionIDs: shownVersionIDs
        )
        switch result {
        case .resolved, .notFound:
            // notFound here = the file has no unresolved versions left; either
            // way the cached listing is wrong now.
            await MainActor.run { markConflictResolved(issueID) }
        case .changed:
            // The cached detail is what the user was shown, and it is out of
            // date. Re-probe this one file so the reloaded screen shows the
            // versions that exist NOW.
            let fresh = await ConflictSource.rescan(fileURL: fileURL)
            await MainActor.run { replaceCachedConflict(issueID, with: fresh) }
        case .failed, .busy:
            break   // ConflictSource logged the cause; the conflict stays open
        }
        return result
    }

    // MARK: - brctl dump + status refresh (background; split out for tests)

    /// Single-flight claim for the background brctl refresh, test-and-set in
    /// ONE MainActor hop so two concurrent snapshots cannot both pass. Gated
    /// on the last ATTEMPT, not the last success: a failing brctl (no Full
    /// Disk Access, bird wedged) must not be re-spawned every 15 s, and
    /// repeated failures back off further.
    @MainActor var statusCacheForTesting: CloudDocsStatusCache { statusCache }

    @MainActor func claimDumpRefresh(now: Date) -> Bool {
        guard !dumpScanInFlight else { return false }
        let interval = Self.dumpRetryInterval(consecutiveFailures: dumpConsecutiveFailures)
        guard lastDumpAttempt.map({ now.timeIntervalSince($0) >= interval }) ?? true else { return false }
        guard dumpHoldUntil.map({ now >= $0 }) ?? true else { return false }
        dumpScanInFlight = true
        lastDumpAttempt = now
        return true
    }

    /// One claimed refresh: `brctl dump -i`, then — only after it has
    /// finished — `brctl status` when due. bird serves one brctl request at a
    /// time, so the two must never overlap: `dumpScanInFlight` stays raised
    /// until both are done, and no other code path spawns either.
    func performDumpRefresh() async {
        let read = await dumpSource.currentDump()
        let fresh = try? read.get()
        // The redacted-path walk (what turns bird's `D{7}s` into a real
        // path) and the exact-match size measurement are blocking filesystem
        // work: on their own queue, never a pool thread.
        let pathCandidates = pathCandidates
        let mapped: MappedDump?
        if let fresh {
            mapped = await BlockingWork.run(on: Self.dumpMappingQueue) {
                MappedDump(fresh.dump, cloudDocsState: fresh.cloudDocsState,
                           candidates: pathCandidates(), measureSizes: true)
            }
        } else {
            mapped = nil
        }
        let statusDue = await MainActor.run { () -> Bool in
            switch read {
            case .success:
                lastDumpFailure = nil
                dumpConsecutiveFailures = 0
            case .failure(let failure):
                lastDumpFailure = failure
                dumpConsecutiveFailures += 1
            }
            if let fresh, let mapped {
                // An item we moved to the Trash must not come back — neither
                // from a dump collected before the move, nor from a fresh one
                // bird has not re-scanned yet.
                let applied = Self.applyingForgotten(forgottenRetryIDs, to: mapped)
                forgottenRetryIDs = applied.keptIDs
                cachedDump = (fresh.dump, applied.mapped, Date())
            }
            // Claim the status read in the same hop — unless the dump just
            // timed out: bird is still working on the abandoned dump, so a
            // status now would queue behind it and time out too. Not marked
            // as an attempt, so it is due again on the next refresh.
            if case .failure(.timedOut) = read { return false }
            guard statusCache.isDue(now: Date()) else { return false }
            statusCache.markAttempt(at: Date())
            return true
        }
        if statusDue {
            let result = await cloudDocs.status()
            await MainActor.run {
                statusCache.record(result, at: Date())
                // A status read that timed out was killed client-side, but
                // bird keeps serving it for the rest of its 15–28 s. Restart
                // the dump's clock now so the next dump does not queue behind
                // it, time out, and blame itself.
                if case .failure = result { dumpHoldUntil = Date() + Self.dumpTTL }
            }
        }
        await MainActor.run { dumpScanInFlight = false }
    }

    // MARK: - Desktop & Documents gate (the only path that may read them)

    struct DesktopDocumentsGate {
        let permissions: [PermissionStatus]
        let fullDiskAccess: PermissionState
        let readsDesktopDocuments: Bool
        let localSizes: [String: LocalSize]
        let breakdownCache: (totals: [StorageCategory: Int64], isPartial: Bool, at: Date, includedDesktopDocuments: Bool)?
    }

    /// Probes permissions (5-minute cache), decides whether ~/Desktop and
    /// ~/Documents may be read (`TransferWatchPolicy.readsDesktopDocuments`:
    /// the feature on AND Full Disk Access granted — without it, touching
    /// them raises a surprise TCC prompt), and hands that ONE decision to all
    /// three readers: the transfer watcher's roots, the local size walk and
    /// the Storage breakdown walk. The walks are single-flight background
    /// Tasks served stale-or-empty; their caches are stamped with the
    /// decision, so a grant (or revocation) re-walks on the next cycle.
    func applyDesktopDocumentsGate(
        featureOn: Bool, containers: [AppContainerSource.Container], now: Date
    ) async -> DesktopDocumentsGate {
        let permissions: [PermissionStatus]
        let cached = await MainActor.run(body: { cachedPermissions })
        if let cached, now.timeIntervalSince(cached.at) < 300 {
            permissions = cached.values
        } else {
            permissions = await readers.permissions()
            await MainActor.run { cachedPermissions = (permissions, now) }
        }
        let fullDiskAccess = permissions.first { $0.name == "Full Disk Access" }?.state ?? .unknown
        let reads = TransferWatchPolicy.readsDesktopDocuments(featureOn: featureOn, fullDiskAccess: fullDiskAccess)
        await MainActor.run { metadata?.setIncludesDesktopDocuments(reads) }

        // Local footprint: served stale-or-empty, refreshed in the background at
        // most every 5 minutes. Sizes land on a later cycle — never gating paint.
        let readers = readers
        let sizesCache = await MainActor.run(body: { cachedLocalSizes })
        if Self.footprintCacheIsDue(sizesCache.map { ($0.at, $0.includedDesktopDocuments) }, desktopDocuments: reads, now: now) {
            let claimed = await MainActor.run { () -> Bool in
                guard !sizeScanInFlight else { return false }
                sizeScanInFlight = true
                return true
            }
            if claimed {
                Task { [weak self] in
                    let measured = await readers.localSizes(containers, reads)
                    guard let self else { return }
                    await MainActor.run {
                        self.cachedLocalSizes = (measured, Date(), reads)
                        self.sizeScanInFlight = false
                    }
                }
            }
        }

        // File-type breakdown: identical discipline. Served stale-or-nil, so the
        // Storage view shows its breakdown from a later cycle, never blocking one.
        let breakdownCache = await MainActor.run(body: { cachedBreakdown })
        if Self.footprintCacheIsDue(breakdownCache.map { ($0.at, $0.includedDesktopDocuments) }, desktopDocuments: reads, now: now) {
            let claimed = await MainActor.run { () -> Bool in
                guard !breakdownScanInFlight else { return false }
                breakdownScanInFlight = true
                return true
            }
            if claimed {
                Task { [weak self] in
                    let measured = await readers.breakdown(reads)
                    guard let self else { return }
                    await MainActor.run {
                        self.cachedBreakdown = (measured.totals, measured.isPartial, Date(), reads)
                        self.breakdownScanInFlight = false
                    }
                }
            }
        }
        return DesktopDocumentsGate(
            permissions: permissions, fullDiskAccess: fullDiskAccess, readsDesktopDocuments: reads,
            localSizes: sizesCache?.values ?? [:], breakdownCache: breakdownCache)
    }

    // MARK: - Conflict scan bookkeeping (MainActor; split out for tests)

    /// A successful scan is trusted for `conflictTTL`; after that a rescan is
    /// claimed (stale-while-revalidate).
    static let conflictTTL: TimeInterval = 300
    /// A failed scan is retried no sooner than this (same idea as `dumpTTL`
    /// gating on the last ATTEMPT): an unreadable CloudDocs must not be
    /// re-walked every 15s.
    static let conflictRetryInterval: TimeInterval = 60
    /// How long a successful scan may keep being served while rescans fail.
    /// Past this the list is dropped rather than shown as if current (C1).
    /// Time-based rather than failure-counted: one comparison, and it bounds
    /// staleness in the unit the user experiences, whatever the retry pace.
    static let conflictMaxStaleness: TimeInterval = 900

    /// The conflict cache, or nil — and dropped — once it is older than
    /// `conflictMaxStaleness`. Every reader goes through here.
    @MainActor func usableConflictCache(now: Date) -> (found: [ConflictSource.FoundConflict], at: Date)? {
        if let cached = cachedConflicts, now.timeIntervalSince(cached.at) >= Self.conflictMaxStaleness {
            logger.info("conflict scan: last good result is \(Int(now.timeIntervalSince(cached.at)), privacy: .public)s old — dropping it")
            cachedConflicts = nil
        }
        return cachedConflicts
    }

    /// Single-flight claim, test-and-set in ONE MainActor hop (the old two-hop
    /// form let two snapshots both launch a scan), gated on the last ATTEMPT
    /// so a failing scan backs off. Returns the ids resolved BEFORE this scan
    /// starts — the scan sees the file after those, so it is authoritative for
    /// them — or nil when a scan is running or was attempted too recently.
    @MainActor func claimConflictScan(now: Date) -> Set<String>? {
        guard !conflictScanInFlight else { return nil }
        if let last = lastConflictScanAttempt, now.timeIntervalSince(last) < Self.conflictRetryInterval { return nil }
        conflictScanInFlight = true
        lastConflictScanAttempt = now
        return resolvedConflictIDs
    }

    /// Lands a finished scan. A FAILED scan (nil) keeps the previous cache
    /// (bounded by `conflictMaxStaleness`) — "could not look" is not "no
    /// conflicts", and caching [] would count as the producer's delivery.
    @MainActor func completeConflictScan(
        _ scanned: [ConflictSource.FoundConflict]?, resolvedBeforeScan: Set<String>, now: Date = Date(),
        isCapped: Bool = false
    ) {
        conflictScanInFlight = false
        guard let scanned else { return }
        conflictScanCapped = isCapped
        resolvedConflictIDs = Self.stillSuppressedConflictIDs(
            resolved: resolvedConflictIDs,
            resolvedBeforeScan: resolvedBeforeScan,
            listedByScan: Set(scanned.map(\.issue.id))
        )
        cachedConflicts = (scanned.filter { !resolvedConflictIDs.contains($0.issue.id) }, now)
    }

    /// After `.changed`: swap in the single-file rescan (or drop the entry
    /// when the file has no unresolved versions left).
    @MainActor func replaceCachedConflict(_ issueID: String, with fresh: ConflictSource.FoundConflict?) {
        guard var cached = cachedConflicts else { return }
        if let fresh, let index = cached.found.firstIndex(where: { $0.issue.id == issueID }) {
            cached.found[index] = fresh
        } else {
            cached.found.removeAll { $0.issue.id == issueID }
        }
        cachedConflicts = cached
    }

    /// After a successful resolve: drop it from the cache so the next snapshot
    /// stops reporting it without waiting out the 5-minute TTL, and remember
    /// the id so an already-running scan can't put it back.
    @MainActor func markConflictResolved(_ issueID: String) {
        resolvedConflictIDs.insert(issueID)
        cachedConflicts?.found.removeAll { $0.issue.id == issueID }
    }

    /// Which resolved ids must stay hidden after a scan lands. Pure and static
    /// so the rule is testable without a scan.
    ///
    /// An id stays suppressed only when BOTH hold:
    /// - it was resolved while this scan was running (not in
    ///   `resolvedBeforeScan`) — the scan may have probed the file before the
    ///   resolve, so its listing can be stale; and
    /// - the scan still lists it — otherwise there is nothing to hide.
    ///
    /// Everything else is dropped. In particular an id resolved BEFORE the scan
    /// started is dropped even when the scan lists it: that scan saw the file
    /// after the resolve, so a listing is a genuinely new (or still open)
    /// conflict on the same file, and hiding it would last until relaunch.
    nonisolated static func stillSuppressedConflictIDs(
        resolved: Set<String>, resolvedBeforeScan: Set<String>, listedByScan: Set<String>
    ) -> Set<String> {
        resolved.subtracting(resolvedBeforeScan).intersection(listedByScan)
    }

    /// Drops a retry-queue row whose file was moved to the Trash, and makes the
    /// next snapshot collect a fresh dump instead of waiting out the 60s TTL —
    /// bird's own view of the item is what the user actually wants to see change.
    func forgetRetryQueueItem(id: String) async {
        await MainActor.run {
            forgottenRetryIDs.insert(id)
            cachedDump?.mapped.retryQueue.removeAll { $0.id == id }
            if let count = cachedDump?.mapped.retryQueueTotal, count > 0 {
                cachedDump?.mapped.retryQueueTotal = count - 1
            }
            // Refresh soon so bird's own view catches up — by shortening the
            // pacing clock only. `dumpHoldUntil` (a status read that timed
            // out is still running inside bird) is left alone.
            lastDumpAttempt = nil
        }
    }

    /// Folds the session's forgotten ids into a freshly mapped dump.
    ///
    /// Two jobs, and the second is the one that keeps the row from coming back
    /// forever: ids bird has stopped listing are DROPPED from the set, because
    /// bird has re-scanned and agrees the item is gone. Anything still listed
    /// stays suppressed — bird lists a trashed folder until its next scan, and
    /// a fresh 60s dump would otherwise resurrect the row the user just cleared.
    ///
    /// Pure and static so the resurrection rule is unit-testable without a dump
    /// refresh, a timer, or the live account.
    nonisolated static func applyingForgotten(
        _ ids: Set<String>, to mapped: MappedDump
    ) -> (mapped: MappedDump, keptIDs: Set<String>) {
        guard !ids.isEmpty else { return (mapped, ids) }
        let listed = Set(BrctlDumpMapper.pendingItems(mapped.dump).map(\.itemID))
        let kept = ids.intersection(listed)
        guard !kept.isEmpty else { return (mapped, kept) }
        var mapped = mapped
        mapped.retryQueue.removeAll { kept.contains($0.id) }
        // Every kept id is still counted by `retryQueueTotal` (it is a count of
        // pending items, not of shown rows), so the "Showing N of M" line has
        // to lose them from BOTH halves.
        mapped.retryQueueTotal = max(mapped.retryQueue.count, mapped.retryQueueTotal - kept.count)
        return (mapped, kept)
    }

    // MARK: - Assembly (pure, testable)

    /// True when brctl status reports the Desktop & Documents feature ON
    /// ("Desktop & Documents: current=YES"). The single source for every
    /// decision to touch ~/Desktop or ~/Documents.

    /// The ONE `/bin/ps` of a refresh cycle. The process table is sampled once
    /// and the SAME raw output feeds both consumers: daemon CPU/memory (which
    /// aggregates multi-instance daemons to one row) and bandwidth pid
    /// discovery (which needs every pid). Two independent spawns walked the
    /// whole table twice per 15s cycle.
    ///
    /// Extracted so this guarantee lives in one callable place: a test drives
    /// this exact function with a recording runner and counts the spawns.
    nonisolated static func sampleProcessStats(
        daemonStats: DaemonStatsSource,
        bandwidth: BandwidthSource
    ) async -> ([DaemonStat], BandwidthSummary) {
        let psRaw = await daemonStats.sampleRaw()
        async let daemons = daemonStats.sample(psOutput: psRaw)
        async let summary = bandwidth.sample(psOutput: psRaw)
        return await (daemons, summary)
    }

    nonisolated static func desktopDocumentsSynced(_ status: BrctlStatus?) -> Bool {
        status?.apps.contains { $0.name.hasPrefix("Desktop") && $0.isCurrent } ?? false
    }

    /// `stateNote` qualifies a CloudDocs state that is not current (see
    /// `CloudDocsReading.staleNote`). `desktopDocuments` defaults to what
    /// `status` itself says, for callers that only have a status read.
    nonisolated static func buildApps(
        status: BrctlStatus?,
        transfers: [TransferItem],
        fileProviderDomains: [String],
        containers: [AppContainerSource.Container] = [],
        localSizes: [String: LocalSize] = [:],
        cloudKitApps: [AppSyncState] = [],
        stateNote: String? = nil,
        desktopDocuments: DesktopDocumentsFlag? = nil,
        desktopDocumentsReadable: Bool = true
    ) -> [AppSyncState] {
        var apps: [AppSyncState] = []
        let home = NSHomeDirectory()
        let flag = desktopDocuments ?? status.map {
            desktopDocumentsSynced($0) ? .on(lastKnown: nil) : .off(lastKnown: nil)
        } ?? .unknown("brctl status has not been read")

        func cloudDocsApp(id: String, name: String, tile: String, location: String) -> AppSyncState {
            // In flight only: a finished item lingers (completionGrace) at 1.0.
            let own = transfers.filter { $0.appID == id && !$0.isDone }
            let (rowStatus, line) = cloudDocsRowStatus(ownTransfers: own, state: status, stateNote: stateNote)
            return AppSyncState(
                id: id, name: name, tileColorHex: tile, backend: .cloudDocs, isApple: true,
                status: rowStatus,
                statusLine: line,
                lastActivity: status?.lastSync,
                // Birdwatch reads no item count for these rows, so it is
                // absent rather than a placeholder zero.
                itemCount: nil, pendingItems: own.count,
                localSize: localSizes[id],     // background size pass; nil until it lands
                locationPath: location,
                lastActivityNote: stateNote
            )
        }

        var drive = cloudDocsApp(
            id: "icloud-drive", name: "iCloud Drive", tile: "30b0c7",
            location: "~/Library/Mobile Documents/com~apple~CloudDocs"
        )
        // Desktop & Documents is unknown until brctl status answers, and has
        // no row of its own until it is known to be on — so the iCloud Drive
        // row says what is (not) known, instead of the feature silently
        // reading as off.
        switch flag {
        case .unknown(let reason):
            drive.infoCallout = "Desktop & Documents sync: \(reason)."
        case .off(let lastKnown?):
            drive.infoCallout = "Desktop & Documents sync is off. \(lastKnown)"
        case .on, .off(nil):
            break
        }
        apps.append(drive)
        if case .on(let lastKnown) = flag {
            var row = cloudDocsApp(
                id: "desktop-documents", name: "Desktop & Documents", tile: "ffa62b",
                location: "~/Desktop · ~/Documents"
            )
            if !desktopDocumentsReadable {
                Self.markNeedsFullDiskAccess(&row)
            }
            if let lastKnown {
                // Visible in the list and popover too, not just the detail
                // callout: this row must not read as freshly confirmed.
                row.statusLine += " · last-known setting"
                row.infoCallout = [row.infoCallout, lastKnown].compactMap { $0 }.joined(separator: " ")
            }
            apps.append(row)
        }

        // CloudKit services: OBSERVED only (Phase 5D). Rows come from cloudd's
        // unified log — an app that never appears there gets no row, because
        // absence of activity is the honest signal. cloudd still exposes no
        // per-item progress API, so status is .active (work seen, no progress)
        // or .upToDate (idle), never a fabricated percentage.
        let cloudKitIDs = Set(apps.map(\.id))
        apps.append(contentsOf: cloudKitApps.filter { !cloudKitIDs.contains($0.id) })

        // File Provider domains from ~/Library/CloudStorage (third-party).
        let tiles = ["1a73e8", "d63d3d", "4b5bd6", "5e5ce6", "30b0c7"]
        for (index, domain) in fileProviderDomains.enumerated() {
            let name = domain.split(separator: "-").first.map(String.init) ?? domain
            apps.append(AppSyncState(
                id: "fp-\(domain.lowercased())", name: name,
                tileColorHex: tiles[index % tiles.count], backend: .fileProvider, isApple: false,
                status: .upToDate,
                statusLine: "File Provider domain active",
                lastActivity: nil,
                // fileproviderd reports only domain status.
                itemCount: nil, pendingItems: nil, localSize: nil,
                locationPath: "\(home)/Library/CloudStorage/\(domain)".replacingOccurrences(of: home, with: "~"),
                infoCallout: "\(name) syncs through a File Provider extension. macOS reports only the domain's overall status."
            ))
        }

        // Per-app iCloud Drive containers (Phase 5A). Ids are distinct from the
        // built-ins above, so a duplicate can only come from a future overlap —
        // filter defensively rather than shipping two rows with the same id.
        let existing = Set(apps.map(\.id))
        apps.append(contentsOf: AppContainerSource
            .makeApps(containers: containers, transfers: transfers, localSizes: localSizes)
            .filter { !existing.contains($0.id) })
        return apps
    }

    /// The Desktop & Documents row while Birdwatch is not reading those
    /// folders (no Full Disk Access): nothing is watched or measured, so no
    /// status, pending count or size may be claimed (C1) — the row says why.
    nonisolated static func markNeedsFullDiskAccess(_ row: inout AppSyncState) {
        row.status = .unknown
        row.statusLine = "Transfers need Full Disk Access"
        row.pendingItems = nil
        row.localSize = LocalSize(bytes: 0, isUnreadable: true)
        row.needsFullDiskAccess = true
        row.infoCallout = "Desktop & Documents transfers need Full Disk Access. Without it Birdwatch doesn't watch or measure ~/Desktop and ~/Documents, so macOS never prompts you for them."
    }

    /// Status of a built-in CloudDocs row. Every claim needs evidence (C1):
    /// - file transfers seen → syncing;
    /// - no CloudDocs state at all → `.unknown` (neutral), never "synced";
    /// - bird's client state not idle → `.active` (the engine is working even
    ///   though no file-level transfer is visible);
    /// - idle → up to date, worded as what bird said, not "all files synced".
    /// A not-current state carries its `stateNote` ("last-known, … ago").
    nonisolated static func cloudDocsRowStatus(
        ownTransfers: [TransferItem], state: BrctlStatus?, stateNote: String?
    ) -> (AppSyncStatus, String) {
        if !ownTransfers.isEmpty {
            let progress = ownTransfers.map(\.progress).reduce(0, +) / Double(ownTransfers.count)
            return (.syncing(progress: progress),
                    "\(ownTransfers.count) file\(ownTransfers.count == 1 ? "" : "s") in transfer")
        }
        let suffix = stateNote.map { " · \($0)" } ?? ""
        guard let state else {
            // Neutral, never `.issue` (a red "Needs attention" on every first
            // launch before the dump lands) and never `.upToDate`.
            return (.unknown, "Sync state unknown")
        }
        if !state.isIdle {
            // Work without a progress figure: `.active`, never `.syncing(0)`,
            // which would drag the overall progress mean to zero.
            return (.active, "Sync engine busy, no file transfers seen" + suffix)
        }
        return (.upToDate, "Sync engine idle" + suffix)
    }


    nonisolated static func deriveIssues(quotaRemaining: Int64?) -> [IssueItem] {
        guard let quota = quotaRemaining, quota < 5_000_000_000 else { return [] }
        return [IssueItem(
            id: "issue-low-quota", severity: .warning,
            title: "iCloud storage is nearly full",
            meta: "Storage · \(Format.capacity(quota)) remaining",
            reason: "Your account is close to its storage limit. Sync of new files may fail until you free space or upgrade your plan.",
            action: .manageStorage, symbolName: "externaldrive.badge.exclamationmark",
            // Account-level: no app owns the quota, so no per-app mute can
            // silence it.
            appID: nil
        )]
    }

    /// The CloudDocs state a snapshot can show, and how current it is.
    nonisolated struct CloudDocsReading: Sendable, Equatable {
        /// Container fields (client/server state, last sync, token) plus the
        /// per-app lines from the last good status read. nil = nothing read.
        var state: BrctlStatus?
        /// Non-nil when `state` is not current: "last-known, brctl dump 4 min
        /// ago" (latest dump refresh failed) or "last-known, brctl status
        /// 12 min ago" (no dump container line to read it from).
        var staleNote: String?
        /// A dump has been parsed at least once (its age), whether or not it
        /// carried a CloudDocs container line.
        var dumpAge: TimeInterval?
        var dumpHasContainer: Bool = false
    }

    /// Container fields from the latest dump when one carried them, else from
    /// the last good `brctl status` (always labelled with its age — it is up
    /// to 5 minutes old by design, more when reads fail). Per-app lines (the
    /// Desktop & Documents flag) only ever come from status, the only place
    /// bird prints them.
    nonisolated static func cloudDocsReading(
        mapped: MappedDump?, dumpAt: Date?, dumpFailure: BrctlReadFailure?,
        statusRead: CloudDocsStatusCache, now: Date
    ) -> CloudDocsReading {
        let dumpAge = dumpAt.map { now.timeIntervalSince($0) }
        var reading = CloudDocsReading(
            dumpAge: mapped == nil ? nil : dumpAge, dumpHasContainer: mapped?.cloudDocsState != nil)
        if var container = mapped?.cloudDocsState {
            container.apps = statusRead.lastGood?.apps ?? []
            reading.state = container
            if dumpFailure != nil, let dumpAge {
                reading.staleNote = "last-known, brctl dump \(ageText(dumpAge))"
            }
        } else if let status = statusRead.lastGood, let at = statusRead.lastGoodAt {
            reading.state = status
            reading.staleNote = "last-known, brctl status \(ageText(now.timeIntervalSince(at)))"
        }
        return reading
    }

    /// "under a minute ago", "12 min ago", "3 h ago".
    nonisolated static func ageText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "under a minute ago"
        case ..<5400: "\(Int(seconds / 60)) min ago"
        default: "\(Int(seconds / 3600)) h ago"
        }
    }

    /// Whether a footprint cache (local sizes, breakdown) must be re-walked:
    /// older than 5 minutes, or walked with a different Desktop & Documents
    /// setting than the one now known (it then misses, or wrongly includes,
    /// ~/Desktop and ~/Documents).
    nonisolated static func footprintCacheIsDue(
        _ cache: (at: Date, includedDesktopDocuments: Bool)?, desktopDocuments: Bool, now: Date
    ) -> Bool {
        guard let cache else { return true }
        return now.timeIntervalSince(cache.at) >= 300 || cache.includedDesktopDocuments != desktopDocuments
    }

    /// Dump refresh pacing: `dumpTTL` while dumps succeed, doubling per
    /// consecutive failure up to 10 minutes — a brctl that keeps timing out
    /// is not hammered every minute.
    nonisolated static func dumpRetryInterval(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 1 else { return dumpTTL }
        return min(600, dumpTTL * pow(2, Double(min(consecutiveFailures - 1, 4))))
    }

    /// Engine card. Never blames a permission it has not checked (C1): a
    /// timeout reads as a timeout, and Full Disk Access is named only when
    /// the probe says it is not granted. A state that is not current says so
    /// with its age, and a failed dump refresh is never hidden behind an
    /// older result (it turns the metadata row amber).
    nonisolated static func engine(
        reading: CloudDocsReading, mapped: MappedDump?, dumpFailure: BrctlReadFailure?,
        fullDiskAccess: PermissionState
    ) -> SyncEngineInfo {
        let missing: String = if reading.dumpAge != nil {
            "Not in brctl dump"           // a dump was read; it had no container line
        } else if dumpFailure != nil {
            "Unavailable"
        } else {
            "Not read yet"
        }
        func label(_ value: String?) -> String {
            guard let value else { return missing }
            return reading.staleNote.map { "\(value) (\($0))" } ?? value
        }
        var engine = SyncEngineInfo(
            serverState: label(reading.state?.serverState),
            clientState: label(reading.state?.clientState),
            lastSyncToken: reading.state?.tokenInfo ?? "—",
            pushBudget: "Not measured",
            pushThrottled: false,
            metadataIndex: "",
            metadataHealthy: false
        )
        guard let mapped else {
            let reason = dumpFailure.map { "brctl dump \($0.summary)" } ?? "Waiting for the first brctl dump"
            engine.metadataIndex = fullDiskAccess == .denied ? "\(reason) — Full Disk Access is not granted" : reason
            return engine
        }
        engine.metadataIndex = reading.dumpHasContainer
            ? "Read via brctl dump"
            : "Read via brctl dump (no CloudDocs container line in it)"
        engine.metadataHealthy = true
        engine = BrctlDumpMapper.enrich(engine, with: mapped.dump)
        if let dumpFailure {
            let age = reading.dumpAge.map { ", shown dump is from \(ageText($0))" } ?? ""
            engine.metadataIndex += " · last-known (latest brctl dump \(dumpFailure.summary)\(age))"
            engine.metadataHealthy = false
        }
        return engine
    }


    @concurrent nonisolated static func fileProviderDomains() async -> [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/CloudStorage")
        do {
            return try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
                .map(\.lastPathComponent)
                .sorted()
        } catch {
            let ns = error as NSError
            logger.warning("CloudStorage enumeration failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return []
        }
    }
}

extension Format {
    /// Nonisolated byte formatting for non-view contexts (Format itself is
    /// MainActor for the view layer).
}
