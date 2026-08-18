import Combine
import OSLog
import Sparkle
import SwiftUI

@main
struct BirdwatchApp: App {
    /// Sparkle auto-updater. `startingUpdater: true` starts the scheduled
    /// update-check cycle; Sparkle asks the user once whether to enable
    /// automatic checks (its standard UX). Feed URL + EdDSA public key are read
    /// from Info.plist (SUFeedURL / SUPublicEDKey — see Birdwatch/Resources/Info.plist).
    ///
    /// The scheduler only starts when updates can actually work — see
    /// `updaterEnabled`. Starting it otherwise makes Sparkle log a warning about
    /// the missing/placeholder key on every launch of a dev copy.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: BirdwatchApp.updaterEnabled, updaterDelegate: nil, userDriverDelegate: nil
    )

    /// Whether the Sparkle updater should run at all this launch. Three gates:
    ///
    /// 1. **Not under XCTest** — the app is its own test host, so an unguarded
    ///    start fires a real feed check (and can raise Sparkle's first-run
    ///    permission prompt) during every test run. That took the suite from
    ///    ~1.5s to ~11s and flaked a wall-clock throughput test.
    /// 2. **A real EdDSA public key** — until `generate_keys` has been run and
    ///    the key pasted into `Birdwatch/Resources/Info.plist`, the placeholder
    ///    can't verify anything and Sparkle warns loudly. (`scripts/release.sh`
    ///    refuses to ship while the placeholder is present, so this gate only
    ///    ever fires on dev builds.)
    /// 3. **Not `--mock`** — demo/screenshot launches must stay quiet and
    ///    offline.
    private static let updaterEnabled: Bool = {
        let info = ProcessInfo.processInfo
        guard info.environment["XCTestConfigurationFilePath"] == nil,
              info.environment["XCTestSessionIdentifier"] == nil
        else { return false }
        guard !info.arguments.contains("--mock") else { return false }

        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.isEmpty, key != "REPLACE_WITH_PUBLIC_ED_KEY" else {
            Logger(subsystem: "com.wizemann.birdwatch", category: "updates")
                .info("Sparkle updater disabled: no public key configured")
            return false
        }
        return true
    }()

    // Constructing the store is cheap by design: no I/O happens until
    // RootView's .task calls refresh() (§6 — nothing heavy before first frame).
    // `--mock` keeps the design-handoff fixture data for demos/screenshots.
    @State private var store = SyncStore(
        source: ProcessInfo.processInfo.arguments.contains("--mock")
            ? MockSyncSource() as any SyncSource
            : SystemSyncSource()
    )

    var body: some Scene {
        Window("Birdwatch", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { viewCommands }

        MenuBarExtra {
            MenuBarPopoverView()
                .environment(store)
        } label: {
            // The app's bird mark as a template image (macOS tints it for the
            // menu bar), with a small state badge: issues outrank pause.
            Image("MenuBarIcon")
                .overlay(alignment: .bottomTrailing) {
                    if let badge = menuBarBadge {
                        Image(systemName: badge)
                            .font(.system(size: 7, weight: .black))
                            .offset(x: 3, y: 2)
                    }
                }
                .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarBadge: String? {
        if store.issueCount > 0 { return "exclamationmark.circle.fill" }
        if store.isGloballyPaused { return "pause.circle.fill" }
        return nil
    }

    private var menuBarAccessibilityLabel: String {
        if store.issueCount > 0 { return "Birdwatch, \(store.issueCount) issues" }
        if store.isGloballyPaused { return "Birdwatch, monitoring paused" }
        return "Birdwatch"
    }

    /// macOS is keyboard-first: ⌘1–⌘9 jump between monitor views, ⌘R refreshes,
    /// ⇧⌘P toggles monitoring.
    @CommandsBuilder
    private var viewCommands: some Commands {
        // Sparkle's "Check for Updates…" sits under the app menu, right after
        // "About Birdwatch" — the conventional macOS placement. Omitted entirely
        // when the updater is gated off (see `updaterEnabled`): a menu item that
        // can only ever fail is worse than no menu item.
        CommandGroup(after: .appInfo) {
            if BirdwatchApp.updaterEnabled {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        CommandMenu("View") {
            ForEach(Array(MonitorView.allCases.enumerated()), id: \.element.id) { index, view in
                Button(view.title) {
                    store.navigate(to: view)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: .command
                )
            }

            Divider()

            Button("Refresh Now") {
                Task { await store.refresh(force: true) }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(store.isGloballyPaused ? "Resume Monitoring" : "Pause Monitoring") {
                store.togglePauseAll()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

/// "Check for Updates…" menu command. Disabled while Sparkle can't check
/// (e.g. a check is already in flight). Canonical Sparkle SwiftUI integration.
private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Bridges Sparkle's KVO `canCheckForUpdates` into an observable flag so the
/// menu item enables/disables correctly.
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
