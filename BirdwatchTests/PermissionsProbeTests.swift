import Foundation
import Testing
@testable import Birdwatch

/// The FDA probe's decision step, driven by injected existence/open closures —
/// never real TCC-protected files.
@Suite("Full Disk Access probe")
struct PermissionsProbeTests {

    private struct Refused: Error {}

    private static let files = PermissionsProbe.fdaProbeFiles(home: "/Users/test")

    private static func evaluate(
        present: Set<String>, opens: Set<String>
    ) -> PermissionsProbe.FDAProbeOutcome {
        let byLabel = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.label) })
        return PermissionsProbe.evaluateFullDiskAccess(
            files,
            exists: { present.contains(byLabel[$0] ?? "") },
            open: { if !opens.contains(byLabel[$0] ?? "") { throw Refused() } }
        )
    }

    // Fails if the always-present TCC.db fallback goes missing or stops being
    // last, or if Safari's container path (possible app-data prompt) returns.
    @Test("Probe list: legacy Safari + Messages first, system TCC.db last, no Safari container")
    func probeList() {
        let paths = Self.files.map(\.path)
        #expect(paths.first == "/Users/test/Library/Safari/CloudTabs.db")
        #expect(paths.contains("/Users/test/Library/Messages/chat.db"))
        #expect(paths.last == "/Library/Application Support/com.apple.TCC/TCC.db")
        #expect(!paths.contains { $0.contains("/Library/Containers/") })
        #expect(Set(Self.files.map(\.label)).count == Self.files.count, "labels identify the probe in logs")
    }

    // C1: "no probe file" is can't-tell, never "not granted".
    @Test("Outcome maps to a tri-state: noProbeFile is unknown, not denied")
    func stateMapping() {
        #expect(PermissionsProbe.state(for: .granted("x")) == .granted)
        #expect(PermissionsProbe.state(for: .denied) == .denied)
        #expect(PermissionsProbe.state(for: .noProbeFile) == .unknown)
    }

    // Fails on the old first-present-decides rule: macOS 27 has no legacy
    // CloudTabs.db, and a refusal on one file must not hide a grant on another.
    @Test("Any present file that opens proves the grant, even after a refusal")
    func grantedAfterRefusal() {
        let outcome = Self.evaluate(
            present: ["safari-bookmarks", "safari-history"],
            opens: ["safari-history"]
        )
        #expect(outcome == .granted("safari-history"))
    }

    // A fresh macOS 27 account (no Safari/Messages files yet) still gets an
    // answer from the TCC.db fallback.
    @Test("Fresh account: only the system TCC.db exists and opens")
    func grantedViaTCCFallback() {
        let outcome = Self.evaluate(present: ["system-tcc-db"], opens: ["system-tcc-db"])
        #expect(outcome == .granted("system-tcc-db"))
    }

    @Test("Every present file refused reports denied")
    func deniedWhenAllRefused() {
        let outcome = Self.evaluate(
            present: ["safari-bookmarks", "messages-chat", "system-tcc-db"], opens: []
        )
        #expect(outcome == .denied)
    }

    // C1: a hung usernoted is "can't tell", never "not granted". The provider
    // blocks (on a GCD thread) until the test releases it after asserting.
    @Test("Notifications check that times out reports unknown", .timeLimit(.minutes(1)))
    func notificationsTimeoutIsUnknown() async {
        let gate = DispatchSemaphore(value: 0)
        let state = await PermissionsProbe.notificationsPermission(timeout: 0.05) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { gate.wait(); continuation.resume() }
            }
            return true
        }
        #expect(state == .unknown)
        gate.signal()
    }

    @Test("Notifications check maps a prompt answer to granted or denied")
    func notificationsAnswered() async {
        #expect(await PermissionsProbe.notificationsPermission(timeout: 3600) { true } == .granted)
        #expect(await PermissionsProbe.notificationsPermission(timeout: 3600) { false } == .denied)
    }

    // Absent files are never opened — an open on a missing path would read as
    // a refusal and turn "can't tell" into "denied".
    @Test("No probe file present reports noProbeFile without opening anything")
    func noProbeFile() {
        var opened: [String] = []
        let outcome = PermissionsProbe.evaluateFullDiskAccess(
            Self.files, exists: { _ in false }, open: { opened.append($0) }
        )
        #expect(outcome == .noProbeFile)
        #expect(opened.isEmpty)
    }
}
