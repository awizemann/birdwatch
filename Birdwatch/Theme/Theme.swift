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

// A sync status's words AND colour come from `SyncStatusDisplay`: neither
// can be honest without the backend and the store's indeterminate decision.
extension SyncStatusDisplay.Tone {
    /// Green only for a confirmed state; an unconfirmable idle is neutral.
    var color: Color {
        switch self {
        case .confirmed: Palette.success
        case .working: Palette.accent
        case .neutral: Surface.fg2
        case .warning: Palette.warning
        case .error: Palette.error
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

/// The type is MainActor (the default isolation) because its two stored
/// formatters, `bytes` and `relative`, are not Sendable — so `size(_:)`,
/// `relative` and `gigabytes(_:)` are main-actor only. Every FormatStyle-based
/// helper (`capacity`, `percent`, `duration`, `compactUnit`, `cpu`, `memory`,
/// `clockTime`, `hourOfDay`) is `nonisolated`, since data sources build
/// user-facing text with them off the main actor.
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

    /// Compact age for engine-reported waits, rounded to one unit: "45s",
    /// "12m", "4h", "75d" in English ("12min", "75j" in French).
    /// A non-finite input has no age to state, so it reads "—"; absurdly large
    /// ones are clamped (`maxCompactSeconds`) rather than trapping.
    nonisolated static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        guard seconds.isFinite else { return "—" }
        let s = min(max(0, seconds), maxCompactSeconds)
        switch s {
        case ..<90: return compactUnit(Int(s.rounded()), .seconds, locale: locale)
        case ..<5_400: return compactUnit(Int((s / 60).rounded()), .minutes, locale: locale)
        case ..<172_800: return compactUnit(Int((s / 3_600).rounded()), .hours, locale: locale)
        default: return compactUnit(Int((s / 86_400).rounded()), .days, locale: locale)
        }
    }

    /// One whole amount of one unit in the locale's narrow style ("12m" in
    /// English, "12min" in German). The caller picks the unit and rounds, so
    /// the formatter never re-rounds into a different unit.
    /// ~31,700 years: far past any real age, far inside Int/Int64 range.
    nonisolated static let maxCompactSeconds: TimeInterval = 1e12

    nonisolated static func compactUnit(_ value: Int, _ unit: Duration.UnitsFormatStyle.Unit, locale: Locale = .current) -> String {
        let perUnit: Int64 = switch unit {
        case .days: 86_400
        case .hours: 3_600
        case .minutes: 60
        default: 1
        }
        // Overflow clamps instead of trapping; a negative amount is an absence.
        let product = Int64(clamping: max(0, value)).multipliedReportingOverflow(by: perUnit)
        let seconds = product.overflow ? Int64.max / perUnit * perUnit : product.partialValue
        var style = Duration.UnitsFormatStyle(allowedUnits: [unit], width: .narrow)
        style.locale = locale
        return Duration.seconds(seconds).formatted(style)
    }

    /// Daemon CPU load as "12% CPU" with a locale-aware percent. `ps` reports
    /// percent of one core, so values above 100 are real and kept.
    ///
    /// Truncated, not rounded: `cpuTint` and the health words compare the raw
    /// value against whole-number thresholds (15 / 30), and floor(x) < T
    /// exactly when x < T — so 29.6 reads "29%" in amber, never "30%" in amber.
    nonisolated static func cpu(_ percent: Double, locale: Locale = .current) -> String {
        let value = percent.isFinite ? max(0, percent) : 0
        return (value / 100).formatted(
            .percent.precision(.fractionLength(0)).rounded(rule: .down).locale(locale)
        ) + " CPU"
    }

    /// Resident memory from `ps` (MiB) as the locale writes memory sizes
    /// ("412 MB", "1.2 GB").
    nonisolated static func memory(megabytes: Double, locale: Locale = .current) -> String {
        Int64((max(0, megabytes) * 1_048_576).rounded())
            .formatted(.byteCount(style: .memory).locale(locale))
    }

    /// A clock time to the second in the user's 12/24-hour convention
    /// ("9:41:02 PM", "21:41:02").
    nonisolated static func clockTime(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .standard)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// The start of an hour of the day (0–23) as the locale writes it
    /// ("2:00 PM", "14:00").
    nonisolated static func hourOfDay(_ hour: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour))
            ?? Date(timeIntervalSinceReferenceDate: TimeInterval(hour * 3_600))
        var style = Date.FormatStyle().hour().minute()
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Same formatter as `capacity` — one way to write a storage figure.
    static func gigabytes(_ bytes: Int64) -> String { capacity(bytes) }

    /// Plan-scale sizes: TB above a terabyte, GB below, trailing zeros
    /// dropped, in the user's locale — it reads the way System Settings does
    /// ("1.8 TB", "2 TB", "205.3 GB"; "1,79 TB" in German). The one storage
    /// formatter: storage headlines, plan lines, the low-quota issue.
    nonisolated static func capacity(_ bytes: Int64, locale: Locale = .current) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 1 {
            return tb.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale)) + " TB"
        }
        let gb = Double(bytes) / 1_000_000_000
        return gb.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale)) + " GB"
    }

    /// "54%" in the user's locale (French "54 %", etc.).
    nonisolated static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
