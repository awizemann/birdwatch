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
            } else if ContentRoute(store: store) == .pausedBeforeFirstLoad {
                // Paused before anything loaded: nothing is in flight, so the
                // spinner would be claiming work that is not happening (C1).
                MonitoringPausedState(compact: true)
                    .frame(width: 328)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 328, height: 120)
                    .accessibilityLabel("Loading iCloud sync state")
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
            Task { await store.menuBarOpened() }
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
        // Each derived fact computed ONCE per render: every one of these walks
        // the app list, and the body used to rebuild them several times over.
        let apps = store.effectiveApps
        let active = apps.filter(\.status.isActive)
        let state = store.overallState
        let overall = OverviewHeroDisplay(
            state: state,
            progress: store.overallProgress,
            progressIsIndeterminate: store.overallProgressIsIndeterminate,
            inFlightCount: store.inFlightTransfers.count,
            pendingFileCount: store.pendingFileCount
        )
        return VStack(alignment: .leading, spacing: 0) {
            header(state: state, overall: overall)
                .padding(.horizontal, 14)
                .padding(.top, 14)

            // Same decision as the Overview hero: a bar only while something
            // is in flight — never "0%" for a paused monitor or "100%" for idle.
            if overall.showsBar {
                MiniProgressBar(progress: store.overallProgress, label: "Overall sync progress",
                                indeterminate: overall.barIsIndeterminate)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            if let hours = store.bandwidth?.hours, !hours.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Sparkline(hours: hours)
                        .frame(height: 26)
                    // The chart carried no caption at all: sighted users saw
                    // bars with no unit and no hint that the figures are
                    // attributed, not measured (C2).
                    Text("iCloud traffic per hour today, estimated")
                        .scaledFont(size: 10.5)
                        .foregroundStyle(Surface.fg2)
                        // The chart element already speaks this line as its
                        // accessibility label; leaving the caption visible to
                        // VoiceOver made it read twice in a row.
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            // Every app the header counts, with or without progress.
            if !active.isEmpty {
                VStack(spacing: 0) {
                    ForEach(active) { app in
                        appRow(app)
                            .padding(.vertical, 7)
                        if app.id != active.last?.id {
                            Divider().overlay(Surface.cardLine)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }

            Divider().overlay(Surface.cardLine)
                .padding(.top, 6)

            if let idleLine = PopoverSummary.idleAppsLine(apps) {
                idleRow(idleLine)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

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

    private func header(state: SyncStore.OverallState, overall: OverviewHeroDisplay) -> some View {
        let isSyncing: Bool = if case .syncing = state { true } else { false }
        let tint: Color = switch state {
        case .paused: Palette.warning
        case .syncing, .active: Palette.accent
        // Neutral: "no activity" is not a confirmed "synced".
        case .idle: Palette.gray
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                StatusDot(color: tint, pulses: overall.tone == .working)
                Text(PopoverSummary.headerTitle(state))
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(Surface.fg)
                    .monospacedDigit()
            }
            if isSyncing {
                Text(overall.subtitle)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg2)
                    .monospacedDigit()
                    .padding(.leading, 15)
            }
            FreshnessText(lastRefresh: store.lastRefresh, size: 11)
                .padding(.leading, 15)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - App rows

    private func appRow(_ app: AppSyncState) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ColorTile(colorHex: app.tileColorHex, letter: app.name, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .scaledFont(size: 12.5, weight: .semibold)
                        .foregroundStyle(Surface.fg)
                        .lineLimit(1)
                    // Dimming was the ONLY mark of a muted row, which reads as
                    // nothing at all to anyone who cannot compare two rows'
                    // opacity. Say it in words as well.
                    if store.isMuted(appID: app.id) {
                        Label("Muted", systemImage: "bell.slash.fill")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(Surface.fg2)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .frame(minWidth: 118, alignment: .leading)
                let display = SyncStatusDisplay(
                    status: app.status, backend: app.backend,
                    progressIsIndeterminate: store.progressIsIndeterminate(appID: app.id)
                )
                switch display.bar {
                case .determinate(let progress):
                    MiniProgressBar(progress: progress, label: "\(app.name) sync progress")
                    Text("\(Int((progress * 100).rounded()))%")
                        .scaledFont(size: 11.5, weight: .semibold)
                        .foregroundStyle(Surface.fg2)
                        .monospacedDigit()
                        .frame(minWidth: 32, alignment: .trailing)
                case .indeterminate:
                    // No percent when the channel has none (TransferItem.isIndeterminate).
                    MiniProgressBar(progress: 0, label: "\(app.name) sync progress", indeterminate: true)
                    Text("…")
                        .scaledFont(size: 11.5, weight: .semibold)
                        .foregroundStyle(Surface.fg2)
                        .frame(minWidth: 32, alignment: .trailing)
                case nil:
                    // Work reported with no progress at all (CloudKit).
                    Text("Active — no progress reported")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .accessibilityElement(children: .combine)
            // Muting silences notifications only — it never pauses sync, so the
            // value must not read as "paused".
            .accessibilityValue(store.isMuted(appID: app.id) ? "Notifications muted" : "")
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

    // MARK: - Summary rows

    /// Idle apps in their rows' own words (PopoverSummary). No checkmark:
    /// "no activity seen" is not a verified result.
    private func idleRow(_ line: String) -> some View {
        Label(line, systemImage: "circle.dashed")
            .scaledFont(size: 12)
            .foregroundStyle(Surface.fg2)
            .monospacedDigit()
    }

    private var issuesRow: some View {
        Button {
            store.navigate(to: .issues, via: .menubar)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                StatusDot(color: Palette.warning)
                Text(PopoverSummary.issuesLine(count: store.issueCount))
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
/// Internal, not private, so its spoken summary is unit-testable.
struct Sparkline: View {
    let hours: [BandwidthHourSample]

    var body: some View {
        let totals = hours.map { $0.uploadedBytes + $0.downloadedBytes }
        let maxTotal = max(totals.max() ?? 1, 1)
        GeometryReader { geo in
            let barWidth = geo.size.width / CGFloat(totals.count)
            Path { path in
                for (i, total) in totals.enumerated() {
                    // Unobserved and silent hours draw nothing (no 2 pt stub).
                    let h = BandwidthPresentation.barHeight(
                        bytes: total, isObserved: hours[i].isObserved,
                        available: geo.size.height, maxBytes: maxTotal)
                    guard h > 0 else { continue }
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
        // Was .accessibilityHidden(true): the only bandwidth figure in the
        // popover, unreadable to VoiceOver. Summarize the series instead of
        // exposing 24 unlabeled bars, and keep the estimate wording (C2).
        .accessibilityElement()
        .accessibilityLabel("iCloud traffic per hour today, estimated")
        .accessibilityValue(Self.summary(of: hours))
    }

    /// "N hours, peak X in the busiest hour, Y total" — derived from the same
    /// samples the bars are drawn from, so the spoken value and the picture can
    /// never disagree. An all-zero series says so rather than implying traffic.
    /// Only OBSERVED hours count: an hour before launch or still to come is
    /// not an hour with no traffic.
    static func summary(of allHours: [BandwidthHourSample]) -> String {
        let hours = allHours.filter(\.isObserved)
        let totals = hours.map { $0.uploadedBytes + $0.downloadedBytes }
        let hourWord = hours.count == 1 ? "hour" : "hours"
        guard let peak = totals.max(), peak > 0 else {
            return "\(hours.count) \(hourWord), no traffic recorded"
        }
        let sum = totals.reduce(Int64(0), +)
        return "\(hours.count) \(hourWord), peak \(Format.size(peak)) in one hour, \(Format.size(sum)) in total"
    }
}
