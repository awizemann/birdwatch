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

    @Test func realNdjsonLineParsesExactly() throws {
        let line = #"{"traceID":123,"eventMessage":"upload finished for item 42","eventType":"logEvent","timestamp":"2026-08-14 10:22:33.123456-0700","messageType":"Default","processImagePath":"/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird","subsystem":"com.apple.clouddocs"}"#
        let parsed = try #require(LogStreamParser.parse(line: line))
        #expect(parsed.message == "upload finished for item 42")
        #expect(parsed.level == .info)

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 14
        components.hour = 10; components.minute = 22; components.second = 33
        components.timeZone = TimeZone(secondsFromGMT: -7 * 3600)
        let expected = Calendar(identifier: .gregorian).date(from: components)!
        #expect(abs(parsed.date.timeIntervalSince(expected) - 0.123456) < 0.001)
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

    @Test func missingFieldsDegradeGracefully() {
        let parsed = LogStreamParser.parse(line: "{}")
        #expect(parsed != nil)
        #expect(parsed?.message == "")
        #expect(parsed?.level == .info)
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
