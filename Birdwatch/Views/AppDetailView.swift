import SwiftUI
import AppKit
import os

private let detailLogger = Logger(subsystem: "com.wizemann.birdwatch", category: "AppDetail")

/// Allocated once — never in body.
private let logTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct AppDetailView: View {
    @Environment(SyncStore.self) private var store
    let appID: String

    var body: some View {
        if let app = store.app(withID: appID) {
            ContentColumn {
                ViewHeader(title: app.name, subtitle: "Applications · \(app.backend.badgeLabel)")

                backLink
                headerCard(app)
                infoGrid(app)

                if let callout = app.infoCallout {
                    InfoCallout(text: callout)
                }

                if app.backend == .cloudDocs {
                    transfersCard
                }

                if !app.queueLabels.isEmpty {
                    queueCard(app)
                }

                diagnosticsSection(app)
                LiveLogConsole(appID: app.id, backend: app.backend)
                SourceFootnote(text: footnoteText(app.backend))
            }
        } else {
            ContentColumn {
                ViewHeader(title: "Application", subtitle: "Not found")
                backLink
            }
        }
    }

    private var backLink: some View {
        Button {
            store.detailAppID = nil
        } label: {
            Label("All applications", systemImage: "chevron.left")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Palette.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to all applications")
    }

    // MARK: - Header card

    private func headerCard(_ app: AppSyncState) -> some View {
        Card(padding: 18) {
            HStack(spacing: 16) {
                ColorTile(colorHex: app.tileColorHex, letter: app.name, size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(app.name)
                            .scaledFont(size: 17, weight: .bold)
                            .foregroundStyle(Surface.fg)
                        SourceBadge(backend: app.backend)
                    }
                    HStack(spacing: 6) {
                        Text(app.status.shortLabel)
                            .scaledFont(size: 12.5, weight: .semibold)
                            .foregroundStyle(app.status.tint)
                            .monospacedDigit()
                        if app.status.isSyncing { SyncSpinner() }
                        Text("· \(app.statusLine)")
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
                            .lineLimit(2)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 12)

                // "Force sync" is deliberately absent: macOS offers no
                // supported API or command to trigger one (see footnote).
                if canReveal(app) {
                    Button("Reveal in Finder") {
                        detailLogger.info("Reveal in Finder requested for \(app.id, privacy: .public)")
                        revealInFinder(app.locationPath)
                    }
                }
            }
        }
    }

    /// CloudKit apps have no location path; Desktop & Documents reports a
    /// dual path ("A · B") we can't resolve to a single Finder selection.
    private func canReveal(_ app: AppSyncState) -> Bool {
        !app.locationPath.isEmpty && !app.locationPath.contains(" · ")
    }

    private func revealInFinder(_ locationPath: String) {
        let expanded = NSString(string: locationPath).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }

    // MARK: - Info grid

    private func infoGrid(_ app: AppSyncState) -> some View {
        let daemon = store.daemons.first { $0.name == app.backend.daemonName }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
            InfoTile(label: "Items indexed", value: "\(app.itemsIndexed.formatted()) items")
            InfoTile(label: "Pending", value: app.pendingItems == 0 ? "None" : "\(app.pendingItems.formatted()) items")
            InfoTile(label: "Last synced", value: lastSyncedText(app))
            // Allocated bytes actually stored locally — dataless placeholders
            // are tiny, so this is the on-disk footprint, not the cloud size.
            InfoTile(label: "On this Mac", value: Format.size(app.localSizeBytes))
            InfoTile(label: "Sync daemon",
                     value: daemon.map { "\($0.name) · \(Int($0.cpuPercent))% CPU" } ?? app.backend.daemonName,
                     monospaced: true)
            InfoTile(label: "Progress detail", value: app.backend.progressDetail)
        }
    }

    private func lastSyncedText(_ app: AppSyncState) -> String {
        if app.status.isSyncing { return "Syncing now" }
        guard let last = app.lastActivity else { return "—" }
        return Format.relative.localizedString(for: last, relativeTo: Date())
    }

    // MARK: - Transfers (CloudDocs only)

    private var transfersCard: some View {
        let transfers = store.transfers(for: appID)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Files in transfer")
            Card {
                VStack(spacing: 12) {
                    ForEach(transfers) { item in
                        TransferRow(item: item)
                        if item.id != transfers.last?.id {
                            Divider().overlay(Surface.cardLine)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Queue breakdown

    private func queueCard(_ app: AppSyncState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Queue breakdown")
            Card {
                HStack(spacing: 0) {
                    ForEach(Array(zip(app.queueLabels, app.queueCounts)), id: \.0) { label, count in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(Surface.fg2)
                            Text(count.formatted())
                                .scaledFont(size: 20, weight: .bold)
                                .foregroundStyle(Surface.fg)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics

    private func diagnosticsSection(_ app: AppSyncState) -> some View {
        let daemon = store.daemons.first { $0.name == app.backend.daemonName }
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Diagnostics")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    if let daemon {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(daemon.name)
                                    .scaledFont(size: 12.5, weight: .semibold)
                                    .monospaced()
                                    .foregroundStyle(Surface.fg)
                                Spacer()
                                Text("\(Int(daemon.cpuPercent))% CPU · \(healthLabel(daemon.cpuPercent))")
                                    .scaledFont(size: 12, weight: .semibold)
                                    .foregroundStyle(cpuTint(daemon.cpuPercent))
                                    .monospacedDigit()
                            }
                            MiniProgressBar(progress: min(daemon.cpuPercent / 100, 1), tint: cpuTint(daemon.cpuPercent), label: "\(daemon.name) CPU load")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(daemon.name), \(Int(daemon.cpuPercent)) percent CPU, \(healthLabel(daemon.cpuPercent))")
                    }

                    if let warning = app.retryWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .scaledFont(size: 12)
                                .foregroundStyle(Palette.warning)
                            Text(warning)
                                .scaledFont(size: 12.5)
                                .foregroundStyle(Surface.fg)
                                .monospacedDigit()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Location")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(Surface.fg2)
                        Text(app.locationPath)
                            .scaledFont(size: 12)
                            .monospaced()
                            .foregroundStyle(Surface.fg)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func healthLabel(_ percent: Double) -> String {
        if percent < 15 { "Healthy" } else if percent < 30 { "Elevated" } else { "High load" }
    }

    private func footnoteText(_ backend: SyncBackend) -> String {
        let source = switch backend {
        case .cloudDocs:
            "Data source: brctl status / NSMetadataQuery (bird) — per-file exact progress."
        case .cloudKit:
            "Data source: cloudd status and item counts — CloudKit exposes no per-item progress API."
        case .fileProvider:
            "Data source: fileproviderd domain status — File Provider reports domain-level status only."
        }
        return source + " macOS offers no supported command to force a sync, so that control isn't offered here."
    }
}

// MARK: - Info tile

private struct InfoTile: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Surface.fg2)
                Text(value)
                    .scaledFont(size: 15, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(Surface.fg)
                    .modifier(MonoIf(enabled: monospaced))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonoIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.monospaced() } else { content }
    }
}

// MARK: - Transfer row

private struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction.symbolName)
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(item.direction.tint)
                .frame(width: 24, height: 24)
                .background(item.direction.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(item.direction == .upload ? "Uploading" : "Downloading")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                    .lineLimit(1)
                Text("\(item.location) · \(Format.size(item.sizeBytes))")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg2)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            MiniProgressBar(
                progress: item.progress,
                tint: item.direction.tint,
                label: "\(item.name) transfer progress",
                indeterminate: item.isIndeterminate
            )
            .frame(width: 90)

            Text(statusText)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(item.isDone ? Palette.success : Surface.fg2)
                .monospacedDigit()
                .frame(width: 68, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// The ubiquity channel has no percentage, so an in-flight row says what
    /// it is doing rather than inventing a number.
    private var statusText: String {
        if item.isDone { return "Done" }
        if item.isIndeterminate { return item.direction == .upload ? "Uploading…" : "Downloading…" }
        return "\(Int((item.progress * 100).rounded()))%"
    }
}

// MARK: - Info callout

private struct InfoCallout: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .scaledFont(size: 13)
                .foregroundStyle(Palette.accent)
            Text(text)
                .scaledFont(size: 12.5)
                .foregroundStyle(Surface.fg)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.accent.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Live log console

/// Always-dark console regardless of appearance. Streams from the store's
/// per-app log stream while the detail is open; resets on app switch.
private struct LiveLogConsole: View {
    let appID: String
    let backend: SyncBackend
    @Environment(SyncStore.self) private var store
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var lines: [LogLine] = []

    private var dimText: Color {
        colorSchemeContrast == .increased ? Color(hex: "c4c4ca") : Color(hex: "9a9aa0")
    }
    private var bodyTextColor: Color {
        colorSchemeContrast == .increased ? Color(hex: "f0f0f4") : Color(hex: "d6d6db")
    }

    private var command: String {
        switch backend {
        case .cloudDocs: "log stream · com.apple.clouddocs"
        case .cloudKit: "log stream · cloudd"
        case .fileProvider: "log stream · fileproviderd"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(command)
                    .scaledFont(size: 11.5, weight: .semibold)
                    .monospaced()
                    .foregroundStyle(dimText)
                Spacer()
                StatusDot(color: Palette.success, pulses: true)
                Text("live")
                    .scaledFont(size: 10.5, weight: .bold)
                    .foregroundStyle(Palette.success)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(logTimestampFormatter.string(from: line.date))
                            .scaledFont(size: 11)
                            .monospaced()
                            .foregroundStyle(dimText) // ≥4.5:1 on the #0b0b0f console
                        Text(line.level.rawValue)
                            .scaledFont(size: 9, weight: .heavy)
                            .monospaced()
                            .kerning(0.4)
                            .foregroundStyle(line.level.tint)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(line.level.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                        Text(line.message)
                            .scaledFont(size: 11.5)
                            .monospaced()
                            .foregroundStyle(bodyTextColor)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }
        .background(Palette.console, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .task(id: appID) {
            lines = []
            // Coalesce arrivals into a local buffer and flush to @State at
            // most every 250ms, so a log storm doesn't drive a SwiftUI
            // state write (and view diff) per line.
            var buffer: [LogLine] = []
            var flushTask: Task<Void, Never>?
            for await line in store.logStream(appID: appID) {
                buffer.insert(line, at: 0)
                guard flushTask == nil else { continue }
                flushTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    // Keep newest at the TOP regardless of arrival order: the
                    // seed burst arrives newest-first while live lines arrive
                    // newest-last, so plain insert-at-0 would leave the seeds
                    // inverted.
                    lines.insert(contentsOf: buffer, at: 0)
                    lines.sort { $0.date > $1.date }
                    if lines.count > 25 { lines.removeLast(lines.count - 25) }
                    buffer.removeAll()
                    flushTask = nil
                }
            }
        }
        .accessibilityLabel("Live log for \(command)")
    }
}
