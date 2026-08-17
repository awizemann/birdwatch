import SwiftUI

// MARK: - Hex color

extension Color {
    /// Design-token hex initializer. Only for palette constants below and
    /// per-app tile colors carried in DTOs — views use named tokens.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

// MARK: - Semantic palette (design/design_handoff_birdwatch tokens)

enum Palette {
    static let accent = Color(hex: "0a84ff")
    static let success = Color(hex: "34c759")
    static let warning = Color(hex: "ff9f0a")
    static let error = Color(hex: "ff453a")
    static let gray = Color(hex: "8e8e93")

    // Sidebar tile colors
    static let navOverview = Color(hex: "0a84ff")
    static let navApplications = Color(hex: "5e5ce6")
    static let navDrive = Color(hex: "30b0c7")
    static let navDevices = Color(hex: "af52de")
    static let navIssues = Color(hex: "ff9f0a")
    static let navActivity = Color(hex: "30d158")
    static let navDiagnostics = Color(hex: "ff453a")
    static let navBandwidth = Color(hex: "5856d6")
    static let navStorage = Color(hex: "8e8e93")

    /// Fixed 8-colour storage breakdown palette. The hexes live on
    /// `StorageCategory` (segments are built off-main); this is the view spelling.
    static func storageCategory(_ category: StorageCategory) -> Color {
        Color(hex: category.colorHex)
    }

    // Log console is always dark regardless of appearance.
    static let console = Color(hex: "0b0b0f")
    static let logDebug = Color(hex: "8e8e93")
    static let logInfo = Color(hex: "34c759")
    static let logWarn = Color(hex: "ff9f0a")
    static let logError = Color(hex: "ff453a")
}

// MARK: - Adaptive surface tokens

/// Neutral surfaces that swap with the appearance, matching the handoff's
/// light/dark variable tables. Views never re-spell raw colors where a token exists.
enum Surface {
    static let card = Color(light: "ffffff", dark: "28282d")
    static let window = Color(light: "ffffff", dark: "1d1d21")
    static let fg = Color(light: "1c1c1e", dark: "f2f2f5")
    static let fg2 = Color(light: "6e6e76", dark: "9a9aa0")
    // Deliberate deviation from the handoff tokens (a6a6ac / 68686e ≈ 2:1
    // contrast — fails WCAG for the timestamps/footnotes it labels). These
    // values keep the "faintest text" role while reaching ~4.5:1.
    static let fg3 = Color(light: "73737c", dark: "94949c")

    static let cardLine = Color(lightWhiteAlpha: false, lightAlpha: 0.07, darkAlpha: 0.08)
    static let line = Color(lightWhiteAlpha: false, lightAlpha: 0.09, darkAlpha: 0.09)
    static let hover = Color(lightWhiteAlpha: false, lightAlpha: 0.05, darkAlpha: 0.07)
}

private extension Color {
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }

    /// Black-in-light / white-in-dark alpha token (borders, hover fills).
    init(lightWhiteAlpha: Bool, lightAlpha: CGFloat, darkAlpha: CGFloat) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(darkAlpha)
                : NSColor.black.withAlphaComponent(lightAlpha)
        })
    }
}

// MARK: - Status → color, single source of truth (§12)

extension AppSyncStatus {
    var tint: Color {
        switch self {
        case .upToDate: Palette.success
        case .syncing: Palette.accent
        case .paused: Palette.warning
        case .issue: Palette.error
        }
    }

    var shortLabel: String {
        switch self {
        case .upToDate: "Up to date"
        case .syncing(let p): "Syncing \(Int((p * 100).rounded()))%"
        case .paused: "Paused"
        case .issue: "Needs attention"
        }
    }
}

extension IssueSeverity {
    var tint: Color {
        switch self {
        case .warning: Palette.warning
        case .conflict, .error: Palette.error
        }
    }

    var pillLabel: String {
        switch self {
        case .warning: "Warning"
        case .conflict: "Conflict"
        case .error: "Error"
        }
    }
}

extension ActivityKind {
    var tint: Color {
        switch self {
        case .upload: Palette.accent
        case .done: Palette.success
        case .warning: Palette.warning
        case .conflict: Palette.error
        case .info: Palette.gray
        }
    }
}

extension LogLevel {
    var tint: Color {
        switch self {
        case .debug: Palette.logDebug
        case .info: Palette.logInfo
        case .warn: Palette.logWarn
        case .error: Palette.logError
        }
    }
}

extension TransferDirection {
    var tint: Color { self == .upload ? Palette.accent : Palette.success }
    var symbolName: String { self == .upload ? "arrow.up" : "arrow.down" }
}

/// Daemon CPU health thresholds from the Diagnostics design (green <15 / amber <30 / red ≥30).
func cpuTint(_ percent: Double) -> Color {
    if percent < 15 { Palette.success } else if percent < 30 { Palette.warning } else { Palette.error }
}

// MARK: - Formatting helpers (allocated once — never in view bodies)

/// MainActor-isolated on purpose: formatters are not Sendable, and all
/// formatting happens in the view layer on main.
enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func size(_ bytes: Int64) -> String { Self.bytes.string(fromByteCount: bytes) }

    /// Compact age for engine-reported waits ("75d", "3.8h", "12m").
    static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<90: "\(Int(seconds.rounded()))s"
        case ..<5_400: "\(Int((seconds / 60).rounded()))m"
        case ..<172_800: "\(Int((seconds / 3_600).rounded()))h"
        default: "\(Int((seconds / 86_400).rounded()))d"
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Plan-scale sizes: TB above a terabyte, GB below, trailing zeros trimmed
    /// so it reads the way System Settings does ("1.8 TB", "2 TB", "205.3 GB").
    nonisolated static func capacity(_ bytes: Int64) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 1 { return trimmed(String(format: "%.2f", tb)) + " TB" }
        return trimmed(String(format: "%.1f", Double(bytes) / 1_000_000_000)) + " GB"
    }

    /// "2.00" → "2", "1.80" → "1.8", "205.3" → "205.3".
    private nonisolated static func trimmed(_ value: String) -> String {
        guard value.contains(".") else { return value }
        var out = value
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }
}
