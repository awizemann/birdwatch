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

    // The label is derived, so it can never disagree with what the button does.
    // Fails if a case is added without a label, or a label is edited to
    // describe a different action than the one it triggers.
    @Test("Every action derives its own label; only .none has none")
    func labelsAreDerived() {
        #expect(IssueAction.reviewVersions.label == "Review versions")
        #expect(IssueAction.openDiagnostics.label == "Open Diagnostics")
        #expect(IssueAction.manageStorage.label == "Manage storage")
        #expect(IssueAction.none.label.isEmpty)

        // Exhaustive over CaseIterable: a NEW case with an empty label would be
        // an invisible button, so only .none may be empty.
        for action in IssueAction.allCases where action != .none {
            #expect(!action.label.isEmpty, "\(action) would render a blank button")
            #expect(Self.issue(action).hasPrimaryAction)
            #expect(Self.issue(action).primaryActionLabel == action.label)
        }
        #expect(!Self.issue(.none).hasPrimaryAction)
        #expect(Self.issue(.none).primaryActionLabel.isEmpty)
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

    // Every issue the mock ships either has a real action or honestly has none
    // — no issue may carry a label without a matching action.
    @Test("Mock issues carry a typed action, and labels follow it")
    func mockIssuesAreTyped() async {
        let issues = await MockSyncSource().currentSnapshot().issues
        #expect(!issues.isEmpty)
        for issue in issues {
            #expect(issue.primaryActionLabel == issue.action.label)
            #expect(issue.hasPrimaryAction == (issue.action != .none))
        }
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
        #expect(quota?.primaryActionLabel == "Manage storage")
    }
}
