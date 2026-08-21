import Foundation

/// Phase 0 fixture source. Data mirrors the design handoff's sample content so
/// every screen renders exactly as designed. Replaced per-backend in Phase 1.
/// A struct, not an actor: everything here is immutable Sendable fixture data,
/// so there is no state to protect (real Phase 1 sources own Process handles
/// and WILL be actors — see the SyncSource execution-context note).
struct MockSyncSource: SyncSource {

    nonisolated func currentSnapshot() async -> SyncSnapshot { Self.snapshot(now: Date()) }

    nonisolated func conflictDetail(issueID: String) async -> ConflictDetail? {
        guard issueID == "issue-conflict" else { return nil }
        let now = Date()
        return ConflictDetail(
            fileName: "Q3 Report.pages",
            location: "Documents",
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

    nonisolated func logStream(appID: String) -> AsyncStream<LogLine> {
        // bufferingNewest: the console shows 25 lines; never buffer unboundedly
        // while the consumer is busy. The real `log stream` wrapper keeps this.
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
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

    // MARK: - Fixture data (handoff sample content)

    nonisolated static func snapshot(now: Date) -> SyncSnapshot {
        SyncSnapshot(
            apps: apps(now: now),
            transfers: transfers,
            driveFolders: driveFolders,
            devices: devices(now: now),
            issues: issues,
            activity: activity(now: now),
            daemons: daemons,
            retryQueue: retryQueue,
            engine: engine,
            permissions: permissions,
            bandwidth: bandwidth,
            storage: storage,
            notifications: notifications(now: now)
        )
    }

    nonisolated private static func apps(now: Date) -> [AppSyncState] {
        [
            AppSyncState(
                id: "photos", name: "Photos", tileColorHex: "fe4f6d", backend: .cloudKit, isApple: true,
                status: .syncing(progress: 0.31), statusLine: "Uploading 234 of 1,024 photos",
                lastActivity: now.addingTimeInterval(-30),
                itemsIndexed: 48_213, pendingItems: 790, localSizeBytes: 84_300_000_000,
                locationPath: "~/Pictures/Photos Library.photoslibrary",
                queueLabels: ["Photos", "Videos", "Shared albums"], queueCounts: [612, 158, 20],
                infoCallout: "Photos syncs through CloudKit, which reports status and item counts but has no per-item progress API. Percentages here are derived from queue counts."
            ),
            AppSyncState(
                id: "desktop-documents", name: "Desktop & Documents", tileColorHex: "ffa62b", backend: .cloudDocs, isApple: true,
                status: .syncing(progress: 0.68), statusLine: "Uploading 42 files · 218 MB remaining",
                lastActivity: now.addingTimeInterval(-8),
                itemsIndexed: 12_480, pendingItems: 42, localSizeBytes: 18_700_000_000,
                locationPath: "~/Desktop · ~/Documents",
                retryWarning: "3 items stuck — attempt 12 of 62. Items that reach 62 attempts stop retrying."
            ),
            AppSyncState(
                id: "icloud-drive", name: "iCloud Drive", tileColorHex: "30b0c7", backend: .cloudDocs, isApple: true,
                status: .upToDate, statusLine: "All files synced",
                lastActivity: now.addingTimeInterval(-120),
                itemsIndexed: 8_912, pendingItems: 0, localSizeBytes: 22_100_000_000,
                locationPath: "~/Library/Mobile Documents/com~apple~CloudDocs"
            ),
            AppSyncState(
                id: "notes", name: "Notes", tileColorHex: "ffcc00", backend: .cloudKit, isApple: true,
                status: .upToDate, statusLine: "All notes synced",
                lastActivity: now.addingTimeInterval(-480),
                itemsIndexed: 1_284, pendingItems: 0, localSizeBytes: 640_000_000,
                locationPath: "~/Library/Group Containers/group.com.apple.notes"
            ),
            AppSyncState(
                id: "messages", name: "Messages", tileColorHex: "34c759", backend: .cloudKit, isApple: true,
                status: .upToDate, statusLine: "Messages in iCloud up to date",
                lastActivity: now.addingTimeInterval(-900),
                itemsIndexed: 96_410, pendingItems: 0, localSizeBytes: 7_900_000_000,
                locationPath: "~/Library/Messages"
            ),
            AppSyncState(
                id: "safari", name: "Safari", tileColorHex: "1e8fff", backend: .cloudKit, isApple: true,
                status: .upToDate, statusLine: "Tabs, bookmarks and history synced",
                lastActivity: now.addingTimeInterval(-1_500),
                itemsIndexed: 3_120, pendingItems: 0, localSizeBytes: 210_000_000,
                locationPath: "~/Library/Safari"
            ),
            AppSyncState(
                id: "1password", name: "1Password", tileColorHex: "1a73e8", backend: .fileProvider, isApple: false,
                status: .syncing(progress: 0.12), statusLine: "Syncing vault changes",
                lastActivity: now.addingTimeInterval(-45),
                itemsIndexed: 890, pendingItems: 14, localSizeBytes: 120_000_000,
                locationPath: "~/Library/CloudStorage/1Password",
                infoCallout: "1Password syncs through a File Provider extension. macOS reports only the domain's overall status — Birdwatch cannot see individual items."
            ),
            AppSyncState(
                id: "bear", name: "Bear", tileColorHex: "d63d3d", backend: .fileProvider, isApple: false,
                status: .upToDate, statusLine: "Notes synced",
                lastActivity: now.addingTimeInterval(-3_600),
                itemsIndexed: 640, pendingItems: 0, localSizeBytes: 310_000_000,
                locationPath: "~/Library/CloudStorage/Bear"
            ),
            AppSyncState(
                id: "craft", name: "Craft", tileColorHex: "4b5bd6", backend: .fileProvider, isApple: false,
                status: .paused, statusLine: "Sync paused",
                lastActivity: now.addingTimeInterval(-7_200),
                itemsIndexed: 1_120, pendingItems: 6, localSizeBytes: 480_000_000,
                locationPath: "~/Library/CloudStorage/Craft"
            ),
        ]
    }

    nonisolated private static let transfers: [TransferItem] = [
        TransferItem(id: "t1", appID: "desktop-documents", name: "Q3 Board Deck.key", location: "Documents/Presentations", sizeBytes: 84_000_000, direction: .upload, progress: 0.72),
        TransferItem(id: "t2", appID: "desktop-documents", name: "Team Offsite.mov", location: "Desktop", sizeBytes: 1_240_000_000, direction: .upload, progress: 0.31),
        TransferItem(id: "t3", appID: "icloud-drive", name: "Brand Assets.zip", location: "iCloud Drive/Design", sizeBytes: 420_000_000, direction: .download, progress: 0.88),
        TransferItem(id: "t4", appID: "desktop-documents", name: "Invoice-2041.pdf", location: "Documents/Finance", sizeBytes: 1_200_000, direction: .upload, progress: 1.0),
        TransferItem(id: "t5", appID: "icloud-drive", name: "Roadmap.sketch", location: "iCloud Drive/Design", sizeBytes: 96_000_000, direction: .download, progress: 0.54),
    ]

    nonisolated private static let driveFolders: [DriveFolder] = [
        DriveFolder(id: "f1", name: "Documents", itemCount: 4_218, status: .syncing(progress: 0.68)),
        DriveFolder(id: "f2", name: "Desktop", itemCount: 312, status: .syncing(progress: 0.41)),
        DriveFolder(id: "f3", name: "Design", itemCount: 1_874, status: .syncing(progress: 0.86)),
        DriveFolder(id: "f4", name: "Finance", itemCount: 640, status: .upToDate),
        DriveFolder(id: "f5", name: "Downloads Archive", itemCount: 2_130, status: .upToDate),
        DriveFolder(id: "f6", name: "Old Projects", itemCount: 5_480, status: .paused),
    ]

    nonisolated private static func devices(now: Date) -> [DeviceItem] {
        [
            DeviceItem(id: "d1", name: "MacBook Pro", kind: "MacBook Pro 14″", osVersion: "macOS 15.5", tileColorHex: "0a84ff", isCurrentDevice: true, statusLabel: "Syncing now", isActive: true, lastChange: "Uploaded 42 files just now"),
            DeviceItem(id: "d2", name: "iPhone 15 Pro", kind: "iPhone", osVersion: "iOS 18.5", tileColorHex: "af52de", isCurrentDevice: false, statusLabel: "Last seen 26m ago", isActive: false, lastChange: "Added 12 photos"),
            DeviceItem(id: "d3", name: "iPad Air", kind: "iPad", osVersion: "iPadOS 18.5", tileColorHex: "30b0c7", isCurrentDevice: false, statusLabel: "Last seen 3h ago", isActive: false, lastChange: "Edited 2 notes"),
            DeviceItem(id: "d4", name: "iMac", kind: "iMac 24″", osVersion: "macOS 15.4", tileColorHex: "ffa62b", isCurrentDevice: false, statusLabel: "Last seen 2d ago", isActive: false, lastChange: "No recent changes"),
            DeviceItem(id: "d5", name: "iCloud.com", kind: "Web session", osVersion: "Safari · Chrome", tileColorHex: "8e8e93", isCurrentDevice: false, statusLabel: "Last seen 5d ago", isActive: false, lastChange: "Viewed Photos"),
        ]
    }

    nonisolated private static let issues: [IssueItem] = [
        IssueItem(
            id: "issue-photos-metered", severity: .warning,
            title: "Photos upload paused on metered network",
            meta: "Photos · 12 minutes ago",
            reason: "macOS pauses large iCloud uploads when it detects a personal hotspot or metered connection to protect your data plan. Uploads resume automatically on Wi-Fi.",
            action: .none, symbolName: "wifi.exclamationmark"
        ),
        IssueItem(
            id: "issue-conflict", severity: .conflict,
            title: "Sync conflict in Documents",
            meta: "Q3 Report.pages · 26 minutes ago",
            reason: "This file was edited on two devices at the same time, so iCloud kept both versions instead of guessing. Review them and choose which to keep — nothing has been lost.",
            action: .reviewVersions, symbolName: "doc.on.doc"
        ),
        IssueItem(
            id: "issue-storage", severity: .warning,
            title: "Not enough iCloud storage for full backup",
            meta: "Storage · 2 hours ago",
            reason: "Your account has 52.8 GB free but the next device backup needs more. Sync of new files continues, but backups will fail until you free space or upgrade the plan.",
            action: .manageStorage, symbolName: "externaldrive.badge.exclamationmark"
        ),
    ]

    nonisolated private static func activity(now: Date) -> [ActivityEvent] {
        [
            ActivityEvent(id: "a1", kind: .upload, title: "Uploading Q3 Board Deck.key", detail: "Documents/Presentations · 84 MB", date: now.addingTimeInterval(-40), symbolName: "arrow.up.circle"),
            ActivityEvent(id: "a2", kind: .done, title: "Invoice-2041.pdf uploaded", detail: "Documents/Finance", date: now.addingTimeInterval(-180), symbolName: "checkmark.circle"),
            ActivityEvent(id: "a3", kind: .conflict, title: "Conflict detected in Q3 Report.pages", detail: "Edited on MacBook Pro and iPhone 15 Pro", date: now.addingTimeInterval(-1_560), symbolName: "exclamationmark.triangle"),
            ActivityEvent(id: "a4", kind: .warning, title: "Photos upload paused", detail: "Metered network detected", date: now.addingTimeInterval(-720), symbolName: "pause.circle"),
            ActivityEvent(id: "a5", kind: .done, title: "Brand Assets.zip downloaded", detail: "iCloud Drive/Design · 420 MB", date: now.addingTimeInterval(-2_400), symbolName: "arrow.down.circle"),
            ActivityEvent(id: "a6", kind: .info, title: "iPhone 15 Pro added 12 photos", detail: "Photo Library", date: now.addingTimeInterval(-1_560), symbolName: "iphone"),
            ActivityEvent(id: "a7", kind: .done, title: "Notes synced", detail: "3 notes updated", date: now.addingTimeInterval(-3_800), symbolName: "checkmark.circle"),
            ActivityEvent(id: "a8", kind: .info, title: "Metadata index refreshed", detail: "8,912 items · bird", date: now.addingTimeInterval(-5_400), symbolName: "arrow.triangle.2.circlepath"),
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

    nonisolated private static let engine = SyncEngineInfo(
        serverState: "Reachable · api.icloud.com",
        clientState: "Active · pushing changes",
        lastSyncToken: "Δ 8f3a…c21e · 2m ago",
        pushBudget: "Throttled — next window in 4m",
        pushThrottled: true,
        metadataIndex: "Healthy · 71,489 items",
        metadataHealthy: true
    )

    nonisolated private static let permissions: [PermissionStatus] = [
        PermissionStatus(name: "Full Disk Access", granted: true),
        PermissionStatus(name: "Automation", granted: true),
        PermissionStatus(name: "Local Network", granted: true),
        PermissionStatus(name: "Notifications", granted: true),
    ]

    nonisolated private static let bandwidth: BandwidthSummary = {
        // Rough daily curve peaking mid-day, mirroring the handoff chart shape.
        let up: [Int64] = [2, 1, 1, 0, 0, 1, 4, 12, 30, 48, 61, 52, 44, 58, 66, 51, 38, 42, 55, 34, 20, 12, 6, 3]
        let down: [Int64] = [4, 2, 1, 1, 0, 2, 8, 22, 41, 35, 28, 44, 52, 38, 30, 46, 61, 55, 40, 28, 18, 10, 8, 5]
        let hours = (0..<24).map { h in
            BandwidthHourSample(hour: h, uploadedBytes: up[h] * 18_000_000, downloadedBytes: down[h] * 15_000_000)
        }
        return BandwidthSummary(
            uploadedTodayBytes: 8_400_000_000,
            downloadedTodayBytes: 6_100_000_000,
            currentRateBytesPerSec: 8_200_000,
            hours: hours
        )
    }()

    nonisolated private static let storage = StorageInfo(
        totalBytes: 200_000_000_000,
        segments: [
            StorageSegment(name: "Photos", colorHex: "fe4f6d", bytes: 84_300_000_000),
            StorageSegment(name: "Backups", colorHex: "5e5ce6", bytes: 31_200_000_000),
            StorageSegment(name: "iCloud Drive", colorHex: "0a84ff", bytes: 22_100_000_000),
            StorageSegment(name: "Mail", colorHex: "34c759", bytes: 4_800_000_000),
            StorageSegment(name: "Other", colorHex: "8e8e93", bytes: 4_800_000_000),
        ],
        planName: "iCloud+ · 200 GB plan",
        planPriceLine: "$2.99/month · renews Sep 3"
    )

    nonisolated private static func notifications(now: Date) -> [AppNotification] {
        [
            AppNotification(id: "n1", severity: .warning, title: "Upload stalled", detail: "Team Offsite.mov has made no progress for 10 minutes", date: now.addingTimeInterval(-600), isRead: false),
            AppNotification(id: "n2", severity: .conflict, title: "Sync conflict", detail: "Q3 Report.pages was edited on two devices", date: now.addingTimeInterval(-1_560), isRead: false),
            AppNotification(id: "n3", severity: .warning, title: "Storage low", detail: "52.8 GB left on your 200 GB plan", date: now.addingTimeInterval(-7_200), isRead: true),
        ]
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
