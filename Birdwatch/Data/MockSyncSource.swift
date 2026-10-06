import Foundation

/// Fixture source for `--mock` (demos, screenshots, deterministic QA) and the
/// app's test host. It shows only states the real backends can produce —
/// see the fixture notes below.
/// A struct, not an actor: everything here is immutable Sendable fixture data,
/// so there is no state to protect (real Phase 1 sources own Process handles
/// and WILL be actors — see the SyncSource execution-context note).
struct MockSyncSource: SyncSource {
    /// When this source (so the `--mock` app) started. The bandwidth chart is
    /// "since Birdwatch started", so hours before this — and hours still to
    /// come — are never drawn as data.
    let launchedAt: Date

    nonisolated init(launchedAt: Date = Date()) { self.launchedAt = launchedAt }

    nonisolated func currentSnapshot() async -> SyncSnapshot {
        Self.snapshot(now: Date(), launchedAt: launchedAt)
    }

    nonisolated func conflictDetail(issueID: String) async -> ConflictDetail? {
        guard issueID == "issue-conflict" else { return nil }
        let now = Date()
        return ConflictDetail(
            fileName: "Q3 Report.pages",
            location: DriveFolder.cloudDocsLocation + "/Presentations",
            versions: [
                ConflictVersion(
                    id: "v-mac", deviceName: "MacBook Pro", tileColorHex: "0a84ff",
                    modified: now.addingTimeInterval(-1_560), sizeBytes: 4_620_000,
                    changeNote: "Added the revenue summary section and updated two charts."
                ),
                ConflictVersion(
                    id: "v-iphone", deviceName: "iPhone 15 Pro", tileColorHex: "af52de",
                    modified: now.addingTimeInterval(-1_140), sizeBytes: 4_580_000,
                    changeNote: "Fixed typos in the introduction on the way to a meeting."
                ),
            ]
        )
    }

    nonisolated func logStream(appID: String, backend: SyncBackend) -> AsyncThrowingStream<LogLine, any Error> {
        // bufferingNewest: the console shows 25 lines; never buffer unboundedly
        // while the consumer is busy. The real `log stream` wrapper keeps this.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(ProcessRunner.streamBufferLimit)) { continuation in
            let task = Task {
                let seeds = Self.seedLogLines(appID: appID)
                for line in seeds.reversed() { continuation.yield(line) }
                var index = seeds.count
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.6))
                    continuation.yield(Self.nextLogLine(appID: appID, index: index))
                    index += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Fixture data
    //
    // Every value below is something a real backend can produce, built where
    // possible by the SAME pure builders the live source uses
    // (SystemSyncSource.buildApps, CloudKitAppMapping.makeApp,
    // AppContainerSource, DriveFolderSource, StorageBreakdownSource,
    // SystemSyncSource.deriveIssues), so --mock exercises the honest states:
    //   - Photos: CloudKit `.active`, no progress of any kind;
    //   - iCloud Drive: CloudDocs transfers with no percentage (boolean channel);
    //   - Desktop & Documents: on, but not watched without a confirmed Full
    //     Disk Access grant (the probe answered "unknown");
    //   - 1Password / Bear: File Provider rows Birdwatch reads nothing for
    //     (`.unknown`);
    //   - Obsidian: a per-app container row, idle = "no activity seen";
    //   - a CloudKit scan that fell back to the 10-minute window and was
    //     truncated, read 2 minutes ago;
    //   - a derived (estimated) 200 GB plan cap from bird's remaining quota,
    //     low enough to raise the real low-quota issue;
    //   - bandwidth hours before launch that were never sampled;
    //   - the engine card and bird's state, both read from one dump excerpt
    //     shaped like the captured fixtures (`dumpText`).
    // Not produced by any backend, so not here: per-app percentages for
    // CloudKit / File Provider, paused or errored app rows, device names
    // (bird redacts them), a "metered network" issue.

    /// `launchedAt` defaults to seven hours before `now` for callers (tests,
    /// previews) that have no launch of their own.
    nonisolated static func snapshot(now: Date, launchedAt: Date? = nil) -> SyncSnapshot {
        let transfers = transfers
        return SyncSnapshot(
            apps: apps(now: now, transfers: transfers),
            transfers: transfers,
            driveFolders: driveFolders(transfers: transfers),
            devices: [],                       // names are permanently redacted by bird
            deviceActivity: deviceActivity(now: now),
            issues: issues,
            activity: activity(now: now),
            daemons: daemons,
            retryQueue: retryQueue,
            engine: engine(now: now),
            permissions: permissions,
            bandwidth: bandwidth(now: now, launchedAt: launchedAt ?? now.addingTimeInterval(-7 * 3_600)),
            storage: storage,
            quotaRemainingBytes: quotaRemaining,
            notifications: notifications(now: now),
            cloudKitScan: .scanned(
                outcome: .observedApps, isStale: false,
                observedAt: now.addingTimeInterval(-120), isTruncated: true,
                windowMinutes: CloudKitAppSource.fallbackWindowMinutes
            )
        )
    }

    /// A `brctl dump -i` excerpt in the shape of the captured fixtures
    /// (BirdwatchTests/Fixtures/brctl-dump-excerpt.txt for the scheduler,
    /// brctl-dump-ga-container-excerpt.txt for the container line), parsed by
    /// the real parser. Only `last-sync` is moved to "2 minutes ago" so the
    /// mock never ages; every other value is as captured. The container line
    /// says `client:idle` — the only client state on record — and per-file
    /// transfers still make the iCloud Drive row "Syncing", as on a real Mac.
    nonisolated static func dumpText(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let lastSync = formatter.string(from: now.addingTimeInterval(-120))
        return """
        scheduler
        -----------------------------------------------------
            + items:                 client:71 thousand (71489), server: 71 thousand (71460)
            + push environment:      production
            + global sync up budget: budget available {  0:01:10s ago  m:0.0% (0.5)  h:0.0% (20.0)  d:0.0% (98.7)  }
            + periodic sync:         idle
            + sync status:           itemsNeedUpload|nonIdleItems

        1 containers matching '*'
        -----------------------------------------------------
        - <c{1}m.a{3}e.C{7}s[1] foreground {client:idle server:full-sync|fetched-recents|fetched-favorites|ever-full-sync sync:has-synced-down last-sync:\(lastSync), requestID:212280, caught-up, token:unkown-token-size:36 (AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)}>
        -----------------------------------------------------
        """
    }

    /// bird's CloudDocs state, read from the dump's container line exactly as
    /// the live source reads it.
    nonisolated static func birdStatus(now: Date) -> BrctlStatus {
        BrctlParser.containerState(inDump: dumpText(now: now)) ?? BrctlStatus()
    }

    /// Diagnostics' engine card, built by the live source's own builder from
    /// the same dump and container state as the rows, so the two agree.
    nonisolated static func engine(now: Date) -> SyncEngineInfo {
        let status = birdStatus(now: now)
        let mapped = SystemSyncSource.MappedDump(BrctlDumpParser.parse(dumpText(now: now)), cloudDocsState: status)
        let reading = SystemSyncSource.CloudDocsReading(state: status, dumpAge: 60, dumpHasContainer: true)
        return SystemSyncSource.engine(reading: reading, mapped: mapped, dumpFailure: nil,
                                       fullDiskAccess: fullDiskAccess)
    }

    nonisolated private static func apps(now: Date, transfers: [TransferItem]) -> [AppSyncState] {
        var obsidian = AppContainerSource.makeContainer(directoryName: "iCloud~md~obsidian")!
        obsidian.itemCount = 14
        obsidian.lastModified = now.addingTimeInterval(-5_400)
        return SystemSyncSource.buildApps(
            status: birdStatus(now: now),
            transfers: transfers,
            fileProviderDomains: ["1Password", "Bear"],
            containers: [obsidian],
            localSizes: [
                "icloud-drive": LocalSize(bytes: 22_100_000_000),
                obsidian.id: LocalSize(bytes: 48_000_000),
            ],
            cloudKitApps: cloudKitApps(now: now),
            desktopDocuments: .on(lastKnown: nil),
            // Full Disk Access not confirmed (see `permissions`): the row says it isn't
            // watched instead of claiming a state.
            desktopDocumentsReadable: false
        )
    }

    /// CloudKit rows exactly as the log scan builds them: Photos moving data
    /// (`.active`, no figure), the rest idle with their last activity.
    nonisolated private static func cloudKitApps(now: Date) -> [AppSyncState] {
        let observed: [(bundle: String, name: String, container: String, state: CloudKitActivityState, age: TimeInterval)] = [
            ("com.apple.Photos", "Photos", "com.apple.photos.cloud", .transferring, 150),
            ("com.apple.Notes", "Notes", "com.apple.notes", .idle, 480),
            ("com.apple.MobileSMS", "Messages", "com.apple.messages.cloud", .idle, 900),
            ("com.apple.Safari", "Safari", "com.apple.SafariShared.WBSCloudBookmarksStore", .idle, 1_500),
        ]
        return observed.map { entry in
            CloudKitAppMapping.makeApp(
                activity: CloudKitAppActivity(
                    bundleID: entry.bundle, containers: [entry.container],
                    lastActivity: now.addingTimeInterval(-entry.age), state: entry.state, operationCount: 12
                ),
                bundleID: entry.bundle, displayName: entry.name, now: now
            )
        }
    }

    /// iCloud Drive transfers as the ubiquity channel reports them: in flight
    /// or done, no percentage. Desktop & Documents has none — it isn't watched.
    nonisolated private static var transfers: [TransferItem] {
        let root = DriveFolder.cloudDocsLocation
        return [
            TransferItem(id: "t1", appID: "icloud-drive", name: "Q3 Board Deck.key", location: root + "/Presentations", sizeBytes: 84_000_000, direction: .upload, progress: 0),
            TransferItem(id: "t2", appID: "icloud-drive", name: "Brand Assets.zip", location: root + "/Design", sizeBytes: 420_000_000, direction: .download, progress: 0),
            TransferItem(id: "t3", appID: "icloud-drive", name: "Roadmap.sketch", location: root + "/Design", sizeBytes: 96_000_000, direction: .download, progress: 0),
            TransferItem(id: "t4", appID: "icloud-drive", name: "Invoice-2041.pdf", location: root + "/Finance", sizeBytes: 1_200_000, direction: .upload, progress: 1.0),
        ]
    }

    nonisolated private static func driveFolders(transfers: [TransferItem]) -> [DriveFolder] {
        let folders = [
            ("Desktop", 312), ("Documents", 4_218), ("Design", 1_874),
            ("Presentations", 96), ("Finance", 640), ("Downloads Archive", 2_130),
        ].map { DriveFolderSource.makeFolder(name: $0.0, itemCount: $0.1, transferLocations: []) }
        return DriveFolderSource.applying(transfers: transfers, to: folders)
    }

    /// bird's anonymous per-device attribution (device names are redacted).
    nonisolated private static func deviceActivity(now: Date) -> DeviceActivitySummary {
        DeviceActivitySummary(
            devices: [
                DeviceActivityItem(index: 1, itemCount: 1_204, lastModified: now.addingTimeInterval(-300)),
                DeviceActivityItem(index: 2, itemCount: 388, lastModified: now.addingTimeInterval(-1_560)),
                DeviceActivityItem(index: 3, itemCount: 96, lastModified: now.addingTimeInterval(-10_800)),
                DeviceActivityItem(index: 4, itemCount: 12, lastModified: nil),
            ],
            registeredDeviceCount: 6,
            countsArePartial: true
        )
    }

    /// Every issue in a shape a real producer emits. Order is a test
    /// contract (MockIssueFixtureTests): the Open Diagnostics card's
    /// neighbour carries a DIFFERENT primary action, so a mark-to-element
    /// mis-resolution in the QA harness shows up as the wrong button.
    nonisolated private static var issues: [IssueItem] {
        [
            // Shaped like BrctlDumpSource's SyncHealthReport error (severity
            // .error, action .openDiagnostics). The id is deliberately stable
            // and obvious — the Issues card derives its accessibility
            // identifier as "issue-primary-<id>", so QA can target it.
            IssueItem(
                id: "issue-stuck-items-mock", severity: .error,
                title: "Upload error reported by bird",
                meta: "iCloud Drive · SyncHealthReport",
                reason: "bird's own health report lists an upload error for iCloud Drive. macOS exposes no cause and redacts the item names, so Birdwatch shows the engine's report rather than guessing — Diagnostics has the raw output this came from.",
                action: .openDiagnostics, symbolName: "exclamationmark.triangle.fill",
                appID: "icloud-drive"
            ),
        ]
        // The real low-quota issue for the fixture's remaining quota.
        + SystemSyncSource.deriveIssues(quotaRemaining: quotaRemaining)
        + [
            // ConflictSource's shape for a file with two versions.
            IssueItem(
                id: "issue-conflict", severity: .conflict,
                title: "Sync conflict in Presentations",
                meta: "Q3 Report.pages · 2 versions",
                reason: "iCloud kept one version as the current file and saved the others for you to choose from. Review them and choose which to keep.",
                action: .reviewVersions, symbolName: "doc.on.doc",
                appID: "icloud-drive"
            ),
        ]
    }

    /// The activity log only ever records transfers starting and finishing
    /// (ActivityEventDescriptor); downloads start as neutral `.info`.
    nonisolated private static func activity(now: Date) -> [ActivityEvent] {
        let root = DriveFolder.cloudDocsLocation
        return [
            ActivityEvent(id: "a1", kind: .upload, title: "Uploading Q3 Board Deck.key", detail: root + "/Presentations", date: now.addingTimeInterval(-40), symbolName: "arrow.up.circle"),
            ActivityEvent(id: "a2", kind: .done, title: "Invoice-2041.pdf uploaded", detail: root + "/Finance", date: now.addingTimeInterval(-180), symbolName: "checkmark.circle"),
            ActivityEvent(id: "a3", kind: .info, title: "Downloading Roadmap.sketch", detail: root + "/Design", date: now.addingTimeInterval(-420), symbolName: "arrow.down.circle"),
            ActivityEvent(id: "a4", kind: .info, title: "Downloading Brand Assets.zip", detail: root + "/Design", date: now.addingTimeInterval(-600), symbolName: "arrow.down.circle"),
            ActivityEvent(id: "a5", kind: .done, title: "Team Notes.md downloaded", detail: root + "/Finance", date: now.addingTimeInterval(-2_400), symbolName: "checkmark.circle"),
        ]
    }

    nonisolated private static let daemons: [DaemonStat] = [
        DaemonStat(name: "bird", role: "CloudDocs sync engine", cpuPercent: 34, memoryMB: 412, pid: 501),
        DaemonStat(name: "cloudd", role: "CloudKit sync", cpuPercent: 18, memoryMB: 286, pid: 512),
        DaemonStat(name: "fileproviderd", role: "File Provider host", cpuPercent: 6, memoryMB: 148, pid: 498),
    ]

    nonisolated private static let retryQueue: [RetryQueueItem] = [
        RetryQueueItem(id: "r1", name: "Archive-2019.zip", attempt: 62, maxAttempts: 62),
        RetryQueueItem(id: "r2", name: "Render_final_v8.mp4", attempt: 12, maxAttempts: 62),
        RetryQueueItem(id: "r3", name: "node_modules.nosync", attempt: 4, maxAttempts: 62),
    ]

    /// Full Disk Access not confirmed (the probe had no answer): Desktop &
    /// Documents is read only with a confirmed grant, so it is unwatched.
    /// The issue producers don't depend on the grant, so they still report.
    nonisolated private static let fullDiskAccess: PermissionState = .unknown

    /// Exactly the two permissions PermissionsProbe checks.
    nonisolated private static let permissions: [PermissionStatus] = [
        PermissionStatus(name: "Full Disk Access", state: fullDiskAccess),
        PermissionStatus(name: "Notifications", state: .granted),
    ]

    /// Only the hours from launch through the current hour of today were
    /// "sampled": hours before Birdwatch started and hours still to come are
    /// not data (`isObserved: false`), and the day's totals add up only the
    /// hours that were. A launch on an earlier day observes from midnight.
    nonisolated static func bandwidth(
        now: Date, launchedAt: Date, calendar: Calendar = .current
    ) -> BandwidthSummary {
        let up: [Int64] = [2, 1, 1, 0, 0, 1, 4, 12, 30, 48, 61, 52, 44, 58, 66, 51, 38, 42, 55, 34, 20, 12, 6, 3]
        let down: [Int64] = [4, 2, 1, 1, 0, 2, 8, 22, 41, 35, 28, 44, 52, 38, 30, 46, 61, 55, 40, 28, 18, 10, 8, 5]
        let currentHour = calendar.component(.hour, from: now)
        let firstObservedHour = calendar.isDate(launchedAt, inSameDayAs: now)
            ? calendar.component(.hour, from: launchedAt) : 0
        let observed = firstObservedHour...max(firstObservedHour, currentHour)
        let hours = (0..<24).map { h in
            observed.contains(h) && launchedAt <= now
                ? BandwidthHourSample(hour: h, uploadedBytes: up[h] * 18_000_000, downloadedBytes: down[h] * 15_000_000)
                : BandwidthHourSample(hour: h, uploadedBytes: 0, downloadedBytes: 0, isObserved: false)
        }
        return BandwidthSummary(
            uploadedTodayBytes: hours.reduce(0) { $0 + $1.uploadedBytes },
            downloadedTodayBytes: hours.reduce(0) { $0 + $1.downloadedBytes },
            currentRateBytesPerSec: 8_200_000,
            hours: hours
        )
    }

    /// bird's `brctl quota` remaining figure: low enough for the real
    /// low-quota issue, and the floor the plan cap is derived from.
    nonisolated private static let quotaRemaining: Int64 = 3_600_000_000

    /// Local footprint by file type (Apple publishes no per-service split),
    /// with the plan cap DERIVED from footprint + remaining quota — an
    /// estimate the UI must label as one.
    nonisolated private static let storage: StorageInfo? = StorageBreakdownSource.makeStorageInfo(
        totals: [
            .video: 52_000_000_000, .documents: 41_200_000_000, .images: 38_500_000_000,
            .archives: 6_400_000_000, .audio: 3_100_000_000, .codeData: 2_800_000_000,
            .appsPackages: 1_600_000_000, .other: 1_600_000_000,
        ],
        remainingBytes: quotaRemaining,
        planCapOverride: nil
    )

    /// What the store derives from issue arrivals: the issue's title and meta.
    nonisolated private static func notifications(now: Date) -> [AppNotification] {
        issues.enumerated().map { index, issue in
            AppNotification(id: "notif-\(issue.id)", severity: issue.severity, title: issue.title,
                            detail: issue.meta, date: now.addingTimeInterval(Double(-600 * (index + 1))),
                            isRead: index == 2)
        }
    }

    // MARK: - Log fixtures

    nonisolated private static func seedLogLines(appID: String) -> [LogLine] {
        let now = Date()
        return logMessages(appID: appID).prefix(8).enumerated().map { i, entry in
            LogLine(id: UUID(), date: now.addingTimeInterval(Double(-(8 - i)) * 1.6), level: entry.0, message: entry.1)
        }
    }

    nonisolated private static func nextLogLine(appID: String, index: Int) -> LogLine {
        let entries = logMessages(appID: appID)
        let entry = entries[index % entries.count]
        return LogLine(id: UUID(), date: Date(), level: entry.0, message: entry.1)
    }

    nonisolated private static func logMessages(appID: String) -> [(LogLevel, String)] {
        switch appID {
        case "photos":
            [
                (.info, "cloudd: CKSyncEngine push · 14 records queued"),
                (.debug, "cloudd: asset scale pass complete (12 items)"),
                (.info, "cloudd: uploaded batch 18/54 · 22.1 MB"),
                (.warn, "cloudd: APNS push budget throttled, deferring fetch"),
                (.debug, "cloudd: zone PhotosZone token advanced"),
                (.info, "cloudd: shared album delta applied (2 items)"),
            ]
        case "desktop-documents", "icloud-drive":
            [
                (.info, "bird: item enqueued for upload · Q3 Board Deck.key"),
                (.debug, "bird: brc.tree apply-edits 42 dirty items"),
                (.info, "bird: uploaded 8 items · 61.4 MB"),
                (.warn, "bird: transfer retry (attempt 12) · Render_final_v8.mp4"),
                (.debug, "bird: xattr sync pass complete"),
                (.error, "bird: NSURLErrorDomain -1005 · will retry with backoff"),
                (.info, "bird: placeholder materialized · Roadmap.sketch"),
            ]
        default:
            [
                (.info, "fileproviderd: domain signal · working set changed"),
                (.debug, "fileproviderd: enumerator session refreshed"),
                (.info, "fileproviderd: 14 items reconciled"),
                (.warn, "fileproviderd: provider slow to respond (1.2s)"),
            ]
        }
    }
}
