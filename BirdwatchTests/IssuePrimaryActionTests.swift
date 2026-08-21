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
