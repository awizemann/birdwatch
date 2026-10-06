import Foundation

/// When the FSEvents transfer watcher (UbiquityTransferSource) should run.
/// It runs only while monitoring is on AND a surface that shows transfers
/// (the main window or the menu-bar popover) is on screen. Pure, so each
/// rule is testable without a window.
nonisolated enum TransferWatchPolicy {

    /// A transfer surface appeared: resume the watcher unless monitoring is
    /// paused (resuming then would run it under a "paused" UI).
    static func shouldResumeOnAppear(monitoringPaused: Bool) -> Bool {
        !monitoringPaused
    }

    /// Whether the watcher should be running right now: monitoring on and a
    /// surface on screen. A minimised (or fully covered) main window is not
    /// on screen; restoring it re-applies this. With nothing on screen —
    /// ⇧⌘P from the menu after closing the window — the next surface to
    /// appear resumes it.
    static func shouldWatch(monitoringPaused: Bool, mainWindowOnScreen: Bool, popoverOpen: Bool) -> Bool {
        !monitoringPaused && (mainWindowOnScreen || popoverOpen)
    }

    /// SwiftUI uses the scene id as the NSWindow identifier: the
    /// `Window("Birdwatch", id: "main")` window is identified "main"
    /// (verified on macOS 27.0, 2026-10-05).
    static let mainWindowIdentifier = "main"

    /// Is this window the main monitor window, on screen? Matched by
    /// identifier, not by "visible and not an NSPanel": the menu-bar status
    /// item lives in its own visible, non-panel NSStatusBarWindow, so that
    /// test was true even with the main window closed (verified live: windows
    /// were `AppKitWindow|main|not visible` and `NSStatusBarWindow|visible`)
    /// and closing the popover never paused the watcher.
    static func isMainWindow(identifier: String?, isVisible: Bool, isPanel: Bool) -> Bool {
        isVisible && !isPanel && identifier == mainWindowIdentifier
    }
}
