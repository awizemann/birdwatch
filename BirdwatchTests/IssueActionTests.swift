import Foundation
import Testing
@testable import Birdwatch

/// `IssueItem.primaryActionLabel` used to be free text AND the key the button
/// was resolved from, so a source could invent a label, compile cleanly, and
/// ship an issue whose button did nothing (or silently vanished). The action is
/// now a typed, non-optional field and the label is derived from it.
///
/// The strongest guarantee here is a COMPILE-TIME one — a new issue-producing
/// site that omits `action:` does not build — which no runtime test can assert.
/// These tests pin what remains: the derivation, and the promise each shipped
/// issue actually makes.
@Suite("Issue actions")
struct IssueActionTests {

    private static func issue(_ action: IssueAction) -> IssueItem {
        TestIssues.make(id: "i", action: action, title: "t", meta: "m", reason: "r")
    }

    // The model no longer carries any display copy — the button's title belongs
    // to IssuePrimaryAction in the view layer. What is left to pin here is the
    // case set itself and what each case promises.
    //
    // Fails if a case is ADDED or removed, which is the point: a new action is
    // a new promise, and whoever adds one must decide here whether it offers a
    // button and teach IssuesView's exhaustive switch to honour it.
    @Test("The action cases are exactly these four, and only .none offers no button")
    func actionCasesAndTheirPromises() {
        #expect(Set(IssueAction.allCases) == [.reviewVersions, .openDiagnostics, .manageStorage, .none])

        for action in IssueAction.allCases where action != .none {
            #expect(Self.issue(action).hasPrimaryAction, "\(action) must offer a button")
        }
        #expect(!Self.issue(.none).hasPrimaryAction)
    }

    // C1: an issue must not promise an action Birdwatch cannot perform. The
    // mock's metered-network issue used to end "or you can resume them now"
    // with a "Resume upload" button that no code path implemented. Fails if
    // either the promise or the phantom button comes back.
    @Test("The mock metered-network issue offers no button and promises no resume")
    func meteredIssueMakesNoPromiseItCannotKeep() async throws {
        let issues = await MockSyncSource().currentSnapshot().issues
        let issue = try #require(issues.first { $0.title.localizedCaseInsensitiveContains("metered") })

        #expect(issue.action == .none, "Birdwatch cannot resume a metered upload — so no button")
        #expect(!issue.hasPrimaryAction)
        #expect(!issue.reason.localizedCaseInsensitiveContains("resume them now"),
                "the copy must not offer an action the app does not have")
        #expect(issue.reason.localizedCaseInsensitiveContains("resume automatically"),
                "what macOS does on its own is still worth saying")
    }

    // The mock must exercise every action path the crew verifies through --mock,
    // including the honest no-button case. Fails if a shipped mock issue kind
    // disappears from the fixture set.
    @Test("Mock issues cover the actionable kinds and the action-less one")
    func mockIssuesAreTyped() async {
        let issues = await MockSyncSource().currentSnapshot().issues
        #expect(!issues.isEmpty)
        #expect(issues.contains { $0.action == .reviewVersions })
        #expect(issues.contains { $0.action == .manageStorage })
        #expect(issues.contains { $0.action == .none })
    }

    // The real (non-mock) sources: a low-quota issue is actionable via
    // storage management, and a conflict is actionable via version review.
    // Fails if a source ever ships an issue with no way to act on it that
    // Birdwatch could in fact act on.
    @Test("deriveIssues gives the low-quota issue the storage action")
    func lowQuotaIssueIsTyped() {
        let issues = SystemSyncSource.deriveIssues(quotaRemaining: 1_000_000)
        let quota = issues.first { $0.id == "issue-low-quota" }
        #expect(quota?.action == .manageStorage)
        #expect(quota?.hasPrimaryAction == true)
    }
}
