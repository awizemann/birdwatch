import Testing
@testable import Birdwatch

/// The Sparkle gates as a pure function: each test flips exactly one input
/// from the enabled baseline, so each gate is shown to matter on its own.
@Suite("Sparkle updater gate")
struct UpdaterGateTests {

    private static let key = "aGVsbG8tdGhpcy1pcy1hLXRlc3Qta2V5"

    private static func enabled(
        bundleID: String? = BirdwatchApp.releaseBundleID,
        publicKey: String? = key,
        arguments: [String] = ["/Applications/Birdwatch.app/Contents/MacOS/Birdwatch"],
        isRunningTests: Bool = false
    ) -> Bool {
        BirdwatchApp.isUpdaterEnabled(
            bundleID: bundleID, publicKey: publicKey, arguments: arguments, isRunningTests: isRunningTests
        )
    }

    @Test("A release build with a real key checks for updates")
    func releaseIsEnabled() {
        #expect(Self.enabled())
    }

    // Fails on the old gate: the dogfood copy carries the real key, so it
    // polled the release feed for updates it can never install.
    @Test("The .dev dogfood build never polls the feed")
    func devBuildIsDisabled() {
        #expect(!Self.enabled(bundleID: "com.wizemann.birdwatch.dev"))
        #expect(!Self.enabled(bundleID: nil))
    }

    @Test("Tests, --mock and a missing or placeholder key each disable it")
    func otherGates() {
        #expect(!Self.enabled(isRunningTests: true))
        #expect(!Self.enabled(arguments: ["Birdwatch", "--mock"]))
        #expect(!Self.enabled(publicKey: nil))
        #expect(!Self.enabled(publicKey: ""))
        #expect(!Self.enabled(publicKey: "REPLACE_WITH_PUBLIC_ED_KEY"))
    }
}
