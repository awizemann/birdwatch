import Foundation
import Testing
@testable import Birdwatch

/// Real captured fixtures live next to this file; #filePath keeps loading
/// independent of bundle resource phases (test-only, acceptable here).
private nonisolated func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("BrctlParser")
struct BrctlParserTests {

    @Test func parsesRealStatusFixture() throws {
        let status = BrctlParser.parseStatus(try fixture("brctl-status.txt"))

        #expect(status.isIdle == true)
        #expect(status.clientState == "idle")
        #expect(status.serverState == "full-sync|fetched-recents|fetched-favorites|ever-full-sync")

        // Exact timestamp from the fixture: 2026-08-14 16:39:27.209 local time.
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 14
        components.hour = 16; components.minute = 39; components.second = 27
        components.nanosecond = 209_000_000
        components.timeZone = .current
        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
        let lastSync = try #require(status.lastSync)
        #expect(abs(lastSync.timeIntervalSince(expected)) < 0.001)

        let token = try #require(status.tokenInfo)
        #expect(token.contains("HwoFCJqQswUYACIWCN+PpcOgt66ZggEQuNu2iaKAuNuhASgA"))
    }

    @Test func capturesDesktopAndDocumentsAppLine() throws {
        let status = BrctlParser.parseStatus(try fixture("brctl-status.txt"))
        let app = try #require(status.apps.first { $0.name == "Desktop & Documents" })
        #expect(app.isCurrent == true)
        #expect(status.apps.count == 1)
    }

    @Test func stripsANSIEscapes() throws {
        let raw = try fixture("brctl-status.txt")
        #expect(raw.contains("\u{1B}["))                      // fixture really has color codes
        let stripped = BrctlParser.stripANSI(raw)
        #expect(!stripped.contains("\u{1B}"))
        #expect(stripped.contains("foreground"))              // colored word survives intact
    }

    @Test func parsesRealQuotaFixture() throws {
        #expect(BrctlParser.parseQuota(try fixture("brctl-quota.txt")) == 220_606_297_196)
    }

    @Test func mangledInputYieldsEmptyParseWithoutThrowing() {
        let garbage = "??? totally unknown format ###\nclient state broken\n12345"
        let status = BrctlParser.parseStatus(garbage)
        #expect(status.clientState == nil)
        #expect(status.serverState == nil)
        #expect(status.lastSync == nil)
        #expect(status.isIdle == false)
        #expect(status.apps.isEmpty)

        #expect(BrctlParser.parseQuota(garbage) == nil)
        #expect(BrctlParser.parseQuota("") == nil)
    }

    @Test func unknownLinesAreSkippedNotFatal() {
        // Future format drift: known tokens still parse amid unknown lines.
        let drifted = """
        future-header: v99
        <container {client:syncing server:partial last-sync:2030-01-02 03:04:05.000, new-field:xyz}>
        SomeNewApp: current=NO lastEnabled=(never)
        trailing junk line
        """
        let status = BrctlParser.parseStatus(drifted)
        #expect(status.clientState == "syncing")
        #expect(status.isIdle == false)
        #expect(status.serverState == "partial")
        #expect(status.lastSync != nil)
        #expect(status.apps == [BrctlAppLine(name: "SomeNewApp", isCurrent: false)])
    }
}
