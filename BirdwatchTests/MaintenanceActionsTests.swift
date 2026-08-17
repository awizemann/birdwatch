import Foundation
import Testing
@testable import Birdwatch

/// Audit P2: "MaintenanceActions error mapping" was untested. Nothing here
/// spawns a process — every branch covered returns before ProcessRunner is
/// reached.
@Suite("MaintenanceActions")
struct MaintenanceActionsTests {

    // Fails if an unknown daemon name ever falls through to launchctl with a
    // half-formed target instead of being rejected up front.
    @Test("restartDaemon rejects a daemon it has no verified launchd label for")
    func unknownDaemonThrowsBeforeSpawning() async throws {
        let actions = MaintenanceActions()
        await #expect(throws: MaintenanceError.unknownDaemon("mds")) {
            _ = try await actions.restartDaemon(name: "mds")
        }
        // The three verified labels are the whole allow-list.
        #expect(MaintenanceActions.serviceLabels.keys.sorted() == ["bird", "cloudd", "fileproviderd"])
    }

    // These two are deliberately unsupported (no safe public command). Fails if
    // either ever silently becomes a no-op success, or starts running something.
    @Test("reindexMetadata and resetCloudDocs stay deliberately unsupported")
    func unsupportedActions() async throws {
        let actions = MaintenanceActions()
        await #expect(throws: MaintenanceError.notSupported("Metadata re-indexing has no safe public command")) {
            try await actions.reindexMetadata()
        }
        await #expect(throws: MaintenanceError.notSupported("Destructive CloudDocs resets are deliberately not offered")) {
            try await actions.resetCloudDocs()
        }
    }

    // MARK: - brctl diagnose

    // `brctl diagnose` shells out to sudo, so a GUI process can never run it —
    // measured live in the dev app: "sudo: a terminal is required to read the
    // password". Fails if it ever goes back to spawning a process (which would
    // put the dead Run button back in the Maintenance card).
    @Test("runDiagnose refuses up front — it needs a terminal, not a button")
    func diagnoseRequiresATerminal() async {
        let actions = MaintenanceActions()
        await #expect(throws: MaintenanceError.requiresTerminal("brctl diagnose --no-reveal")) {
            try await actions.runDiagnose()
        }
        // The command the card shows the user must be the one we name here.
        #expect(MaintenanceActions.diagnoseCommand == "brctl diagnose --no-reveal")
    }
}
