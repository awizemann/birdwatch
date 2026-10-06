import Foundation
import Testing
@testable import Birdwatch

@Suite struct SystemParserTests {

    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - LogStreamParser

    @Test func ndjsonHeaderLineParsesToNil() throws {
        let header = try Self.fixture("logstream.ndjson")
            .split(separator: "\n").first.map(String.init) ?? ""
        #expect(header.hasPrefix("Filtering the log data"))
        #expect(LogStreamParser.parse(line: header) == nil)
    }

    /// Real `log stream --style ndjson --level info --predicate 'subsystem ==
    /// "com.apple.clouddocs"'` output captured on macOS 27.0 (26A428),
    /// 2026-10-05: the header, four bird events, and the
    /// `{"count":N,"finished":1}` trailer `log` prints when a stream ends.
    @Test func realNdjsonLinesParseExactly() throws {
        let lines = try Self.fixture("logstream.ndjson").split(separator: "\n").map(String.init)
        #expect(lines.count == 6)
        let parsed = lines.compactMap(LogStreamParser.parse(line:))
        #expect(parsed.count == 4, "header and trailer are not log events")

        let first = try #require(parsed.first)
        #expect(first.message == "[INFO] <private>: reply(<private>, (null))")
        #expect(first.level == .info)
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 5
        components.hour = 22; components.minute = 21; components.second = 20
        components.timeZone = TimeZone(secondsFromGMT: -4 * 3600)
        let expected = Calendar(identifier: .gregorian).date(from: components)!
        #expect(abs(first.date.timeIntervalSince(expected) - 0.379080) < 0.001)
        #expect(parsed.map(\.date) == parsed.map(\.date).sorted(), "fixture lines are in stream order")
    }

    // Fails on the old parser, which turned the trailer into a blank row
    // stamped with the time it was parsed (C1).
    @Test func streamTrailerIsNotALogLine() throws {
        let trailer = try Self.fixture("logstream.ndjson")
            .split(separator: "\n").last.map(String.init) ?? ""
        #expect(trailer.contains("\"finished\""))
        #expect(LogStreamParser.parse(line: trailer) == nil)
    }

    @Test(arguments: [
        ("Debug", LogLevel.debug),
        ("Error", LogLevel.error),
        ("Fault", LogLevel.error),
        ("Default", LogLevel.info),
        ("SomethingNew", LogLevel.info),
    ])
    func messageTypeMapping(type: String, expected: LogLevel) {
        let line = #"{"eventMessage":"m","timestamp":"2026-08-14 10:22:33.000000-0700","messageType":"\#(type)"}"#
        #expect(LogStreamParser.parse(line: line)?.level == expected)
    }

    @Test func garbageLinesParseToNilWithoutThrowing() {
        for garbage in ["", "not json", "{broken json", "[1,2,3]", "{\"a\":}"] {
            #expect(LogStreamParser.parse(line: garbage) == nil)
        }
    }

    // Fails on the old parser: `{}` became a blank row, and a missing or
    // unparseable timestamp was replaced with Date() — a fabricated time (C1).
    @Test func objectsWithoutAnEventOrTimestampAreSkipped() {
        #expect(LogStreamParser.parse(line: "{}") == nil)
        #expect(LogStreamParser.parse(line: #"{"eventMessage":"m","messageType":"Default"}"#) == nil)
        #expect(LogStreamParser.parse(line: #"{"eventMessage":"m","timestamp":"yesterday"}"#) == nil)
        #expect(LogStreamParser.parse(line: #"{"timestamp":"2026-08-14 10:22:33.000000-0700"}"#) == nil)
    }

    // MARK: - DaemonStatsSource.parse

    @Test func psFixtureExcludesSimulatorAndAggregatesCloudd() throws {
        let stats = DaemonStatsSource.parse(psOutput: try Self.fixture("ps-daemons.txt"))

        #expect(stats.count == 3)
        #expect(Set(stats.map(\.name)) == ["bird", "cloudd", "fileproviderd"])
        // No simulator PIDs (55912+) may survive.
        #expect(stats.allSatisfy { ($0.pid ?? 0) < 55000 })

        let cloudd = try #require(stats.first { $0.name == "cloudd" })
        #expect(abs(cloudd.memoryMB - Double(5040 + 24640) / 1024) < 0.001)
        #expect(cloudd.pid == 798)
        #expect(cloudd.role == "CloudKit sync")

        let bird = try #require(stats.first { $0.name == "bird" })
        #expect(bird.pid == 1098)
        #expect(abs(bird.memoryMB - 29872.0 / 1024) < 0.001)
    }

    @Test func psGarbageInputYieldsEmptyWithoutThrowing() {
        #expect(DaemonStatsSource.parse(psOutput: "").isEmpty)
        #expect(DaemonStatsSource.parse(psOutput: "total nonsense\n???\n").isEmpty)
        #expect(DaemonStatsSource.parse(psOutput: "  PID  %CPU  RSS COMM\n").isEmpty)
    }
}
