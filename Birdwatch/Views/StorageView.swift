import SwiftUI
import AppKit
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "storage")

struct StorageView: View {
    @Environment(SyncStore.self) private var store
    /// Prompt is shown when the plan is a guess and the user hasn't answered;
    /// "Change plan" re-opens it.
    @State private var promptOpen: Bool?

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.storage.title, subtitle: MonitorView.storage.subtitle)

            if let storage = store.storage {
                if isPromptVisible(storage) {
                    PlanPromptCard(
                        derivedCap: PlanPromptChoice.suggestedCap(storage),
                        derivedIsSuggestion: PlanPromptChoice.seedIsSuggestion(storage),
                        onConfirm: { cap in
                            store.setPlanCap(cap)
                            promptOpen = false
                        },
                        onDismiss: {
                            store.planCapConfirmed = true
                            promptOpen = false
                        }
                    )
                }
                if storage.planCapBelowRemaining, let cap = storage.totalBytes,
                   let remaining = storage.remainingBytes {
                    planDisagreementCard(cap: cap, remaining: remaining)
                } else if storage.hasAccountTier {
                    accountCard(storage)
                }
                usageCard(storage)
                planCard(storage)
                SourceFootnote(text: footnote(storage))
            } else {
                quotaCard(remaining: store.quotaRemainingBytes)
                SourceFootnote(text: "Measuring the files iCloud keeps on this Mac. Until that finishes, quota remaining is the only number brctl reports.")
            }
        }
    }

    /// Ask once: only while the cap is a guess (or missing) and unconfirmed.
    private func isPromptVisible(_ storage: StorageInfo) -> Bool {
        if let promptOpen { return promptOpen }
        guard storage.capSource != .userChosen else { return false }
        // Several plans fit the quota: account usage stays unknown until the
        // user says which, so the question stays up even if dismissed before.
        if storage.planIsAmbiguous { return true }
        return !store.planCapConfirmed
    }

    private func footnote(_ storage: StorageInfo) -> String {
        let capPhrase = switch storage.capSource {
        case .userChosen: "set by you"
        case .derived: "derived from the remaining quota iCloud reports"
        case .unknown: storage.planIsAmbiguous
            ? "not confirmed — more than one plan fits the quota iCloud reports"
            : "not known — iCloud reported no remaining quota"
        }
        if storage.hasAccountTier {
            return "Account totals come from your live iCloud quota; the breakdown below is only the iCloud Drive files stored on this Mac. Your plan total is \(capPhrase)."
        }
        return "Used = files on this Mac. Evicted files, Photos and device backups aren't counted; your plan total is \(capPhrase)."
    }

    // MARK: - Account tier (whole iCloud account)

    /// Headline that matches System Settings: cap − live remaining quota. The
    /// bar is two honest segments — the part Birdwatch can measure (iCloud
    /// Drive files on this Mac) and everything else the account holds, which
    /// Apple does not break down for third-party apps.
    private func accountCard(_ storage: StorageInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(accountHeadline(storage))
                        .scaledFont(size: 15, weight: .bold)
                        .foregroundStyle(Surface.fg)
                        .monospacedDigit()
                    Spacer()
                    if let remaining = storage.remainingBytes {
                        Text("\(Format.capacity(remaining)) available")
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
                            .monospacedDigit()
                    }
                }

                accountBar(storage)

                VStack(alignment: .leading, spacing: 8) {
                    accountLegendRow(
                        color: Color(hex: StorageCategory.documents.colorHex),
                        name: "iCloud Drive on this Mac",
                        bytes: storage.accountLocalSegmentBytes ?? 0,
                        isEstimated: Self.localPartIsEstimated(storage)
                    )
                    accountLegendRow(
                        color: Surface.fg3,
                        name: "Photos, Messages, backups & other devices",
                        bytes: storage.accountRemainderBytes ?? 0,
                        isEstimated: Self.remainderIsEstimated(storage)
                    )
                }

                if storage.localExceedsAccount {
                    Text("The files measured on this Mac exceed the account total iCloud reports — shared (Family) storage or a stale quota can do that, so the local segment is shown capped.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                }

                HStack(alignment: .bottom, spacing: 14) {
                    Text("Account totals come from your iCloud quota; Apple doesn't expose the per-app split (Photos, Messages, backups) to third-party apps — see System Settings for that breakdown.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    manageButton
                }
            }
        }
    }

    private func accountHeadline(_ storage: StorageInfo) -> String {
        guard let used = storage.accountUsedBytes, let cap = storage.totalBytes else {
            return usageHeadline(storage)
        }
        return StorageCapLabel.accountHeadline(used: used, cap: cap, capIsEstimated: storage.capSource == .derived)
    }

    private static func remainderIsEstimated(_ storage: StorageInfo) -> Bool {
        StorageCapLabel.estimatedAccountParts(storage).remainder
    }

    private static func localPartIsEstimated(_ storage: StorageInfo) -> Bool {
        StorageCapLabel.estimatedAccountParts(storage).local
    }

    private func accountBar(_ storage: StorageInfo) -> some View {
        let local = storage.accountLocalSegmentBytes ?? 0
        let remainder = storage.accountRemainderBytes ?? 0
        let localEstimated = Self.localPartIsEstimated(storage)
        let remainderEstimated = Self.remainderIsEstimated(storage)
        let denominator = max(storage.totalBytes ?? 1, 1)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach([
                    (name: "iCloud Drive on this Mac", bytes: local, estimated: localEstimated,
                     color: Color(hex: StorageCategory.documents.colorHex)),
                    (name: "Photos, Messages, backups & other devices", bytes: remainder, estimated: remainderEstimated,
                     color: Surface.fg3),
                ], id: \.name) { part in
                    if part.bytes > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(part.color)
                            .frame(width: max(4, geo.size.width * CGFloat(part.bytes) / CGFloat(denominator)))
                            .help("\(part.name): \(StorageCapLabel.accountPartText(part.bytes, isEstimated: part.estimated))")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Surface.hover, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("iCloud account storage")
        .accessibilityValue(
            "\(accountHeadline(storage)), iCloud Drive on this Mac \(StorageCapLabel.accountPartAccessibility(local, isEstimated: localEstimated)), Photos, Messages, backups and other devices \(StorageCapLabel.accountPartAccessibility(remainder, isEstimated: remainderEstimated))"
        )
    }

    private func accountLegendRow(color: Color, name: String, bytes: Int64, isEstimated: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .scaledFont(size: 12.5, weight: .medium)
                .foregroundStyle(Surface.fg)
            Spacer()
            Text(StorageCapLabel.accountPartText(bytes, isEstimated: isEstimated))
                .scaledFont(size: 12.5)
                .foregroundStyle(Surface.fg2)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(StorageCapLabel.accountPartAccessibility(bytes, isEstimated: isEstimated))
    }

    private var manageButton: some View {
        Button("Manage iCloud in System Settings…") {
            logger.info("Manage iCloud in System Settings requested")
            AppleAccountSettings.open(from: .storage, store: store)
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.accent)
        .fixedSize()
    }

    // MARK: - Plan setting contradicted by the live quota

    /// Replaces the account card when iCloud reports more remaining than the
    /// chosen plan: no "0 of 2 TB used" — the setting is what's wrong.
    private func planDisagreementCard(cap: Int64, remaining: Int64) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(StorageCapLabel.planDisagreement(cap: cap, remaining: remaining))
                        .scaledFont(size: 13.5, weight: .bold)
                        .foregroundStyle(Surface.fg)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Palette.warning)
                }
                Text("Account usage is your plan size minus what iCloud reports as available, so Birdwatch won't show it until the plan matches. Stacked plans (for example Apple One 2 TB plus iCloud+ 6 TB) count as their total.")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Surface.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Change plan…") { promptOpen = true }
                    .accessibilityHint("Choose which iCloud plan you're on")
            }
        }
    }

    // MARK: - Quota-only (breakdown not measured yet)

    private func quotaCard(remaining: Int64?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if let remaining {
                    Text("\(Format.gigabytes(remaining)) remaining in your iCloud account")
                        .scaledFont(size: 15, weight: .bold)
                        .foregroundStyle(Surface.fg)
                        .monospacedDigit()
                } else {
                    Text("Storage details unavailable")
                        .scaledFont(size: 15, weight: .bold)
                        .foregroundStyle(Surface.fg)
                }
                Text("Apple doesn't publish a per-service breakdown to third-party apps. Birdwatch measures the iCloud files stored on this Mac instead — that scan runs in the background and appears here shortly.")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Surface.fg2)
            }
        }
    }

    // MARK: - Usage

    private func usageCard(_ storage: StorageInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(usageHeadline(storage))
                        .scaledFont(size: 15, weight: .bold)
                        .foregroundStyle(Surface.fg)
                        .monospacedDigit()
                    Spacer()
                    if !storage.hasAccountTier, let available = storage.availableBytes {
                        Text(StorageCapLabel.availableText(available, capIsEstimated: storage.capSource == .derived))
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
                            .monospacedDigit()
                    }
                }

                segmentedBar(storage)

                legend(storage)

                if storage.hasAccountTier {
                    Text("Only the iCloud Drive files this Mac keeps on disk. Files evicted to the cloud take almost no space here, and Photos, Messages and device backups never live in this folder at all.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func usageHeadline(_ storage: StorageInfo) -> String {
        // With the account tier above, this card is explicitly the local slice.
        if storage.hasAccountTier {
            return "iCloud Drive on this Mac — \(StorageCapLabel.localFigure(storage.usedBytes, isPartial: storage.localIsPartial))"
        }
        // `trustedCapBytes`: a plan setting the live quota contradicts is
        // never shown as the denominator.
        return StorageCapLabel.usageHeadline(
            used: storage.usedBytes, cap: storage.trustedCapBytes, capIsEstimated: storage.capSource == .derived,
            planIsAmbiguous: storage.planIsAmbiguous, localIsPartial: storage.localIsPartial)
    }

    private func segmentedBar(_ storage: StorageInfo) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(storage.segments) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: segment.colorHex))
                        // Minimum visible width so a tiny bucket never vanishes.
                        .frame(width: max(4, geo.size.width * CGFloat(segment.bytes) / CGFloat(storage.barDenominator)))
                        .help("\(segment.name): \(Format.size(segment.bytes))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Surface.hover, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Storage usage by file type")
        .accessibilityValue(
            ([usageHeadline(storage)] + storage.segments.map { "\($0.name) \(Format.size($0.bytes))" })
                .joined(separator: ", ")
        )
    }

    private func legend(_ storage: StorageInfo) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(storage.segments) { segment in
                let share = storage.usedBytes > 0
                    ? Double(segment.bytes) / Double(storage.usedBytes) * 100 : 0
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: segment.colorHex))
                        .frame(width: 8, height: 8)
                    Text(segment.name)
                        .scaledFont(size: 12.5, weight: .medium)
                        .foregroundStyle(Surface.fg)
                    Spacer()
                    Text(Format.size(segment.bytes))
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Surface.fg2)
                        .monospacedDigit()
                    Text(Format.percent(share / 100))
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(segment.name)
                .accessibilityValue("\(Format.size(segment.bytes)), \(Int(share.rounded())) percent")
                .help("\(segment.name): \(Format.size(segment.bytes))")
            }
        }
    }

    // MARK: - Plan

    private func planCard(_ storage: StorageInfo) -> some View {
        Card {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(storage.planName)
                        .scaledFont(size: 13.5, weight: .bold)
                        .foregroundStyle(Surface.fg)
                    Text(StorageCapLabel.planCardLine(storage))
                        .scaledFont(size: 12.5)
                        .foregroundStyle(storage.planCapBelowRemaining ? Palette.warning : Surface.fg2)
                        .monospacedDigit()
                    Button("Change plan") { promptOpen = true }
                        .buttonStyle(.link)
                        .scaledFont(size: 12)
                        .accessibilityHint("Choose which iCloud plan you're on")
                }
                Spacer()
                // The account card already carries this button when it's shown.
                if !storage.hasAccountTier { manageButton }
            }
        }
    }
}

// MARK: - Plan prompt (inline card, never a modal)

private struct PlanPromptCard: View {
    let derivedCap: Int64?
    /// The pre-selection is Birdwatch's derivation, not the user's answer.
    let derivedIsSuggestion: Bool
    let onConfirm: (Int64?) -> Void
    let onDismiss: () -> Void

    /// Index into the tier list, or `custom` for the free-form total.
    @State private var selection: Int = 0
    @State private var customText: String = ""
    @State private var customIsTB = true
    @State private var didSeed = false

    private static let customTag = -1

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Which iCloud plan are you on?")
                        .scaledFont(size: 13.5, weight: .bold)
                        .foregroundStyle(Surface.fg)
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Surface.fg3)
                    .accessibilityLabel("Dismiss plan question")
                }
                Text("Birdwatch can only measure the iCloud files on this Mac, so it can't tell your plan size on its own. Telling it once makes the bar accurate. For stacked plans (Apple One plus iCloud+), choose Custom and enter the total.")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Surface.fg2)

                Picker("iCloud plan", selection: $selection) {
                    ForEach(Array(StorageBreakdownSource.tiers.enumerated()), id: \.offset) { index, tier in
                        Text(shortLabel(tier.name)).tag(index)
                    }
                    Text("Custom…").tag(Self.customTag)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("iCloud plan size")

                HStack(spacing: 10) {
                    if selection == Self.customTag {
                        TextField(customIsTB ? "TB" : "GB", text: $customText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel("Custom plan total")
                        Picker("Unit", selection: $customIsTB) {
                            Text("GB").tag(false)
                            Text("TB").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 90)
                        .accessibilityLabel("Custom plan unit")
                    }
                    // Labelled while the answer is still the untouched
                    // derivation — the moment it is edited it is the user's.
                    if derivedIsSuggestion, chosenCap() == derivedCap {
                        Text(PlanPromptChoice.suggestionNote)
                            .scaledFont(size: 11.5)
                            .foregroundStyle(Surface.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Confirm") { onConfirm(chosenCap()) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .disabled(chosenCap() == nil)
                }
            }
        }
        .task {
            guard !didSeed else { return }
            didSeed = true
            let seed = PlanPromptChoice.seed(for: derivedCap)
            if let index = seed.tierIndex {
                selection = index
            } else {
                selection = Self.customTag
                customText = seed.customText
                customIsTB = seed.customIsTB
            }
        }
    }

    private func chosenCap() -> Int64? {
        if selection == Self.customTag {
            return PlanPromptChoice.customCap(text: customText, isTB: customIsTB)
        }
        guard StorageBreakdownSource.tiers.indices.contains(selection) else { return nil }
        return StorageBreakdownSource.tiers[selection].bytes
    }

    /// "iCloud+ 200 GB" → "200 GB" — the segmented control has no room for the
    /// brand on every segment.
    private func shortLabel(_ tierName: String) -> String {
        tierName.replacingOccurrences(of: "iCloud+ ", with: "")
            .replacingOccurrences(of: "iCloud ", with: "")
    }
}
