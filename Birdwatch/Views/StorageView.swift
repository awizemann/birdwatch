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
                        derivedCap: storage.totalBytes,
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
                if storage.hasAccountTier {
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
        return !store.planCapConfirmed
    }

    private func footnote(_ storage: StorageInfo) -> String {
        let capPhrase = switch storage.capSource {
        case .userChosen: "set by you"
        case .derived: "derived from the remaining quota iCloud reports"
        case .unknown: "not known — iCloud reported no remaining quota"
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
                        bytes: storage.accountLocalSegmentBytes ?? 0
                    )
                    accountLegendRow(
                        color: Surface.fg3,
                        name: "Photos, Messages, backups & other devices",
                        bytes: storage.accountRemainderBytes ?? 0
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
        return "\(Format.capacity(used)) of \(Format.capacity(cap)) used"
    }

    private func accountBar(_ storage: StorageInfo) -> some View {
        let local = storage.accountLocalSegmentBytes ?? 0
        let remainder = storage.accountRemainderBytes ?? 0
        let denominator = max(storage.totalBytes ?? 1, 1)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach([
                    (name: "iCloud Drive on this Mac", bytes: local, color: Color(hex: StorageCategory.documents.colorHex)),
                    (name: "Photos, Messages, backups & other devices", bytes: remainder, color: Surface.fg3),
                ], id: \.name) { part in
                    if part.bytes > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(part.color)
                            .frame(width: max(4, geo.size.width * CGFloat(part.bytes) / CGFloat(denominator)))
                            .help("\(part.name): \(Format.size(part.bytes))")
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
            "\(accountHeadline(storage)), iCloud Drive on this Mac \(Format.size(local)), Photos, Messages, backups and other devices \(Format.size(remainder))"
        )
    }

    private func accountLegendRow(color: Color, name: String, bytes: Int64) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .scaledFont(size: 12.5, weight: .medium)
                .foregroundStyle(Surface.fg)
            Spacer()
            Text(Format.size(bytes))
                .scaledFont(size: 12.5)
                .foregroundStyle(Surface.fg2)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(Format.size(bytes))
    }

    private var manageButton: some View {
        Button("Manage iCloud in System Settings…") {
            logger.info("Manage iCloud in System Settings requested")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.accent)
        .fixedSize()
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
                        Text("\(Format.gigabytes(available)) available")
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
            return "iCloud Drive on this Mac — \(Format.gigabytes(storage.usedBytes))"
        }
        guard let total = storage.totalBytes else {
            return "\(Format.gigabytes(storage.usedBytes)) of iCloud files on this Mac"
        }
        return "\(Format.gigabytes(storage.usedBytes)) of \(Format.gigabytes(total)) used"
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
                    Text(String(format: "%.0f%%", share))
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
                    Text(storage.planPriceLine)
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Surface.fg2)
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
    let onConfirm: (Int64?) -> Void
    let onDismiss: () -> Void

    /// Index into the tier list, or `custom` for the free-form GB field.
    @State private var selection: Int = 0
    @State private var customGB: String = ""
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
                Text("Birdwatch can only measure the iCloud files on this Mac, so it can't tell your plan size on its own. Telling it once makes the bar accurate.")
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
                        TextField("GB", text: $customGB)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel("Custom plan size in gigabytes")
                        Text("GB")
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
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
            if let derivedCap,
               let index = StorageBreakdownSource.tiers.firstIndex(where: { $0.bytes == derivedCap }) {
                selection = index
            }
        }
    }

    private func chosenCap() -> Int64? {
        if selection == Self.customTag {
            guard let gb = Double(customGB.trimmingCharacters(in: .whitespaces)), gb > 0 else { return nil }
            return Int64(gb * 1_000_000_000)
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
