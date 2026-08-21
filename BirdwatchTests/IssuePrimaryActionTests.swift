import Testing
@testable import Birdwatch
import Foundation

/// The Issues card offers a primary button only for operations Birdwatch can
/// genuinely perform, and the label states that operation. These tests pin the
/// mapping so a new issue kind cannot quietly reintroduce a button that
/// implies work the app never does (C1).
@MainActor
struct IssuePrimaryActionTests {
    private func issue(
        label: String,
        severity: IssueSeverity = .warning,
        id: String = "issue-x"
    ) -> IssueItem {
        IssueItem(
            id: id, severity: severity, title: "t", meta: "m", reason: "r",
            primaryActionLabel: label, symbolName: "circle"
        )
    }

    @Test("A conflict offers the version comparison, whatever label it carries")
    func conflictResolvesToReviewVersions() {
        #expect(IssuePrimaryAction(issue: issue(label: "Review versions", severity: .conflict)) == .reviewVersions)
        #expect(IssuePrimaryAction(issue: issue(label: "Anything else", severity: .conflict)) == .reviewVersions)
    }

    @Test("bird-reported errors open Diagnostics rather than dismissing themselves")
    func diagnosticsIssuesResolveToNavigation() {
        #expect(IssuePrimaryAction(issue: issue(label: "Open Diagnostics", severity: .error)) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(label: "Open Diagnostics")) == .openDiagnostics)
    }

    @Test("Low quota opens the one pane that can change the plan, and says so")
    func storageIssueOpensAppleAccountSettings() {
        let action = IssuePrimaryAction(issue: issue(label: "Manage storage"))
        #expect(action == .openAppleAccountSettings)
        // The old label claimed Birdwatch managed storage; the new one names
        // the surface the click actually opens.
        #expect(action?.label == "Manage iCloud in System Settings…")
    }

    @Test("An action Birdwatch cannot perform gets no button at all")
    func unsupportedActionsResolveToNil() {
        #expect(IssuePrimaryAction(issue: issue(label: "Resume upload")) == nil)
        #expect(IssuePrimaryAction(issue: issue(label: "Free up space")) == nil)
        #expect(IssuePrimaryAction(issue: issue(label: "")) == nil)
    }

    @Test("Every offered action's label names its own operation")
    func labelsAreNonEmptyAndDistinct() {
        let all: [IssuePrimaryAction] = [.reviewVersions, .openDiagnostics, .openAppleAccountSettings]
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(all.allSatisfy { !$0.label.isEmpty && !$0.accessibilityHint.isEmpty })
    }

    @Test("Every issue kind the production sources emit is either actionable or button-free")
    func productionIssueKindsAreCovered() {
        // Labels the shipping sources actually construct (BrctlDumpSource,
        // SystemSyncSource.deriveIssues, ConflictSource).
        #expect(IssuePrimaryAction(issue: issue(label: "Open Diagnostics", severity: .error, id: "issue-account-session")) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(label: "Open Diagnostics", id: "issue-stuck-items")) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(label: "Open Diagnostics", severity: .error, id: "issue-synchealth-upload")) == .openDiagnostics)
        #expect(IssuePrimaryAction(issue: issue(label: "Manage storage", id: "issue-low-quota")) == .openAppleAccountSettings)
        #expect(IssuePrimaryAction(issue: issue(label: "Review versions", severity: .conflict, id: "conflict-abc")) == .reviewVersions)
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

    private func issue(_ id: String, label: String, severity: IssueSeverity = .warning) -> IssueItem {
        IssueItem(id: id, severity: severity, title: id, meta: "", reason: "",
                  primaryActionLabel: label, symbolName: "circle")
    }

    @Test("Open Diagnostics navigates and removes nothing")
    func openDiagnosticsNavigatesWithoutDismissing() async {
        let store = await storeWithIssues([
            issue("issue-account-session", label: "Open Diagnostics", severity: .error),
            issue("issue-stuck-items", label: "Open Diagnostics"),
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
            issue("issue-account-session", label: "Open Diagnostics", severity: .error),
            issue("issue-stuck-items", label: "Open Diagnostics"),
        ])
        for item in store.issues {
            IssuePrimaryAction(issue: item)?.perform(on: store, issueID: item.id)
        }
        #expect(store.selectedView == .diagnostics)
        #expect(store.issues.count == 2)
    }

    @Test("Review versions opens the comparison and removes nothing")
    func reviewVersionsDoesNotDismiss() async {
        let store = await storeWithIssues([issue("conflict-1", label: "Review versions", severity: .conflict)])
        let action = try! #require(IssuePrimaryAction(issue: store.issues[0]))
        action.perform(on: store, issueID: "conflict-1")
        #expect(store.conflictIssueID == "conflict-1")
        #expect(store.issues.count == 1)
    }

    @Test("Dismiss is the only path that removes a card — so the tests above can tell them apart")
    func dismissRemovesTheCard() async {
        let store = await storeWithIssues([issue("issue-stuck-items", label: "Open Diagnostics")])
        store.dismissIssue(id: "issue-stuck-items")
        #expect(store.issues.isEmpty)
        #expect(store.selectedView == .overview)
    }
}
