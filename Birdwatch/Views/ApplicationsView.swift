import SwiftUI

struct ApplicationsView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        let apps = store.effectiveApps
        let apple = apps.filter(\.isApple)
        let thirdParty = apps.filter { !$0.isApple }

        ContentColumn {
            ViewHeader(title: MonitorView.applications.title, subtitle: MonitorView.applications.subtitle)

            appGroup(label: "Apple apps", apps: apple)
            appGroup(label: "Third-party apps", apps: thirdParty)

            SourceFootnote(text: "Per-app status from brctl (CloudDocs), cloudd item counts (CloudKit) and fileproviderd domain status (File Provider).")
        }
    }

    private func appGroup(label: String, apps: [AppSyncState]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: label)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(apps) { app in
                        AppRow(app: app) { store.detailAppID = app.id }
                        if app.id != apps.last?.id {
                            Divider().overlay(Surface.cardLine)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row

private struct AppRow: View {
    let app: AppSyncState
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ColorTile(colorHex: app.tileColorHex, letter: app.name, size: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(app.name)
                                .scaledFont(size: 13.5, weight: .semibold)
                                .foregroundStyle(Surface.fg)
                            SourceBadge(backend: app.backend)
                        }
                        Text(app.statusLine)
                            .scaledFont(size: 12)
                            .foregroundStyle(Surface.fg2)
                            .lineLimit(1)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(app.status.shortLabel)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(app.status.tint)
                                .monospacedDigit()
                            if app.status.isSyncing { SyncSpinner() }
                        }
                        if let last = app.lastActivity {
                            RelativeTimeText(date: last)
                        }
                        // Local footprint, once the background size pass lands.
                        if app.localSizeBytes > 0 {
                            Text(Format.size(app.localSizeBytes))
                                .scaledFont(size: 11)
                                .foregroundStyle(Surface.fg3)
                                .monospacedDigit()
                        }
                    }

                    Image(systemName: "chevron.right")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Surface.fg3)
                }

                if case .syncing(let progress) = app.status {
                    MiniProgressBar(progress: progress)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering || focused ? Surface.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                // Visible focus ring for Full Keyboard Access (plain buttons
                // suppress the system effect).
                if focused {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Palette.accent, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled(false)
        .onHover { hovering = $0 }
        .accessibilityLabel(
            "\(app.name), \(app.backend.badgeLabel), \(app.status.shortLabel)"
            + (app.localSizeBytes > 0 ? ", \(Format.size(app.localSizeBytes)) on this Mac" : "")
        )
        .accessibilityHint("Shows sync details")
    }
}
