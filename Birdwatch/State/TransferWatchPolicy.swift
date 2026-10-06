import Foundation

/// When the FSEvents transfer watcher (UbiquityTransferSource) should run.
/// It runs only while monitoring is on AND a surface that shows transfers
/// (the main window or the menu-bar popover) is on screen. Pure, so each
/// rule is testable without a window.
nonisolated enum TransferWatchPolicy {

    /// Whether the watcher should be running right now: monitoring on and a
    /// surface on screen. A minimised (or fully covered) main window is not
    /// on screen; restoring it re-applies this. With nothing on screen —
    /// ⇧⌘P from the menu after closing the window — the next surface to
    /// appear resumes it.
    static func shouldWatch(monitoringPaused: Bool, mainWindowOnScreen: Bool, popoverOpen: Bool) -> Bool {
        !monitoringPaused && (mainWindowOnScreen || popoverOpen)
    }

    /// Whether Birdwatch may read ~/Desktop and ~/Documents at all — the
    /// transfer watcher's roots, the local size walk and the Storage
    /// breakdown walk all follow this one rule. Only when the sync feature is
    /// on AND Full Disk Access is confirmed: without FDA, touching those
    /// folders raises a surprise TCC prompt ("Birdwatch would like to access
    /// files in your Desktop folder"). `.unknown` FDA (not probed yet, or
    /// the probe couldn't tell) counts as not granted. The permissions probe
    /// re-runs on its TTL, so a later grant starts them on that cycle.
    static func readsDesktopDocuments(featureOn: Bool, fullDiskAccess: PermissionState?) -> Bool {
        featureOn && fullDiskAccess == .granted
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
