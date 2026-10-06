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
    /// "attempt 12 of 62"). nil: the percent, or "In progress".
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

/// The travelling shimmer, in its own view so it owns its own `@State`.
///
/// WHY SEPARATE: when the phase state lived on `MiniProgressBar`, a *second*
/// indeterminate spell reused the surviving view identity — `shimmerPhase` was
/// still 1 from the first spell, `onAppear` set it to 1 again, and SwiftUI saw
/// old == new, so no animation was scheduled and the bar sat frozen. Here the
/// view is created and destroyed with the indeterminate branch, so every spell
/// gets a fresh `-1` and a real -1 → 1 transition.
private struct ShimmerFill: View {
    let width: CGFloat
    let height: CGFloat
    let tint: Color

    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.15), tint, tint.opacity(0.15)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: max(height, width * 0.45))
            // Travels left edge → right edge and wraps; stays inside the
            // track, so no clipping of the parent is needed.
            .offset(x: (shimmerPhase + 1) / 2 * max(0, width * 0.55))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1
                }
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

/// The pulse, in its own view so it owns its own `@State` — the same reason
/// as `ShimmerFill`. When the flag lived on `StatusDot` and was latched in
/// `onAppear`, a dot that appeared idle and later started syncing never
/// pulsed (onAppear had already run). Here the view is created with the
/// pulsing branch, so every idle → working change starts a fresh pulse.
private struct PulsingDot: View {
    let color: Color
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .opacity(dimmed ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
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
        .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: 6)))
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
