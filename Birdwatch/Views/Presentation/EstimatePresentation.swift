import Foundation

// Wording for derived numbers. C2: a derived figure (plan-cap arithmetic,
// nettop deltas) is always labelled as one; C1: an unobserved hour or a
// failed sample is never drawn or spoken as a measured zero.

// MARK: - Storage

/// Storage figures that depend on the plan cap. When the cap was DERIVED
/// (smallest tier ≥ local footprint + remaining quota — a guess) every number
/// built on it carries "≈" and the word "estimated"; a cap the user chose, or
/// no cap at all, reads plainly.
enum StorageCapLabel {
    /// Sidebar footer text.
    static func footerText(_ figure: StorageFooterFigure, capIsEstimated: Bool) -> String {
        switch figure {
        case let .account(used, cap):
            // Account usage is cap − remaining: derived cap, derived usage.
            let text = "\(Format.capacity(used)) / \(Format.capacity(cap))"
            return capIsEstimated ? "≈ \(text)" : text
        case let .local(used, cap):
            return "\(Format.gigabytes(used)) / \(capIsEstimated ? "≈ " : "")\(Format.gigabytes(cap)) on this Mac"
        case let .localOnly(used):
            return "\(Format.gigabytes(used)) on this Mac"
        }
    }

    /// What VoiceOver says for the footer ("≈" is read as a symbol name).
    static func footerAccessibilityValue(_ figure: StorageFooterFigure, capIsEstimated: Bool) -> String {
        let plain = footerText(figure, capIsEstimated: false)
        switch figure {
        case .account, .local:
            return capIsEstimated ? "\(plain), estimated from your remaining quota" : plain
        case .localOnly:
            return plain
        }
    }

    /// Storage → account card headline.
    static func accountHeadline(used: Int64, cap: Int64, capIsEstimated: Bool) -> String {
        capIsEstimated
            ? "≈ \(Format.capacity(used)) of \(Format.capacity(cap)) used · estimated plan"
            : "\(Format.capacity(used)) of \(Format.capacity(cap)) used"
    }

    /// Storage → local usage headline when no account tier is shown.
    static func usageHeadline(used: Int64, cap: Int64?, capIsEstimated: Bool) -> String {
        guard let cap else { return "\(Format.gigabytes(used)) of iCloud files on this Mac" }
        return capIsEstimated
            ? "\(Format.gigabytes(used)) of ≈ \(Format.gigabytes(cap)) used · estimated plan"
            : "\(Format.gigabytes(used)) of \(Format.gigabytes(cap)) used"
    }

    /// "X available" next to the local headline: cap − local is as derived
    /// as the cap itself.
    static func availableText(_ bytes: Int64, capIsEstimated: Bool) -> String {
        "\(capIsEstimated ? "≈ " : "")\(Format.gigabytes(bytes)) available"
    }

    /// Which account-bar segments are estimates. The remainder is cap −
    /// remaining − local, so it is as derived as the cap; the local segment is
    /// measured unless it had to be capped to the (derived) account total.
    static func estimatedAccountParts(_ storage: StorageInfo) -> (local: Bool, remainder: Bool) {
        let derived = storage.capSource == .derived
        return (derived && storage.localExceedsAccount, derived)
    }

    /// One segment of the account bar (legend value, tooltip, VoiceOver).
    /// "Photos, Messages, backups & other devices" is cap − remaining − local:
    /// as estimated as the cap. The local segment is measured, unless it had
    /// to be capped to the (derived) account total.
    static func accountPartText(_ bytes: Int64, isEstimated: Bool) -> String {
        isEstimated ? "≈ \(Format.size(bytes))" : Format.size(bytes)
    }

    /// VoiceOver wording for the same value ("≈" is read as a symbol name).
    static func accountPartAccessibility(_ bytes: Int64, isEstimated: Bool) -> String {
        isEstimated ? "about \(Format.size(bytes)), estimated" : Format.size(bytes)
    }
}

// MARK: - Bandwidth

/// Bandwidth wording. The hour buckets are the CURRENT calendar day and only
/// hold traffic seen since Birdwatch launched, so the chart is "Today, since
/// Birdwatch started" — not "Last 24 hours".
enum BandwidthPresentation {
    static let chartTitle = "Today, since Birdwatch started"

    /// Every byte figure here is attributed from daemon traffic (C2). With no
    /// hour observed yet there is no figure at all — "≈ Zero KB" would be a
    /// measurement that never happened (C1).
    static func totalText(_ bytes: Int64, hours: [BandwidthHourSample]) -> String {
        guard hours.contains(where: \.isObserved) else { return "—" }
        return "≈ \(Format.size(bytes))"
    }

    static func rateText(_ summary: BandwidthSummary) -> String {
        if summary.lastSampleFailed { return "Unavailable" }
        if !summary.rateIsMeasured { return "Measuring…" }
        return "≈ \(Format.size(summary.currentRateBytesPerSec))/s"
    }

    /// Unobserved hours and silent hours draw nothing — a 2 pt stub would
    /// claim a measurement that isn't there. Real traffic keeps a 2 pt floor
    /// so a small hour stays visible.
    static func barHeight(bytes: Int64, isObserved: Bool, available: CGFloat, maxBytes: Int64) -> CGFloat {
        guard isObserved, bytes > 0, maxBytes > 0 else { return 0 }
        return max(2, available * CGFloat(bytes) / CGFloat(maxBytes))
    }

    /// The Bandwidth chart's spoken value. Only observed hours count, and an
    /// all-zero series names no busiest hour.
    static func chartSummary(_ samples: [BandwidthHourSample]) -> String {
        let observed = samples.filter(\.isObserved)
        guard !observed.isEmpty else { return "No hours observed yet today" }
        let uploaded = observed.reduce(Int64(0)) { $0 + $1.uploadedBytes }
        let downloaded = observed.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        let base = "Estimated: uploaded \(Format.size(uploaded)), downloaded \(Format.size(downloaded)) today since Birdwatch started"
        guard let peak = observed.max(by: { $0.uploadedBytes + $0.downloadedBytes < $1.uploadedBytes + $1.downloadedBytes }),
              peak.uploadedBytes + peak.downloadedBytes > 0 else {
            return "\(base); no traffic recorded"
        }
        return "\(base); busiest hour \(peak.hour):00"
    }
}

// MARK: - Devices

/// The anonymous Devices headline: only counts the dump actually supports.
/// The registry lists more devices than wrote anything in the item tree, so
/// the two are stated separately — and when bird truncated its dump, the
/// writer and activity counts are floors ("at least").
enum DevicesHeadline {
    static func text(registered: Int, wroteItems: Int, activeThisWeek: Int, countsArePartial: Bool) -> String {
        let floor = countsArePartial ? "at least " : ""
        let wrote = wroteItems == 1 ? "1 has written items" : "\(wroteItems) have written items"
        return "\(Plural.count(registered, "device")) registered · \(floor)\(wrote) · \(floor)\(activeThisWeek) active this week"
    }
}
