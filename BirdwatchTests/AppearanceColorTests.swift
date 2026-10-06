import AppKit
import Testing
@testable import Birdwatch

/// PulsingDot, ShimmerLayer and SpinningArc hand Core Animation CGColors,
/// and a CGColor is a snapshot of one appearance. They now keep the dynamic
/// NSColor and re-resolve it, through `resolvedCGColors`, in the view's own
/// effective appearance whenever that changes.
@MainActor
@Suite("Layer colours follow the appearance")
struct AppearanceColorTests {

    private let dynamic = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }

    private func components(_ color: CGColor?) -> [CGFloat] {
        (color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [])
            .map { ($0 * 100).rounded() / 100 }
    }

    @Test("The same dynamic colour resolves per view appearance")
    func resolvesInTheViewsAppearance() {
        let light = NSView(), dark = NSView()
        light.appearance = NSAppearance(named: .aqua)
        dark.appearance = NSAppearance(named: .darkAqua)
        #expect(components(light.resolvedCGColors([dynamic]).first) == [0, 0, 0, 1])
        #expect(components(dark.resolvedCGColors([dynamic]).first) == [1, 1, 1, 1])
    }

    // Fails on the old code, which resolved once with whatever appearance
    // was current when SwiftUI built the representable.
    @Test("A view switched to Dark resolves the Dark colour")
    func switchesWithTheView() {
        let view = NSView()
        view.appearance = NSAppearance(named: .aqua)
        let before = components(view.resolvedCGColors([dynamic]).first)
        view.appearance = NSAppearance(named: .darkAqua)
        #expect(before != components(view.resolvedCGColors([dynamic]).first))
    }
}
