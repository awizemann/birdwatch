import Foundation

/// The home folder every real-root default in Birdwatch hangs off
/// (~/Library/Mobile Documents, ~/Library/CloudStorage, ~/Desktop,
/// ~/Documents, the Full Disk Access probe files).
///
/// Under XCTest it is a throwaway folder in the temporary directory, never
/// the person's real home: a test that forgets to inject a temp root then
/// reads an empty folder instead of iCloud Drive — which, without Full Disk
/// Access, would raise macOS 27's iCloud Drive prompt for the test host.
/// `UserHomeGuardTests` fails if any source reaches for `NSHomeDirectory()`
/// directly again.
nonisolated enum UserHome {
    static let path: String = resolve(
        environment: ProcessInfo.processInfo.environment,
        realHome: NSHomeDirectory(),
        temporaryDirectory: NSTemporaryDirectory()
    )

    /// True when the process is an XCTest host (the app is its own).
    static func isRunningTests(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil
    }

    /// Pure, so the rule is testable without being a test host.
    ///
    /// Debug builds only (tests run Debug): in a Release build the
    /// environment is never consulted, so a user-set XCTest variable cannot
    /// point the shipping app at a temp folder.
    static func resolve(environment: [String: String], realHome: String, temporaryDirectory: String) -> String {
        #if DEBUG
        guard isRunningTests(environment) else { return realHome }
        return (temporaryDirectory as NSString).appendingPathComponent("birdwatch-test-home")
        #else
        return realHome
        #endif
    }
}
