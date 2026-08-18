import SwiftUI
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "issues")

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
                        Button(issue.primaryActionLabel) {
                            if issue.isConflict {
                                store.conflictIssueID = issue.id
                            } else if issue.primaryActionLabel == "Manage storage" {
                                // TODO(Phase 1): perform the real operation (open storage
                                // management / upgrade flow), not just navigation.
                                logger.info("Issue action: \(issue.primaryActionLabel, privacy: .public) for \(issue.id, privacy: .public)")
                                store.navigate(to: .storage, via: .link)
                            } else {
                                // TODO(Phase 1): perform the real operation (e.g. actually
                                // resume the upload) — logging + dismissal is a placeholder.
                                logger.info("Issue action: \(issue.primaryActionLabel, privacy: .public) for \(issue.id, privacy: .public)")
                                store.dismissIssue(id: issue.id)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)

                        Button("Dismiss") {
                            store.dismissIssue(id: issue.id)
                        }
                        .buttonStyle(.bordered)
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
}
