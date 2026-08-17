import SwiftUI

/// Conflict resolution — Issues → "Review versions" (handoff §5a).
struct ConflictResolutionView: View {
    @Environment(SyncStore.self) private var store
    let issueID: String

    @State private var detail: ConflictDetail?

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.issues.title, subtitle: MonitorView.issues.subtitle)

            Button {
                store.conflictIssueID = nil
            } label: {
                Text("‹ Back to issues")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to issues")

            if let detail {
                explainerCard(detail)

                HStack(alignment: .top, spacing: 14) {
                    ForEach(detail.versions) { version in
                        VersionPanel(version: version) {
                            Task {
                                await store.resolveConflict(issueID: issueID, keepVersionID: version.id)
                                AccessibilityNotification.Announcement("Kept version from \(version.deviceName)").post()
                            }
                        }
                    }
                }

                Button {
                    Task {
                        await store.resolveConflict(issueID: issueID, keepVersionID: ConflictSource.keepBothVersionID)
                        AccessibilityNotification.Announcement("Kept both versions").post()
                    }
                } label: {
                    Text("Keep both versions")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Card {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading conflict versions…")
                            .scaledFont(size: 13)
                            .foregroundStyle(Surface.fg2)
                    }
                }
            }
        }
        .task(id: issueID) {
            detail = await store.conflictDetail(issueID: issueID)
            if detail != nil {
                AccessibilityNotification.Announcement("Conflict versions loaded").post()
            }
        }
    }

    private func explainerCard(_ detail: ConflictDetail) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                ColorTile(colorHex: "ff453a", symbolName: "exclamationmark.triangle", size: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(detail.fileName) has a sync conflict")
                        .scaledFont(size: 14, weight: .bold)
                        .foregroundStyle(Surface.fg)
                    Text("\(detail.location) · edited on two devices at once")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(Surface.fg2)
                    Text("iCloud kept both versions so nothing is lost. Choose which one to keep — or keep both and Birdwatch will rename one.")
                        .scaledFont(size: 13)
                        .lineSpacing(4)
                        .foregroundStyle(Surface.fg2)
                        .padding(.top, 2)
                }
            }
        }
    }
}

private struct VersionPanel: View {
    let version: ConflictVersion
    let keepAction: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ColorTile(colorHex: version.tileColorHex, letter: version.deviceName, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.deviceName)
                            .scaledFont(size: 13.5, weight: .bold)
                            .foregroundStyle(Surface.fg)
                        Text(version.modified, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .scaledFont(size: 11.5)
                            .foregroundStyle(Surface.fg3)
                            .monospacedDigit()
                    }
                }

                Divider().overlay(Surface.cardLine)

                HStack {
                    Text("Size")
                        .scaledFont(size: 12)
                        .foregroundStyle(Surface.fg2)
                    Spacer()
                    Text(Format.size(version.sizeBytes))
                        .scaledFont(size: 12.5, weight: .bold)
                        .foregroundStyle(Surface.fg)
                        .monospacedDigit()
                }

                Text(version.changeNote)
                    .scaledFont(size: 12.5)
                    .lineSpacing(3)
                    .foregroundStyle(Surface.fg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Surface.hover, in: RoundedRectangle(cornerRadius: 8))

                Button(action: keepAction) {
                    Text("Keep this version")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.regular)
                .accessibilityLabel("Keep version from \(version.deviceName)")
            }
        }
    }
}
