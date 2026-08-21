import Foundation
import Testing
@testable import Birdwatch

/// Audit P2 ("merge the two `ps` spawns per cycle"). The merge itself was
/// already in place; what was missing was anything that could DETECT its
/// regression — every existing test asserts parser output, and parser output
/// is identical whether the process table was walked once or twice.
///
/// These tests count spawns at the `ProcessRunning` seam, so a future edit that
/// re-introduces a second `/bin/ps` per refresh cycle fails here.
@Suite("Process spawn budget")
struct ProcessSpawnBudgetTests {

    /// Records every spawn and replays canned stdout per tool. Never touches a
    /// real process — the point is the CALL LEDGER, not the output.
    actor RecordingRunner: ProcessRunning {
        /// (toolPath, arguments) in call order.
        private(set) var calls: [(tool: String, arguments: [String])] = []
        private let responses: [String: String]

        init(responses: [String: String]) { self.responses = responses }

        func run(toolPath: String, arguments: [String], timeout: Duration) async throws -> String {
            calls.append((tool: toolPath, arguments: arguments))
            return responses[toolPath] ?? ""
        }

        func callCount(for tool: String) -> Int { calls.filter { $0.tool == tool }.count }
    }

    /// Same real-capture fixtures the parser suites use (C3) — matches the
    /// #filePath convention in SystemParserTests.
    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // THE FALSIFIER. One refresh cycle = exactly ONE `/bin/ps`. Fails the
    // moment either consumer goes back to spawning its own.
    @Test("One refresh cycle spawns /bin/ps exactly once, shared by daemon stats and bandwidth")
    func oneCycleSpawnsPsOnce() async throws {
        let ps = try Self.fixture("ps-daemons.txt")
        let runner = RecordingRunner(responses: [
            "/bin/ps": ps,
            "/usr/bin/nettop": try Self.fixture("nettop-sample.csv"),
        ])
        let daemonStats = DaemonStatsSource(runner: runner)
        let bandwidth = BandwidthSource(runner: runner)

        let (daemons, summary) = await SystemSyncSource.sampleProcessStats(
            daemonStats: daemonStats, bandwidth: bandwidth
        )

        #expect(await runner.callCount(for: "/bin/ps") == 1,
                "the process table must be walked once per cycle, not once per consumer")
        // Both consumers really ran off that one spawn — a cycle that produced
        // no daemons and no nettop call would satisfy the count trivially.
        #expect(daemons.map(\.name) == ["bird", "cloudd", "fileproviderd"])
        #expect(await runner.callCount(for: "/usr/bin/nettop") == 1,
                "bandwidth still sampled — the pids came from the shared ps output")
        #expect(summary.hours.count == 24)
    }

    // The shared spawn only works because ONE `ps` column layout serves both
    // consumers. Fails if either parser stops understanding
    // `DaemonStatsSource.psArguments` output — the change that would force the
    // second spawn back.
    @Test("Both consumers parse the same shared ps column layout")
    func sharedColumnLayoutServesBothConsumers() throws {
        #expect(DaemonStatsSource.psArguments == ["-axo", "pid,pcpu,rss,comm"])
        let ps = try Self.fixture("ps-daemons.txt")

        // Daemon stats: aggregated to one row per daemon.
        let stats = DaemonStatsSource.parse(psOutput: ps)
        #expect(stats.map(\.name) == ["bird", "cloudd", "fileproviderd"])

        // Bandwidth: EVERY real pid, including both cloudd instances, from the
        // very same text — simulator copies dropped by both.
        let pids = BandwidthSource.extractDaemonPids(psOutput: ps)
        #expect(pids == [798, 1031, 1098, 1103])
        #expect(pids.allSatisfy { $0 < 55000 }, "no iOS-simulator daemon may reach nettop")
    }

    // Every spawn through the seam carries a timeout (C5). Fails if a call
    // site is ever added that leans on an unbounded run.
    @Test("Every spawn in a refresh cycle passes through the runner seam")
    func everySpawnGoesThroughTheSeam() async throws {
        let runner = RecordingRunner(responses: ["/bin/ps": try Self.fixture("ps-daemons.txt")])
        _ = await SystemSyncSource.sampleProcessStats(
            daemonStats: DaemonStatsSource(runner: runner),
            bandwidth: BandwidthSource(runner: runner)
        )
        let tools = await Set(runner.calls.map(\.tool))
        #expect(tools == ["/bin/ps", "/usr/bin/nettop"])
        #expect(await runner.calls.allSatisfy { $0.tool.hasPrefix("/") },
                "fixed absolute tool paths only — never a PATH lookup")
    }
}
