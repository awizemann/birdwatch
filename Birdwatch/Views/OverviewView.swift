import SwiftUI

struct OverviewView: View {
    @Environment(SyncStore.self) private var store
    /// Width the stat tiles get; drives one row of four vs two rows of two.
    @State private var statGridWidth: CGFloat = 0

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
            SourceFootnote(text: "Aggregated from brctl dump -i (bird engine state), FSEvents transfer flags and cloudd activity in the unified log. File Provider apps are listed from ~/Library/CloudStorage without sync status.")
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
            pendingFileCount: store.pendingFileCount,
            unknownAppCount: store.unknownStateAppCount,
            unwatchedAppCount: store.unwatchedApps.count,
            unreportedAppCount: store.unreportedAppCount,
            backlogLine: BacklogSummary.appsLine(store.effectiveApps, leading: true)
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
                    FreshnessText(lastRefresh: store.lastRefresh, onTick: { store.reageApps(now: $0) })
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
        let unwatched = store.unwatchedApps
        let ready = store.hasLoaded && store.transferWatchReady
        let up = TransferWatchNotes.tile(bytes: remainingBytes(direction: .upload),
                                         paused: store.isGloballyPaused, unwatched: unwatched, ready: ready)
        let down = TransferWatchNotes.tile(bytes: remainingBytes(direction: .download),
                                           paused: store.isGloballyPaused, unwatched: unwatched, ready: ready)
        let apps = OverviewTiles.activeApps(count: activeCount, loaded: store.hasLoaded,
                                            paused: store.isGloballyPaused)
        let issues = IssuesTile.display(count: store.issueCount, qualifiers: IssuesEmptyState.qualifiers(
            isPaused: store.isGloballyPaused,
            deliveredProducers: store.deliveredIssueProducers, conflictScanCap: store.conflictScanCap,
            engineReadAt: store.engineReadAt))
        let upTile = StatTile(label: "Uploading", value: up.value, tint: Palette.accent, caption: up.caption)
        let downTile = StatTile(label: "Downloading", value: down.value, tint: Palette.success, caption: down.caption)
        let appsTile = StatTile(label: "Active apps", value: apps.value, tint: Surface.fg, caption: apps.caption)
        let issuesTile = StatTile(label: "Issues", value: issues.value,
                                  tint: store.issueCount > 0 ? Palette.warning : Surface.fg, caption: issues.caption)
        // One row of four where it fits, else two rows of two — never three
        // plus one stranded tile (the adaptive grid's answer at mid widths).
        // Decided by WIDTH, not ViewThatFits: that measures captions on one
        // line, so it chose 2×2 where four fit and flipped as captions changed.
        // Tiles in a row share its height, captioned or not.
        return Group {
            if OverviewTiles.columns(forWidth: statGridWidth) == 4 {
                HStack(alignment: .top, spacing: 14) {
                    upTile; downTile; appsTile; issuesTile
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow { upTile; downTile }
                    GridRow { appsTile; issuesTile }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { statGridWidth = $0 }
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
                VStack(alignment: .leading, spacing: 12) {
                    if paused || active.isEmpty {
                        Text(paused ? "Monitoring is paused — transfer activity is not being watched." : "No apps are actively transferring.")
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(active.prefix(4)) { app in
                            activeTransferRow(app)
                        }
                    }
                    // A row Birdwatch can't watch is shown, with "—", not
                    // silently left out of "nothing transferring".
                    if !paused {
                        ForEach(store.unwatchedApps) { app in
                            unwatchedRow(app)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activeTransferRow(_ app: AppSyncState) -> some View {
        let display = SyncStatusDisplay(
            app: app,
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
                case .determinate(let progress): Text(Format.percent(progress))
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

    private func unwatchedRow(_ app: AppSyncState) -> some View {
        HStack(spacing: 10) {
            ColorTile(colorHex: app.tileColorHex, letter: app.name, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                Text("Not watched — needs Full Disk Access")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg2)
            }
            Spacer()
            Text("—")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Surface.fg2)
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
                    if store.activity.isEmpty {
                        Text(ActivityEmptyState.text(paused: store.isGloballyPaused))
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
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
        .accessibilityLabel { label in
            // The dot's colour was the only mark of the kind.
            if let kind = event.kind.spokenKind { Text(kind) }
            label
        }
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
            if indeterminate && !reduceMotion {
                // Created and destroyed with the indeterminate state, so each
                // spell spins from 12 o'clock. Core Animation, not a SwiftUI
                // repeatForever: that re-rendered the window every frame
                // (~12% CPU on the Overview with nothing else changing).
                SpinningArc(trim: trim, lineWidth: 10,
                            colors: [tint.opacity(0.55), tint].map { NSColor($0) })
            } else {
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
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                switch ring {
                case .percent(let progress):
                    Text(Format.percent(progress))
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
    /// What limits the figure ("Excludes Desktop & Documents").
    var caption: String? = nil

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Surface.fg2)
                Text(value)
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundStyle(value == "—" ? Surface.fg2 : tint)
                    .monospacedDigit()
                if let caption {
                    Text(caption)
                        .scaledFont(size: 11)
                        .foregroundStyle(Surface.fg3)
                        .lineLimit(2)
                }
            }
            // Fills the row's height, so a tile without a caption is as tall
            // as its captioned neighbours.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: OverviewTiles.minimumTileWidth)
        .accessibilityElement(children: .combine)
    }
}

/// The indeterminate hero arc: a conic-gradient arc that turns once every
/// 1.4 s, drawn and rotated by Core Animation in the render server.
private struct SpinningArc: NSViewRepresentable {
    let trim: Double
    let lineWidth: CGFloat
    /// Dynamic colours, resolved by the view in its own appearance.
    let colors: [NSColor]

    func makeNSView(context: Context) -> ArcView { ArcView() }

    func updateNSView(_ view: ArcView, context: Context) {
        view.configure(trim: trim, lineWidth: lineWidth, colors: colors)
    }

    final class ArcView: NSView {
        private let spinner = CALayer()
        private let gradient = CAGradientLayer()
        private let arc = CAShapeLayer()
        private var trim: Double = 0.22
        private var lineWidth: CGFloat = 10
        private var colors: [NSColor] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            arc.fillColor = nil
            arc.strokeColor = NSColor.black.cgColor
            arc.lineCap = .round
            gradient.mask = arc
            spinner.addSublayer(gradient)
            layer?.addSublayer(spinner)
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi          // clockwise on screen
            turn.duration = 1.4
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            spinner.add(turn, forKey: "spin")
        }

        required init?(coder: NSCoder) { nil }

        func configure(trim: Double, lineWidth: CGFloat, colors: [NSColor]) {
            self.trim = trim
            self.lineWidth = lineWidth
            self.colors = colors
            applyColors()
            needsLayout = true
        }

        /// Re-resolved on every appearance change (see ShimmerView).
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        private func applyColors() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = resolvedCGColors(colors)
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spinner.bounds = bounds
            spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
            gradient.frame = bounds
            arc.frame = bounds
            arc.lineWidth = lineWidth
            let radius = (min(bounds.width, bounds.height) - lineWidth) / 2
            // Starts at 12 o'clock and runs clockwise for `trim` of a turn
            // (layer y points up on macOS, so clockwise is a negative angle).
            let start = CGFloat.pi / 2
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                        startAngle: start, endAngle: start - 2 * .pi * trim, clockwise: true)
            arc.path = path
            CATransaction.commit()
        }
    }
}
