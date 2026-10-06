import Foundation
import Testing
import os
@testable import Birdwatch

/// Coverage for SystemSyncSource's pure assembly step (audit P2: "untested pure
/// assembly"). Everything here is a `nonisolated static` function over plain
/// values — no brctl, no file system, no metadata query.
@Suite("SystemSyncSource assembly")
struct SystemSyncSourceAssemblyTests {

    private static func transfer(
        id: String, appID: String, name: String = "f", progress: Double
    ) -> TransferItem {
        TransferItem(id: id, appID: appID, name: name, location: "Documents",
                     sizeBytes: 1, direction: .upload, progress: progress)
    }

    private static func status(
        apps: [BrctlAppLine] = [], isIdle: Bool = false
    ) -> BrctlStatus {
        BrctlStatus(clientState: "idle", serverState: "idle", lastSync: nil,
                    isIdle: isIdle, tokenInfo: nil, apps: apps)
    }

    // MARK: - Desktop & Documents presence

    // Fails if the Desktop & Documents tile is ever shown unconditionally (or
    // for a domain brctl reports as NOT current) — the honesty rule is that we
    // only claim the feature is on when brctl says `current=YES`.
    @Test("Desktop & Documents appears only when brctl reports a current Desktop app line")
    func desktopDocumentsPresence() {
        let present = SystemSyncSource.buildApps(
            status: Self.status(apps: [BrctlAppLine(name: "Desktop & Documents", isCurrent: true)]),
            transfers: [], fileProviderDomains: []
        )
        #expect(present.contains { $0.id == "desktop-documents" })

        let notCurrent = SystemSyncSource.buildApps(
            status: Self.status(apps: [BrctlAppLine(name: "Desktop & Documents", isCurrent: false)]),
            transfers: [], fileProviderDomains: []
        )
        #expect(!notCurrent.contains { $0.id == "desktop-documents" })

        let noStatus = SystemSyncSource.buildApps(status: nil, transfers: [], fileProviderDomains: [])
        #expect(!noStatus.contains { $0.id == "desktop-documents" })
        #expect(noStatus.contains { $0.id == "icloud-drive" }, "iCloud Drive is unconditional")
    }

    // MARK: - CloudDocs progress / status line

    // Fails on a regression in the mean-progress math (e.g. summing without
    // dividing, or counting transfers that belong to another app) and on the
    // singular/plural of the status line.
    @Test("CloudDocs progress is the mean of that app's transfers; count drives the status line")
    func cloudDocsProgressAndCount() throws {
        let apps = SystemSyncSource.buildApps(
            status: Self.status(),
            transfers: [
                Self.transfer(id: "a", appID: "icloud-drive", progress: 0.2),
                Self.transfer(id: "b", appID: "icloud-drive", progress: 0.6),
                Self.transfer(id: "c", appID: "photos", progress: 0.9),   // other app: ignored
            ],
            fileProviderDomains: []
        )
        let drive = try #require(apps.first { $0.id == "icloud-drive" })
        guard case .syncing(let progress) = drive.status else {
            Issue.record("expected .syncing, got \(drive.status)")
            return
        }
        #expect(abs(progress - 0.4) < 1e-9, "mean of 0.2 and 0.6")
        #expect(drive.statusLine == "2 files in transfer")
        #expect(drive.pendingItems == 2)
    }

    @Test("A single transfer says \"1 file in transfer\" (singular)")
    func singularTransferLine() throws {
        let apps = SystemSyncSource.buildApps(
            status: Self.status(),
            transfers: [Self.transfer(id: "a", appID: "icloud-drive", progress: 0.5)],
            fileProviderDomains: []
        )
        let drive = try #require(apps.first { $0.id == "icloud-drive" })
        #expect(drive.statusLine == "1 file in transfer")
        #expect(drive.pendingItems == 1)
    }

    // C1: the old code said "Up to date · Sync engine active" while bird was
    // busy and "All files synced" with no evidence at all (nil state).
    @Test("With no transfers, the row says what bird reported — never 'synced' without evidence")
    func idleStatusLine() {
        let busy = SystemSyncSource.buildApps(
            status: Self.status(isIdle: false), transfers: [], fileProviderDomains: []
        )
        let busyDrive = busy.first { $0.id == "icloud-drive" }
        #expect(busyDrive?.statusLine == "Sync engine busy, no file transfers seen")
        #expect(busyDrive?.status != .upToDate, "a busy engine is not up to date")

        let idle = SystemSyncSource.buildApps(
            status: Self.status(isIdle: true), transfers: [], fileProviderDomains: []
        )
        #expect(idle.first { $0.id == "icloud-drive" }?.statusLine == "Sync engine idle")
        #expect(idle.first { $0.id == "icloud-drive" }?.status == .upToDate)

        let unknown = SystemSyncSource.buildApps(status: nil, transfers: [], fileProviderDomains: [])
        #expect(unknown.first { $0.id == "icloud-drive" }?.statusLine == "Sync state unknown")
        #expect(unknown.first { $0.id == "icloud-drive" }?.status != .upToDate)

        let stale = SystemSyncSource.buildApps(
            status: Self.status(isIdle: true), transfers: [], fileProviderDomains: [],
            stateNote: "last-known, brctl status 12 min ago"
        )
        #expect(stale.first { $0.id == "icloud-drive" }?.statusLine
                == "Sync engine idle · last-known, brctl status 12 min ago")
    }

    // MARK: - File Provider domains

    // Fails if the id stops being lowercased (ids must be stable/comparable) or
    // if the display name stops being the pre-hyphen vendor segment.
    @Test("File Provider domain maps to a lowercased id and a hyphen-stripped display name")
    func fileProviderDomainMapping() throws {
        let apps = SystemSyncSource.buildApps(
            status: Self.status(), transfers: [], fileProviderDomains: ["GoogleDrive-x"]
        )
        let fp = try #require(apps.first { $0.backend == .fileProvider })
        #expect(fp.id == "fp-googledrive-x")
        #expect(fp.name == "GoogleDrive")
        #expect(fp.statusLine == "File Provider domain active")
    }

    // MARK: - CloudKit apps

    // Fails if a CloudKit app ever gains an invented progress number — cloudd
    // exposes no per-app API, so these stay activity-and-recency only. Since
    // Phase 5D the rows are OBSERVED (from cloudd's log): none are passed in
    // here, so none may appear.
    @Test("CloudKit apps are observed-only and never given progress")
    func cloudKitAppsAreObservedOnly() {
        let observed = CloudKitAppMapping.makeApp(
            activity: CloudKitAppActivity(
                bundleID: "com.apple.Photos", containers: ["com.apple.photos.cloud"],
                lastActivity: Date(), state: .idle, operationCount: 3
            ),
            bundleID: "com.apple.Photos", displayName: "Photos", now: Date()
        )
        for status in [Self.status(isIdle: true), Self.status(isIdle: false)] {
            let none = SystemSyncSource.buildApps(
                status: status,
                transfers: [Self.transfer(id: "x", appID: "photos", progress: 0.3)],
                fileProviderDomains: []
            )
            #expect(none.filter { $0.backend == .cloudKit }.isEmpty,
                    "no observation means no row — the hardcoded list was fabricated")

            let apps = SystemSyncSource.buildApps(
                status: status,
                transfers: [Self.transfer(id: "x", appID: "photos", progress: 0.3)],
                fileProviderDomains: [],
                cloudKitApps: [observed]
            )
            let ck = apps.filter { $0.backend == .cloudKit }
            #expect(ck.map(\.id) == ["photos"])
            for app in ck {
                #expect(app.status == .upToDate)
                // nil = cloudd reports no pending count (not a placeholder 0).
                #expect(app.pendingItems == nil, "a stray transfer must not leak into a CloudKit tile")
            }
        }
    }

    // MARK: - deriveIssues

    // Boundary test: fails if the comparison flips to `<=` / `>=` or the
    // threshold drifts, and if the quota issue is ever attributed to an app
    // (which would let a per-app mute silence an account-level warning).
    @Test("Low-quota issue fires strictly below 5 GB and is account-level (appID nil)")
    func deriveIssuesBoundary() throws {
        #expect(SystemSyncSource.deriveIssues(quotaRemaining: 5_000_000_000).isEmpty,
                "exactly 5 GB is not yet 'nearly full'")
        #expect(SystemSyncSource.deriveIssues(quotaRemaining: nil).isEmpty,
                "unknown quota is never an issue — honesty over guessing")

        let issues = SystemSyncSource.deriveIssues(quotaRemaining: 4_999_999_999)
        #expect(issues.count == 1)
        let issue = try #require(issues.first)
        #expect(issue.id == "issue-low-quota")
        #expect(issue.severity == .warning)
        #expect(issue.meta.contains("5.0 GB"))
        #expect(issue.appID == nil)
    }

    // MARK: - Resolved-conflict suppression

    // The old set was never pruned: once a file's conflict was resolved, a NEW
    // conflict on that file (same path → same id) stayed hidden until relaunch.
    @Test("A resolve before the scan started never hides that scan's listing; one during the scan does, once")
    func resolvedConflictPruning() {
        // Resolved before this scan began: the scan saw the file afterwards,
        // so a listing is a new conflict and must show.
        #expect(SystemSyncSource.stillSuppressedConflictIDs(
            resolved: ["conflict-a"], resolvedBeforeScan: ["conflict-a"], listedByScan: ["conflict-a"]
        ).isEmpty)
        // Resolved while the scan ran and still listed: the listing may predate
        // the resolve, so it stays hidden — for this scan only.
        #expect(SystemSyncSource.stillSuppressedConflictIDs(
            resolved: ["conflict-b"], resolvedBeforeScan: [], listedByScan: ["conflict-b"]
        ) == ["conflict-b"])
        // The next scan started after that resolve, so it is authoritative.
        #expect(SystemSyncSource.stillSuppressedConflictIDs(
            resolved: ["conflict-b"], resolvedBeforeScan: ["conflict-b"], listedByScan: ["conflict-b"]
        ).isEmpty)
        // Not listed: nothing to hide, nothing to remember.
        #expect(SystemSyncSource.stillSuppressedConflictIDs(
            resolved: ["conflict-c"], resolvedBeforeScan: [], listedByScan: []
        ).isEmpty)
    }

    // The wiring around that rule: the claim must capture the resolved set AT
    // CLAIM TIME, and completion must use the captured set, not the live one.
    // Drives the real claim/complete/mark methods; no scan, no file system
    // (constructing SystemSyncSource does no I/O).
    @Test("The scan claim captures resolves made before it; completion hides only those made during it")
    func resolvedBeforeScanWiring() async {
        func found(_ id: String) -> ConflictSource.FoundConflict {
            ConflictSource.FoundConflict(
                issue: TestIssues.make(id: id, action: .reviewVersions, severity: .conflict),
                detail: ConflictDetail(fileName: id, location: "", versions: [])
            )
        }
        let source = SystemSyncSource()
        let t0 = Date()

        source.markConflictResolved("conflict-before")
        let captured = source.claimConflictScan(now: t0)
        #expect(captured == ["conflict-before"])
        #expect(source.claimConflictScan(now: t0) == nil, "single-flight: a second claim is refused")
        source.markConflictResolved("conflict-during")    // resolved while the scan runs
        source.completeConflictScan([found("conflict-before"), found("conflict-during")],
                                    resolvedBeforeScan: captured ?? [])

        #expect(await source.conflictDetail(issueID: "conflict-before") != nil,
                "resolved before the scan began: its listing is a new conflict and shows")
        #expect(await source.conflictDetail(issueID: "conflict-during") == nil,
                "resolved during the scan: the listing may be stale, so it stays hidden")

        // The next scan began after that resolve, so it is authoritative.
        let next = source.claimConflictScan(now: t0 + SystemSyncSource.conflictRetryInterval)
        source.completeConflictScan([found("conflict-during")], resolvedBeforeScan: next ?? [])
        #expect(await source.conflictDetail(issueID: "conflict-during") != nil)
    }

    // A scan that could not look (nil) is not "no conflicts": it must not
    // replace the cache, or it would count as the producer's first delivery.
    @Test("A failed conflict scan keeps the previous cache and frees the claim")
    func failedScanKeepsCache() async {
        let source = SystemSyncSource()
        let t0 = Date()
        let retry = SystemSyncSource.conflictRetryInterval
        let first = source.claimConflictScan(now: t0)
        source.completeConflictScan([ConflictSource.FoundConflict(
            issue: TestIssues.make(id: "conflict-a", action: .reviewVersions, severity: .conflict),
            detail: ConflictDetail(fileName: "a", location: "", versions: [])
        )], resolvedBeforeScan: first ?? [])
        let second = source.claimConflictScan(now: t0 + retry)
        source.completeConflictScan(nil, resolvedBeforeScan: second ?? [])
        #expect(await source.conflictDetail(issueID: "conflict-a") != nil)
        #expect(source.claimConflictScan(now: t0 + 2 * retry) != nil, "a failed scan still releases single-flight")
    }

    // A failing scan used to be re-walked on every 15s snapshot: the claim
    // never looked at when the last attempt was.
    @Test("A failed scan is not retried before the retry interval")
    func failedScanBacksOff() {
        let source = SystemSyncSource()
        let t0 = Date()
        let retry = SystemSyncSource.conflictRetryInterval
        let claimed = source.claimConflictScan(now: t0)
        #expect(claimed != nil)
        source.completeConflictScan(nil, resolvedBeforeScan: claimed ?? [])
        #expect(source.claimConflictScan(now: t0 + 15) == nil, "the next 15s snapshot must not rescan")
        #expect(source.claimConflictScan(now: t0 + retry - 1) == nil)
        #expect(source.claimConflictScan(now: t0 + retry) != nil)
    }

    // After one good scan, failing rescans used to serve that list forever as
    // if it were current (C1). It is dropped once older than the bound.
    @Test("A good conflict list stops being served once it is older than the staleness bound")
    func staleConflictListAgesOut() async {
        let source = SystemSyncSource()
        let scanned = Date()
        let claimed = source.claimConflictScan(now: scanned)
        source.completeConflictScan([ConflictSource.FoundConflict(
            issue: TestIssues.make(id: "conflict-a", action: .reviewVersions, severity: .conflict),
            detail: ConflictDetail(fileName: "a", location: "", versions: [])
        )], resolvedBeforeScan: claimed ?? [], now: scanned)

        let bound = SystemSyncSource.conflictMaxStaleness
        #expect(source.usableConflictCache(now: scanned + bound - 1) != nil, "inside the bound it is still served")
        #expect(source.usableConflictCache(now: scanned + bound) == nil, "past it, it is gone — not shown as current")
        #expect(await source.conflictDetail(issueID: "conflict-a") == nil, "every reader sees the drop")
    }

    // MARK: - Engine card

    private static let idleState = BrctlStatus(
        clientState: "idle", serverState: "up", lastSync: nil, isIdle: true, tokenInfo: "tok-42", apps: [])

    private static func reading(
        mapped: SystemSyncSource.MappedDump? = nil, dumpAge: TimeInterval? = nil,
        failure: BrctlReadFailure? = nil, status: CloudDocsStatusCache = CloudDocsStatusCache()
    ) -> SystemSyncSource.CloudDocsReading {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        return SystemSyncSource.cloudDocsReading(
            mapped: mapped, dumpAt: dumpAge.map { now - $0 }, dumpFailure: failure, statusRead: status, now: now)
    }

    // Fails if a missing CloudDocs state is ever rendered as a healthy engine,
    // or if a timeout is ever blamed on Full Disk Access (the old text said
    // "check Full Disk Access" for every failure, including timeouts — C1).
    @Test("Engine with nothing read says why, and names FDA only when it is denied")
    func engineNothingRead() {
        let waiting = SystemSyncSource.engine(reading: Self.reading(), mapped: nil, dumpFailure: nil, fullDiskAccess: .unknown)
        #expect(waiting.serverState == "Not read yet")
        #expect(waiting.clientState == "Not read yet")
        #expect(waiting.lastSyncToken == "—")
        #expect(waiting.metadataIndex == "Waiting for the first brctl dump")
        #expect(waiting.metadataHealthy == false)
        #expect(waiting.pushBudget == "Not measured")

        let timedOut = SystemSyncSource.engine(
            reading: Self.reading(failure: .timedOut(seconds: 15)), mapped: nil,
            dumpFailure: .timedOut(seconds: 15), fullDiskAccess: .granted)
        #expect(timedOut.serverState == "Unavailable")
        #expect(timedOut.metadataIndex == "brctl dump timed out after 15 s")

        let denied = SystemSyncSource.engine(
            reading: Self.reading(failure: .failed("exited with status 1")), mapped: nil,
            dumpFailure: .failed("exited with status 1"), fullDiskAccess: .denied)
        #expect(denied.metadataIndex == "brctl dump exited with status 1 — Full Disk Access is not granted")
    }

    // The review's case: status was the only source and the dump failed —
    // the old engine said "Reachable via brctl", healthy, with no age.
    @Test("Status-only state is labelled last-known with its age, and the dump failure stays visible")
    func engineStatusOnlyAfterDumpFailure() {
        var cache = CloudDocsStatusCache()
        cache.record(.success(Self.idleState), at: Date(timeIntervalSinceReferenceDate: 10_000 - 720))
        let reading = Self.reading(failure: .timedOut(seconds: 15), status: cache)
        let engine = SystemSyncSource.engine(
            reading: reading, mapped: nil, dumpFailure: .timedOut(seconds: 15), fullDiskAccess: .granted)
        #expect(engine.clientState == "idle (last-known, brctl status 12 min ago)")
        #expect(engine.serverState == "up (last-known, brctl status 12 min ago)")
        #expect(engine.metadataIndex == "brctl dump timed out after 15 s")
        #expect(!engine.metadataHealthy)
    }

    @Test("A failed dump refresh labels the still-shown older dump as last-known, with its age")
    func engineLastKnownDump() {
        let mapped = SystemSyncSource.MappedDump(BrctlDump(), cloudDocsState: Self.idleState)
        let fresh = SystemSyncSource.engine(
            reading: Self.reading(mapped: mapped, dumpAge: 30), mapped: mapped, dumpFailure: nil, fullDiskAccess: .granted)
        #expect(fresh.metadataIndex == "Read via brctl dump")
        #expect(fresh.clientState == "idle")
        #expect(fresh.metadataHealthy)

        let stale = SystemSyncSource.engine(
            reading: Self.reading(mapped: mapped, dumpAge: 240, failure: .timedOut(seconds: 15)),
            mapped: mapped, dumpFailure: .timedOut(seconds: 15), fullDiskAccess: .granted)
        #expect(stale.clientState == "idle (last-known, brctl dump 4 min ago)")
        #expect(stale.metadataIndex
                == "Read via brctl dump · last-known (latest brctl dump timed out after 15 s, shown dump is from 4 min ago)")
        #expect(!stale.metadataHealthy)
    }

    // Item 9: a dump that parsed but carried no `{client:` line is not
    // "waiting for the first dump".
    @Test("A dump without a container line is distinguished from no dump at all")
    func engineDumpWithoutContainer() {
        let mapped = SystemSyncSource.MappedDump(BrctlDump())
        let engine = SystemSyncSource.engine(
            reading: Self.reading(mapped: mapped, dumpAge: 10), mapped: mapped, dumpFailure: nil, fullDiskAccess: .granted)
        #expect(engine.clientState == "Not in brctl dump")
        #expect(engine.serverState == "Not in brctl dump")
        #expect(engine.metadataIndex == "Read via brctl dump (no CloudDocs container line in it)")
    }

    @Test("A runner timeout maps to .timedOut with the timeout it was given")
    func readFailureMapping() {
        #expect(BrctlReadFailure(RunnerError.timeout, timeout: .seconds(45)) == .timedOut(seconds: 45))
        #expect(BrctlReadFailure(RunnerError.nonZeroExit(code: 2, stderr: "x"), timeout: .seconds(1))
                == .failed("exited with status 2"))
        #expect(BrctlReadFailure.timedOut(seconds: 45).summary == "timed out after 45 s")
    }

    @Test("Dump refresh backs off on consecutive failures, capped at 10 minutes")
    func dumpBackoff() {
        #expect(SystemSyncSource.dumpRetryInterval(consecutiveFailures: 0) == 60)
        #expect(SystemSyncSource.dumpRetryInterval(consecutiveFailures: 1) == 60)
        #expect(SystemSyncSource.dumpRetryInterval(consecutiveFailures: 2) == 120)
        #expect(SystemSyncSource.dumpRetryInterval(consecutiveFailures: 3) == 240)
        #expect(SystemSyncSource.dumpRetryInterval(consecutiveFailures: 5) == 600)
        #expect(SystemSyncSource.dumpRetryInterval(consecutiveFailures: 50) == 600)
    }

    // MARK: - Desktop & Documents (tri-state)

    private static let desktopOn = BrctlStatus(
        clientState: "idle", serverState: "old", lastSync: nil, isIdle: true, tokenInfo: nil,
        apps: [BrctlAppLine(name: "Desktop & Documents", isCurrent: true)])

    @Test("Desktop & Documents is unknown — not off — until brctl status answers, and the iCloud Drive row says so")
    func desktopDocumentsUnknown() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var cache = CloudDocsStatusCache()
        guard case .unknown(let notYet) = cache.desktopDocuments(now: t0) else {
            Issue.record("expected unknown before any read"); return
        }
        #expect(notYet.hasPrefix("not read yet"))
        #expect(!cache.desktopDocumentsSynced, "unknown never touches ~/Desktop or ~/Documents")

        cache.markAttempt(at: t0)
        cache.record(.failure(.timedOut(seconds: 45)), at: t0 + 45)
        guard case .unknown(let failed) = cache.desktopDocuments(now: t0 + 60) else {
            Issue.record("a failed first read is still unknown"); return
        }
        #expect(failed.contains("timed out after 45 s"))

        let apps = SystemSyncSource.buildApps(
            status: nil, transfers: [], fileProviderDomains: [], desktopDocuments: cache.desktopDocuments(now: t0 + 60))
        let drive = try #require(apps.first { $0.id == "icloud-drive" })
        #expect(drive.infoCallout == "Desktop & Documents sync: \(failed).")
        #expect(!apps.contains { $0.id == "desktop-documents" })
    }

    // The flapping bug: every timed-out status read turned the flag off, hid
    // the row and re-armed the FSEvents watcher. A failure must keep it — and
    // the row's STATUS LINE (list, popover) must say it is last-known.
    @Test("A failed status read keeps the last-known flag, on the row's status line too")
    func statusCacheKeepsLastKnown() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var cache = CloudDocsStatusCache()
        #expect(cache.isDue(now: t0))
        cache.markAttempt(at: t0)
        cache.record(.success(Self.desktopOn), at: t0)
        #expect(cache.desktopDocuments(now: t0) == .on(lastKnown: nil))
        #expect(cache.desktopDocumentsSynced)
        #expect(!cache.isDue(now: t0 + 299))
        #expect(cache.isDue(now: t0 + 300))

        cache.markAttempt(at: t0 + 300)
        cache.record(.failure(.timedOut(seconds: 45)), at: t0 + 345)
        #expect(cache.desktopDocumentsSynced, "a timeout is not 'feature off'")
        guard case .on(let note?) = cache.desktopDocuments(now: t0 + 600) else {
            Issue.record("expected a last-known ON"); return
        }
        #expect(note.contains("Last-known"))
        #expect(note.contains("10 min ago"))
        #expect(note.contains("timed out after 45 s"))

        let apps = SystemSyncSource.buildApps(
            status: Self.desktopOn, transfers: [], fileProviderDomains: [],
            desktopDocuments: cache.desktopDocuments(now: t0 + 600))
        let row = try #require(apps.first { $0.id == "desktop-documents" })
        #expect(row.infoCallout == note)
        #expect(row.statusLine == "Sync engine idle · last-known setting")
    }

    @Test("Container state comes from the dump; per-app lines only from status; status alone is aged")
    func cloudDocsReadingMerge() throws {
        var cache = CloudDocsStatusCache()
        #expect(Self.reading(status: cache).state == nil)

        let fromDump = BrctlStatus(clientState: "busy", serverState: "new", lastSync: nil, isIdle: false, tokenInfo: "t", apps: [])
        let dumpOnly = Self.reading(mapped: .init(BrctlDump(), cloudDocsState: fromDump), dumpAge: 20, status: cache)
        #expect(dumpOnly.state?.clientState == "busy")
        #expect(dumpOnly.staleNote == nil)
        #expect(!SystemSyncSource.desktopDocumentsSynced(dumpOnly.state))

        cache.record(.success(Self.desktopOn), at: Date(timeIntervalSinceReferenceDate: 10_000 - 120))
        let merged = Self.reading(mapped: .init(BrctlDump(), cloudDocsState: fromDump), dumpAge: 20, status: cache)
        #expect(merged.state?.serverState == "new", "the dump (≤60 s old) wins over an older status read")
        #expect(SystemSyncSource.desktopDocumentsSynced(merged.state))

        let statusOnly = Self.reading(status: cache)
        #expect(statusOnly.state?.serverState == "old")
        #expect(statusOnly.staleNote == "last-known, brctl status 2 min ago")
    }

    // MARK: - Footprint caches vs the Desktop & Documents flag

    @Test("Footprint caches are re-walked when the Desktop & Documents flag differs from the walk's")
    func footprintCacheFollowsFlag() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(SystemSyncSource.footprintCacheIsDue(nil, desktopDocuments: false, now: t0))
        #expect(!SystemSyncSource.footprintCacheIsDue((t0, false), desktopDocuments: false, now: t0 + 10))
        #expect(SystemSyncSource.footprintCacheIsDue((t0, false), desktopDocuments: true, now: t0 + 10),
                "walked before the flag was known: stale at once, not after 5 minutes")
        #expect(SystemSyncSource.footprintCacheIsDue((t0, true), desktopDocuments: true, now: t0 + 300))
    }
}

// MARK: - brctl refresh ordering (injected runner)

/// Records every brctl spawn and how many overlap. The dump writes a small
/// real-shaped dump to its `-o` path; status answers or times out.
private nonisolated final class RecordingBrctlRunner: ProcessRunning {
    struct State {
        var events: [String] = []
        var inFlight = 0
        var maxInFlight = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let statusTimesOut: Bool

    init(statusTimesOut: Bool = false) { self.statusTimesOut = statusTimesOut }

    static let dump = """
        1 containers matching '*'
        -----------------------------------------------------
        - <c{1}m.a{3}e.C{7}s[1] foreground {client:idle server:full-sync last-sync:2026-10-05 20:20:52.446, token:unkown-token-size:36 (AAAA)}>
        """

    func run(toolPath: String, arguments: [String], timeout: Duration) async throws -> String {
        let kind = arguments.first ?? "?"
        state.withLock {
            $0.events.append("start \(kind)")
            $0.inFlight += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
        }
        // Give any other spawn the chance to start while this one is "running".
        await Task.yield()
        defer { state.withLock { $0.events.append("end \(kind)"); $0.inFlight -= 1 } }
        switch kind {
        case "dump":
            if let flag = arguments.firstIndex(of: "-o"), flag + 1 < arguments.count {
                try Self.dump.write(toFile: arguments[flag + 1], atomically: true, encoding: .utf8)
            }
            return ""
        case "status":
            if statusTimesOut { throw RunnerError.timeout }
            return "Desktop & Documents: current=YES lastEnabled=(never) lastDisabled=(never)\n"
        default:
            return ""
        }
    }

    var events: [String] { state.withLock { $0.events } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
}

@Suite("brctl background refresh")
struct BrctlRefreshOrderingTests {

    // bird serves one brctl request at a time; a status overlapping the dump
    // made the dump time out. Status must start only after the dump ENDED,
    // and a second claim while the refresh runs must be refused.
    @Test("Status never starts while the dump is in flight, and runs after it")
    func statusRunsAfterDump() async {
        let runner = RecordingBrctlRunner()
        let source = SystemSyncSource(brctlRunner: runner, pathCandidates: { [] })
        let now = Date()
        #expect(await source.claimDumpRefresh(now: now))
        #expect(await !source.claimDumpRefresh(now: now + 3600), "single flight while the refresh runs")
        await source.performDumpRefresh()

        #expect(runner.events == ["start dump", "end dump", "start status", "end status"])
        #expect(runner.maxInFlight == 1)
        let flag = source.statusCacheForTesting.desktopDocuments(now: Date())
        #expect(flag == .on(lastKnown: nil))
    }

    // A timed-out status keeps bird busy for its remaining 15–28 s; the next
    // dump must not be claimed straight away (it would queue and time out).
    @Test("A failed status read restarts the dump clock before the refresh ends")
    func statusFailureDefersNextDump() async {
        let runner = RecordingBrctlRunner(statusTimesOut: true)
        let source = SystemSyncSource(brctlRunner: runner, pathCandidates: { [] })
        // Claimed "long ago": without the re-stamp, a claim right after the
        // refresh would pass the 60 s gate.
        #expect(await source.claimDumpRefresh(now: Date() - 600))
        await source.performDumpRefresh()
        #expect(runner.events.last == "end status")
        #expect(await !source.claimDumpRefresh(now: Date() + 1))
        #expect(await source.claimDumpRefresh(now: Date() + 61))
    }
}
