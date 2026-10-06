import AppKit
import SwiftUI

/// The ⌘, window. Hosts preferences that already exist elsewhere — it adds
/// none of its own. The usage toggle is the same control (and the same
/// storage, via `SyncStore.setUsageSharing`) as the one in Diagnostics; the
/// plan is chosen where it is explained, on the Storage screen.
struct SettingsView: View {
    @Environment(SyncStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The plan with its provenance (≈ estimated / set by you /
        // contested), the same rule as every other storage figure (C2).
        let plan = StorageCapLabel.settingsPlanText(store.storage)
        Form {
            Section {
                UsageSharingToggle()
            }

            Section {
                LabeledContent("iCloud plan") {
                    Text(plan.text)
                        .foregroundStyle(Surface.fg2)
                        .accessibilityLabel(plan.spoken)
                }
                Button("Change Plan in Storage…") {
                    // A link from another surface: the existing `.link`
                    // navigation source, so the analytics contract is
                    // unchanged.
                    store.navigate(to: .storage, via: .link)
                    openWindow(id: "main")
                    NSApp.activate()
                    // The jump lands in the main window; Settings would
                    // otherwise stay on top of it.
                    dismiss()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The anonymous-usage opt-out (swift-stats consumer checklist §4). One
/// control, shown in Diagnostics and in Settings; copy says exactly what is
/// and isn't sent.
struct UsageSharingToggle: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        Toggle(isOn: usageSharingBinding) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Share anonymous usage")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(Surface.fg)
                Text("Which screens and actions get used, plus app version, macOS version, Mac model, language and region, under a random install ID. Never file names, paths, app names or account details.")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.usageSharingAvailable {
                    // Gated off (no analytics key, a --mock run): nothing is
                    // sent, so there is nothing for the switch to control.
                    Text("Not available in this build — it sends no usage data.")
                        .scaledFont(size: 11.5, weight: .medium)
                        .foregroundStyle(Surface.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!store.usageSharingAvailable)
        .task { await store.loadUsagePreference() }
    }

    private var usageSharingBinding: Binding<Bool> {
        Binding(get: { store.usageSharingEnabled }, set: { store.setUsageSharing($0) })
    }
}
