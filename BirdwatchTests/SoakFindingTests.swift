import Foundation
import Testing
@testable import Birdwatch

/// Small findings from the release soak on macOS 27.
@Suite("Soak findings")
struct SoakFindingTests {

    private actor TimingOutRunner: ProcessRunning {
        nonisolated func run(toolPath: String, arguments: [String], timeout: Duration) async throws -> String {
            throw RunnerError.timeout
        }
    }

    // The Sync Daemons card rendered as an empty card when `ps` timed out.
    @Test("A failed ps sample says why; an empty card never appears")
    func daemonsCardSaysWhy() async {
        let source = DaemonStatsSource(runner: TimingOutRunner())
        #expect(await source.sample().isEmpty)
        #expect(await source.lastSampleFailure == "ps timed out")
        #expect(DaemonStatsSource.failureReason(RunnerError.nonZeroExit(code: 1, stderr: "")) == "ps failed")

        #expect(DiagnosticsView.daemonsEmptyText(count: 0, failure: "ps timed out", hasLoaded: true)
                == "Couldn't sample daemons (ps timed out)")
        #expect(DiagnosticsView.daemonsEmptyText(count: 0, failure: nil, hasLoaded: false) == OverviewTiles.waiting)
        #expect(DiagnosticsView.daemonsEmptyText(count: 0, failure: nil, hasLoaded: true)
                == "None of bird, cloudd or fileproviderd is running")
        #expect(DiagnosticsView.daemonsEmptyText(count: 3, failure: "ps timed out", hasLoaded: true) == nil)
    }

    // The hero named bird's backlog only when idle; with CloudKit activity
    // on screen (the usual case) it said nothing about it.
    @Test("The hero names the backlog in every working state, not only idle")
    func heroBacklogWhenActive() {
        let line = "2 apps with items not syncing"
        let active = OverviewHeroDisplay(state: .active(appCount: 1), progress: 0, progressIsIndeterminate: true,
                                         inFlightCount: 0, pendingFileCount: 0, backlogLine: line)
        #expect(active.subtitle.contains(line), "got \(active.subtitle)")
        let syncing = OverviewHeroDisplay(state: .syncing(appCount: 1, alsoActive: 0), progress: 0,
                                          progressIsIndeterminate: true, inFlightCount: 2, pendingFileCount: 2,
                                          backlogLine: line)
        #expect(syncing.subtitle.contains(line))
        let determinate = OverviewHeroDisplay(state: .syncing(appCount: 1, alsoActive: 0), progress: 0.5,
                                              progressIsIndeterminate: false, inFlightCount: 1, pendingFileCount: 1,
                                              backlogLine: line)
        #expect(determinate.subtitle == "1 file remaining. \(line).")
        let idle = OverviewHeroDisplay(state: .idle, progress: 1, progressIsIndeterminate: false,
                                       inFlightCount: 0, pendingFileCount: 0, backlogLine: line)
        #expect(idle.subtitle.contains(line))
        let paused = OverviewHeroDisplay(state: .paused, progress: 0, progressIsIndeterminate: false,
                                         inFlightCount: 0, pendingFileCount: 0, backlogLine: line)
        #expect(!paused.subtitle.contains(line), "paused: nothing is current")
    }

    // The sidebar footer said "83.2 GB on this Mac" while the size walk had
    // hit its cap (the Storage screen said "partial scan").
    @Test("A capped size walk reads 'at least' in the footer, the Storage headline, and under a chosen plan")
    func partialLocalFigure() throws {
        let gb: Int64 = 1_000_000_000
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: [.documents: 83 * gb], remainingBytes: nil, planCapOverride: nil, isPartial: true))
        #expect(info.localIsPartial)
        let footer = StorageCapLabel.footerText(info.footerFigure, capIsEstimated: false, localIsPartial: info.localIsPartial)
        #expect(footer.hasPrefix("at least "), "got \(footer)")
        #expect(StorageCapLabel.footerAccessibilityValue(info.footerFigure, capIsEstimated: false,
                                                         localIsPartial: true).hasPrefix("at least "))
        #expect(StorageCapLabel.usageHeadline(used: 83 * gb, cap: nil, capIsEstimated: false, localIsPartial: true)
                .hasPrefix("At least "))
        #expect(!StorageCapLabel.footerText(.localOnly(used: 83 * gb), capIsEstimated: false).contains("at least"))
        // The account figure is cap − remaining, not the walk: never qualified.
        #expect(!StorageCapLabel.footerText(.account(used: 50 * gb, cap: 200 * gb), capIsEstimated: false,
                                            localIsPartial: true).contains("at least"))
        let chosen = try #require(SyncStore.applyPlanCap(2_000 * gb, to: info))
        #expect(chosen.localIsPartial)
    }
}
