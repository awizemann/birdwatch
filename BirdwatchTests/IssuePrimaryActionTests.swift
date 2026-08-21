import Testing
@testable import Birdwatch
import Foundation

/// The Issues card offers a primary button only for operations Birdwatch can
/// genuinely perform, and the label states that operation. These tests pin the
/// mapping so a new issue kind cannot quietly reintroduce a button that
/// implies work the app never does (C1).
@MainActor
struct IssuePrimaryActionTests {
    /// `action` replaced a free-text `label:` when IssueItem's primary action
    /// became typed: the label is now DERIVED from the action, so a test can no
    /// longer hand this helper a string the sources could never produce.
    private func issue(
        action: IssueAction,
        severity: IssueSeverity = .warning,
        id: String = "issue-x"
    ) -> IssueItem {
        IssueItem(
            id: id, severity: severity, title: "t", meta: "m", reason: "r",
            action: action, symbolName: "circle"
        )
    }

    @Test("A conflict offers the version comparison, whatever label it carries")
    func conflictResolvesToReviewVersions() {
        #expect(IssuePrimaryAction(issue: issue(action: .reviewVersions, severity: .conflict)) == .reviewVersions)
        // Severity wins over whatever the source asked for: a conflict always
        // opens the version comparison. (Was "Anything else" as a free label;
        // an unrepresentable string is now an unrelated ACTION.)
        #expect(IssuePrimaryAction(issue: issue(action: .openDiagnostics, severity: .conflict)) == .reviewVersions)
    }

    @Test("bird-reported errors open Diagnostics rather than dismissing themselves")
    func diagnosticsIssuesResolveToNavigation() {
        #expect(IssuePrimaryAction(issue: issue(action: .openDiagnostics, severity: .error)) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(action: .openDiagnostics)) == .openDiagnostics)
    }

    @Test("Low quota opens the one pane that can change the plan, and says so")
    func storageIssueOpensAppleAccountSettings() {
        let action = IssuePrimaryAction(issue: issue(action: .manageStorage))
        #expect(action == .openAppleAccountSettings)
        // The old label claimed Birdwatch managed storage; the new one names
        // the surface the click actually opens.
        #expect(action?.label == "Manage iCloud in System Settings…")
    }

    // Same purpose as before, now expressed in the type system: the cases that
    // used to be unrecognised LABELS ("Resume upload", "Free up space", "") are
    // all one thing — an issue whose source says there is nothing Birdwatch can
    // do. `.none` is the only way to say that now, and it must yield no button.
    @Test("An action Birdwatch cannot perform gets no button at all")
    func unsupportedActionsResolveToNil() {
        #expect(IssuePrimaryAction(issue: issue(action: .none)) == nil)
        #expect(IssuePrimaryAction(issue: issue(action: .none, severity: .error)) == nil)
        // The label that fed the old string switch is empty for .none, so the
        // "" case it used to test is now unreachable by construction.
        #expect(issue(action: .none).primaryActionLabel.isEmpty)
        #expect(!issue(action: .none).hasPrimaryAction)
    }

    @Test("Every offered action's label names its own operation")
    func labelsAreNonEmptyAndDistinct() {
        let all: [IssuePrimaryAction] = [.reviewVersions, .openDiagnostics, .openAppleAccountSettings]
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(all.allSatisfy { !$0.label.isEmpty && !$0.accessibilityHint.isEmpty })
    }

    @Test("Every issue kind the production sources emit is either actionable or button-free")
    func productionIssueKindsAreCovered() {
        // Actions the shipping sources actually set (BrctlDumpSource,
        // SystemSyncSource.deriveIssues, ConflictSource, MockSyncSource).
        #expect(IssuePrimaryAction(issue: issue(action: .openDiagnostics, severity: .error, id: "issue-account-session")) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(action: .openDiagnostics, id: "issue-stuck-items")) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(action: .openDiagnostics, severity: .error, id: "issue-synchealth-upload")) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(action: .manageStorage, id: "issue-low-quota")) == .openAppleAccountSettings)
        #expect(IssuePrimaryAction(issue: issue(action: .reviewVersions, severity: .conflict, id: "conflict-abc")) == .reviewVersions)
        // And the one the mock models but Birdwatch cannot perform.
        #expect(IssuePrimaryAction(issue: issue(action: .none, id: "issue-photos-metered")) == nil)
    }
}

/// QA (REP-004) reported the "Open Diagnostics" button removing the card and
/// never navigating — the pre-diff placeholder's behaviour. These tests run the
/// button's ENTIRE closure body against a real SyncStore, so the two effects
/// are told apart directly: navigation must happen, and the issue list must be
/// untouched. Only "Dismiss" may remove a card.
@MainActor
struct IssueActionEffectTests {
    private func storeWithIssues(_ issues: [IssueItem]) async -> SyncStore {
        let store = SyncStore(source: StubSyncSource(snapshot: .minimal(issues: issues)))
        await store.refresh(force: true)
        return store
    }

    /// Takes the typed `action` (was a free-text `label:`): IssueItem's primary
    /// action is now the stored fact and the label is derived from it.
    private func issue(_ id: String, action: IssueAction, severity: IssueSeverity = .warning) -> IssueItem {
        IssueItem(id: id, severity: severity, title: id, meta: "", reason: "",
                  action: action, symbolName: "circle")
    }

    @Test("Open Diagnostics navigates and removes nothing")
    func openDiagnosticsNavigatesWithoutDismissing() async {
        let store = await storeWithIssues([
            issue("issue-account-session", action: .openDiagnostics, severity: .error),
            issue("issue-stuck-items", action: .openDiagnostics),
        ])
        #expect(store.selectedView == .overview)
        #expect(store.issues.count == 2)

        let action = try! #require(IssuePrimaryAction(issue: store.issues[0]))
        action.perform(on: store, issueID: store.issues[0].id)

        // The exact pair QA observed failing: the screen must change AND the
        // card must survive. Either half alone is not the fix.
        #expect(store.selectedView == .diagnostics)
        #expect(store.issues.count == 2)
        #expect(store.issues.contains { $0.id == "issue-account-session" })
    }

    @Test("The second card behaves the same as the first")
    func repeatedOpenDiagnosticsKeepsBothCards() async {
        let store = await storeWithIssues([
            issue("issue-account-session", action: .openDiagnostics, severity: .error),
            issue("issue-stuck-items", action: .openDiagnostics),
        ])
        for item in store.issues {
            IssuePrimaryAction(issue: item)?.perform(on: store, issueID: item.id)
        }
        #expect(store.selectedView == .diagnostics)
        #expect(store.issues.count == 2)
    }

    @Test("Review versions opens the comparison and removes nothing")
    func reviewVersionsDoesNotDismiss() async {
        let store = await storeWithIssues([issue("conflict-1", action: .reviewVersions, severity: .conflict)])
        let action = try! #require(IssuePrimaryAction(issue: store.issues[0]))
        action.perform(on: store, issueID: "conflict-1")
        #expect(store.conflictIssueID == "conflict-1")
        #expect(store.issues.count == 1)
    }

    @Test("Dismiss is the only path that removes a card — so the tests above can tell them apart")
    func dismissRemovesTheCard() async {
        let store = await storeWithIssues([issue("issue-stuck-items", action: .openDiagnostics)])
        store.dismissIssue(id: "issue-stuck-items")
        #expect(store.issues.isEmpty)
        #expect(store.selectedView == .overview)
    }
}
