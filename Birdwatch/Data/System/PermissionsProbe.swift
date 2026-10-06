import AppKit
import Foundation
import os
import UserNotifications

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "PermissionsProbe")

enum PermissionsProbe {

    /// A file only Full Disk Access unlocks. `label` is a fixed, user-free name
    /// that is safe to log publicly; `path` may contain the home directory.
    nonisolated struct FDAProbeFile: Equatable, Sendable {
        let label: String
        let path: String
    }

    nonisolated enum FDAProbeOutcome: Equatable, Sendable {
        /// An open succeeded on this probe file (its label).
        case granted(String)
        /// At least one probe file exists and every open was refused.
        case denied
        /// No probe file exists, so the probe cannot tell.
        case noProbeFile
    }

    /// Probe files, in order. Each is protected by Full Disk Access alone —
    /// Safari, Messages and TCC data are not covered by any narrower TCC
    /// service — so a successful open proves FDA.
    ///
    /// - ~/Library/Safari/CloudTabs.db: the classic probe (macOS 15–26).
    /// - ~/Library/Safari/Bookmarks.plist and History.db: still live in the
    ///   legacy folder on macOS 27 (only CloudTabs.db moved into Safari's
    ///   container) and present for anyone who has opened Safari.
    /// - ~/Library/Messages/chat.db: accounts that use Messages.
    /// - The system TCC.db, LAST: the one probe file present on every Mac.
    ///   macOS 27's release notes say apps can no longer access it directly,
    ///   but on 27.0 (26A428) a process with FDA still opens it read-only. If a
    ///   later build closes it, an account with none of the other files reads
    ///   as not granted — the onboarding escape hatch covers that.
    ///
    /// Deliberately NOT probed: Safari's macOS 27 container copy of
    /// CloudTabs.db. That container carries a data-container personality, and
    /// macOS 14+ app-data protection may answer a process without FDA with an
    /// "access data from other apps" prompt — raised every 2 s by onboarding,
    /// and a false grant if the user allows it. Without FDA every probe file
    /// is tried, so ordering cannot avoid that; the files above already cover
    /// a typical account.
    nonisolated static func fdaProbeFiles(home: String = NSHomeDirectory()) -> [FDAProbeFile] {
        [
            FDAProbeFile(label: "safari-cloudtabs", path: home + "/Library/Safari/CloudTabs.db"),
            FDAProbeFile(label: "safari-bookmarks", path: home + "/Library/Safari/Bookmarks.plist"),
            FDAProbeFile(label: "safari-history", path: home + "/Library/Safari/History.db"),
            FDAProbeFile(label: "messages-chat", path: home + "/Library/Messages/chat.db"),
            FDAProbeFile(label: "system-tcc-db", path: "/Library/Application Support/com.apple.TCC/TCC.db"),
        ]
    }

    /// Pure decision step: granted as soon as ANY present probe file opens.
    /// One refusal does not end the search — a file can fail to open for its
    /// own reasons (moved, re-protected by a newer OS), and every candidate is
    /// FDA-only, so one success is proof while one failure is not.
    nonisolated static func evaluateFullDiskAccess(
        _ files: [FDAProbeFile],
        exists: (String) -> Bool,
        open: (String) throws -> Void
    ) -> FDAProbeOutcome {
        var sawFile = false
        for file in files {
            guard exists(file.path) else { continue }
            sawFile = true
            do {
                try open(file.path)
                return .granted(file.label)
            } catch {
                // Domain and code only in public: localizedDescription names
                // the file ("…the file “chat.db” in the folder “Messages”").
                let nsError = error as NSError
                logger.info("FDA probe \(file.label, privacy: .public) refused (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)) at \(file.path, privacy: .private): \(nsError.localizedDescription, privacy: .private)")
            }
        }
        return sawFile ? .denied : .noProbeFile
    }

    /// Maps the probe's answer onto what the UI may claim (C1): no probe file
    /// means "can't tell", never "not granted".
    nonisolated static func state(for outcome: FDAProbeOutcome) -> PermissionState {
        switch outcome {
        case .granted: .granted
        case .denied: .denied
        case .noProbeFile: .unknown
        }
    }

    /// Full Disk Access probe: actually open an FDA-protected file.
    /// `isReadableFile` is not enough — TCC denies at open time — so each
    /// present probe file gets a real FileHandle open (no bytes are read).
    ///
    /// Caveats:
    /// - False positive: none known — every probe file is FDA-only.
    /// - `.unknown`: no probe file exists at all (not expected while TCC.db is
    ///   on disk).
    /// - False negative: a future macOS that moves or re-protects every probe
    ///   file reports `.denied` with FDA on. Onboarding therefore lets the user
    ///   continue without it, and Diagnostics keeps showing this answer.
    @concurrent
    static func fullDiskAccessState() async -> PermissionState {
        let outcome = evaluateFullDiskAccess(
            fdaProbeFiles(),
            exists: { FileManager.default.fileExists(atPath: $0) },
            open: { try FileHandle(forReadingFrom: URL(fileURLWithPath: $0)).close() }
        )
        switch outcome {
        case .granted(let label):
            logger.info("FDA probe granted via \(label, privacy: .public)")
        case .denied:
            logger.info("FDA probe: every present probe file was refused; reporting not granted")
        case .noProbeFile:
            logger.warning("no FDA probe file present; reporting unknown")
        }
        return state(for: outcome)
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            logger.error("failed to build Full Disk Access settings URL")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Notification authorization, time-boxed at 1.5s: getNotificationSettings
    /// talks to usernoted over XPC and can hang if the daemon is wedged. This
    /// gates the FIRST data paint (cold permissions cache), so the deadline has
    /// to return on time — Deadline abandons a hung query instead of waiting
    /// it out. A timeout is `.unknown`, not "not granted".
    /// `isAuthorized` is injectable so a test can stand in a hung usernoted.
    static func notificationsPermission(
        timeout: Double = 1.5,
        isAuthorized: @escaping @Sendable () async -> Bool = systemNotificationsAuthorized
    ) async -> PermissionState {
        guard let granted = await Deadline.run(seconds: timeout, isAuthorized) else {
            logger.warning("notification settings query timed out after \(timeout, privacy: .public)s; reporting unknown")
            return .unknown
        }
        return granted ? .granted : .denied
    }

    nonisolated static func systemNotificationsAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Snapshot of all permission rows for the diagnostics panel.
    static func currentPermissions() async -> [PermissionStatus] {
        async let fda = fullDiskAccessState()
        async let notifications = notificationsPermission()
        return [
            PermissionStatus(name: "Full Disk Access", state: await fda),
            PermissionStatus(name: "Notifications", state: await notifications),
        ]
    }
}
