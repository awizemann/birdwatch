import AppKit
import QuartzCore
import SwiftUI

// MARK: - Dynamic Type

/// Design-size fonts that scale with the user's text size (§12 — Dynamic Type
/// is launch-blocking). Use `.scaledFont(size:weight:)` everywhere a design
/// point size is specified; never a bare `.font(.system(size:))`.
private struct ScaledFont: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

// MARK: - Card

/// The standard content card: Surface.card fill, 0.5px cardline border, 12pt radius.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Surface.cardLine, lineWidth: 0.5))
    }
}

/// Muted 11pt/700 letter-spaced section label ("APPLE APPS", "MONITOR").
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .scaledFont(size: 11, weight: .bold)
            .kerning(0.5)
            .foregroundStyle(Surface.fg2)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Tiles

/// Rounded color tile with an SF Symbol or a first-letter fallback.
struct ColorTile: View {
    let color: Color
    var symbolName: String?
    var letter: String?
    var size: CGFloat = 32

    init(color: Color, symbolName: String? = nil, letter: String? = nil, size: CGFloat = 32) {
        self.color = color
        self.symbolName = symbolName
        self.letter = letter
        self.size = size
    }

    init(colorHex: String, symbolName: String? = nil, letter: String? = nil, size: CGFloat = 32) {
        self.init(color: Color(hex: colorHex), symbolName: symbolName, letter: letter, size: size)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let symbolName {
                    Image(systemName: symbolName)
                        .scaledFont(size: size * 0.48, weight: .semibold)
                        .foregroundStyle(.white)
                } else if let letter {
                    Text(letter.prefix(1).uppercased())
                        .scaledFont(size: size * 0.48, weight: .bold)
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true) // decorative; siblings carry the name
    }
}

// MARK: - Progress

/// Thin accent-gradient progress bar used across the app.
struct MiniProgressBar: View {
    let progress: Double        // 0...1
    var tint: Color = Palette.accent
    var height: CGFloat = 4
    var label: String = "Progress"
    /// TRUE when the backing channel reports "in progress" with no percentage
    /// (the ubiquity resource values are booleans). Renders a moving shimmer
    /// instead of a fill, and never announces a fabricated percent.
    var indeterminate: Bool = false
    /// What the bar measures when it is not a percentage of work done (e.g.
    /// "3 failed attempts"). nil: the percent, or "In progress".
    var valueDescription: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The bar's spoken value. A fill that is a count of something (retry
    /// attempts) must not be read as "19 percent".
    nonisolated static func spokenValue(progress: Double, indeterminate: Bool, valueDescription: String?) -> String {
        if let valueDescription { return valueDescription }
        return indeterminate ? "In progress" : "\(Int((progress * 100).rounded())) percent"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Surface.hover)
                if indeterminate {
                    indeterminateFill(width: geo.size.width)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Self.spokenValue(progress: progress, indeterminate: indeterminate, valueDescription: valueDescription))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Barber-pole shimmer, or — under Reduce Motion — a static half fill that
    /// reads as "working" without any animation.
    @ViewBuilder
    private func indeterminateFill(width: CGFloat) -> some View {
        if reduceMotion {
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: max(height, width * 0.5))
        } else {
            ShimmerFill(width: width, height: height, tint: tint)
        }
    }
}

/// The travelling shimmer, created and destroyed with the indeterminate
/// branch so every indeterminate spell starts a fresh run.
///
/// Core Animation, not a SwiftUI `repeatForever` (same reason as
/// `PulsingDot`): a SwiftUI repeating animation re-renders the window's view
/// graph every display frame; a layer animation runs in the render server.
private struct ShimmerFill: View {
    let width: CGFloat
    let height: CGFloat
    let tint: Color

    var body: some View {
        ShimmerLayer(colors: [tint.opacity(0.15), tint, tint.opacity(0.15)].map { NSColor($0) })
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A capsule 45% of the track wide, travelling left edge → right edge and
/// wrapping, every 1.2 s; it stays inside the track, so nothing is clipped.
private struct ShimmerLayer: NSViewRepresentable {
    /// Dynamic colours, resolved by the view in its own appearance.
    let colors: [NSColor]

    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

    func updateNSView(_ view: ShimmerView, context: Context) { view.setColors(colors) }

    final class ShimmerView: NSView {
        private let capsule = CAGradientLayer()
        private var animatedWidth: CGFloat = -1
        private var colors: [NSColor] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            capsule.startPoint = CGPoint(x: 0, y: 0.5)
            capsule.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(capsule)
        }

        required init?(coder: NSCoder) { nil }

        func setColors(_ colors: [NSColor]) {
            self.colors = colors
            applyColors()
        }

        /// A CGColor is a snapshot of one appearance: re-resolved whenever
        /// the view's appearance changes (Light ↔ Dark, Increase Contrast),
        /// not only when SwiftUI happens to call updateNSView.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        private func applyColors() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            capsule.colors = resolvedCGColors(colors)
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            let width = bounds.width, height = bounds.height
            guard width != animatedWidth else { return }
            animatedWidth = width
            let capsuleWidth = max(height, width * 0.45)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            capsule.bounds = CGRect(x: 0, y: 0, width: capsuleWidth, height: height)
            capsule.cornerRadius = height / 2
            capsule.position = CGPoint(x: capsuleWidth / 2, y: height / 2)
            CATransaction.commit()
            let travel = CABasicAnimation(keyPath: "position.x")
            travel.fromValue = capsuleWidth / 2
            travel.toValue = capsuleWidth / 2 + max(0, width * 0.55)
            travel.duration = 1.2
            travel.repeatCount = .infinity
            travel.isRemovedOnCompletion = false
            capsule.add(travel, forKey: "shimmer")
        }
    }
}

/// Pulsing status dot. Color always pairs with adjacent text (§12 — never color alone).
struct StatusDot: View {
    let color: Color
    var pulses = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pulse only when asked to and Reduce Motion is off.
    nonisolated static func shouldPulse(pulses: Bool, reduceMotion: Bool) -> Bool {
        pulses && !reduceMotion
    }

    var body: some View {
        Group {
            if Self.shouldPulse(pulses: pulses, reduceMotion: reduceMotion) {
                PulsingDot(color: color)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// The pulse, in its own view so the pulsing branch is created fresh — a
/// dot that appeared idle and later started working pulses from then on.
///
/// Core Animation, not a SwiftUI `repeatForever`: a SwiftUI-driven repeating
/// animation re-renders the window's whole view graph every display frame.
/// One "live" dot in the log console kept the app at ~10% CPU with nothing
/// else changing (`sample`: NSHostingView.layout → ViewGraph render on every
/// display cycle). A layer animation runs in the render server, so the app
/// does no per-frame work at all.
private struct PulsingDot: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        view.setColor(NSColor(color))
    }

    final class PulseView: NSView {
        private let dot = CALayer()
        private var color: NSColor = .clear

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Survives the window going off screen and coming back.
            pulse.isRemovedOnCompletion = false
            dot.add(pulse, forKey: "pulse")
        }

        required init?(coder: NSCoder) { nil }

        func setColor(_ color: NSColor) {
            self.color = color
            applyColor()
        }

        /// Re-resolved on every appearance change (see ShimmerView).
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColor()
        }

        private func applyColor() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.backgroundColor = resolvedCGColors([color]).first
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
            CATransaction.commit()
        }
    }
}

extension NSView {
    /// `colors` as CGColors resolved in THIS view's effective appearance.
    /// Dynamic system and asset colours have no single CGColor; resolving
    /// outside the view's appearance (or once) freezes whichever appearance
    /// happened to be current.
    func resolvedCGColors(_ colors: [NSColor]) -> [CGColor] {
        var resolved: [CGColor] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = colors.map(\.cgColor)
        }
        return resolved
    }
}

// MARK: - Badges & chips

/// Tinted data-source badge (CloudDocs / CloudKit / File Provider).
struct SourceBadge: View {
    let backend: SyncBackend

    var body: some View {
        Text(backend.badgeLabel)
            .scaledFont(size: 9, weight: .heavy)
            .kerning(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private var tint: Color {
        switch backend {
        case .cloudDocs: Palette.navDrive
        case .cloudKit: Palette.navApplications
        case .fileProvider: Palette.gray
        }
    }
}

/// Severity pill on issue cards.
struct SeverityPill: View {
    let severity: IssueSeverity

    var body: some View {
        Text(severity.pillLabel)
            .scaledFont(size: 10, weight: .heavy)
            .kerning(0.4)
            .foregroundStyle(severity.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(severity.tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - View header

/// Standard content header: 24/700 title + 13.5 muted subtitle.
struct ViewHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 24, weight: .bold)
                .kerning(-0.3)
                .foregroundStyle(Surface.fg)
            Text(subtitle)
                .scaledFont(size: 13.5)
                .foregroundStyle(Surface.fg2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Standard scrolling content column: max 1180pt, 24/20 padding, fade-in.
/// Wider than the design handoff's 920pt column on purpose — v0.1.1 widened
/// the content (4c22bac) so cards use a large window; 1180 is the handoff's
/// window cap.
struct ContentColumn<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .modifier(HardTopScrollEdge())
        .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: 6)))
    }
}

/// macOS 26+: content scrolling under the glass toolbar ran straight beneath
/// the Search pill and the toolbar buttons — an info banner's text sat
/// legible behind "Search". The hidden title bar leaves no system scroll-edge
/// effect there (`scrollEdgeEffectStyle(.hard, for: .top)` was tried and drew
/// nothing), so the column masks itself: content fades out over the top
/// `fade` points of its own frame and is never drawn under the toolbar.
/// At rest that band is the column's top padding, so nothing visible changes.
/// Earlier systems keep their own opaque toolbar.
private struct HardTopScrollEdge: ViewModifier {
    private let fade: CGFloat = 14

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: fade)
                    Rectangle()
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Honesty footnote

/// The ⓘ footnote naming the exact data source a screen reads.
struct SourceFootnote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .scaledFont(size: 11.5)
            .foregroundStyle(Surface.fg3)
    }
}

// MARK: - Spinner

/// Small indeterminate spinner shown next to "Syncing" rows.
struct SyncSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Syncing")
    }
}

// MARK: - Relative time

/// "Updated 30s ago" from the store's last landed snapshot. A 15 s timeline,
/// not a per-second one: the label is coarse by design (FreshnessLabel).
struct FreshnessText: View {
    let lastRefresh: Date?
    var size: CGFloat = 11.5
    /// Runs on each 15 s tick — the store re-ages time-bound states on it
    /// (`SyncStore.reageApps`), so an open surface never shows stale activity.
    var onTick: ((Date) -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(FreshnessLabel.text(lastRefresh: lastRefresh, now: context.date))
                .scaledFont(size: size)
                .foregroundStyle(Surface.fg3)
                .monospacedDigit()
                .onChange(of: context.date) { _, date in onTick?(date) }
        }
    }
}

/// Relative time ("26 min. ago", "in 5 min.") on a once-a-minute timeline.
///
/// Was `Text(date, style: .relative) + Text(" ago")`: a per-second timer in
/// every visible row, a seconds count VoiceOver read in full ("3 minutes, 4
/// seconds"), a hard-coded English "ago", and "ago" stuck on future dates.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(RelativeTimeLabel.text(for: date, now: context.date))
                .scaledFont(size: 11.5)
                .foregroundStyle(Surface.fg3)
                .monospacedDigit()
        }
    }
}

/// The words `RelativeTimeText` shows, as a pure function of the clock.
enum RelativeTimeLabel {
    nonisolated static func text(for date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        // No seconds field: a 60 s timeline can't keep a seconds count true.
        // Inside a minute the formatter would round up to "1 min. ago", so
        // format a zero interval instead — "this minute", in its own words.
        let reference = abs(now.timeIntervalSince(date)) < 60 ? date : now
        let style = Date.AnchoredRelativeFormatStyle(
            anchor: date,
            allowedFields: [.year, .month, .week, .day, .hour, .minute],
            presentation: .named,
            unitsStyle: .abbreviated,
            locale: locale
        )
        return style.format(reference)
    }
}
