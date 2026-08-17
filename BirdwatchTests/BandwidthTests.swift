import Foundation
import Testing
@testable import Birdwatch

@Suite struct BandwidthTests {

    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // A UTC calendar + fixed dates make the day/hour math deterministic.
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: - parseNettop

    @Test func parsesRealCapturedCSV() throws {
        // Captured on this machine: nettop -P -x -L 1 -p 798 -p 1031 -p 1098 -p 1103.
        // Only cloudd.1031 had network activity — nettop omits idle processes.
        let csv = try Self.fixture("nettop-sample.csv")
        let rows = BandwidthSource.parseNettop(csv: csv)
        #expect(rows.count == 1)
        #expect(rows[0].pid == 1031)
        #expect(rows[0].bytesIn == 14958)
        #expect(rows[0].bytesOut == 14341)
    }

    @Test func parseSkipsHeaderAndGarbage() {
        let csv = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe
        garbage line without commas
        17:35:41.917883,cloudd.1031,,,100,200,0
        17:35:41.917883,noPidHere,,,1,2,0
        17:35:41.917883,bird.1098,,,notanumber,2,0
        17:35:41.917883,bird.1098,,,300,400,0
        """
        let rows = BandwidthSource.parseNettop(csv: csv)
        #expect(rows.map(\.pid) == [1031, 1098])
        #expect(rows.map(\.bytesIn) == [100, 300])
        #expect(rows.map(\.bytesOut) == [200, 400])
    }

    // MARK: - extractDaemonPids

    @Test func pidExtractionFiltersSimulatorCopies() throws {
        let ps = """
          PID COMM
          798 /System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd
         1031 /System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd
         1098 /System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird
         1213 /System/Library/PrivateFrameworks/iTunesCloud.framework/Support/itunescloudd
        55941 /Library/Developer/CoreSimulator/Volumes/iOS_23C54/x/RuntimeRoot/System/Library/PrivateFrameworks/iCloudDriveCore.framework/bird
        """
        // Both cloudd instances kept, simulator bird dropped, itunescloudd (wrong basename) dropped.
        #expect(BandwidthSource.extractDaemonPids(psOutput: ps) == [798, 1031, 1098])
    }

    // MARK: - Delta logic

    @Test func firstSampleEstablishesBaselineOnly() {
        let now = Self.date(2026, 8, 14, 10)
        let s = BandwidthSource.advance(
            state: .init(),
            readings: [1031: .init(bytesIn: 5000, bytesOut: 7000)],
            now: now, calendar: Self.utc
        )
        #expect(s.uploadedTodayBytes == 0)
        #expect(s.downloadedTodayBytes == 0)
        #expect(s.currentRateBytesPerSec == 0)
    }

    @Test func normalIncreaseYieldsDelta() {
        let t0 = Self.date(2026, 8, 14, 10, 0)
        let t1 = Self.date(2026, 8, 14, 10, 0, 10)
        var s = BandwidthSource.advance(
            state: .init(), readings: [1031: .init(bytesIn: 1000, bytesOut: 2000)],
            now: t0, calendar: Self.utc
        )
        s = BandwidthSource.advance(
            state: s, readings: [1031: .init(bytesIn: 1500, bytesOut: 2100)],
            now: t1, calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 500)
        #expect(s.uploadedTodayBytes == 100)
        // (500 + 100) bytes over 10 seconds.
        #expect(s.currentRateBytesPerSec == 60)
        #expect(s.hourDownloaded[10] == 500)
        #expect(s.hourUploaded[10] == 100)
    }

    @Test func cumulativeDecreaseClampsToZero() {
        let t0 = Self.date(2026, 8, 14, 10, 0)
        let t1 = Self.date(2026, 8, 14, 10, 0, 10)
        var s = BandwidthSource.advance(
            state: .init(), readings: [1031: .init(bytesIn: 9000, bytesOut: 9000)],
            now: t0, calendar: Self.utc
        )
        // Daemon restarted: counters below baseline → zero delta, new baseline kept.
        s = BandwidthSource.advance(
            state: s, readings: [1031: .init(bytesIn: 100, bytesOut: 50)],
            now: t1, calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 0)
        #expect(s.uploadedTodayBytes == 0)
        #expect(s.lastCumulative[1031] == .init(bytesIn: 100, bytesOut: 50))
    }

    @Test func sameDayAccumulatesAcrossHours() {
        var s = BandwidthSource.advance(
            state: .init(), readings: [1: .init(bytesIn: 0, bytesOut: 0)],
            now: Self.date(2026, 8, 14, 9), calendar: Self.utc
        )
        s = BandwidthSource.advance(
            state: s, readings: [1: .init(bytesIn: 100, bytesOut: 10)],
            now: Self.date(2026, 8, 14, 9, 30), calendar: Self.utc
        )
        s = BandwidthSource.advance(
            state: s, readings: [1: .init(bytesIn: 300, bytesOut: 40)],
            now: Self.date(2026, 8, 14, 11), calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 300)
        #expect(s.uploadedTodayBytes == 40)
        #expect(s.hourDownloaded[9] == 100)
        #expect(s.hourDownloaded[11] == 200)
        #expect(s.hourUploaded[9] == 10)
        #expect(s.hourUploaded[11] == 30)
    }

    @Test func dayRolloverResetsTotalsAndHourBuffer() {
        var s = BandwidthSource.advance(
            state: .init(), readings: [1: .init(bytesIn: 0, bytesOut: 0)],
            now: Self.date(2026, 8, 14, 23), calendar: Self.utc
        )
        s = BandwidthSource.advance(
            state: s, readings: [1: .init(bytesIn: 500, bytesOut: 500)],
            now: Self.date(2026, 8, 14, 23, 30), calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 500)
        // Next sample lands on the 15th: totals and buffer reset, but the
        // delta earned across midnight still counts toward the NEW day.
        s = BandwidthSource.advance(
            state: s, readings: [1: .init(bytesIn: 600, bytesOut: 550)],
            now: Self.date(2026, 8, 15, 0, 5), calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 100)
        #expect(s.uploadedTodayBytes == 50)
        #expect(s.hourDownloaded[23] == 0)   // yesterday's slot zeroed
        #expect(s.hourDownloaded[0] == 100)
    }

    // Audit open question #4, adjudicated: "accept as estimated". When a sample
    // yields NO readings (nettop failed, or every daemon was momentarily
    // absent), `advance` stores an EMPTY lastCumulative, so the next real
    // reading is treated as a first sighting and only re-establishes a
    // baseline. Traffic that happened across the gap is therefore NOT counted.
    // This test pins that accepted undercount deliberately: if someone later
    // decides to merge baselines instead, this test must be updated on purpose,
    // not silently.
    @Test func gapWithNoReadingsRebaselinesAndUndercounts() {
        let t0 = Self.date(2026, 8, 14, 10, 0)
        let t1 = Self.date(2026, 8, 14, 10, 0, 15)
        let t2 = Self.date(2026, 8, 14, 10, 0, 30)

        // Established baseline.
        var s = BandwidthSource.advance(
            state: .init(), readings: [1031: .init(bytesIn: 1_000, bytesOut: 2_000)],
            now: t0, calendar: Self.utc
        )
        // The daemons vanish from this cycle: empty readings.
        s = BandwidthSource.advance(state: s, readings: [:], now: t1, calendar: Self.utc)
        #expect(s.lastCumulative.isEmpty, "an empty sample clears the per-pid baselines")
        #expect(s.currentRateBytesPerSec == 0)

        // They come back having moved 4 MB while we weren't looking.
        s = BandwidthSource.advance(
            state: s, readings: [1031: .init(bytesIn: 3_000_000, bytesOut: 3_000_000)],
            now: t2, calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 0, "gap traffic is not counted — accepted undercount")
        #expect(s.uploadedTodayBytes == 0)
        #expect(s.currentRateBytesPerSec == 0)
        #expect(s.lastCumulative[1031] == .init(bytesIn: 3_000_000, bytesOut: 3_000_000),
                "but the new baseline is armed, so the NEXT cycle counts normally")

        // Proof the re-baseline works: the next delta is counted in full.
        s = BandwidthSource.advance(
            state: s, readings: [1031: .init(bytesIn: 3_000_100, bytesOut: 3_000_050)],
            now: Self.date(2026, 8, 14, 10, 0, 40), calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 100)
        #expect(s.uploadedTodayBytes == 50)
    }

    // nettop with `-P` can still emit one row PER INTERFACE for a single pid
    // (e.g. Wi-Fi and a VPN utun). parseNettop reports every row verbatim (it
    // is a parser, not an aggregator); `sample()` then folds duplicates with
    // `uniquingKeysWith: { a, b in a + b }`. This mirrors that exact fold, so a
    // regression to "last row wins" (which would silently drop an interface's
    // traffic) fails here.
    @Test func duplicatePidRowsAreSummedNotOverwritten() {
        let csv = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe
        17:35:41.917883,bird.1098,en0,,100,200,0
        17:35:41.917883,bird.1098,utun3,,30,40,0
        17:35:41.917883,cloudd.1031,en0,,7,8,0
        """
        let rows = BandwidthSource.parseNettop(csv: csv)
        #expect(rows.map(\.pid) == [1098, 1098, 1031], "the parser never merges — it reports rows")

        // Mirror of BandwidthSource.sample()'s uniquing.
        let merged = Dictionary(
            rows.map { ($0.pid, BandwidthSource.Reading(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut)) },
            uniquingKeysWith: { a, b in
                BandwidthSource.Reading(bytesIn: a.bytesIn + b.bytesIn, bytesOut: a.bytesOut + b.bytesOut)
            }
        )
        #expect(merged[1098] == .init(bytesIn: 130, bytesOut: 240))
        #expect(merged[1031] == .init(bytesIn: 7, bytesOut: 8))

        // And the merged cumulative feeds the delta math as one pid.
        let t0 = Self.date(2026, 8, 14, 12, 0)
        var s = BandwidthSource.advance(state: .init(), readings: merged, now: t0, calendar: Self.utc)
        s = BandwidthSource.advance(
            state: s,
            readings: [1098: .init(bytesIn: 230, bytesOut: 340), 1031: .init(bytesIn: 7, bytesOut: 8)],
            now: Self.date(2026, 8, 14, 12, 0, 10), calendar: Self.utc
        )
        #expect(s.downloadedTodayBytes == 100)
        #expect(s.uploadedTodayBytes == 100)
        #expect(s.currentRateBytesPerSec == 20)
    }

    @Test func summaryMapsStateFaithfully() {
        var state = BandwidthSource.State()
        state.uploadedTodayBytes = 7
        state.downloadedTodayBytes = 9
        state.currentRateBytesPerSec = 3
        state.hourUploaded[5] = 100
        state.hourDownloaded[5] = 200
        let summary = BandwidthSource.summary(from: state)
        #expect(summary.uploadedTodayBytes == 7)
        #expect(summary.downloadedTodayBytes == 9)
        #expect(summary.currentRateBytesPerSec == 3)
        #expect(summary.hours.count == 24)
        #expect(summary.hours[5].uploadedBytes == 100)
        #expect(summary.hours[5].downloadedBytes == 200)
    }
}
