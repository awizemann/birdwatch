import SwiftUI

struct BandwidthView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.bandwidth.title, subtitle: MonitorView.bandwidth.subtitle)

            if let bandwidth = store.bandwidth {
                HStack(spacing: 14) {
                    statTile(label: "Uploaded today", value: Format.size(bandwidth.uploadedTodayBytes), tint: Palette.accent)
                    statTile(label: "Downloaded today", value: Format.size(bandwidth.downloadedTodayBytes), tint: Palette.success)
                    statTile(label: "Current rate", value: "≈ \(Format.size(bandwidth.currentRateBytesPerSec))/s", tint: Surface.fg)
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Last 24 hours")
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
                                .frame(height: barHeight(sample.uploadedBytes, halfHeight: halfHeight, maxBytes: maxBytes))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.success)
                                .frame(height: barHeight(sample.downloadedBytes, halfHeight: halfHeight, maxBytes: maxBytes))
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        .frame(maxWidth: .infinity)
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
        .accessibilityLabel("24-hour upload and download chart")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let uploaded = samples.map(\.uploadedBytes).reduce(0, +)
        let downloaded = samples.map(\.downloadedBytes).reduce(0, +)
        let peakHour = samples.max { ($0.uploadedBytes + $0.downloadedBytes) < ($1.uploadedBytes + $1.downloadedBytes) }?.hour ?? 0
        return "Uploaded \(Format.size(uploaded)), downloaded \(Format.size(downloaded)) in the last 24 hours; busiest hour \(peakHour):00"
    }

    private func barHeight(_ bytes: Int64, halfHeight: CGFloat, maxBytes: Int64) -> CGFloat {
        max(2, halfHeight * CGFloat(bytes) / CGFloat(maxBytes))
    }
}
