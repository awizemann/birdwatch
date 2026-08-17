import AppKit
import Foundation
import os
import UserNotifications

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "PermissionsProbe")

enum PermissionsProbe {

    /// Full Disk Access probe: attempt to actually open an FDA-protected file.
    ///
    /// Probe choice: ~/Library/Safari/CloudTabs.db — readable only with FDA on
    /// every macOS since 10.14, exists on effectively all user accounts, and
    /// lives in the user's home (no root privileges confound). Fallback probe:
    /// the system TCC.db.
    ///
    /// Caveats:
    /// - False positive: none known — a successful open of either file requires FDA.
    /// - False negative: if BOTH files are absent (fresh account that never
    ///   launched Safari on a system layout that moved TCC.db), we report false
    ///   even when FDA is granted. Acceptable: the UI then prompts the user to
    ///   grant something they may already have, which is harmless.
    /// - isReadableFile alone is insufficient (TCC denial happens at open time),
    ///   so we open a file handle for the real answer.
    @concurrent
    static func fullDiskAccessGranted() async -> Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Safari/CloudTabs.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in probes {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if !FileManager.default.isReadableFile(atPath: path) { return false }
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                try handle.close()
                return true
            } catch {
                logger.info("FDA probe denied at \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        logger.warning("no FDA probe file present; reporting not granted")
        return false
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            logger.error("failed to build Full Disk Access settings URL")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Notification authorization, time-boxed at 1.5s: getNotificationSettings
    /// talks to usernoted over XPC and can hang if the daemon is wedged.
    static func notificationsPermission() async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
            group.addTask {
                // Hang guard only — the API answers in ms when healthy, and this
                // race gates the FIRST data paint (cold permissions cache).
                try? await Task.sleep(for: .seconds(1.5))
                return nil
            }
            defer { group.cancelAll() }
            if let first = await group.next(), let granted = first {
                return granted
            }
            logger.warning("notification settings query timed out after 1.5s")
            return false
        }
    }

    /// Snapshot of all permission rows for the diagnostics panel.
    static func currentPermissions() async -> [PermissionStatus] {
        async let fda = fullDiskAccessGranted()
        async let notifications = notificationsPermission()
        return [
            PermissionStatus(name: "Full Disk Access", granted: await fda),
            PermissionStatus(name: "Notifications", granted: await notifications),
        ]
    }
}
