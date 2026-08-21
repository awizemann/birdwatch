import Testing
@testable import Birdwatch
import Foundation

/// The menu-bar sparkline used to be `.accessibilityHidden(true)` — the only
/// bandwidth figure in the popover, and silent. Its spoken value is derived
/// from the same samples the bars are drawn from, and it must keep saying the
/// figures are estimated (C2) and never invent traffic that is not in the
/// series (C1).
@MainActor
struct PopoverAccessibilityTests {
    private func hours(_ totals: [Int64]) -> [BandwidthHourSample] {
        totals.enumerated().map { hour, total in
            // Split across both directions so the summary has to add them.
            BandwidthHourSample(hour: hour, uploadedBytes: total / 2, downloadedBytes: total - total / 2)
        }
    }

    @Test("The summary reports the sample count, the peak hour and the total")
    func summaryReportsSeriesFacts() {
        let value = Sparkline.summary(of: hours([1_000_000, 5_000_000, 2_000_000]))
        #expect(value.hasPrefix("3 hours, "))
        #expect(value.contains("peak \(Format.size(5_000_000)) in one hour"))
        #expect(value.contains("\(Format.size(8_000_000)) in total"))
    }

    @Test("A single sample is not pluralized")
    func singleSampleWording() {
        #expect(Sparkline.summary(of: hours([4_000_000])).hasPrefix("1 hour, "))
    }

    @Test("An all-zero series says there was no traffic instead of implying some")
    func silentSeriesSaysSo() {
        let value = Sparkline.summary(of: hours([0, 0, 0, 0]))
        #expect(value == "4 hours, no traffic recorded")
        #expect(!value.contains("peak"))
    }

    @Test("An empty series does not claim traffic either")
    func emptySeries() {
        #expect(Sparkline.summary(of: []) == "0 hours, no traffic recorded")
    }

    @Test("The peak is a real sample, never a mean or an interpolation")
    func peakIsAnActualSample() {
        let totals: [Int64] = [3_000_000, 7_000_000, 1_000_000]
        let value = Sparkline.summary(of: hours(totals))
        // The bars sum the two directions per hour; the peak must be one of
        // those hourly totals, not an average of them.
        #expect(value.contains(Format.size(7_000_000)))
        #expect(!value.contains(Format.size(totals.reduce(0, +) / Int64(totals.count))))
    }
}
