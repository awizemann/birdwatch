import SwiftUI

struct OverviewView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        // Every app doing work, with or without progress — the hero's
        // "Activity in N apps" and this column must count the same apps.
        let active = store.activeApps
        let paused = store.isGloballyPaused

        ContentColumn {
            ViewHeader(title: MonitorView.overview.title, subtitle: MonitorView.overview.subtitle)

            heroCard
            if paused {
                SourceFootnote(text: "Pause stops Birdwatch's own polling and log streams. iCloud continues syncing in the background; data shown is the last snapshot taken before the pause.")
            }
            statGrid(activeCount: active.count)
            HStack(alignment: .top, spacing: 18) {
                activeTransfersColumn(active: active, paused: paused)
                recentActivityColumn
            }
            SourceFootnote(text: "Aggregated from brctl status (bird), cloudd item counts and fileproviderd domain status.")
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        // Every claim the hero makes is decided in OverviewHeroDisplay: the
        // live channel is boolean, CloudKit reports work without progress,
        // and a paused monitor knows nothing current.
        let progress = store.overallProgress
        let hero = OverviewHeroDisplay(
            state: store.overallState,
            progress: progress,
            progressIsIndeterminate: store.overallProgressIsIndeterminate,
            inFlightCount: store.inFlightTransfers.count,
            pendingFileCount: store.pendingFileCount
        )
        let tint: Color = switch hero.tone {
        case .paused: Palette.warning
        case .working: Palette.accent
        // Neutral, not success green: "nothing detected" is not "synced".
        case .idle: Palette.gray
        }

        return Card(padding: 22) {
            HStack(spacing: 24) {
                ProgressRing(ring: hero.ring, tint: tint)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(color: tint, pulses: hero.tone == .working)
                        Text(hero.title)
                            .scaledFont(size: 19, weight: .bold)
                            .foregroundStyle(Surface.fg)
                            .monospacedDigit()
                    }
                    Text(hero.subtitle)
                        .scaledFont(size: 13)
                        .foregroundStyle(Surface.fg2)
                        .monospacedDigit()
                    FreshnessText(lastRefresh: store.lastRefresh)
                    if hero.showsBar {
                        MiniProgressBar(progress: progress, tint: tint, height: 6,
                                        label: "Overall sync progress", indeterminate: hero.barIsIndeterminate)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Stat grid

    private func statGrid(activeCount: Int) -> some View {
        let uploadingBytes = remainingBytes(direction: .upload)
        let downloadingBytes = remainingBytes(direction: .download)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            StatTile(label: "Uploading", value: Format.size(uploadingBytes), tint: Palette.accent)
            StatTile(label: "Downloading", value: Format.size(downloadingBytes), tint: Palette.success)
            StatTile(label: "Active apps", value: "\(activeCount)", tint: Surface.fg)
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

    private func activeTransfersColumn(active: [AppSyncState], paused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Active transfers")
            Card {
                if paused || active.isEmpty {
                    Text(paused ? "Monitoring is paused — transfer activity is not being watched." : "No apps are actively transferring.")
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Surface.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 12) {
                        ForEach(active.prefix(4)) { app in
                            activeTransferRow(app)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activeTransferRow(_ app: AppSyncState) -> some View {
        let display = SyncStatusDisplay(
            status: app.status, backend: app.backend,
            progressIsIndeterminate: store.progressIsIndeterminate(appID: app.id)
        )
        let pending = store.transfers(for: app.id).filter { !$0.isDone }.count
        return HStack(spacing: 10) {
            ColorTile(colorHex: app.tileColorHex, letter: app.name, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                switch display.bar {
                case .determinate(let progress):
                    MiniProgressBar(progress: progress, label: "\(app.name) sync progress")
                case .indeterminate:
                    MiniProgressBar(progress: 0, label: "\(app.name) sync progress", indeterminate: true)
                case nil:
                    // Work reported without any progress (CloudKit): no bar.
                    Text("Active — no progress reported")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg2)
                }
            }
            Group {
                switch display.bar {
                case .determinate(let progress): Text("\(Int((progress * 100).rounded()))%")
                case .indeterminate: Text(Plural.count(pending, "file"))
                case nil: EmptyView()
                }
            }
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

/// 104pt conic-gradient ring with "N% / SYNCED" center, per the Overview hero
/// spec. Only a real percentage shows a number: no honest percentage spins a
/// short arc ("SYNCING"), a paused monitor shows a pause glyph, and the idle
/// state says "NO ACTIVITY" rather than "100% SYNCED".
private struct ProgressRing: View {
    let ring: OverviewHeroDisplay.Ring
    var tint: Color = Palette.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    private var indeterminate: Bool { ring == .indeterminate }

    private var trim: Double {
        switch ring {
        case .percent(let progress): min(max(progress, 0), 1)
        case .indeterminate: 0.22
        case .paused: 0
        // No arc: a full ring would read as 100% synced, which idle isn't.
        case .idle: 0
        }
    }

    var body: some View {
        ZStack {
            Circle()
                // Idle: a dashed track — neither empty (0%) nor complete.
                .stroke(Surface.hover, style: StrokeStyle(lineWidth: 10, dash: ring == .idle ? [4, 6] : []))
            Circle()
                .trim(from: 0, to: trim)
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
                switch ring {
                case .percent(let progress):
                    Text("\(Int((progress * 100).rounded()))%")
                        .scaledFont(size: 22, weight: .bold)
                        .foregroundStyle(Surface.fg)
                        .monospacedDigit()
                case .indeterminate:
                    centerSymbol("arrow.trianglehead.2.clockwise.rotate.90.icloud")
                case .paused:
                    centerSymbol("pause.fill")
                case .idle:
                    centerSymbol("icloud")
                }
                Text(caption)
                    .scaledFont(size: 9, weight: .heavy)
                    .kerning(0.5)
                    .foregroundStyle(Surface.fg3)
            }
        }
        .frame(width: 104, height: 104)
        .accessibilityElement()
        .accessibilityLabel("Overall sync progress")
        .accessibilityValue(accessibilityValue)
    }

    private func centerSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .scaledFont(size: 20, weight: .semibold)
            .foregroundStyle(Surface.fg)
    }

    private var caption: String {
        switch ring {
        case .percent: "SYNCED"
        case .indeterminate: "SYNCING"
        case .paused: "PAUSED"
        case .idle: "NO ACTIVITY"
        }
    }

    private var accessibilityValue: String {
        switch ring {
        case .percent(let progress): "\(Int((progress * 100).rounded())) percent synced"
        case .indeterminate: "In progress"
        case .paused: "Monitoring paused"
        case .idle: "No sync activity detected"
        }
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
