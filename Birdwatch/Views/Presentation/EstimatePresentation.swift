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
    /// The local footprint as a figure: "83.2 GB", or "at least 83.2 GB"
    /// when the size walk stopped at its cap (the Storage screen's
    /// "partial scan").
    static func localFigure(_ used: Int64, isPartial: Bool) -> String {
        isPartial ? "at least \(Format.gigabytes(used))" : Format.gigabytes(used)
    }

    /// Sidebar footer text. `localIsPartial` qualifies the LOCAL figure; the
    /// account figure (cap − remaining) does not come from the walk.
    static func footerText(_ figure: StorageFooterFigure, capIsEstimated: Bool, localIsPartial: Bool = false) -> String {
        switch figure {
        case let .account(used, cap):
            // Account usage is cap − remaining: derived cap, derived usage.
            let text = "\(Format.capacity(used)) / \(Format.capacity(cap))"
            return capIsEstimated ? "≈ \(text)" : text
        case let .local(used, cap):
            return "\(localFigure(used, isPartial: localIsPartial)) / \(capIsEstimated ? "≈ " : "")\(Format.gigabytes(cap)) on this Mac"
        case let .localOnly(used):
            return "\(localFigure(used, isPartial: localIsPartial)) on this Mac"
        }
    }

    /// What VoiceOver says for the footer ("≈" is read as a symbol name).
    static func footerAccessibilityValue(_ figure: StorageFooterFigure, capIsEstimated: Bool, localIsPartial: Bool = false) -> String {
        let plain = footerText(figure, capIsEstimated: false, localIsPartial: localIsPartial)
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
    /// `planIsAmbiguous`: the quota is known but fits more than one plan, so
    /// account usage is unknown and only its floor is stated.
    static func usageHeadline(
        used: Int64, cap: Int64?, capIsEstimated: Bool, planIsAmbiguous: Bool = false, localIsPartial: Bool = false
    ) -> String {
        if cap == nil, planIsAmbiguous {
            return "Account usage unknown — at least \(Format.capacity(used)) on this Mac"
        }
        let figure = localFigure(used, isPartial: localIsPartial)
        let lead = figure.prefix(1).uppercased() + figure.dropFirst()
        guard let cap else { return "\(lead) of iCloud files on this Mac" }
        return capIsEstimated
            ? "\(lead) of ≈ \(Format.gigabytes(cap)) used · estimated plan"
            : "\(lead) of \(Format.gigabytes(cap)) used"
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

    /// The plan card when the live quota contradicts the plan setting: the
    /// setting is shown, but marked as contested rather than "Set by you".
    static func planCardLine(_ storage: StorageInfo) -> String {
        guard storage.planCapBelowRemaining, let remaining = storage.remainingBytes else {
            return storage.planPriceLine
        }
        return "Set by you — contested: iCloud reports \(Format.capacity(remaining)) available, more than this plan holds"
    }

    /// The Settings window's plan row: the plan with its provenance, so a
    /// derived cap never reads as fact there either (C2). `spoken` is the
    /// VoiceOver form ("≈" is read as a symbol name).
    static func settingsPlanText(_ storage: StorageInfo?) -> (text: String, spoken: String) {
        guard let storage else { return ("Not known yet", "Not known yet") }
        let name = storage.planName
        switch storage.capSource {
        case .derived:
            return ("≈ \(name) · estimated", "about \(name), estimated from your remaining quota")
        case .userChosen where storage.planCapBelowRemaining:
            return ("\(name) · set by you, contested", "\(name), set by you, contested by iCloud's quota")
        case .userChosen:
            return ("\(name) · set by you", "\(name), set by you")
        case .unknown:
            // planName already says "not confirmed" / "size unknown".
            return (name, name)
        }
    }

    /// Shown instead of any usage figure when iCloud reports more remaining
    /// than the plan setting allows: the setting is wrong, not the quota.
    static func planDisagreement(cap: Int64, remaining: Int64) -> String {
        "Your plan setting (\(Format.capacity(cap))) looks too small — iCloud reports \(Format.capacity(remaining)) still available."
    }
}

/// The plan question's choices. Single tiers sit on the segmented control;
/// anything else — a stacked plan such as Apple One 2 TB + iCloud+ 6 TB, or
/// a size Birdwatch doesn't list — is a custom total in GB or TB.
enum PlanPromptChoice {
    /// What to pre-select: the cap the user already chose when the quota
    /// agrees with it; otherwise the derived plan (smallest purchasable total
    /// that holds this Mac's files plus the remaining quota).
    /// When several plans fit, the smallest that holds the floor is offered
    /// as the starting choice; nothing is stored until the user confirms.
    static func suggestedCap(_ storage: StorageInfo) -> Int64? {
        if storage.capSource == .userChosen, !storage.planCapBelowRemaining { return storage.totalBytes }
        if let remaining = storage.remainingBytes,
           let smallest = StorageBreakdownSource.planCandidates(
               floorBytes: max(storage.usedBytes, 0) + remaining).first {
            return smallest.bytes
        }
        return storage.trustedCapBytes
    }

    /// Said beside the pre-selected answer while it is still Birdwatch's
    /// derivation rather than the user's own choice: a prefilled "8 TB" with
    /// no label reads as a fact (C2). nil when the seed is what the user
    /// already confirmed, or when nothing is pre-selected.
    static let suggestionNote = "Suggested from iCloud's reported space — not confirmed"

    static func seedIsSuggestion(_ storage: StorageInfo) -> Bool {
        let userOwn = storage.capSource == .userChosen && !storage.planCapBelowRemaining
        return !userOwn && suggestedCap(storage) != nil
    }

    struct Seed: Equatable {
        /// Index into `StorageBreakdownSource.tiers`, or nil for custom.
        var tierIndex: Int?
        var customText: String = ""
        var customIsTB: Bool = true
    }

    static func seed(for cap: Int64?, locale: Locale = .current) -> Seed {
        guard let cap else { return Seed(tierIndex: 0) }
        if let index = StorageBreakdownSource.tiers.firstIndex(where: { $0.bytes == cap }) {
            return Seed(tierIndex: index)
        }
        if cap >= 1_000_000_000_000 {
            return Seed(tierIndex: nil, customText: number(Double(cap) / 1_000_000_000_000, locale), customIsTB: true)
        }
        return Seed(tierIndex: nil, customText: number(Double(cap) / 1_000_000_000, locale), customIsTB: false)
    }

    /// The custom total in bytes, read in the user's locale; nil for anything
    /// that isn't an unambiguous positive number. A grouping separator is
    /// accepted only in real groups of three ("1,000" in English is 1000;
    /// "2,2" there is rejected rather than guessed as 22 or 2.2), and the
    /// locale's decimal separator is the only one accepted.
    static func customCap(text: String, isTB: Bool, locale: Locale = .current) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let decimal = locale.decimalSeparator ?? "."
        let grouping = locale.groupingSeparator ?? ","
        let parts = trimmed.components(separatedBy: decimal)
        guard parts.count <= 2, let integer = parts.first, !integer.isEmpty else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard fraction.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        let groups = integer.components(separatedBy: grouping)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        if groups.count > 1 {
            guard groups[0].count <= 3, groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        guard let value = Double(groups.joined() + (fraction.isEmpty ? "" : "." + fraction)),
              value > 0, value.isFinite else { return nil }
        return Int64((value * (isTB ? 1_000_000_000_000 : 1_000_000_000)).rounded())
    }

    private static func number(_ value: Double, _ locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
    }
}

// MARK: - Bandwidth

/// Bandwidth wording. The hour buckets are the CURRENT calendar day and only
/// hold traffic seen since Birdwatch launched, so the chart is "Today, since
/// Birdwatch started" — not "Last 24 hours".
enum BandwidthPresentation {
    static let chartTitle = "Today, since Birdwatch started"
    /// The popover sparkline's caption. "Estimated" LEADS: at the popover's
    /// 328 pt the old trailing ", estimated" was the part that truncated
    /// away, leaving an attributed figure unlabelled (C2).
    static let popoverCaption = "Estimated iCloud traffic per hour, today since Birdwatch started"

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
        return "\(base); busiest hour \(Format.hourOfDay(peak.hour))"
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

    /// One device row's count. When bird truncated its dump every per-row
    /// figure is a floor too, and says so like the headline does.
    static func itemCount(_ count: Int, countsArePartial: Bool) -> String {
        (countsArePartial ? "at least " : "") + Plural.count(count, "item")
    }
}
