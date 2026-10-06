import Foundation
import Testing
@testable import Birdwatch

@Suite("Component decisions")
struct ComponentDecisionTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let english = Locale(identifier: "en_US")

    private func label(_ offset: TimeInterval, locale: Locale = english) -> String {
        RelativeTimeLabel.text(for: Self.now.addingTimeInterval(offset), now: Self.now, locale: locale)
    }

    // The old view appended a literal " ago" to a self-counting relative
    // date: a future date read "in 5 minutes ago".
    @Test("A future date reads as future, never with \"ago\"")
    func futureDate() {
        let text = label(300)
        #expect(text.hasPrefix("in "))
        #expect(!text.contains("ago"))
    }

    // Structural, not exact ICU strings: the formatter's abbreviations may
    // change between OS releases; what matters is what it never says.
    @Test("A past date is relative, in minutes or coarser — no seconds count")
    func pastDate() {
        let fiveMinutes = label(-300)
        #expect(fiveMinutes.contains("ago"))
        #expect(fiveMinutes.contains("5"))
        #expect(!fiveMinutes.contains("sec"))
        #expect(label(-184) == label(-180), "seconds are dropped, not spelled out")
        #expect(!label(-3_800).contains("sec"))
    }

    @Test("Inside a minute it says so instead of counting seconds")
    func underAMinute() {
        let text = label(-30)
        #expect(text == label(0), "any age under a minute reads the same")
        #expect(!text.contains("sec"))
        let hasDigit = text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        #expect(!hasDigit, "no count at all")
    }

    // The old " ago" was a hard-coded English string.
    @Test("The whole phrase is localized, not just the number")
    func localized() {
        let german = label(-300, locale: Locale(identifier: "de_DE"))
        #expect(!german.contains("ago"))
        #expect(german.contains("5"))
        #expect(german != label(-300))
    }

    // The retry bar's fill is attempts / max attempts; it was announced as
    // "19 percent", as if 19% of some work were done.
    @Test("A bar that counts something says the count, not a percent")
    func retryBarValue() {
        let value = MiniProgressBar.spokenValue(progress: 12.0 / 62.0, indeterminate: false,
                                                valueDescription: "attempt 12 of 62")
        #expect(value == "attempt 12 of 62")
        #expect(!value.contains("percent"))
        // Ordinary bars are unchanged.
        #expect(MiniProgressBar.spokenValue(progress: 0.42, indeterminate: false, valueDescription: nil) == "42 percent")
        #expect(MiniProgressBar.spokenValue(progress: 0, indeterminate: true, valueDescription: nil) == "In progress")
    }

    // Activity rows conveyed warning/conflict/done only by icon or dot colour,
    // both hidden from VoiceOver.
    @Test("Activity kinds that only colour conveyed are spoken")
    func activityKindIsSpoken() {
        #expect(ActivityKind.warning.spokenKind == "Warning")
        #expect(ActivityKind.conflict.spokenKind == "Conflict")
        #expect(ActivityKind.done.spokenKind == "Done")
        // The title already says "Uploading …" / "Downloading …".
        #expect(ActivityKind.upload.spokenKind == nil)
        #expect(ActivityKind.info.spokenKind == nil)
    }

    // Settings showed `planName` alone, so a derived cap read as fact (C2).
    @Test("Settings states the plan with its provenance")
    func settingsPlanProvenance() throws {
        let totals: [StorageCategory: Int64] = [.documents: 100_000_000_000]
        let derived = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: totals, remainingBytes: 60_000_000_000, planCapOverride: nil))
        #expect(derived.capSource == .derived)
        let estimated = StorageCapLabel.settingsPlanText(derived)
        #expect(estimated.text.hasPrefix("≈ "))
        #expect(estimated.text.contains("estimated"))
        #expect(estimated.spoken.contains("estimated"))
        #expect(!estimated.spoken.contains("≈"))

        let chosen = try #require(SyncStore.applyPlanCap(2_000_000_000_000, to: derived))
        #expect(StorageCapLabel.settingsPlanText(chosen).text.hasSuffix("set by you"))

        let contested = try #require(SyncStore.applyPlanCap(50_000_000_000, to: derived))
        #expect(contested.planCapBelowRemaining)
        #expect(StorageCapLabel.settingsPlanText(contested).text.contains("contested"))

        #expect(StorageCapLabel.settingsPlanText(nil).text == "Not known yet")
    }

    @Test("A status dot pulses only when asked and Reduce Motion is off")
    func statusDotPulse() {
        #expect(StatusDot.shouldPulse(pulses: true, reduceMotion: false))
        #expect(!StatusDot.shouldPulse(pulses: true, reduceMotion: true))
        #expect(!StatusDot.shouldPulse(pulses: false, reduceMotion: false))
    }
}
