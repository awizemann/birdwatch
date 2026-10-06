import SwiftUI

struct BandwidthView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.bandwidth.title, subtitle: MonitorView.bandwidth.subtitle)

            if let bandwidth = store.bandwidth {
                // Every figure is attributed from daemon traffic (C2), so each
                // carries "≈"; a rate that wasn't measured says so (C1).
                HStack(spacing: 14) {
                    statTile(label: "Uploaded since Birdwatch started (today)", value: BandwidthPresentation.totalText(bandwidth.uploadedTodayBytes, hours: bandwidth.hours), tint: Palette.accent)
                    statTile(label: "Downloaded since Birdwatch started (today)", value: BandwidthPresentation.totalText(bandwidth.downloadedTodayBytes, hours: bandwidth.hours), tint: Palette.success)
                    statTile(label: "Current rate", value: BandwidthPresentation.rateText(bandwidth),
                             tint: bandwidth.rateIsMeasured && !bandwidth.lastSampleFailed ? Surface.fg : Surface.fg3)
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(BandwidthPresentation.chartTitle)
                                .scaledFont(size: 13.5, weight: .bold)
                                .foregroundStyle(Surface.fg)
                            Spacer()
                            legendItem(color: Palette.accent, label: "Upload")
                            legendItem(color: Palette.success, label: "Download")
                        }
                        DualBarChart(samples: bandwidth.hours)
                            .frame(height: 180)
                    }
                }

                estimatedCallout
            }

            SourceFootnote(text: "Traffic sampled per-process from bird, cloudd and fileproviderd")
        }
    }

    private func statTile(label: String, value: String, tint: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Surface.fg2)
                Text(value)
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .scaledFont(size: 11.5, weight: .semibold)
                .foregroundStyle(Surface.fg2)
        }
    }

    private var estimatedCallout: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(size: 13)
                    .foregroundStyle(Palette.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Estimated")
                        .scaledFont(size: 13, weight: .bold)
                        .foregroundStyle(Palette.warning)
                    Text("macOS has no public per-app bandwidth API. These figures attribute network traffic from bird, cloudd and fileproviderd to iCloud.")
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Surface.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Dual bar chart (plain shapes per handoff — no Charts)

private struct DualBarChart: View {
    let samples: [BandwidthHourSample]

    private static let labeledHours: Set<Int> = [0, 6, 12, 18, 23]

    var body: some View {
        // Computed once per body evaluation instead of per bar.
        let maxBytes = max(samples.map(\.uploadedBytes).max() ?? 1, samples.map(\.downloadedBytes).max() ?? 1, 1)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let halfHeight = geo.size.height / 2
                HStack(alignment: .center, spacing: 3) {
                    ForEach(samples) { sample in
                        VStack(spacing: 1) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.accent)
                                .frame(height: BandwidthPresentation.barHeight(
                                    bytes: sample.uploadedBytes, isObserved: sample.isObserved,
                                    available: halfHeight, maxBytes: maxBytes))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.success)
                                .frame(height: BandwidthPresentation.barHeight(
                                    bytes: sample.downloadedBytes, isObserved: sample.isObserved,
                                    available: halfHeight, maxBytes: maxBytes))
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        .frame(maxWidth: .infinity)
                        // Observed hours sit on a faint column so the window
                        // Birdwatch actually watched is visible; the rest of
                        // the day is blank — not data.
                        .background(sample.isObserved ? Surface.hover.opacity(0.6) : .clear,
                                    in: RoundedRectangle(cornerRadius: 2))
                    }
                }
                .overlay {
                    Rectangle()
                        .fill(Surface.line)
                        .frame(height: 1)
                }
            }
            HStack(spacing: 3) {
                ForEach(samples) { sample in
                    Text(Self.labeledHours.contains(sample.hour) ? "\(sample.hour)" : " ")
                        .scaledFont(size: 9.5)
                        .foregroundStyle(Surface.fg3)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Hourly upload and download chart, today since Birdwatch started")
        .accessibilityValue(BandwidthPresentation.chartSummary(samples))
    }
}
