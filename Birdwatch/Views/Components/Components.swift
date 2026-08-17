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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .accessibilityValue(indeterminate ? "In progress" : "\(Int((progress * 100).rounded())) percent")
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
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldPulse: Bool { pulses && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(shouldPulse && pulsing ? 0.35 : 1)
            .animation(shouldPulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil, value: pulsing)
            .onAppear { if shouldPulse { pulsing = true } }
            .accessibilityHidden(true)
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

/// Standard content header: 24/700 title + 13.5 muted subtitle, 920pt column.
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

/// Standard scrolling content column: max 920pt, 24/30 padding, fade-in.
struct ContentColumn<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 30)
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

/// Live-updating relative time ("26 min ago"); `.relative` style counts on its own.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        (Text(date, style: .relative) + Text(" ago"))
            .scaledFont(size: 11.5)
            .foregroundStyle(Surface.fg3)
            .monospacedDigit()
    }
}
