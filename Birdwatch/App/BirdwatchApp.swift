import AppKit
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

    /// Whether the Sparkle updater should run at all this launch. Four gates:
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
    /// 4. **The exact release bundle id** — the dogfood copy
    ///    (`com.wizemann.birdwatch.dev`, scripts/build-detached.sh) carries the
    ///    real key, so without this it polled the release feed for updates it
    ///    can never install (Sparkle refuses the bundle-id mismatch).
    private static let updaterEnabled: Bool = {
        let enabled = isUpdaterEnabled(
            bundleID: Bundle.main.bundleIdentifier,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            arguments: ProcessInfo.processInfo.arguments,
            isRunningTests: isRunningTests
        )
        if !enabled {
            Logger(subsystem: "com.wizemann.birdwatch", category: "updates")
                .info("Sparkle updater disabled for this build or launch")
        }
        return enabled
    }()

    /// The bundle id release builds ship with; any other id is a dev copy.
    nonisolated static let releaseBundleID = "com.wizemann.birdwatch"

    /// The four gates above as a pure function, so each one is testable.
    nonisolated static func isUpdaterEnabled(
        bundleID: String?, publicKey: String?, arguments: [String], isRunningTests: Bool
    ) -> Bool {
        guard !isRunningTests else { return false }
        guard !arguments.contains("--mock") else { return false }
        guard bundleID == releaseBundleID else { return false }
        guard let publicKey, !publicKey.isEmpty, publicKey != "REPLACE_WITH_PUBLIC_ED_KEY" else { return false }
        return true
    }

    // Constructing the store is cheap by design: no I/O happens until
    // RootView's .task calls refresh() (§6 — nothing heavy before first frame).
    // `--mock` keeps the design-handoff fixture data for demos/screenshots.
    // Usage analytics (swift-stats) rides along: `makeTracker()` is a no-op
    // under XCTest, `--mock`, or without a baked-in write key. Constructing
    // the client does no I/O either.
    @State private var store: SyncStore
    /// Keeps the NSApplication observers alive for the app's lifetime.
    private let usageLifecycle: UsageLifecycle
    /// The app's one maintenance actor, handed to the view tree through the
    /// environment so Diagnostics cannot mint a fresh one per body pass.
    /// Allocating it runs no Process and touches no disk (C4).
    @State private var maintenance = MaintenanceActions()

    /// The app is its own test host, so this `init` runs for every test run.
    private static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()

    init() {
        let usage = UsageAnalytics.makeTracker()
        // Under XCTest the host app must be inert: the live source would spawn
        // brctl / ps / nettop / log, walk iCloud Drive and post real banners
        // during every test run. Tests build their own stores with stubs.
        let inert = Self.isRunningTests || ProcessInfo.processInfo.arguments.contains("--mock")
        let store = SyncStore(
            source: inert ? MockSyncSource() as any SyncSource : SystemSyncSource(),
            notifier: { title, body, id in
                guard !inert else { return }
                SystemNotifier.post(title: title, body: body, id: id)
            },
            usage: usage,
            setTransferWatching: { watching in
                NotificationCenter.default.post(
                    name: watching ? UbiquityTransferSource.resumeRequest : UbiquityTransferSource.pauseRequest,
                    object: nil
                )
            },
            isMainWindowVisible: { MenuBarPopoverView.isMainWindowVisible(in: NSApp.windows) }
        )
        _store = State(initialValue: store)
        usageLifecycle = UsageLifecycle(store: store)
    }

    var body: some Scene {
        Window("Birdwatch", id: "main") {
            // Under XCTest the host window renders nothing: RootView would
            // start the 15s poll and OnboardingView's .task polls the real
            // Full Disk Access probe every 2s. Tests drive views directly.
            if Self.isRunningTests {
                EmptyView()
            } else {
                RootView()
                    .environment(store)
                    .environment(\.maintenanceActions, maintenance)
                    .frame(minWidth: 900, minHeight: 620)
            }
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
        if store.issueCount > 0 { return "Birdwatch, \(Plural.count(store.issueCount, "issue"))" }
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
                    store.navigate(to: view, via: .shortcut)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: .command
                )
            }

            Divider()

            Button("Refresh Now") {
                store.record(.refreshForced)
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

/// swift-stats installs no lifecycle observers of its own; `didBecomeActive`
/// is what produces `app_open` and sessions (consumer checklist §1). Driven
/// from NSApplication rather than `scenePhase`: this is a Window + MenuBarExtra
/// app, so the window's scene phase goes `.background` when the window closes
/// while the app is still in use from the menu bar, and never fires again once
/// the window is gone. Resign-active (every ⌘-tab away) only flushes the queue
/// — no `app_background` event, that would be noise on macOS.
///
/// Deliberately no activation call at launch: a launch nobody sees (a login
/// item) must not count as an open or start a session. Activation goes
/// through the store, which also holds the launch events until then; a person
/// opening the menu-bar popover without activating the app is covered by
/// `SyncStore.menuBarOpened()`.
///
/// No willTerminate flush: the process exits as soon as that notification
/// returns, so a spawned flush Task never ran — a no-op that looked like a
/// guarantee. swift-stats keeps its queue on disk and the next launch picks
/// it up, so quitting costs latency, not events — short of a `record()` from
/// the last instant that had not reached disk yet, which is not worth a
/// terminateLater delegate.
@MainActor
final class UsageLifecycle {
    private var tokens: [any NSObjectProtocol] = []

    init(store: SyncStore) {
        let center = NotificationCenter.default
        let usage = store.usage
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { await store.applicationDidBecomeActive() }
        })
        tokens.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { await usage.flush() }
        })
    }

    // No deinit: this object lives as long as the App does, and block-based
    // observers are removed automatically when their tokens deallocate.
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
