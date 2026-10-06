import Foundation
import Testing
@testable import Birdwatch

/// Tests must never read the person's real home: without Full Disk Access a
/// read of ~/Library/Mobile Documents raises macOS 27's iCloud Drive prompt
/// for the test host. Every real-root default goes through `UserHome.path`,
/// which is a temp folder under XCTest; these pin that rule and that no
/// source bypasses it.
@Suite("Real home is never read under tests")
struct UserHomeGuardTests {

    @Test("Under XCTest UserHome is a temp folder, not the real home")
    func testHostHomeIsTemporary() throws {
        let entry = try #require(getpwuid(getuid()))
        let real = String(cString: entry.pointee.pw_dir)
        #expect(UserHome.path != real)
        #expect(UserHome.path != NSHomeDirectory())
        #expect(UserHome.path.hasPrefix(NSTemporaryDirectory()))
    }

    @Test("Outside tests UserHome is the real home")
    func appHomeIsReal() {
        #expect(UserHome.resolve(environment: [:], realHome: "/Users/x", temporaryDirectory: "/tmp/") == "/Users/x")
        #expect(UserHome.resolve(environment: ["XCTestSessionIdentifier": "1"], realHome: "/Users/x", temporaryDirectory: "/tmp/")
                == "/tmp/birdwatch-test-home")
    }

    // The regression guard: a new `NSHomeDirectory()` (or `~` expansion) in
    // app code would read the real home from tests again.
    @Test("No app source reaches for the home folder except through UserHome")
    func noDirectHomeAccess() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Birdwatch")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "UserHome.swift" }
        #expect(files.count > 20, "found the app sources")
        let banned = ["NSHomeDirectory()", "expandingTildeInPath", "homeDirectoryForCurrentUser", "FileManager.default.homeDirectory"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in banned {
                #expect(!text.contains(token), "\(file.lastPathComponent) uses \(token); go through UserHome.path")
            }
        }
    }
}
