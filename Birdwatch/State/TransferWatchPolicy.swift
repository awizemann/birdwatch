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

    /// What Birdwatch may touch in iCloud Drive, decided from the Full Disk
    /// Access probe. This is THE decision: every iCloud Drive reader in
    /// SystemSyncSource (brctl, the transfer watcher, the folder, container,
    /// conflict, size and breakdown walks, the redacted-path walk), the main
    /// window's blocking screen and onboarding's "Enter Birdwatch" all follow
    /// it, and `readsDesktopDocuments` narrows it further.
    ///
    /// Why it exists (macOS 27): an app WITHOUT Full Disk Access that reads
    /// ~/Library/Mobile Documents — or has bird serve brctl for it — raises
    /// tccd's iCloud Drive (FileProviderDomain) prompt, and the read stalls
    /// until someone answers it (3.5 min observed). Full Disk Access is
    /// therefore required (Alan, 2026-10-06).
    ///
    /// - nil (not probed yet) → `.notProbed`: touch nothing until it answers.
    /// - `.granted` → read.
    /// - `.denied` → touch nothing.
    /// - `.unknown` → `.unconfirmed`: read, and say macOS may ask. The probe
    ///   answers unknown only when NONE of its probe files exists (a fresh
    ///   account on a Mac without TCC.db on disk), so it can never confirm a
    ///   grant there. Gating on it would lock that person out for good,
    ///   whatever they grant; letting them in with the warning costs at
    ///   worst the prompt this gate exists to avoid, which they were told
    ///   to expect.
    static func iCloudDriveAccess(fullDiskAccess: PermissionState?) -> ICloudDriveAccess {
        switch fullDiskAccess {
        case nil: .notProbed
        case .granted: .granted
        case .denied: .denied
        case .unknown: .unconfirmed
        }
    }

    /// Whether Birdwatch may read ~/Desktop and ~/Documents at all — the
    /// transfer watcher's roots, the local size walk and the Storage
    /// breakdown walk all follow this one rule. Only when the sync feature is
    /// on AND Full Disk Access is confirmed: without FDA, touching those
    /// folders raises a surprise TCC prompt ("Birdwatch would like to access
    /// files in your Desktop folder"). Unlike iCloud Drive, an unconfirmed
    /// grant does NOT open these (Alan's earlier rule: no Desktop/Documents
    /// prompt without a confirmed grant). The permissions probe re-runs on
    /// its TTL, so a later grant starts them on that cycle.
    static func readsDesktopDocuments(featureOn: Bool, fullDiskAccess: PermissionState?) -> Bool {
        featureOn && iCloudDriveAccess(fullDiskAccess: fullDiskAccess) == .granted
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

/// The outcome of `TransferWatchPolicy.iCloudDriveAccess(fullDiskAccess:)`.
nonisolated enum ICloudDriveAccess: Sendable, Equatable {
    /// The Full Disk Access probe has not answered yet.
    case notProbed
    /// Full Disk Access is confirmed.
    case granted
    /// The probe cannot tell (no probe file on this Mac). Reads go ahead;
    /// the person was told macOS may ask first.
    case unconfirmed
    /// Full Disk Access is not granted.
    case denied

    /// Whether anything may read iCloud Drive (brctl included).
    var readsICloudDrive: Bool { self == .granted || self == .unconfirmed }

    /// Setup is complete but access is gone: the main window shows the Full
    /// Disk Access screen instead of data it may no longer read. Not while
    /// the probe is still out — that is the ordinary first-load state.
    var blocksMainWindow: Bool { self == .denied }
}
