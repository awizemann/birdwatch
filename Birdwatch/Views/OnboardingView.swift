import AppKit
import os
import SwiftUI
import UserNotifications

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "onboarding")

/// The two first-run screens. Raw values are the `onboarding_step_shown`
/// wire values.
nonisolated enum OnboardingStep: String, Sendable, CaseIterable {
    case welcome
    case grantAccess = "grant_access"
}

/// First-run setup (design: "First-run onboarding"). Completion persists in
/// preferences. Full Disk Access is required: setup finishes only when the
/// probe confirms it, or cannot tell (see TransferWatchPolicy.iCloudDriveAccess).
struct OnboardingView: View {
    @Environment(SyncStore.self) private var store
    @Binding var isComplete: Bool
    @State private var step = OnboardingStep.welcome
    /// nil until the first probe answers (see FullDiskAccessCard).
    @State private var fdaState: PermissionState?
    private var canEnter: Bool {
        TransferWatchPolicy.iCloudDriveAccess(fullDiskAccess: fdaState).readsICloudDrive
    }
    @State private var optNotifications = true

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case .welcome: welcome
                case .grantAccess: grantAccess
                }
            }
            .frame(maxWidth: 460)
            // The funnel: which screen people reach, so drop-off between
            // welcome, the Full Disk Access step and completion is visible.
            .onChange(of: step, initial: true) { _, shown in
                store.recordOnboardingStepShown(shown)
            }
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

            Button("Get Started") { step = .grantAccess }
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
            Text("Grant Full Disk Access")
                .scaledFont(size: 24, weight: .bold)
                .kerning(-0.3)
                .accessibilityAddTraits(.isHeader)

            Text(FullDiskAccessCopy.whyRequired + " Your files and sync data never leave your Mac; anonymous usage counts do, and Settings has the switch to turn that off.")
                .scaledFont(size: 13.5)
                .foregroundStyle(Surface.fg2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            FullDiskAccessCard(state: $fdaState)

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

            // No way past this step without access (Alan, 2026-10-06): the
            // one exception is a probe that cannot tell, which the card
            // above warns about (see TransferWatchPolicy.iCloudDriveAccess).
            HStack {
                Button("Back") { step = .welcome }
                    .buttonStyle(.bordered)
                Button("Enter Birdwatch") { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canEnter)
                    .accessibilityHint(canEnter ? "" : "Requires Full Disk Access")
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
                // The answer just changed the Notifications row.
                await store.reprobePermissions()
            }
        }
        // The store may have cached permission answers while setup was on
        // screen (the popover refreshes too) — before the grant made here.
        // No refresh of its own: the main window's first one follows.
        Task { await store.reprobePermissions() }
        // Setup can only finish with access granted or unconfirmed, so
        // fda_granted is false only when the probe could not tell (`.unknown`).
        store.record(.onboardingCompleted(fdaGranted: fdaState == .granted, notificationsRequested: optNotifications))
        isComplete = true
    }
}

/// The words for why Full Disk Access is required, shared by setup and the
/// screen shown when access is turned off later.
enum FullDiskAccessCopy {
    static let whyRequired = "Birdwatch needs Full Disk Access. Without it, reading iCloud Drive makes macOS ask for permission and hold every read until someone answers — so until access is granted, Birdwatch reads nothing in iCloud Drive. With it, Birdwatch can also watch Desktop & Documents."

    /// The line under the status row, per probe answer.
    static func note(for state: PermissionState?) -> String? {
        switch state {
        case nil, .granted?: nil
        case .denied?: "Turn on Birdwatch in System Settings — Birdwatch detects it automatically."
        case .unknown?: "Birdwatch can't tell whether access is granted on this Mac. You can continue, but if it isn't, macOS may ask before Birdwatch can read iCloud Drive."
        }
    }
}

/// Privacy & Security › Full Disk Access, as Birdwatch sees it: the probe's
/// answer, a way to System Settings, and what the answer means. Polls the
/// real probe every 2 s while on screen (TCC grants land while the person is
/// in System Settings) and stops once access is granted.
struct FullDiskAccessCard: View {
    /// nil until the first probe answers — nothing about access is claimed
    /// while it is still checking.
    @Binding var state: PermissionState?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Privacy & Security › Full Disk Access")
                HStack(spacing: 10) {
                    ColorTile(colorHex: "0a84ff", symbolName: "binoculars.fill", size: 26)
                    Text("Birdwatch").scaledFont(size: 13, weight: .semibold)
                    Spacer()
                    if state == nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").scaledFont(size: 12).foregroundStyle(Surface.fg3)
                        }
                        .accessibilityElement(children: .combine)
                    } else if state == .granted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(Palette.success)
                    } else {
                        Button("Open System Settings…") {
                            PermissionsProbe.openFullDiskAccessSettings()
                        }
                    }
                }
                if let note = FullDiskAccessCopy.note(for: state) {
                    Text(note)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            while !Task.isCancelled && state != .granted {
                state = await PermissionsProbe.fullDiskAccessState()
                if state == .granted { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Shown in place of the main window when Full Disk Access is turned off
/// after setup. By then the source has stopped every iCloud Drive read
/// (SystemSyncSource.fullDiskAccessGate); this says so, and the moment the
/// card sees access again it re-probes and refreshes, which brings the main
/// window back. Records no setup events: this is not setup.
struct FullDiskAccessRequiredView: View {
    @Environment(SyncStore.self) private var store
    @State private var fdaState: PermissionState?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 18) {
                Text("Full Disk Access is off")
                    .scaledFont(size: 24, weight: .bold)
                    .kerning(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text(FullDiskAccessCopy.whyRequired)
                    .scaledFont(size: 13.5)
                    .foregroundStyle(Surface.fg2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                FullDiskAccessCard(state: $fdaState)
            }
            .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.window)
        // Works while monitoring is paused too: see SyncStore.fullDiskAccessProbed.
        .onChange(of: fdaState) { _, state in
            guard let state else { return }
            Task { await store.fullDiskAccessProbed(state) }
        }
    }
}
