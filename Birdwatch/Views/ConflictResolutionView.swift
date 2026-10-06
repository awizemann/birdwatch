import SwiftUI

/// Conflict resolution — Issues → "Review versions" (handoff §5a).
struct ConflictResolutionView: View {
    @Environment(SyncStore.self) private var store
    let issueID: String

    /// Loading and "the source has nothing for this id" are different answers:
    /// a nil detail (already resolved, or no longer in the scan) used to leave
    /// "Loading…" on screen forever.
    private enum Phase {
        case loading
        case loaded(ConflictDetail)
        case gone
    }

    @State private var phase: Phase = .loading
    /// Why the last Keep did not resolve (the conflict is still open).
    private enum Notice { case failed, changed }
    @State private var notice: Notice?
    /// A Keep was clicked and its resolve has not returned yet.
    @State private var submitting = false

    private var keepDisabled: Bool { submitting || store.isResolvingConflict }

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

            switch phase {
            case .loaded(let detail):
                explainerCard(detail)

                if let notice { noticeCard(notice) }

                HStack(alignment: .top, spacing: 14) {
                    ForEach(detail.versions) { version in
                        VersionPanel(version: version, isDisabled: keepDisabled) {
                            resolve(detail, keeping: version.id,
                                    success: "Kept the version from \(version.deviceName) of \(detail.fileName)")
                        }
                    }
                }

                Button {
                    resolve(detail, keeping: ConflictSource.keepBothVersionID,
                            success: "Kept both versions of \(detail.fileName)")
                } label: {
                    Text("Keep both versions")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(keepDisabled)
            case .gone:
                goneCard
            case .loading:
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
            phase = .loading
            notice = nil
            submitting = false
            await loadDetail()
        }
    }

    /// Loads (or reloads) what the source has for this conflict now.
    private func loadDetail() async {
        if let detail = await store.conflictDetail(issueID: issueID) {
            phase = .loaded(detail)
            AccessibilityNotification.Announcement("Conflict versions loaded").post()
        } else {
            phase = .gone
            AccessibilityNotification.Announcement("This conflict is no longer reported").post()
        }
    }

    /// Sends the choice together with the versions this screen SHOWED, so
    /// the source can refuse to remove one the user never saw.
    ///
    /// `submitting` is set synchronously, before the Task, so a second click
    /// landing before SwiftUI re-renders with `isResolvingConflict` is
    /// dropped here rather than reported as a failure. Failure outcomes are
    /// applied only if this screen still shows the conflict they were for
    /// (the store notes them in the panel otherwise). The success line names
    /// the file, so a late one is never mistaken for the conflict now on
    /// screen.
    private func resolve(_ detail: ConflictDetail, keeping versionID: String, success: String) {
        guard !submitting else { return }
        submitting = true
        notice = nil
        let submittedID = issueID
        let shown = Set(detail.versions.map(\.id))
        Task {
            let result = await store.resolveConflict(
                issueID: submittedID, keepVersionID: versionID, shownVersionIDs: shown
            )
            submitting = false
            switch result {
            case .resolved:
                AccessibilityNotification.Announcement(success).post()
            case .busy:
                break   // another resolve is running; its own result speaks
            case .failed, .notFound, .changed:
                guard store.conflictIssueID == submittedID else { return }
                switch result {
                case .notFound:
                    phase = .gone
                    AccessibilityNotification.Announcement("This conflict is no longer reported").post()
                case .changed:
                    // Show what exists NOW (the source re-probed the file).
                    await loadDetail()
                    notice = .changed
                    AccessibilityNotification.Announcement("A new version arrived. Review the versions again.").post()
                default:
                    notice = .failed
                    AccessibilityNotification.Announcement("Couldn't resolve this conflict. It is still open.").post()
                }
            }
        }
    }

    private func noticeCard(_ notice: Notice) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(notice == .failed ? Palette.error : Palette.warning)
                    .accessibilityHidden(true)
                Text(notice == .failed
                     ? "Birdwatch couldn't resolve this conflict, so it is still open. Try again in a moment."
                     : "A new version of this file arrived after these were shown, so Birdwatch stopped before removing anything. Review the versions below and choose again.")
                    .scaledFont(size: 13)
                    .lineSpacing(3)
                    .foregroundStyle(Surface.fg)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var goneCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("This conflict is no longer reported")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(Surface.fg)
                Text("Birdwatch's latest scan doesn't list it any more — it may already have been resolved here, on another device, or in the app that made the file.")
                    .scaledFont(size: 13)
                    .lineSpacing(3)
                    .foregroundStyle(Surface.fg2)
                Button("Back to Issues") { store.conflictIssueID = nil }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
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
    /// True while any resolution is in flight — no second Keep can start.
    let isDisabled: Bool
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
                .disabled(isDisabled)
                .accessibilityLabel("Keep version from \(version.deviceName)")
            }
        }
    }
}
