import AppKit
import SwiftUI

/// Tracks whether the hosting window is actually on screen. Occluded (fully
/// covered) or miniaturized windows render nothing, so the 15s monitor loop
/// must not spawn five processes per tick for pixels nobody sees.
@Observable
final class WindowVisibility {
    var isVisible = true
}

/// Zero-size accessor that finds the hosting NSWindow and mirrors its
/// occlusion/miniaturization state into `visibility`.
private struct WindowVisibilityReader: NSViewRepresentable {
    let visibility: WindowVisibility

    final class Coordinator {
        var tokens: [NSObjectProtocol] = []
        var attachedTo: NSWindow?

        func refresh(_ visibility: WindowVisibility) {
            guard let window = attachedTo else { return }
            visibility.isVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        }

        func removeObservers() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.removeObservers() }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window isn't attached during makeNSView; defer one runloop turn.
        DispatchQueue.main.async { attach(to: view.window, context: context) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(to: nsView.window, context: context)
    }

    private func attach(to window: NSWindow?, context: Context) {
        guard let window, context.coordinator.attachedTo !== window else { return }
        let coordinator = context.coordinator
        coordinator.removeObservers()
        coordinator.attachedTo = window

        let names: [NSNotification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [visibility] _ in
                MainActor.assumeIsolated { coordinator.refresh(visibility) }
            }
            coordinator.tokens.append(token)
        }
        coordinator.refresh(visibility)
    }
}

struct RootView: View {
    @Environment(SyncStore.self) private var store
    @AppStorage("bw_setup_complete") private var setupComplete = false
    @State private var visibility = WindowVisibility()

    var body: some View {
        if !setupComplete {
            OnboardingView(isComplete: $setupComplete)
        } else {
            mainWindow
        }
    }

    private var mainWindow: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(224)
        } detail: {
            ContentRouterView()
        }
        .toolbar { MainToolbar() }
        .background(WindowVisibilityReader(visibility: visibility))
        .task {
            // Live monitor cadence: 15s while the window exists. Cancelled with
            // the window; the menu-bar popover falls back to debounced loads.
            await store.refresh(force: true)
            var skipNextTick = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                // Occluded/miniaturized: keep ticking (cheap) but do no work.
                // didBecomeActive covers the catch-up when the window returns.
                guard visibility.isVisible else { continue }
                // Skip, don't queue: if the previous refresh ate the whole
                // interval, drop this tick rather than stacking a burst.
                if skipNextTick {
                    skipNextTick = false
                    continue
                }
                let started = ContinuousClock.now
                await store.refresh(force: true)
                skipNextTick = started.duration(to: .now) >= .seconds(15)
            }
        }
        .onAppear {
            NotificationCenter.default.post(name: UbiquityTransferSource.resumeRequest, object: nil)
        }
        .onDisappear {
            // Window closed: retire the FSEvents watcher + probe ticker (they
            // otherwise run forever with only the menu-bar extra left).
            NotificationCenter.default.post(name: UbiquityTransferSource.pauseRequest, object: nil)
        }
        // Activation-driven refresh; the store's 60s debounce is the throttle,
        // so app-switcher peeks stay cheap (§6).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
    }
}

/// What the main pane is showing. Extracted from the view so the one decision
/// that can lie — showing a spinner while monitoring is paused, which claims
/// work that is not happening (C1) — is unit-testable rather than only
/// observable by eye.
enum ContentRoute: Equatable {
    /// Paused before anything ever loaded: nothing is in flight and nothing
    /// will be until monitoring resumes. MUST NOT render a spinner.
    case pausedBeforeFirstLoad
    case loading
    case conflict(String)
    case app(String)
    case view(MonitorView)

    init(store: SyncStore) {
        // Order matters: paused-before-first-load is also `!hasLoaded`, and
        // testing `hasLoaded` first is exactly the bug this type prevents.
        if store.isPausedBeforeFirstLoad {
            self = .pausedBeforeFirstLoad
        } else if !store.hasLoaded {
            self = .loading
        } else if let issueID = store.conflictIssueID {
            self = .conflict(issueID)
        } else if let appID = store.detailAppID {
            self = .app(appID)
        } else {
            self = .view(store.selectedView)
        }
    }

    /// Equatable key the 0.25s fade/6px pop animates on.
    var key: String {
        switch self {
        case .pausedBeforeFirstLoad: "paused"
        case .loading: "loading"
        case .conflict(let id): "conflict-\(id)"
        case .app(let id): "app-\(id)"
        case .view(let view): "view-\(view.rawValue)"
        }
    }

    /// The spinner is honest ONLY here.
    var showsSpinner: Bool { self == .loading }
}

/// Routes the selected sidebar destination, app detail, and conflict screen.
struct ContentRouterView: View {
    @Environment(SyncStore.self) private var store

    private var route: ContentRoute { ContentRoute(store: store) }

    var body: some View {
        Group {
            if route == .pausedBeforeFirstLoad {
                MonitoringPausedState()
            } else if route.showsSpinner {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading iCloud sync state")
            } else if let issueID = store.conflictIssueID {
                ConflictResolutionView(issueID: issueID)
            } else if let appID = store.detailAppID {
                AppDetailView(appID: appID)
            } else {
                switch store.selectedView {
                case .overview: OverviewView()
                case .applications: ApplicationsView()
                case .drive: DriveView()
                case .devices: DevicesView()
                case .issues: IssuesView()
                case .activity: ActivityView()
                case .diagnostics: DiagnosticsView()
                case .bandwidth: BandwidthView()
                case .storage: StorageView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: route.key)
    }
}
