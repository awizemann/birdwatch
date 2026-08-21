import SwiftUI
import AppKit
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "issues")

/// What an issue card's primary button actually does when clicked.
///
/// Birdwatch observes iCloud sync, it does not fix it: there is no public API
/// to resume an upload, clear an account-session error or free storage. So the
/// button offers only operations the app can genuinely perform, and its label
/// states exactly that operation. An issue whose DTO asks for something
/// Birdwatch cannot do gets no primary button at all rather than one that
/// implies work happened (C1).
enum IssuePrimaryAction: String, Sendable, Hashable {
    /// Opens the conflict comparison screen for this issue.
    case reviewVersions
    /// Switches to the Diagnostics screen, where the engine output behind the
    /// issue (SyncHealthReport, `brctl` state) is shown verbatim.
    case openDiagnostics
    /// Opens System Settings › Apple Account, the only place iCloud storage
    /// can actually be managed or upgraded.
    case openAppleAccountSettings

    var label: String {
        switch self {
        case .reviewVersions: "Review versions"
        case .openDiagnostics: "Open Diagnostics"
        case .openAppleAccountSettings: "Manage iCloud in System Settings…"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .reviewVersions: "Compares the conflicting versions of this file"
        case .openDiagnostics: "Shows the engine output this issue came from"
        case .openAppleAccountSettings: "Opens System Settings"
        }
    }

    /// Resolves the action from the issue, so the rendered label can never
    /// outlive what the click does. Conflicts are keyed on severity (the
    /// conflict detail is what the screen needs); everything else on the
    /// action the source asked for. An unrecognised request resolves to nil —
    /// no button — which is the honest answer for anything Birdwatch cannot
    /// carry out (e.g. the "Resume upload" the mock source models).
    init?(issue: IssueItem) {
        if issue.isConflict {
            self = .reviewVersions
            return
        }
        switch issue.primaryActionLabel {
        case "Open Diagnostics": self = .openDiagnostics
        case "Manage storage": self = .openAppleAccountSettings
        default: return nil
        }
    }
}

/// Issues — stacked severity-accented cards with plain-language reasons (handoff §5).
struct IssuesView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.issues.title, subtitle: MonitorView.issues.subtitle)

            if store.issues.isEmpty {
                emptyState
            } else {
                ForEach(store.issues) { issue in
                    IssueCard(issue: issue)
                }
            }
        }
    }

    private var emptyState: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 40)
                    .foregroundStyle(Palette.success)
                    .accessibilityHidden(true)
                Text("No issues")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundStyle(Surface.fg)
                Text("Everything is syncing normally.")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Surface.fg2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}

private struct IssueCard: View {
    @Environment(SyncStore.self) private var store
    let issue: IssueItem

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: issue.symbolName)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(issue.severity.tint)
                    .frame(width: 28, height: 28)
                    .background(issue.severity.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(issue.title)
                            .scaledFont(size: 14, weight: .bold)
                            .foregroundStyle(Surface.fg)
                        SeverityPill(severity: issue.severity)
                    }

                    Text(issue.meta)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(Surface.fg2)
                        .monospacedDigit()

                    Text(issue.reason)
                        .scaledFont(size: 13)
                        .lineSpacing(4)
                        .foregroundStyle(Surface.fg2)
                        .frame(maxWidth: 560, alignment: .leading)

                    HStack(spacing: 8) {
                        // No button at all when Birdwatch cannot honestly do
                        // what the issue asks for — only "Dismiss", which
                        // removes the card and nothing else.
                        if let action = IssuePrimaryAction(issue: issue) {
                            Button(action.label) { perform(action) }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.accent)
                                .accessibilityHint(action.accessibilityHint)
                        }

                        Button("Dismiss") {
                            store.dismissIssue(id: issue.id)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Removes this issue from the list")
                    }
                    .controlSize(.regular)
                    .padding(.top, 4)
                }
            }
        }
        .overlay(alignment: .leading) {
            // Left accent border in the severity color.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(issue.severity.tint)
                .frame(width: 3)
                .padding(.vertical, 10)
                .accessibilityHidden(true)
        }
    }

    private func perform(_ action: IssuePrimaryAction) {
        // The id can be a hashed file path (ConflictSource), so it stays private.
        logger.info("Issue action: \(action.label, privacy: .public) for \(issue.id, privacy: .private)")
        switch action {
        case .reviewVersions:
            store.conflictIssueID = issue.id
        case .openDiagnostics:
            store.navigate(to: .diagnostics, via: .link)
        case .openAppleAccountSettings:
            openAppleAccountSettings()
        }
    }

    /// Same pane Storage and Devices open — the one surface that can actually
    /// change an iCloud plan. A refusal from the URL system is logged rather
    /// than swallowed: the click then did nothing, and the log says so.
    private func openAppleAccountSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") else {
            logger.error("Apple Account settings URL is malformed; cannot open System Settings")
            return
        }
        if !NSWorkspace.shared.open(url) {
            logger.error("System Settings refused to open the Apple Account pane")
        }
    }
}
