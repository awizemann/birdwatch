import SwiftUI

struct SidebarView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: selectionBinding) {
                Section {
                    ForEach(MonitorView.allCases) { item in
                        SidebarRow(item: item, issueCount: item == .issues ? store.issueCount : 0)
                            .tag(item)
                    }
                } header: {
                    SectionLabel(text: "Monitor")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            StorageFooter()
        }
        .background(.ultraThinMaterial)
    }

    private var selectionBinding: Binding<MonitorView?> {
        Binding(
            // Keep the sidebar highlighted while a detail (app or conflict)
            // screen is open — those routes belong to their parent sections.
            get: { store.selectedView },
            set: { newValue in
                guard let newValue else { return }
                store.detailAppID = nil
                store.conflictIssueID = nil
                store.selectedView = newValue
            }
        )
    }
}

private struct SidebarRow: View {
    let item: MonitorView
    let issueCount: Int

    var body: some View {
        HStack(spacing: 9) {
            ColorTile(color: tileColor, symbolName: item.symbolName, size: 22)
            Text(item.title)
                .scaledFont(size: 13, weight: .medium)
            Spacer()
            if issueCount > 0 {
                Text("\(issueCount)")
                    .scaledFont(size: 10.5, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Palette.error, in: Capsule())
                    .accessibilityLabel("\(issueCount) issues")
            }
        }
        .padding(.vertical, 1)
    }

    private var tileColor: Color {
        switch item {
        case .overview: Palette.navOverview
        case .applications: Palette.navApplications
        case .drive: Palette.navDrive
        case .devices: Palette.navDevices
        case .issues: Palette.navIssues
        case .activity: Palette.navActivity
        case .diagnostics: Palette.navDiagnostics
        case .bandwidth: Palette.navBandwidth
        case .storage: Palette.navStorage
        }
    }
}

/// Pinned footer: "iCloud Storage 147.2 / 200 GB" + thin gradient bar.
struct StorageFooter: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        if let storage = store.storage {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("iCloud Storage")
                        .scaledFont(size: 11.5, weight: .semibold)
                        .foregroundStyle(Surface.fg2)
                    Spacer()
                    // Account figure when the quota makes it knowable (matches
                    // System Settings); no cap known → the measured footprint
                    // alone rather than a fraction of an invented total.
                    Text(Self.label(for: storage.footerFigure))
                        .scaledFont(size: 11)
                        .foregroundStyle(Surface.fg3)
                        .monospacedDigit()
                }
                if let progress = storage.footerFigure.progress {
                    MiniProgressBar(progress: progress, height: 3, label: "iCloud storage used")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
    }

    static func label(for figure: StorageFooterFigure) -> String {
        switch figure {
        case let .account(used, cap):
            "\(Format.capacity(used)) / \(Format.capacity(cap))"
        case let .local(used, cap):
            "\(Format.gigabytes(used)) / \(Format.gigabytes(cap)) on this Mac"
        case let .localOnly(used):
            "\(Format.gigabytes(used)) on this Mac"
        }
    }
}
