import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(SyncStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.hasLoaded {
                content
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 328, height: 120)
            }
        }
        // Cached-first: `content` renders from the store's existing snapshot on
        // the same frame the popover opens — the .task below runs after the
        // first render and never gates it; the spinner only appears before the
        // very first load. The store's 60s debounce makes repeated opens free.
        .task { await store.refresh() }
        // The popover is a transfer-showing surface in its own right. Without
        // this, closing the main window paused the FSEvents watcher + probe
        // ticker for good and the popover showed a frozen transfer list
        // forever — the window's onDisappear was the only resume/pause driver.
        .onAppear {
            NotificationCenter.default.post(name: UbiquityTransferSource.resumeRequest, object: nil)
        }
        .onDisappear {
            // Only pause when nothing else is on screen: the popover can be
            // dismissed while the main window is still open and showing live
            // transfers, and pausing then would freeze the window instead.
            guard !Self.hasVisibleMainWindow else { return }
            NotificationCenter.default.post(name: UbiquityTransferSource.pauseRequest, object: nil)
        }
        .background(Surface.card)
    }

    /// A visible, non-panel app window — i.e. the main monitor window. The
    /// popover and the menu-bar extra are hosted in NSPanels, so excluding
    /// panels is what distinguishes "the window is up" from "only the popover".
    @MainActor
    private static var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)

            MiniProgressBar(progress: store.overallProgress, label: "Overall sync progress",
                            indeterminate: store.overallProgressIsIndeterminate)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            if let hours = store.bandwidth?.hours, !hours.isEmpty {
                Sparkline(hours: hours)
                    .frame(height: 26)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            if !store.syncingApps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(store.syncingApps) { app in
                        appRow(app)
                            .padding(.vertical, 7)
                        if app.id != store.syncingApps.last?.id {
                            Divider().overlay(Surface.cardLine)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }

            Divider().overlay(Surface.cardLine)
                .padding(.top, 6)

            upToDateRow
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            if store.issueCount > 0 {
                issuesRow
            }

            Divider().overlay(Surface.cardLine)

            footer
                .padding(12)
        }
        .frame(width: 328)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                StatusDot(color: headerTint, pulses: isSyncing)
                Text(headerTitle)
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(Surface.fg)
                    .monospacedDigit()
            }
            if isSyncing {
                Text("\(store.pendingFileCount) files remaining")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg2)
                    .monospacedDigit()
                    .padding(.leading, 15)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isSyncing: Bool {
        if case .syncing = store.overallState { true } else { false }
    }

    private var headerTitle: String {
        switch store.overallState {
        case .paused: "Monitoring paused"
        case .syncing(let appCount): appCount == 1 ? "Syncing 1 app" : "Syncing \(appCount) apps"
        case .allSynced: "All synced"
        }
    }

    private var headerTint: Color {
        switch store.overallState {
        case .paused: Palette.warning
        case .syncing: Palette.accent
        case .allSynced: Palette.success
        }
    }

    // MARK: - App rows

    private func appRow(_ app: AppSyncState) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ColorTile(colorHex: app.tileColorHex, letter: app.name, size: 22)
                Text(app.name)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                    .lineLimit(1)
                    .frame(minWidth: 118, alignment: .leading)
                MiniProgressBar(progress: appProgress(app), label: "\(app.name) sync progress",
                                indeterminate: store.progressIsIndeterminate(appID: app.id))
                // No percent when the channel has none (see TransferItem.isIndeterminate).
                Text(store.progressIsIndeterminate(appID: app.id)
                     ? "…" : "\(Int((appProgress(app) * 100).rounded()))%")
                    .scaledFont(size: 11.5, weight: .semibold)
                    .foregroundStyle(Surface.fg2)
                    .monospacedDigit()
                    .frame(minWidth: 32, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            // Quick "mute": dims the row and silences the app's notifications.
            // It does NOT (and cannot) pause the app's iCloud sync.
            Button {
                store.toggleMute(appID: app.id)
            } label: {
                Image(systemName: store.isMuted(appID: app.id) ? "bell.slash.fill" : "bell.slash")
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(Surface.fg2)
                    .frame(width: 22, height: 22)
                    .background(Surface.hover, in: Circle())
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isMuted(appID: app.id) ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .opacity(store.isMuted(appID: app.id) ? 0.45 : 1)
    }

    private func appProgress(_ app: AppSyncState) -> Double {
        if case .syncing(let p) = app.status { p } else { 0 }
    }

    // MARK: - Summary rows

    private var upToDateRow: some View {
        let upToDateCount = store.effectiveApps.filter { $0.status == .upToDate }.count
        return Label("\(upToDateCount) apps up to date", systemImage: "checkmark")
            .scaledFont(size: 12)
            .foregroundStyle(Surface.fg2)
            .monospacedDigit()
    }

    private var issuesRow: some View {
        Button {
            store.navigate(to: .issues)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                StatusDot(color: Palette.warning)
                Text("\(store.issueCount) issues need attention")
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Palette.warning)
                    .monospacedDigit()
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(Palette.warning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.warning.opacity(0.1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(store.isGloballyPaused ? "Resume Monitoring" : "Pause Monitoring") {
                store.togglePauseAll()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button("Open Monitor") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Sparkline

/// Tiny recent-bandwidth sparkline: one bar per hour of combined traffic.
private struct Sparkline: View {
    let hours: [BandwidthHourSample]

    var body: some View {
        let totals = hours.map { $0.uploadedBytes + $0.downloadedBytes }
        let maxTotal = max(totals.max() ?? 1, 1)
        GeometryReader { geo in
            let barWidth = geo.size.width / CGFloat(totals.count)
            Path { path in
                for (i, total) in totals.enumerated() {
                    let h = max(2, geo.size.height * CGFloat(total) / CGFloat(maxTotal))
                    path.addRoundedRect(
                        in: CGRect(
                            x: CGFloat(i) * barWidth,
                            y: geo.size.height - h,
                            width: max(1, barWidth - 2),
                            height: h
                        ),
                        cornerSize: CGSize(width: 1, height: 1)
                    )
                }
            }
            .fill(Palette.accent.opacity(0.55))
        }
        .accessibilityHidden(true)
    }
}
