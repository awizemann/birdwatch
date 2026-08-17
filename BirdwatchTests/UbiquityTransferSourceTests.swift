import Foundation
import Testing
@testable import Birdwatch

/// Real captured fixtures live next to this file; #filePath keeps loading
/// independent of bundle resource phases (test-only, acceptable here).
private nonisolated func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name)")
}

/// One captured 1 Hz tick: what the resource-value probe returned for every
/// FSEvents candidate path at that moment.
private nonisolated struct CapturedTick: Decodable {
    struct Probe: Decodable {
        let path: String
        let name: String
        let sizeBytes: Int64
        let isUbiquitous: Bool
        let isUploading: Bool
        let isDownloading: Bool
    }
    let tick: Int
    let probes: [Probe]

    var results: [UbiquityProbeResult] {
        probes.map {
            UbiquityProbeResult(
                path: $0.path, name: $0.name, sizeBytes: $0.sizeBytes,
                isUbiquitous: $0.isUbiquitous, isUploading: $0.isUploading,
                isDownloading: $0.isDownloading
            )
        }
    }
}

private nonisolated func capturedTimeline() throws -> [CapturedTick] {
    let raw = try String(contentsOf: fixtureURL("ubiquity-probe-timeline.ndjson"), encoding: .utf8)
    let decoder = JSONDecoder()
    return try raw
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { try decoder.decode(CapturedTick.self, from: Data($0.utf8)) }
}

@Suite("UbiquityTransferSource")
struct UbiquityTransferSourceTests {

    private let home = "/Users/tester"
    private let file = "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/bwtest10.bin"

    // MARK: - Replay of a real captured upload

    /// The fixture is a real 60 MB upload into iCloud Drive, captured live at
    /// 1 Hz: the file appears mid-copy (ubiquitous, not yet uploading), goes
    /// uploading for ~15 s, then reports not-uploading once the sync engine is
    /// done. Replaying it through the real state machine must produce exactly
    /// one transfer that appears, persists, and then retires.
    @Test func replayingARealUploadProducesATransferThatAppearsAndRetires() throws {
        let ticks = try capturedTimeline()
        #expect(ticks.count == 25)

        var candidates: [String: UbiquityCandidate] = [:]
        let start = Date(timeIntervalSince1970: 0)
        var perTick: [[TransferItem]] = []

        // FSEvents announces a path when it CHANGES — the write that started
        // the upload. It says nothing more afterwards, so the path is merged
        // once and only the probe ticker observes the rest of its life.
        var announced: Set<String> = []
        for tick in ticks {
            let now = start.addingTimeInterval(Double(tick.tick))
            let fresh = tick.results.map(\.path).filter { announced.insert($0).inserted }
            candidates = UbiquityTransferSource.merge(candidates, newPaths: fresh, at: now)
            // The real probe only ever visits paths still in the table.
            let probed = tick.results.filter { candidates[$0.path] != nil }
            candidates = UbiquityTransferSource.reduce(candidates, results: probed, now: now)
            perTick.append(UbiquityTransferSource.transferItems(from: probed, homeDirectory: home))
        }
        let inFlightTicks = perTick.indices.filter { !perTick[$0].isEmpty }
        // Ticks 4...18 in the capture (0-based 3...17).
        #expect(inFlightTicks == Array(3...17))

        let item = try #require(perTick[5].first)
        #expect(item.name == "bwtest10.bin")
        #expect(item.direction == .upload)
        #expect(item.sizeBytes == 62_914_560)
        #expect(item.appID == "icloud-drive")
        #expect(item.location == "~/Library/Mobile Documents/com~apple~CloudDocs")
        #expect(item.id == file)

        // Once the engine stops reporting the upload, the candidate is retired
        // immediately rather than lingering for the TTL — that disappearance is
        // the ONLY observable for completion.
        #expect(candidates[file] == nil)
        #expect(perTick.last?.isEmpty == true)
    }

    /// The disappearance the replay produces is what the Activity feed turns
    /// into a completion entry — the end-to-end contract Alan saw broken.
    @Test func aRetiredTransferBecomesACompletedActivityEvent() throws {
        let ticks = try capturedTimeline()
        let uploading = UbiquityTransferSource.transferItems(
            from: ticks[5].results, homeDirectory: home
        )
        let finished = UbiquityTransferSource.transferItems(
            from: ticks[20].results, homeDirectory: home
        )
        #expect(!uploading.isEmpty)
        #expect(finished.isEmpty)

        let appeared = ActivityLog.diff(old: [], new: uploading)
        #expect(appeared.count == 1)
        #expect(appeared.first?.title == "Uploading bwtest10.bin")

        let completed = ActivityLog.diff(old: uploading, new: finished)
        #expect(completed.count == 1)
        #expect(completed.first?.kind == .done)
        #expect(completed.first?.title == "bwtest10.bin uploaded")
    }

    // MARK: - Retention rules

    @Test func aCandidateThatNeverGoesInFlightExpiresOnTTL() {
        let now = Date(timeIntervalSince1970: 10_000)
        let path = "/Users/tester/Documents/scratch.txt"
        var candidates = UbiquityTransferSource.merge([:], newPaths: [path], at: now)
        let idle = UbiquityProbeResult(
            path: path, name: "scratch.txt", sizeBytes: 5, isUbiquitous: true,
            isUploading: false, isDownloading: false
        )

        candidates = UbiquityTransferSource.reduce(candidates, results: [idle], now: now.addingTimeInterval(30))
        #expect(candidates[path] != nil, "still inside the TTL")

        candidates = UbiquityTransferSource.reduce(candidates, results: [idle], now: now.addingTimeInterval(300))
        #expect(candidates.isEmpty, "expired past the TTL")
    }

    @Test func candidateTableIsBoundedAndKeepsTheNewest() {
        let base = Date(timeIntervalSince1970: 0)
        var candidates: [String: UbiquityCandidate] = [:]
        for index in 0..<50 {
            candidates = UbiquityTransferSource.merge(
                candidates, newPaths: ["/p/\(index)"],
                at: base.addingTimeInterval(Double(index)), limit: 10
            )
        }
        #expect(candidates.count == 10)
        #expect(candidates["/p/49"] != nil)
        #expect(candidates["/p/0"] == nil)
    }

    @Test func mergeRefreshesTheTimestampOfAKnownPath() {
        let base = Date(timeIntervalSince1970: 0)
        var candidates = UbiquityTransferSource.merge([:], newPaths: ["/p/a"], at: base)
        candidates = UbiquityTransferSource.merge(
            candidates, newPaths: ["/p/a"], at: base.addingTimeInterval(60)
        )
        #expect(candidates.count == 1)
        #expect(candidates["/p/a"]?.lastEventAt == base.addingTimeInterval(60))
    }

    // MARK: - Completion grace window

    /// The same file can finish twice inside one 90s grace window (edit → sync
    /// → edit → sync). `TransferItem.id` is the path, so stacking both would
    /// publish two items with the SAME id and break ForEach identity.
    @Test func completingTheSamePathTwiceKeepsOneEntryWithNoDuplicateIDs() {
        let base = Date(timeIntervalSince1970: 10_000)
        let path = "/Users/tester/Documents/notes.md"
        let item = UbiquityTransferSource.makeTransferItem(
            path: path, name: "notes.md", sizeBytes: 1_024, isUploading: true,
            homeDirectory: "/Users/tester"
        )

        var completed = UbiquityTransferSource.foldCompletions([], finished: [item], now: base)
        #expect(completed.count == 1)

        // Second completion, still well inside the grace window.
        let later = base.addingTimeInterval(20)
        completed = UbiquityTransferSource.foldCompletions(completed, finished: [item], now: later)

        #expect(completed.count == 1, "the second completion refreshed the entry rather than stacking")
        #expect(completed[0].at == later, "the grace window restarted from the newer completion")
        #expect(completed[0].item.progress == 1)

        let ids = completed.map(\.item.id)
        #expect(Set(ids).count == ids.count, "no duplicate TransferItem.id")

        // And the entry still expires once the grace window really lapses.
        let expired = UbiquityTransferSource.foldCompletions(
            completed, finished: [],
            now: later.addingTimeInterval(UbiquityTransferSource.completionGrace + 1)
        )
        #expect(expired.isEmpty)
    }

    // MARK: - Probe budget

    /// A candidate table larger than the per-tick budget is probed in bounded
    /// slices that still cover every path over a few ticks.
    @Test func probeBatchIsBoundedAndCoversEveryCandidateOverSeveralTicks() {
        let source = UbiquityTransferSource()
        let base = Date(timeIntervalSince1970: 0)
        let paths = (0..<600).map { "/Users/tester/Documents/f\($0).bin" }
        source.ingestForTesting(paths: paths, at: base)

        var seen = Set<String>()
        var ticks = 0
        while seen.count < paths.count, ticks < 10 {
            let batch = source.probeBatchForTesting()
            #expect(batch.count <= UbiquityTransferSource.probeBudget,
                    "each tick stays inside the probe budget")
            seen.formUnion(batch)
            ticks += 1
        }
        #expect(seen == Set(paths), "the round-robin cursor covered the whole table")
        #expect(ticks <= 3, "600 paths at 256/tick is covered in 3 ticks")
    }

    // MARK: - Fault tolerance

    /// Probe results are per-item and independent: a nonsense or non-ubiquitous
    /// entry is skipped, and the good ones still map. Nothing throws.
    @Test func garbageProbeResultsAreSkippedNotFatal() {
        let good = UbiquityProbeResult(
            path: "/Users/tester/Desktop/deck.key", name: "deck.key", sizeBytes: 900,
            isUbiquitous: true, isUploading: true, isDownloading: false
        )
        let notUbiquitous = UbiquityProbeResult(
            path: "/tmp/local.txt", name: "local.txt", sizeBytes: 1,
            isUbiquitous: false, isUploading: true, isDownloading: false
        )
        let empty = UbiquityProbeResult(
            path: "", name: "", sizeBytes: -1, isUbiquitous: true,
            isUploading: false, isDownloading: false
        )

        let items = UbiquityTransferSource.transferItems(
            from: [notUbiquitous, empty, good], homeDirectory: home
        )
        #expect(items.count == 1)
        #expect(items.first?.name == "deck.key")
        #expect(items.first?.appID == "desktop-documents")
    }

    @Test func downloadsAreDistinguishedFromUploads() throws {
        let incoming = UbiquityProbeResult(
            path: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/in.zip",
            name: "in.zip", sizeBytes: 42, isUbiquitous: true,
            isUploading: false, isDownloading: true
        )
        let item = try #require(UbiquityTransferSource.transferItems(
            from: [incoming], homeDirectory: home
        ).first)
        #expect(item.direction == .download)
    }

    // MARK: - Evidence: why the old mechanisms were dropped

    /// `brctl monitor com.apple.CloudDocs` was captured live across a 120 MB
    /// upload. It emits its banner and NOTHING else — it is an entitled
    /// NSMetadataQuery wrapper, same dead channel as the query itself. This
    /// fixture exists so nobody re-adopts it on the strength of the man page.
    @Test func brctlMonitorReportsNoItemEventsDuringARealUpload() throws {
        let raw = try String(contentsOf: fixtureURL("brctl-monitor-live-upload.txt"), encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("observing in "))
    }
}
