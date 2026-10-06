import SwiftUI

struct ApplicationsView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        let apps = store.effectiveApps
        let apple = apps.filter(\.isApple)
        let thirdParty = apps.filter { !$0.isApple }

        ContentColumn {
            ViewHeader(title: MonitorView.applications.title, subtitle: MonitorView.applications.subtitle)

            // What the scans behind this list could say: an empty or old list
            // is labelled, never passed off as complete (C1).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let notices = [
                    ScanFreshnessNotice.text(store.containerScan, subject: "app containers", now: context.date),
                    CloudKitNotice.text(store.cloudKitScan, now: context.date),
                ].compactMap { $0 }
                if !notices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notices, id: \.self) { SourceFootnote(text: $0) }
                    }
                }
            }

            appGroup(label: "Apple apps", apps: apple)
            appGroup(label: "Third-party apps", apps: thirdParty)

            SourceFootnote(text: "Per-app status from brctl dump -i and FSEvents transfer flags (CloudDocs), cloudd activity in the unified log over the last 30 min — no per-item progress or counts (CloudKit) — and File Provider apps listed from ~/Library/CloudStorage, without sync status.")
        }
    }

    private func appGroup(label: String, apps: [AppSyncState]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: label)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(apps) { app in
                        AppRow(app: app, display: SyncStatusDisplay(
                            status: app.status, backend: app.backend,
                            progressIsIndeterminate: store.progressIsIndeterminate(appID: app.id)
                        )) { store.detailAppID = app.id }
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
    let display: SyncStatusDisplay
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
                            Text(display.label)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(display.tone.color)
                                .monospacedDigit()
                            if display.showsSpinner { SyncSpinner() }
                        }
                        if let last = app.lastActivity {
                            RelativeTimeText(date: last)
                        }
                        // Local footprint, once the background size pass lands.
                        if let size = app.localSize, size.bytes > 0 {
                            Text(LocalSizeText.text(size))
                                .scaledFont(size: 11)
                                .foregroundStyle(Surface.fg3)
                                .monospacedDigit()
                        }
                    }

                    Image(systemName: "chevron.right")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Surface.fg3)
                }

                switch display.bar {
                case .determinate(let progress):
                    MiniProgressBar(progress: progress, label: "\(app.name) sync progress")
                case .indeterminate:
                    MiniProgressBar(progress: 0, label: "\(app.name) sync progress", indeterminate: true)
                case nil:
                    EmptyView()
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
            "\(app.name), \(app.backend.badgeLabel), \(display.label), \(app.statusLine)"
            + (app.localSize.map { $0.bytes > 0 ? ", \(LocalSizeText.text($0)) on this Mac" : "" } ?? "")
        )
        .accessibilityHint("Shows sync details")
    }
}
