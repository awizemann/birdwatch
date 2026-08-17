import SwiftUI
import UserNotifications

/// First-run setup (design: "First-run onboarding"). Completion persists in
/// preferences; Phase 1 replaces the manual switch with real Full Disk Access
/// detection + a deep link to Privacy & Security.
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var step = 0
    @State private var fdaGranted = false
    @State private var optNotifications = true

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                if step == 0 { welcome } else { grantAccess }
            }
            .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.window)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Palette.accent, Palette.navApplications], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay(Text("B").scaledFont(size: 30, weight: .bold).foregroundStyle(.white))
                .accessibilityHidden(true)

            Text("Welcome to Birdwatch")
                .scaledFont(size: 24, weight: .bold)
                .kerning(-0.3)
                .accessibilityAddTraits(.isHeader)

            Text("Birdwatch watches the system services that run iCloud and shows you what they're doing — sync progress, files in transit, issues, and diagnostics — all in one place.")
                .scaledFont(size: 13.5)
                .foregroundStyle(Surface.fg2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "What it reads")
                    ForEach(sources, id: \.0) { name, detail in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Palette.success)
                                .scaledFont(size: 13)
                            Text(name).scaledFont(size: 12.5, weight: .semibold).monospaced()
                            Text(detail).scaledFont(size: 12).foregroundStyle(Surface.fg2)
                            Spacer()
                        }
                    }
                }
            }

            Button("Get Started") { step = 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private let sources: [(String, String)] = [
        ("brctl · bird", "CloudDocs sync engine"),
        ("cloudd", "CloudKit status and counts"),
        ("fileproviderd", "Third-party sync domains"),
        ("NSMetadataQuery", "Per-file transfer progress"),
    ]

    private var grantAccess: some View {
        VStack(spacing: 18) {
            Text("Grant system access")
                .scaledFont(size: 24, weight: .bold)
                .kerning(-0.3)
                .accessibilityAddTraits(.isHeader)

            Text("Birdwatch runs outside the App Sandbox and needs Full Disk Access to read iCloud's sync state. Nothing leaves your Mac.")
                .scaledFont(size: 13.5)
                .foregroundStyle(Surface.fg2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Privacy & Security › Full Disk Access")
                    HStack(spacing: 10) {
                        ColorTile(colorHex: "0a84ff", symbolName: "binoculars.fill", size: 26)
                        Text("Birdwatch").scaledFont(size: 13, weight: .semibold)
                        Spacer()
                        if fdaGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(Palette.success)
                        } else {
                            Button("Open System Settings…") {
                                PermissionsProbe.openFullDiskAccessSettings()
                            }
                        }
                    }
                    Text("Required. Grant access in System Settings — Birdwatch detects it automatically.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                }
            }
            // Poll the real grant while this step is visible (2s cadence —
            // TCC grants land while the user is in System Settings).
            .task {
                while !Task.isCancelled && !fdaGranted {
                    fdaGranted = await PermissionsProbe.fullDiskAccessGranted()
                    if fdaGranted { break }
                    try? await Task.sleep(for: .seconds(2))
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Optional")
                    Toggle("Notifications", isOn: $optNotifications).toggleStyle(.switch)
                    Text("Get notified about issues, conflicts and storage alerts.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                }
            }
            .scaledFont(size: 13)

            HStack {
                Button("Back") { step = 0 }
                    .buttonStyle(.bordered)
                Button("Enter Birdwatch") {
                    if optNotifications {
                        Task {
                            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                        }
                    }
                    isComplete = true
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!fdaGranted)
                    .accessibilityHint(fdaGranted ? "" : "Requires Full Disk Access to be enabled")
            }
        }
    }
}
