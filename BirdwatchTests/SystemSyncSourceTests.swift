import Foundation
import Testing
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

    // Fails if the idle branch ever collapses to a single string — "Sync engine
    // active" is the honest line when brctl says the engine is busy but the
    // metadata query has no file-level transfers to show.
    @Test("With no transfers, the status line follows brctl's idle flag")
    func idleStatusLine() {
        let busy = SystemSyncSource.buildApps(
            status: Self.status(isIdle: false), transfers: [], fileProviderDomains: []
        )
        #expect(busy.first { $0.id == "icloud-drive" }?.statusLine == "Sync engine active")
        #expect(busy.first { $0.id == "icloud-drive" }?.status == .upToDate)

        let idle = SystemSyncSource.buildApps(
            status: Self.status(isIdle: true), transfers: [], fileProviderDomains: []
        )
        #expect(idle.first { $0.id == "icloud-drive" }?.statusLine == "All files synced")

        let unknown = SystemSyncSource.buildApps(status: nil, transfers: [], fileProviderDomains: [])
        #expect(unknown.first { $0.id == "icloud-drive" }?.statusLine == "All files synced",
                "no brctl status is not evidence of an active engine")
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
    @Test("CloudKit apps are observed-only, always up-to-date, never given progress")
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
                #expect(app.pendingItems == 0, "a stray transfer must not leak into a CloudKit tile")
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

    // MARK: - engineInfo

    // Fails if a missing brctl status is ever rendered as a healthy engine —
    // the whole point is telling the user Full Disk Access is the problem.
    @Test("engineInfo with no brctl status reports unavailable and unhealthy metadata")
    func engineInfoUnavailable() {
        let info = SystemSyncSource.engineInfo(from: nil)
        #expect(info.serverState == "Unavailable")
        #expect(info.clientState == "Unavailable")
        #expect(info.lastSyncToken == "—")
        #expect(info.metadataIndex == "brctl unavailable — check Full Disk Access")
        #expect(info.metadataHealthy == false)
        #expect(info.pushThrottled == false)
        #expect(info.pushBudget == "Not measured")
    }

    @Test("engineInfo maps every brctl field through unchanged")
    func engineInfoMapped() {
        let info = SystemSyncSource.engineInfo(from: BrctlStatus(
            clientState: "idle", serverState: "up", lastSync: Date(timeIntervalSinceReferenceDate: 0),
            isIdle: true, tokenInfo: "tok-42", apps: []
        ))
        #expect(info.serverState == "up")
        #expect(info.clientState == "idle")
        #expect(info.lastSyncToken == "tok-42")
        #expect(info.metadataIndex == "Reachable via brctl")
        #expect(info.metadataHealthy)
        #expect(info.pushBudget == "Not measured", "push budget is not measurable — never invented")
    }
}
