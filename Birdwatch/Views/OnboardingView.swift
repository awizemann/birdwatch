import AppKit
import os
import SwiftUI
import UserNotifications

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "onboarding")

/// First-run setup (design: "First-run onboarding"). Completion persists in
/// preferences; Phase 1 replaces the manual switch with real Full Disk Access
/// detection + a deep link to Privacy & Security.
struct OnboardingView: View {
    @Environment(SyncStore.self) private var store
    @Binding var isComplete: Bool
    @State private var step = 0
    /// nil until the first probe answers — nothing about access is claimed
    /// (and the escape hatch stays hidden) while it is still checking.
    @State private var fdaState: PermissionState?
    private var fdaGranted: Bool { fdaState == .granted }
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
            // The real app icon (already loaded by AppKit — no I/O here), not
            // a lettered "B" tile that matched nothing the user will see in
            // the Dock. The icon art carries its own transparent margin, so
            // it is drawn a little larger than the old 64pt tile.
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            Text("Welcome to Birdwatch")
                .scaledFont(size: 24, weight: .bold)
                .kerning(-0.3)
                .accessibilityAddTraits(.isHeader)

            Text("Birdwatch watches the system services that run iCloud and shows you what they're doing — sync activity, files in transit, issues, and diagnostics — all in one place.")
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
        ("brctl · bird", "iCloud Drive engine state and quota"),
        ("FSEvents", "Which iCloud Drive files are moving"),
        ("log · cloudd", "CloudKit activity in the system log"),
        ("ps · nettop", "Daemon load and estimated traffic"),
    ]

    private var grantAccess: some View {
        VStack(spacing: 18) {
            Text("Grant system access")
                .scaledFont(size: 24, weight: .bold)
                .kerning(-0.3)
                .accessibilityAddTraits(.isHeader)

            Text("Birdwatch runs outside the App Sandbox and asks for Full Disk Access so it can also watch Desktop & Documents, which macOS protects. Without it, most of Birdwatch still works and those folders are left alone. Your files and sync data never leave your Mac; anonymous usage counts do, and Diagnostics has the switch to turn that off.")
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
                        if fdaState == nil {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking…").scaledFont(size: 12).foregroundStyle(Surface.fg3)
                            }
                            .accessibilityElement(children: .combine)
                        } else if fdaGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(Palette.success)
                        } else {
                            Button("Open System Settings…") {
                                PermissionsProbe.openFullDiskAccessSettings()
                            }
                        }
                    }
                    Text(fdaState == .unknown
                         ? "Birdwatch can't tell whether access is granted on this Mac. If you've granted it, continue below."
                         : "Grant access in System Settings — Birdwatch detects it automatically.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                }
            }
            // Poll the real grant while this step is visible (2s cadence —
            // TCC grants land while the user is in System Settings).
            .task {
                while !Task.isCancelled && !fdaGranted {
                    fdaState = await PermissionsProbe.fullDiskAccessState()
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
                Button("Enter Birdwatch") { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!fdaGranted)
                    .accessibilityHint(fdaGranted ? "" : "Requires Full Disk Access to be enabled")
            }

            // Escape hatch: the probe can miss a real grant (an account with
            // none of its probe files, or a future macOS that moves them), and
            // a false negative must not lock anyone out. Diagnostics keeps
            // reporting the probe's real answer either way.
            if fdaState == .denied || fdaState == .unknown {
                VStack(spacing: 4) {
                    Button("Continue without Full Disk Access") { finish() }
                        .buttonStyle(.link)
                        .scaledFont(size: 12.5, weight: .semibold)
                    Text("Desktop & Documents won't be watched. Diagnostics shows whether access is granted, and you can re-run setup from there.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func finish() {
        if optNotifications {
            Task {
                do {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                    logger.info("notification authorization request answered: granted=\(granted, privacy: .public)")
                } catch {
                    logger.error("notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // fdaGranted is false for `.denied` AND `.unknown`, and can now be false
        // on completion via "Continue without Full Disk Access".
        store.record(.onboardingCompleted(fdaGranted: fdaGranted, notificationsRequested: optNotifications))
        isComplete = true
    }
}
