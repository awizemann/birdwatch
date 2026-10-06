import Foundation
import Testing
@testable import Birdwatch

@Suite("CloudKit notice window")
struct CloudKitWindowNoticeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // Fails on the old notice, which always said "30 minutes" — even when the
    // scan had fallen back to reading only the last 10.
    @Test("\"No CloudKit activity\" names the window the scan actually read")
    func noActivityUsesScanWindow() {
        let fallback = CloudKitScanState(CloudKitScan(apps: [], outcome: .noActivity, observedAt: Self.now,
                                                      windowMinutes: CloudKitAppSource.fallbackWindowMinutes))
        #expect(CloudKitNotice.text(fallback, now: Self.now) == "No CloudKit activity in the last 10 minutes.")
        let primary = CloudKitScanState(CloudKitScan(apps: [], outcome: .noActivity, observedAt: Self.now))
        #expect(CloudKitNotice.text(primary, now: Self.now) == "No CloudKit activity in the last 30 minutes.")
    }

    // A capped read saw only part of the window, so "none in the last 10
    // minutes" would claim more than was read.
    @Test("A truncated read with no activity claims only the part it read")
    func truncatedNoActivity() throws {
        let capped = CloudKitScanState(CloudKitScan(apps: [], outcome: .noActivity, observedAt: Self.now,
                                                    isTruncated: true,
                                                    windowMinutes: CloudKitAppSource.fallbackWindowMinutes))
        let text = try #require(CloudKitNotice.text(capped, now: Self.now))
        #expect(!text.contains("in the last"))
        #expect(text.contains("in the part of the log that was read"))
    }
}
