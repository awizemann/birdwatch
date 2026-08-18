import SwiftUI

struct OverviewView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        let syncing = store.syncingApps
        let paused = store.isGloballyPaused

        ContentColumn {
            ViewHeader(title: MonitorView.overview.title, subtitle: MonitorView.overview.subtitle)

            heroCard
            if paused {
                SourceFootnote(text: "Pause stops Birdwatch's own polling and log streams. iCloud continues syncing in the background; data shown is the last snapshot taken before the pause.")
            }
            statGrid
            HStack(alignment: .top, spacing: 18) {
                activeTransfersColumn(syncing: syncing, paused: paused)
                recentActivityColumn
            }
            SourceFootnote(text: "Aggregated from brctl status (bird), cloudd item counts and fileproviderd domain status.")
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        // Three-way state; overallProgress is pause-aware in the store, so no
        // view-side special-casing.
        let state = store.overallState
        let progress = store.overallProgress
        // The live channel reports a boolean per file. When nothing in flight
        // carries a real fraction the ring must NOT show a mean of zeros.
        let indeterminate = store.overallProgressIsIndeterminate
        let inFlightCount = store.inFlightTransfers.count

        let dotColor: Color
        let pulses: Bool
        let title: String
        let subtitle: String
        var ringTint: Color = Palette.accent
        switch state {
        case .paused:
            dotColor = Palette.warning
            pulses = false
            title = "Monitoring paused"
            subtitle = "macOS does not offer a supported way to pause iCloud sync itself — Birdwatch has stopped watching."
        case .syncing(let appCount):
            dotColor = Palette.accent
            pulses = true
            title = indeterminate
                ? "Syncing \(inFlightCount) file\(inFlightCount == 1 ? "" : "s")"
                : "Syncing \(appCount) apps"
            subtitle = indeterminate
                ? "macOS reports these as in progress without a percentage."
                : "\(store.pendingFileCount) files remaining"
        case .allSynced:
            dotColor = Palette.success
            pulses = false
            title = "Everything is up to date"
            subtitle = "All apps are fully synced."
            ringTint = Palette.success
        }

        return Card(padding: 22) {
            HStack(spacing: 24) {
                ProgressRing(progress: progress, tint: ringTint, indeterminate: indeterminate)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(color: dotColor, pulses: pulses)
                        Text(title)
                            .scaledFont(size: 19, weight: .bold)
                            .foregroundStyle(Surface.fg)
                            .monospacedDigit()
                    }
                    Text(subtitle)
                        .scaledFont(size: 13)
                        .foregroundStyle(Surface.fg2)
                        .monospacedDigit()
                    MiniProgressBar(progress: progress, tint: ringTint, height: 6,
                                    label: "Overall sync progress", indeterminate: indeterminate)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Stat grid

    private var statGrid: some View {
        let uploadingBytes = remainingBytes(direction: .upload)
        let downloadingBytes = remainingBytes(direction: .download)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            StatTile(label: "Uploading", value: Format.size(uploadingBytes), tint: Palette.accent)
            StatTile(label: "Downloading", value: Format.size(downloadingBytes), tint: Palette.success)
            StatTile(label: "Active apps", value: "\(store.syncingApps.count)", tint: Surface.fg)
            StatTile(label: "Issues", value: "\(store.issueCount)",
                     tint: store.issueCount > 0 ? Palette.warning : Surface.fg)
        }
    }

    private func remainingBytes(direction: TransferDirection) -> Int64 {
        store.transfers
            .filter { $0.direction == direction && !$0.isDone }
            .reduce(Int64(0)) { $0 + Int64(Double($1.sizeBytes) * (1 - $1.progress)) }
    }

    // MARK: - Columns

    private func activeTransfersColumn(syncing: [AppSyncState], paused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Active transfers")
            Card {
                if paused || syncing.isEmpty {
                    Text(paused ? "Monitoring is paused — transfer activity is not being watched." : "No apps are actively transferring.")
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Surface.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 12) {
                        ForEach(syncing.prefix(4)) { app in
                            activeTransferRow(app)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activeTransferRow(_ app: AppSyncState) -> some View {
        let progress: Double = if case .syncing(let p) = app.status { p } else { 0 }
        let indeterminate = store.progressIsIndeterminate(appID: app.id)
        let pending = store.transfers(for: app.id).filter { !$0.isDone }.count
        return HStack(spacing: 10) {
            ColorTile(colorHex: app.tileColorHex, letter: app.name, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                MiniProgressBar(progress: progress, label: "\(app.name) sync progress",
                                indeterminate: indeterminate)
            }
            Text(indeterminate ? "\(pending) file\(pending == 1 ? "" : "s")"
                               : "\(Int((progress * 100).rounded()))%")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Surface.fg2)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var recentActivityColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Recent activity")
                Spacer()
                Button("All") { store.navigate(to: .activity, via: .link) }
                    .buttonStyle(.plain)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Palette.accent)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Show all activity")
            }
            Card {
                VStack(spacing: 12) {
                    ForEach(store.activity.prefix(4)) { event in
                        activityRow(event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: event.kind.tint)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                    .lineLimit(1)
                Text(event.detail)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            RelativeTimeText(date: event.date)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress ring

/// 104pt conic-gradient ring with "N% / SYNCED" center, per the Overview hero spec.
private struct ProgressRing: View {
    let progress: Double
    var tint: Color = Palette.accent
    /// No honest percentage available — the ring spins a short arc and the
    /// centre says SYNCING instead of "0%".
    var indeterminate: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        let percent = Int((progress * 100).rounded())
        ZStack {
            Circle()
                .stroke(Surface.hover, lineWidth: 10)
            Circle()
                .trim(from: 0, to: indeterminate ? 0.22 : min(max(progress, 0), 1))
                .stroke(
                    // Fixed 0–360° gradient under the trim — the trim alone
                    // clips it, so the gradient never double-scales.
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(indeterminate ? (spin ? 270 : -90) : -90))
                .animation(
                    indeterminate && !reduceMotion
                        ? .linear(duration: 1.4).repeatForever(autoreverses: false) : nil,
                    value: spin
                )
                // `indeterminate` is false at first paint (the snapshot has not
                // landed yet), so an onAppear-only latch could never fire and
                // never restart. Drive the flag off the VALUE both ways: true
                // starts the repeating rotation, false stops it and resets the
                // arc to the 12-o'clock start. onAppear covers the case where
                // the view is created already indeterminate.
                .onChange(of: indeterminate) { _, isIndeterminate in
                    spin = isIndeterminate && !reduceMotion
                }
                .onAppear { spin = indeterminate && !reduceMotion }
            VStack(spacing: 1) {
                if indeterminate {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                        .scaledFont(size: 20, weight: .semibold)
                        .foregroundStyle(Surface.fg)
                } else {
                    Text("\(percent)%")
                        .scaledFont(size: 22, weight: .bold)
                        .foregroundStyle(Surface.fg)
                        .monospacedDigit()
                }
                Text(indeterminate ? "SYNCING" : "SYNCED")
                    .scaledFont(size: 9, weight: .heavy)
                    .kerning(0.5)
                    .foregroundStyle(Surface.fg3)
            }
        }
        .frame(width: 104, height: 104)
        .accessibilityElement()
        .accessibilityLabel("Overall sync progress")
        .accessibilityValue(indeterminate ? "In progress" : "\(percent) percent synced")
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Surface.fg2)
                Text(value)
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
