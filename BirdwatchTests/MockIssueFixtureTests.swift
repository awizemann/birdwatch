import Foundation
import Testing
@testable import Birdwatch

/// `--mock` is how the crew verifies issue-card behaviour without waiting for a
/// real bird failure, so a click path the mock cannot produce is a click path
/// nobody can check. The mock's issue set had NO `.openDiagnostics` issue, which
/// made every --mock verification of that button vacuous (t-66b548d2, the
/// unblocker for the Open Diagnostics click-defect investigation).
///
/// These tests pin the fixture shape the investigation depends on. They fail on
/// the pre-change MockSyncSource, which shipped no .openDiagnostics issue at all.
@Suite("Mock issue fixtures")
struct MockIssueFixtureTests {

    private static func issues() async -> [IssueItem] {
        await MockSyncSource().currentSnapshot().issues
    }

    // Fails on the old mock: it had no .openDiagnostics issue, so --mock could
    // never render the button whose click path is under investigation.
    @Test("The mock ships an actionable Open Diagnostics issue with a stable, targetable id")
    func mockOffersAnOpenDiagnosticsIssue() async throws {
        let issues = await Self.issues()
        let diagnostic = try #require(issues.first { $0.action == .openDiagnostics },
                                      "--mock cannot exercise the Open Diagnostics path without one")

        #expect(diagnostic.hasPrimaryAction)
        #expect(diagnostic.severity == .error, "the reported defect is on ERROR cards")
        // The accessibility identifier the Issues card derives is
        // "issue-primary-<id>", so this id is a test contract, not decoration.
        #expect(diagnostic.id == "issue-stuck-items-mock")
        #expect(!diagnostic.reason.isEmpty)
    }

    // The neighbour is the control: a card whose primary does something ELSE
    // beside the Open Diagnostics one turns a mark-to-element mis-resolution
    // into a visible wrong action. (It used to be an action-less card; no real
    // producer emits one, so the mock no longer invents it — see
    // IssueActionTests.mockIssuesAreTyped.)
    @Test("A card with a different primary action sits adjacent to the Open Diagnostics one")
    func differentActionNeighbourIsAdjacent() async throws {
        let issues = await Self.issues()
        let index = try #require(issues.firstIndex { $0.action == .openDiagnostics })
        let neighbours = [index - 1, index + 1]
            .filter { issues.indices.contains($0) }
            .map { issues[$0] }

        #expect(!neighbours.isEmpty)
        #expect(neighbours.contains { $0.hasPrimaryAction && $0.action != .openDiagnostics },
                "the .openDiagnostics card must have a neighbour whose button does something else")
    }

    // NOTE: "Every mock issue's copy matches whether it actually offers a button"
    // lived here and has been REMOVED, not relocated. It paired a label check
    // against `hasPrimaryAction`; once IssueItem carried no label, the only
    // assertion left was `hasPrimaryAction == (action != .none)` — which is the
    // DEFINITION of hasPrimaryAction, so the test could no longer fail. The C1
    // property it guarded is now enforced by the type system (a model with no
    // display copy cannot promise a capability in copy), and the mock's
    // copy-vs-capability check that still has teeth lives in
    // IssueActionTests.meteredIssueMakesNoPromiseItCannotKeep.
}
