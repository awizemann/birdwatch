import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "system-source")

/// Phase 1 composite source: assembles the live snapshot from the real system
/// services. Honesty rules apply — data a backend cannot provide is absent or
/// explicitly labeled, never invented (see the product-shape memory note).
///
/// Isolation: the SyncSource requirements are nonisolated(nonsending), so they
/// run on the caller (SyncStore's MainActor). That is fine HERE because this
/// type only orchestrates — every expensive step hops to its owning actor
/// (CloudDocsSource / DaemonStatsSource run brctl and ps on their executors;
/// DriveFolderSource scans on a @concurrent function). Reading
/// UbiquityTransferSource (MainActor) from here is exactly right.
final class SystemSyncSource: SyncSource {
    private let cloudDocs = CloudDocsSource()
    private let daemonStats = DaemonStatsSource()
    private let logSource = LogStreamSource()
    private let bandwidthSource = BandwidthSource()
    @MainActor private var metadata: UbiquityTransferSource?
    @MainActor private var activityLog: ActivityLog?
    // Conflict scan cache: enumerating CloudDocs + NSFileVersion probing is
    // too heavy for every 15s refresh. 5-minute TTL like cachedPermissions.
    @MainActor private var cachedConflicts: (found: [ConflictSource.FoundConflict], at: Date)?
    // Issue ids the user has already resolved this session. A scan that was
    // in flight during the resolve would otherwise resurrect the issue when it
    // lands, so completed scans are filtered against this set before caching.
    @MainActor private var resolvedConflictIDs: Set<String> = []
    // Guarded by MainActor (currentSnapshot always runs on the caller's actor).
    // Cached because the notifications probe races a 1.5s timeout — paying that
    // on every 15s refresh (or on first paint) is wasted latency. 5-minute TTL
    // so a grant made mid-session (e.g. FDA flipped in System Settings) shows
    // up without a relaunch.
    @MainActor private var cachedPermissions: (values: [PermissionStatus], at: Date)?
    @MainActor private var conflictScanInFlight = false
    // Per-app local footprint (allocated bytes). A deep walk over every
    // container is far too heavy for the 15s cycle, so it NEVER runs on the
    // snapshot path: 5-minute TTL, single-flight, results served from cache and
    // folded into the next snapshot's rows.
    @MainActor private var cachedLocalSizes: (values: [String: Int64], at: Date)?
    @MainActor private var sizeScanInFlight = false
    // File-type breakdown of the local footprint (Storage view). Deep walk over
    // every container + Desktop/Documents — same rule as the size pass: 5-minute
    // TTL, single-flight, never on the paint path.
    @MainActor private var cachedBreakdown: (totals: [StorageCategory: Int64], isPartial: Bool, at: Date)?
    @MainActor private var breakdownScanInFlight = false
    // Observed CloudKit apps (from cloudd's unified log). `log show` costs ~2s,
    // so it follows the same rule as the size/conflict scans: 5-minute TTL,
    // single-flight, never on the paint path — rows appear on a later cycle.
    private let cloudKitApps = CloudKitAppSource()
    @MainActor private var cachedCloudKitApps: (values: [AppSyncState], at: Date)?
    @MainActor private var cloudKitScanInFlight = false
    // `brctl dump -i` is a ~2s spawn plus a multi-megabyte parse — far too
    // heavy for the 15s cycle and never allowed to gate paint. Same discipline
    // as the scans above, with a shorter 60s TTL because the retry queue and
    // engine internals it feeds are the diagnostics the user is watching.
    private let dumpSource = BrctlDumpSource()
    @MainActor private var cachedDump: (value: BrctlDump, mapped: MappedDump, at: Date)?
    @MainActor private var dumpScanInFlight = false
    @MainActor private var lastDumpAttempt: Date?
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
        /// base (which comes from brctl status and changes every cycle).
        /// `enrich` itself is O(1) — it reads a handful of scalar fields — so
        /// there is nothing to memoize about it beyond holding the dump.
        var dump: BrctlDump

        init(_ dump: BrctlDump, candidates: [PathCandidate] = [], measureSizes: Bool = false) {
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

    nonisolated init() {}   // cheap by design — no I/O before first snapshot (§6)

    /// Races `operation` against a deadline; nil on timeout. The loser is
    /// cancelled, but a non-cooperative operation may run on in the background —
    /// acceptable for read-only scans.
    nonisolated static func withDeadline<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated static func withTimeout<T: Sendable>(
        seconds: Double, fallback: T, _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withDeadline(seconds: seconds, operation) ?? fallback
    }

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
            let activity = activityLog?.record(transfers) ?? []
            return (transfers, activity)
        }

        async let statusTask = cloudDocs.status()
        async let quotaTask = cloudDocs.quotaRemaining()
        // One ps spawn per cycle, shared by daemon stats and bandwidth (audit:
        // the two independent spawns walked the whole process table twice).
        // Both consumers go through `sampleProcessStats` — the single place
        // that owns that guarantee, and the one a test can pin.
        async let processStatsTask = Self.sampleProcessStats(
            daemonStats: daemonStats, bandwidth: bandwidthSource
        )
        // §6: time-box system scans and return partial results — a cold-metadata
        // CloudDocs enumeration (getattrlistbulk on placeholders) blocked first
        // paint for tens of seconds. Empty now, complete on a later cycle.
        async let foldersTask = Self.withTimeout(seconds: 5, fallback: [DriveFolder]()) {
            await DriveFolderSource.currentFolders(transfers: transfers)
        }
        let (status, quota, processStats, folders) =
            await (statusTask, quotaTask, processStatsTask, foldersTask)
        let (daemons, bandwidth) = processStats
        // Desktop & Documents are only iCloud data when the sync feature is on;
        // brctl status says so. Nothing reads those folders (or earns a TCC
        // prompt) until it does. Starts false; flips as soon as status confirms.
        let desktopDocumentsSynced = Self.desktopDocumentsSynced(status)
        await MainActor.run { metadata?.setIncludesDesktopDocuments(desktopDocumentsSynced) }
        let permissions: [PermissionStatus]
        let cached = await MainActor.run(body: { cachedPermissions })
        if let cached, Date().timeIntervalSince(cached.at) < 300 {
            permissions = cached.values
        } else {
            permissions = await PermissionsProbe.currentPermissions()
            await MainActor.run { cachedPermissions = (permissions, Date()) }
        }

        let conflicts: [ConflictSource.FoundConflict]
        let cachedC = await MainActor.run(body: { cachedConflicts })
        if let cachedC, Date().timeIntervalSince(cachedC.at) < 300 {
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
            let claimed = await MainActor.run { () -> Bool in
                guard !conflictScanInFlight else { return false }
                conflictScanInFlight = true
                return true
            }
            if claimed {
                Task { [weak self] in
                    let scanned = await ConflictSource.findConflicts()
                    guard let self else { return }
                    await MainActor.run {
                        let kept = scanned.filter { !self.resolvedConflictIDs.contains($0.issue.id) }
                        self.cachedConflicts = (kept, Date())
                        self.conflictScanInFlight = false
                    }
                }
            }
        }

        // One capped, shallow container enumeration per cycle, time-boxed like
        // every other system scan (§6). Empty on timeout; complete next cycle.
        let containers = await Self.withTimeout(seconds: 5, fallback: [AppContainerSource.Container]()) {
            await AppContainerSource.currentContainers()
        }
        // Local footprint: served stale-or-empty, refreshed in the background at
        // most every 5 minutes. Sizes land on a later cycle — never gating paint.
        let sizesCache = await MainActor.run(body: { cachedLocalSizes })
        let localSizes = sizesCache?.values ?? [:]
        if sizesCache == nil || Date().timeIntervalSince(sizesCache!.at) >= 300 {
            let claimed = await MainActor.run { () -> Bool in
                guard !sizeScanInFlight else { return false }
                sizeScanInFlight = true
                return true
            }
            if claimed {
                Task { [weak self] in
                    let measured = await AppContainerSource.localSizes(
                        containers: containers, includeDesktopDocuments: desktopDocumentsSynced)
                    guard let self else { return }
                    await MainActor.run {
                        self.cachedLocalSizes = (measured, Date())
                        self.sizeScanInFlight = false
                    }
                }
            }
        }

        // File-type breakdown: identical discipline. Served stale-or-nil, so the
        // Storage view shows its breakdown from a later cycle, never blocking one.
        let breakdownCache = await MainActor.run(body: { cachedBreakdown })
        if breakdownCache == nil || Date().timeIntervalSince(breakdownCache!.at) >= 300 {
            let claimed = await MainActor.run { () -> Bool in
                guard !breakdownScanInFlight else { return false }
                breakdownScanInFlight = true
                return true
            }
            if claimed {
                Task { [weak self] in
                    let measured = await StorageBreakdownSource.currentTotals(
                        includeDesktopDocuments: desktopDocumentsSynced)
                    guard let self else { return }
                    await MainActor.run {
                        self.cachedBreakdown = (measured.totals, measured.isPartial, Date())
                        self.breakdownScanInFlight = false
                    }
                }
            }
        }

        // Observed CloudKit apps: same stale-or-empty, single-flight, 5-minute
        // discipline as the size pass — `log show` is a ~2s spawn and must
        // never gate first paint. Empty on the first cycle; real rows next.
        let ckCache = await MainActor.run(body: { cachedCloudKitApps })
        let observedCloudKit = ckCache?.values ?? []
        if ckCache == nil || Date().timeIntervalSince(ckCache!.at) >= 300 {
            let claimed = await MainActor.run { () -> Bool in
                guard !cloudKitScanInFlight else { return false }
                cloudKitScanInFlight = true
                return true
            }
            if claimed {
                Task { [weak self] in
                    let observed = await self?.cloudKitApps.currentApps() ?? []
                    guard let self else { return }
                    await MainActor.run {
                        self.cachedCloudKitApps = (observed, Date())
                        self.cloudKitScanInFlight = false
                    }
                }
            }
        }

        // brctl dump: stale-or-nil now, refreshed in the background at most
        // once a minute. Retry queue / devices / engine internals appear on a
        // later cycle rather than delaying first paint by ~2s.
        // Read the MAPPED result, not the dump: the mapping (retry queue sort,
        // issue derivation, device rollup, engine enrichment) walks every
        // pending item in a multi-megabyte dump, and doing it here would repay
        // that cost on every 15s snapshot for a dump that changes at most once
        // a minute. It is computed once, in the refresh Task below.
        let mapped = await MainActor.run(body: { cachedDump?.mapped })
        // Gate on the last ATTEMPT, not the last success: a failing brctl
        // (no Full Disk Access, bird wedged) must not be re-spawned every 15s.
        // Single-hop claim: due-check and claim in one MainActor.run so two
        // concurrent snapshots cannot both pass the gate.
        let claimedDump = await MainActor.run { () -> Bool in
            guard !dumpScanInFlight else { return false }
            guard lastDumpAttempt.map({ Date().timeIntervalSince($0) >= Self.dumpTTL }) ?? true else { return false }
            dumpScanInFlight = true
            lastDumpAttempt = Date()
            return true
        }
        if claimedDump {
            Task { [weak self] in
                let fresh = await self?.dumpSource.currentDump()
                guard let self else { return }
                // One capped walk of ~/Library/Mobile Documents per dump
                // refresh, on this same background Task — it is what turns
                // bird's redacted `D{7}s` into a real path we can show.
                let candidates = fresh == nil ? [] : RedactedPathResolver.candidates()
                // Map off the snapshot path, on this Task, before publishing.
                let mapped = fresh.map { MappedDump($0, candidates: candidates, measureSizes: true) }
                await MainActor.run {
                    if let fresh, let mapped {
                        // An item we moved to the Trash must not come back —
                        // neither from a dump collected before the move, nor
                        // from a fresh one bird has not re-scanned yet.
                        let applied = Self.applyingForgotten(self.forgottenRetryIDs, to: mapped)
                        self.forgottenRetryIDs = applied.keptIDs
                        self.cachedDump = (fresh, applied.mapped, Date())
                    }
                    self.dumpScanInFlight = false
                }
            }
        }

        let apps = Self.buildApps(
            status: status,
            transfers: transfers,
            fileProviderDomains: await Self.fileProviderDomains(),
            containers: containers,
            localSizes: localSizes,
            cloudKitApps: observedCloudKit
        )

        return SyncSnapshot(
            apps: apps,
            transfers: transfers,
            driveFolders: folders,
            devices: [],                          // names are permanently redacted by bird
            deviceActivity: mapped?.deviceSummary,
            issues: Self.deriveIssues(quotaRemaining: quota)
                + conflicts.map(\.issue)
                + (mapped?.issues ?? []),
            activity: activity,
            daemons: daemons,
            retryQueue: mapped?.retryQueue ?? [],
            retryQueueTotal: mapped?.retryQueueTotal ?? 0,
            engine: {
                let base = Self.engineInfo(from: status)
                return mapped.map { BrctlDumpMapper.enrich(base, with: $0.dump) } ?? base
            }(),
            permissions: permissions,
            bandwidth: bandwidth,                 // nettop deltas — estimated
            // Local file-type footprint (nil until the background pass lands).
            // The plan cap here is only ever DERIVED — the user's override is
            // applied by SyncStore, which owns the persisted preference.
            storage: breakdownCache.flatMap {
                StorageBreakdownSource.makeStorageInfo(
                    totals: $0.totals, remainingBytes: quota,
                    planCapOverride: nil, isPartial: $0.isPartial
                )
            },
            quotaRemainingBytes: quota,           // brctl quota — remaining only
            notifications: []
        )
    }

    nonisolated func logStream(appID: String) -> AsyncStream<LogLine> {
        let backend: SyncBackend = switch appID {
        case "icloud-drive", "desktop-documents": .cloudDocs
        case "photos", "notes", "messages", "safari": .cloudKit
        default: .fileProvider
        }
        return logSource.stream(predicate: LogStreamSource.predicate(for: backend))
    }

    func conflictDetail(issueID: String) async -> ConflictDetail? {
        await MainActor.run { cachedConflicts?.found.first { $0.issue.id == issueID }?.detail }
    }

    func resolveConflict(issueID: String, keepVersionID: String) async {
        let detail = await MainActor.run { cachedConflicts?.found.first { $0.issue.id == issueID }?.detail }
        guard let fileURL = detail?.fileURL else {
            logger.error("resolveConflict: no cached conflict for issue \(issueID, privacy: .public)")
            return
        }
        if await ConflictSource.resolve(fileURL: fileURL, keepVersionID: keepVersionID) {
            // Drop it from the cache so the next snapshot stops reporting it
            // without waiting out the 5-minute scan TTL, and remember the id so
            // an already-running scan can't put it back.
            await MainActor.run {
                resolvedConflictIDs.insert(issueID)
                cachedConflicts?.found.removeAll { $0.issue.id == issueID }
            }
        }
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

    nonisolated static func buildApps(
        status: BrctlStatus?,
        transfers: [TransferItem],
        fileProviderDomains: [String],
        containers: [AppContainerSource.Container] = [],
        localSizes: [String: Int64] = [:],
        cloudKitApps: [AppSyncState] = []
    ) -> [AppSyncState] {
        var apps: [AppSyncState] = []
        let home = NSHomeDirectory()

        func cloudDocsApp(id: String, name: String, tile: String, location: String) -> AppSyncState {
            let own = transfers.filter { $0.appID == id }
            let syncing = !own.isEmpty
            let progress = syncing ? own.map(\.progress).reduce(0, +) / Double(own.count) : 1
            return AppSyncState(
                id: id, name: name, tileColorHex: tile, backend: .cloudDocs, isApple: true,
                status: syncing ? .syncing(progress: progress) : .upToDate,
                statusLine: syncing
                    ? "\(own.count) file\(own.count == 1 ? "" : "s") in transfer"
                    : (status?.isIdle == false ? "Sync engine active" : "All files synced"),
                lastActivity: status?.lastSync,
                itemsIndexed: 0, pendingItems: own.count,
                localSizeBytes: localSizes[id] ?? 0,     // background size pass; 0 until it lands
                locationPath: location
            )
        }

        apps.append(cloudDocsApp(
            id: "icloud-drive", name: "iCloud Drive", tile: "30b0c7",
            location: "~/Library/Mobile Documents/com~apple~CloudDocs"
        ))
        if status?.apps.contains(where: { $0.name.hasPrefix("Desktop") && $0.isCurrent }) ?? false {
            apps.append(cloudDocsApp(
                id: "desktop-documents", name: "Desktop & Documents", tile: "ffa62b",
                location: "~/Desktop · ~/Documents"
            ))
        }

        // CloudKit services: OBSERVED only (Phase 5D). Rows come from cloudd's
        // unified log — an app that never appears there gets no row, because
        // absence of activity is the honest signal. cloudd still exposes no
        // per-item progress API, so status is always .upToDate with an
        // activity/recency status line, never a fabricated percentage.
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
                itemsIndexed: 0, pendingItems: 0, localSizeBytes: 0,
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

    nonisolated static func deriveIssues(quotaRemaining: Int64?) -> [IssueItem] {
        guard let quota = quotaRemaining, quota < 5_000_000_000 else { return [] }
        return [IssueItem(
            id: "issue-low-quota", severity: .warning,
            title: "iCloud storage is nearly full",
            meta: "Storage · \(Format.sizeNonisolated(quota)) remaining",
            reason: "Your account is close to its storage limit. Sync of new files may fail until you free space or upgrade your plan.",
            action: .manageStorage, symbolName: "externaldrive.badge.exclamationmark",
            // Account-level: no app owns the quota, so no per-app mute can
            // silence it.
            appID: nil
        )]
    }

    nonisolated static func engineInfo(from status: BrctlStatus?) -> SyncEngineInfo {
        SyncEngineInfo(
            serverState: status?.serverState ?? "Unavailable",
            clientState: status?.clientState ?? "Unavailable",
            lastSyncToken: status?.tokenInfo ?? "—",
            pushBudget: "Not measured",
            pushThrottled: false,
            metadataIndex: status != nil ? "Reachable via brctl" : "brctl unavailable — check Full Disk Access",
            metadataHealthy: status != nil
        )
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
    nonisolated static func sizeNonisolated(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
