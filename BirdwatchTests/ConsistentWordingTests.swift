import Foundation
import Testing
@testable import Birdwatch

/// Every screen says the same thing about the same fact: an unwatched
/// Desktop & Documents row, a container's modification date, a last-known
/// engine state, incomplete issue checks, an empty feed.
@MainActor
@Suite("Consistent wording across screens")
struct ConsistentWordingTests {

    private static func row(
        _ id: String, status: AppSyncStatus = .upToDate, backend: SyncBackend = .cloudDocs
    ) -> AppSyncState {
        AppSyncState(id: id, name: id == "desktop-documents" ? "Desktop & Documents" : id,
                     tileColorHex: "000000", backend: backend, isApple: true,
                     status: status, statusLine: "", lastActivity: nil,
                     itemCount: nil, pendingItems: nil, localSize: nil, locationPath: "~")
    }

    private static var unwatched: AppSyncState {
        var dd = row("desktop-documents", status: .unknown)
        dd.needsFullDiskAccess = true
        return dd
    }

    @Test("An unwatched row's tiles say 'Not watched without Full Disk Access'")
    func detailTiles() {
        let dd = Self.unwatched
        #expect(AppDetailFacts.itemTile(dd).value == "Not watched without Full Disk Access")
        #expect(AppDetailFacts.pendingValue(dd) == "Not watched without Full Disk Access")
        #expect(AppDetailFacts.localSizeValue(dd) == "Not watched without Full Disk Access")
    }

    @Test("Transfer lists and tiles are qualified when a row is unwatched or monitoring paused")
    func transferNotes() {
        #expect(TransferWatchNotes.qualifier(paused: false, unwatched: []) == nil)
        #expect(TransferWatchNotes.qualifier(paused: false, unwatched: [Self.unwatched])
                == "Desktop & Documents transfers aren't watched without Full Disk Access.")
        #expect(TransferWatchNotes.tile(bytes: 0, paused: false, unwatched: [Self.unwatched])
                == ("—", "Excludes Desktop & Documents"))
        #expect(TransferWatchNotes.tile(bytes: 0, paused: true, unwatched: []).value == "—")
        #expect(TransferWatchNotes.tile(bytes: 0, paused: false, unwatched: []).caption == nil)
    }

    // The soak test saw "Zero KB" with no caption while the first read was
    // still pending — a figure nobody had measured yet (C1).
    @Test("Before the first read the Overview tiles say so instead of showing zero")
    func tilesBeforeFirstRead() {
        #expect(TransferWatchNotes.tile(bytes: 0, paused: false, unwatched: [], ready: false)
                == ("—", "Waiting for first read"))
        #expect(OverviewTiles.activeApps(count: 0, loaded: false, paused: false) == ("—", "Waiting for first read"))
        #expect(OverviewTiles.activeApps(count: 2, loaded: true, paused: false) == ("2", nil))
    }

    // While paused the soak test saw "Active apps 0" and "0% CPU · Healthy"
    // presented as live readings of a snapshot taken before the pause (C1).
    @Test("Paused: active apps and daemon load are not shown as live")
    func pausedFiguresAreNotLive() {
        #expect(OverviewTiles.activeApps(count: 0, loaded: true, paused: true) == ("—", "Not watched while paused"))

        let bird = DaemonStat(name: "bird", role: "", cpuPercent: 0, memoryMB: 40, pid: 1)
        let paused = DaemonLoadDisplay(bird, paused: true)
        #expect(paused.cpuText == "—")
        #expect(paused.healthWord == "Not sampled while paused")
        #expect(paused.barFraction == nil)
        #expect(paused.color == Palette.gray)

        for percent in [0.0, 14.99, 15, 29.6, 30, 134] {
            var sample = bird
            sample.cpuPercent = percent
            let live = DaemonLoadDisplay(sample, paused: false)
            #expect(live.color == cpuTint(percent), "one threshold rule for \(percent)")
            #expect(live.cpuText == Format.cpu(percent))
        }
        #expect(DaemonLoadDisplay(bird, paused: false).healthWord == "Healthy")
    }

    @Test("A source's snapshot is not ready until the transfer watcher has swept once")
    func watcherReadiness() async {
        let gate = AsyncStream<Void>.makeStream()
        let watcher = UbiquityTransferSource(roots: ["/nonexistent-bw-root"], sweep: { _ in
            for await _ in gate.stream { break }
            return []
        })
        watcher.start()
        defer { watcher.stop() }
        #expect(!watcher.hasSwept)
        gate.continuation.yield()
        await watcher.finishSweepForTesting()
        #expect(watcher.hasSwept)
    }

    @Test("Drive folders: gated Desktop/Documents, and never green while the engine is unknown or paused")
    func driveFolders() {
        let docs = DriveFolder(id: "d", name: "Documents", itemCount: 3, status: .upToDate)
        let other = DriveFolder(id: "o", name: "Notes", itemCount: 3, status: .upToDate)
        func show(_ f: DriveFolder, unknown: Bool = false, paused: Bool = false, gated: Bool = false) -> SyncStatusDisplay {
            DriveFolderDisplay.display(f, progressIsIndeterminate: false, engineStateUnknown: unknown,
                                       paused: paused, desktopDocumentsUnwatched: gated)
        }
        #expect(show(docs, gated: true).label == "Not watched — needs Full Disk Access")
        #expect(show(other, gated: true).tone == .confirmed)
        #expect(show(other, unknown: true) == SyncStatusDisplay(label: "State unknown", tone: .neutral))
        #expect(show(other, paused: true) == SyncStatusDisplay(label: "Monitoring paused", tone: .neutral))
    }

    @Test("Recency tile: containers say 'Last modified'; a last-known state carries its note")
    func recencyTile() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var container = Self.row("pages")
        container.lastActivity = now - 3600
        container.lastActivityLabel = "Last modified"
        #expect(AppDetailFacts.lastActivityTile(container, now: now).label == "Last modified")

        var drive = Self.row("icloud-drive")
        drive.lastActivity = now - 3600
        drive.lastActivityNote = "last-known, brctl dump 4 min ago"
        let tile = AppDetailFacts.lastActivityTile(drive, now: now)
        #expect(tile.label == "Last synced")
        #expect(tile.value.hasSuffix("(last-known, brctl dump 4 min ago)"))

        let apps = SystemSyncSource.buildApps(
            status: BrctlStatus(clientState: "idle", serverState: "s", lastSync: now, isIdle: true, tokenInfo: nil, apps: []),
            transfers: [], fileProviderDomains: [], stateNote: "last-known, brctl dump 4 min ago")
        #expect(apps.first { $0.id == "icloud-drive" }?.lastActivityNote == "last-known, brctl dump 4 min ago")
    }

    @Test("CloudDocs progress detail is boolean, not 'per-file exact'")
    func progressDetail() {
        #expect(SyncBackend.cloudDocs.progressDetail == "In flight / done only (no percentage)")
    }

    @Test("Issues tile: '—' when none found but checks are incomplete, plain count otherwise")
    func issuesTile() {
        #expect(IssuesTile.display(count: 0, qualifiers: []) == ("0", nil))
        #expect(IssuesTile.display(count: 0, qualifiers: ["x"]) == ("—", "None found — not fully checked"))
        #expect(IssuesTile.display(count: 2, qualifiers: ["x"]) == ("2", "May be incomplete"))
        let lines = IssuesEmptyState.qualifiers(isPaused: true,
                                                deliveredProducers: nil, conflictScanCap: nil)
        #expect(lines.count == 1)
    }

    @Test("Empty feeds say so")
    func emptyActivity() {
        #expect(ActivityEmptyState.text(paused: false) == "No sync activity seen since Birdwatch started.")
        #expect(ActivityEmptyState.text(paused: true).hasPrefix("Monitoring is paused"))
    }
}
