import SwiftUI

/// Devices — one card per device on the account (handoff §4).
struct DevicesView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.devices.title, subtitle: MonitorView.devices.subtitle)

            if store.devices.isEmpty {
                if let activity = store.deviceActivity {
                    AnonymousDeviceSummary(summary: activity)
                    SourceFootnote(text: "Derived from bird's own item tree (brctl dump -i): each item records the index of the device that last wrote it. macOS permanently redacts device names, and bird truncates its dump, so names are unavailable and counts are lower bounds.")
                } else {
                    emptyState
                    SourceFootnote(text: "The bird device registry redacts device names in its diagnostic output, and CloudKit's device list has no public API.")
                }
                DeviceManagementFootnote()
            } else {
                ForEach(store.devices) { device in
                    DeviceCard(device: device)
                }
                SourceFootnote(text: "Read from the CloudKit account device list and the bird device registry.")
                DeviceManagementFootnote()
            }
        }
    }

    /// Honest empty state: verified on this machine that `brctl dump` lists
    /// devices only with redacted names ("A{15}o"), and there is no public
    /// CloudKit device-list API — so live mode cannot show real devices.
    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("No device list available", systemImage: "laptopcomputer.slash")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(Surface.fg)
                Text("macOS does not expose the device registry to third-party apps. The devices on your account are visible in System Settings › iCloud.")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Surface.fg2)
            }
        }
    }
}

/// Devices can only be removed from the Apple Account pane — `brctl` exposes
/// no device-management verb (its commands are diagnose/log/dump/status/
/// accounts/quota/monitor, all read-only), and there is no public API for it.
struct DeviceManagementFootnote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            SourceFootnote(text: "Devices are managed in System Settings › Apple Account (removing one there also signs it out of iCloud); Birdwatch can only observe them.")
            Button("Open Apple Account settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .scaledFont(size: 11.5)
        }
    }
}

/// Honest, anonymous device view. bird length-redacts every device name
/// ("A{15}o") and exposes no kind/OS/last-seen, so a row can only ever be an
/// index, an item count and a last-touch date — all three of which ARE real.
struct AnonymousDeviceSummary: View {
    let summary: DeviceActivitySummary
    /// Injected so the "active this week" boundary is testable/stable.
    var now: Date = Date()

    private var activeThisWeek: Int {
        summary.activeCount(since: now.addingTimeInterval(-7 * 86_400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label(headline, systemImage: "laptopcomputer.and.iphone")
                        .scaledFont(size: 14, weight: .bold)
                        .foregroundStyle(Surface.fg)
                    Text("macOS redacts device names, so Birdwatch can only show how much each device has written. Item counts are partial — bird truncates its own diagnostic dump.")
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Surface.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(summary.devicesByActivity.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider().overlay(Surface.cardLine) }
                        row(device)
                            .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private var headline: String {
        let total = summary.registeredDeviceCount
        return "\(total) device\(total == 1 ? "" : "s") have touched your iCloud Drive · \(activeThisWeek) active this week"
    }

    private func row(_ device: DeviceActivityItem) -> some View {
        let active = (device.lastModified ?? .distantPast) >= now.addingTimeInterval(-7 * 86_400)
        return HStack(spacing: 12) {
            StatusDot(color: active ? Palette.success : Palette.gray)
            Text("Device \(device.index)")
                .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                .foregroundStyle(Surface.fg)
                .frame(minWidth: 92, alignment: .leading)
            Text("\(device.itemCount.formatted()) item\(device.itemCount == 1 ? "" : "s")")
                .scaledFont(size: 12.5)
                .foregroundStyle(Surface.fg2)
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(lastTouch(device))
                .scaledFont(size: 12)
                .foregroundStyle(active ? Palette.success : Surface.fg3)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Device \(device.index), \(device.itemCount) items, \(lastTouch(device))")
    }

    private func lastTouch(_ device: DeviceActivityItem) -> String {
        guard let date = device.lastModified else { return "no dated items" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        // "active" is reserved for the week the status dot is green; anything
        // older is stated as a past write, so wording and color never disagree.
        switch days {
        case ..<0, 0: return "active today"
        case 1: return "active yesterday"
        case 2...6: return "active \(days) days ago"
        case 7...60: return "last write \(days) days ago"
        default: return "last write \(date.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }
}

private struct DeviceCard: View {
    let device: DeviceItem

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                ColorTile(colorHex: device.tileColorHex, symbolName: symbolName, letter: device.name, size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .scaledFont(size: 14, weight: .bold)
                            .foregroundStyle(Surface.fg)
                        if device.isCurrentDevice {
                            Text("This device")
                                .scaledFont(size: 9, weight: .heavy)
                                .kerning(0.4)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Palette.accent, in: Capsule())
                        }
                    }
                    Text("\(device.kind) · \(device.osVersion)")
                        .scaledFont(size: 12)
                        .foregroundStyle(Surface.fg2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        StatusDot(color: device.isActive ? Palette.success : Palette.gray, pulses: device.isActive)
                        Text(device.statusLabel)
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(device.isActive ? Palette.success : Surface.fg2)
                            .monospacedDigit()
                    }
                    Text(device.lastChange)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [device.name]
        if device.isCurrentDevice { parts.append("current device") }
        parts.append("\(device.kind), \(device.osVersion)")
        parts.append(device.isActive ? "active, \(device.statusLabel)" : device.statusLabel)
        parts.append(device.lastChange)
        return parts.joined(separator: ", ")
    }

    /// Device symbol inferred from kind; ColorTile falls back to the letter otherwise.
    private var symbolName: String? {
        let kind = device.kind.lowercased()
        if kind.contains("macbook") { return "laptopcomputer" }
        if kind.contains("iphone") { return "iphone" }
        if kind.contains("ipad") { return "ipad" }
        if kind.contains("imac") || kind.contains("mac") { return "desktopcomputer" }
        if kind.contains("web") { return "safari" }
        return nil
    }
}
