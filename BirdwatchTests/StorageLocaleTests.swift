import Foundation
import Testing
@testable import Birdwatch

@MainActor
@Suite("Storage — locale-aware numbers and the contested plan card")
struct StorageLocaleTests {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    // Fails on the old parser, which read "1,000" as 1 GB.
    @Test("Custom totals parse in the user's locale; ambiguous input is rejected")
    func customParse() {
        #expect(PlanPromptChoice.customCap(text: "1,000", isTB: false, locale: us) == 1_000_000_000_000)
        #expect(PlanPromptChoice.customCap(text: "2.2", isTB: true, locale: us) == 2_200_000_000_000)
        #expect(PlanPromptChoice.customCap(text: "2,2", isTB: true, locale: us) == nil, "neither 22 nor 2.2 is guessed")
        #expect(PlanPromptChoice.customCap(text: "2,2", isTB: true, locale: de) == 2_200_000_000_000)
        #expect(PlanPromptChoice.customCap(text: "1.000", isTB: false, locale: de) == 1_000_000_000_000)
        #expect(PlanPromptChoice.customCap(text: "1.5.0", isTB: true, locale: us) == nil)
        #expect(PlanPromptChoice.seed(for: 2_200_000_000_000, locale: de).customText == "2,2")
    }

    // Fails on the fixed "%.1f GB" ("Derived from 6780.0 GB remaining").
    @Test("One capacity formatter, in the user's locale")
    func capacityLocale() {
        #expect(Format.capacity(6_780_000_000_000, locale: us) == "6.78 TB")
        #expect(Format.capacity(6_780_000_000_000, locale: de) == "6,78 TB")
        #expect(Format.capacity(205_330_000_000, locale: us) == "205.3 GB")
        #expect(Format.percent(0.54, locale: us) == "54%")
    }

    @Test("A plan setting the quota contradicts is marked contested on the plan card")
    func contestedPlanCard() throws {
        let derived = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: [.documents: 91_000_000_000], remainingBytes: 6_780_000_000_000, planCapOverride: nil))
        let tooSmall = try #require(SyncStore.applyPlanCap(2_000_000_000_000, to: derived))
        #expect(StorageCapLabel.planCardLine(tooSmall).hasPrefix("Set by you — contested"))
        let fine = try #require(SyncStore.applyPlanCap(8_000_000_000_000, to: derived))
        #expect(StorageCapLabel.planCardLine(fine) == "Set by you")
    }
}
