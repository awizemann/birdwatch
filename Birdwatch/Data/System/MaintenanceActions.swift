import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "maintenance")

nonisolated enum MaintenanceError: Error, Equatable {
    /// The action has no safe public command on macOS — deliberately unsupported.
    case notSupported(String)
    case unknownDaemon(String)
    /// No process owned by this user matched the daemon, so there is nothing to signal.
    case daemonNotRunning(String)
    /// A delete was asked for outside the three folders Birdwatch is willing to
    /// touch. Refused before any file operation happens.
    case pathNotAllowed(String)
    /// The command shells out to `sudo`, so it can only ever run in a terminal.
    /// Not a failure mode — a fact about the command, known before we try.
    case requiresTerminal(String)
}

/// Real maintenance commands behind the Diagnostics view, run via ProcessRunner
/// (timeouts, cancellation, pipe draining come from it). Actor-isolated so the
/// whole spawn/wait cycle happens off the MainActor.
///
/// Service labels were verified against `launchctl print gui/$UID` on this
/// machine: com.apple.bird, com.apple.cloudd, com.apple.FileProvider all exist.
///
/// RESTART MECHANISM (researched live on macOS 27, SIP enabled — 2026-08-15):
/// `launchctl kickstart -k gui/$UID/<label>` and `launchctl stop <label>` BOTH
/// fail with exit 150 "Operation not permitted while System Integrity
/// Protection is engaged" for all three daemons — SIP protects Apple's
/// LaunchAgents from unprivileged domain operations, and no user-visible
/// setting changes that. What DOES work unprivileged is a plain `SIGTERM` to
/// the process itself: the jobs are launchd-managed and relaunch immediately
/// (measured: a new pid within 500 ms for bird, cloudd and fileproviderd).
/// So the restart is `/bin/kill -TERM <pid>`, followed by a bounded poll for a
/// pid that differs from the one we signalled.
actor MaintenanceActions {
    private let runner = ProcessRunner()

    /// Daemon display name → launchd service label (verified live). Kept as the
    /// allow-list for restartable daemons and for the labels shown in the UI —
    /// the restart itself no longer goes through launchctl (see the type doc).
    static let serviceLabels: [String: String] = [
        "bird": "com.apple.bird",
        "cloudd": "com.apple.cloudd",
        "fileproviderd": "com.apple.FileProvider",
    ]

    /// How long we are willing to wait for launchd to bring the daemon back.
    ///
    /// 12s, not 5: `launchctl print gui/$UID/com.apple.bird` reports
    /// `minimum runtime = 10`, and launchd honours it — a daemon that has just
    /// been restarted is held down for the remainder of that window before it
    /// is relaunched. Measured on this Mac: a cold SIGTERM respawns in <0.5s,
    /// but a second restart soon after took ~7s, which a 5s poll reported as
    /// "respawn not observed" for a restart that had in fact worked.
    static let respawnWait: Duration = .seconds(12)
    private static let respawnPollInterval: Duration = .milliseconds(250)

    /// Returned when the signal landed but no replacement process appeared
    /// inside `respawnWait`. NOT a failure and NOT a success: `cloudd` in
    /// particular is launched on demand, so it legitimately stays down until
    /// something asks it for a CloudKit operation. The UI tints this outcome as
    /// a caution rather than claiming a restart we did not witness.
    static let respawnNotObserved = "Signal sent, respawn not observed"

    /// The command string shown in the UI and in the confirm sheet. It must be
    /// what we actually run — a stale `launchctl kickstart` line here is how the
    /// dead button shipped in the first place.
    static func restartCommand(name: String) -> String {
        "kill -TERM <pid of \(name)>"
    }

    /// Restarts a sync daemon by signalling it and letting launchd respawn it.
    ///
    /// Returns "Restarted (new pid N)" when a different pid is observed inside
    /// `respawnWait`, or "Signal sent, respawn not observed" when the poll
    /// expires — never a success claim we did not witness.
    func restartDaemon(name: String) async throws -> String {
        guard Self.serviceLabels[name] != nil else {
            throw MaintenanceError.unknownDaemon(name)
        }
        let before = await hostPIDs(name: name)
        guard !before.isEmpty else { throw MaintenanceError.daemonNotRunning(name) }

        for pid in before {
            _ = try await runner.run(toolPath: "/bin/kill", arguments: ["-TERM", String(pid)])
        }
        logger.info("Signalled \(name, privacy: .public) pid(s) \(before.map(String.init).joined(separator: ","), privacy: .public) with SIGTERM")

        let deadline = ContinuousClock.now + Self.respawnWait
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.respawnPollInterval)
            let after = await hostPIDs(name: name)
            if let fresh = after.first(where: { !before.contains($0) }) {
                return "Restarted (new pid \(fresh))"
            }
        }
        logger.warning("\(name, privacy: .public) did not respawn within the poll window")
        return Self.respawnNotObserved
    }

    /// pids of the REAL system daemon owned by this user. Reuses
    /// `DaemonStatsSource.psArguments`-shaped output with a uid column so a
    /// root-owned instance (there is a `cloudd --system` running as uid 0) is
    /// never signalled — we would only earn an EPERM.
    private func hostPIDs(name: String) async -> [Int32] {
        let output = (try? await runner.run(
            toolPath: "/bin/ps", arguments: ["-axo", "pid,uid,comm"]
        )) ?? ""
        return Self.hostPIDs(name: name, psOutput: output, uid: getuid())
    }

    /// Pure parse of `ps -axo pid,uid,comm`. Internal so the filtering rule —
    /// the part that decides which process gets a SIGTERM — is unit-testable
    /// without spawning anything.
    ///
    /// Three filters, each load-bearing:
    /// 1. `/System/Library/` prefix — iOS Simulator runtimes under
    ///    `/Library/Developer/CoreSimulator` ship the same basenames.
    /// 2. exact basename match.
    /// 3. uid == ours — the root `cloudd --system` is not ours to restart.
    nonisolated static func hostPIDs(name: String, psOutput: String, uid: uid_t) -> [Int32] {
        var out: [Int32] = []
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let owner = UInt32(fields[1]) else { continue }
            guard owner == uid else { continue }
            let path = String(fields[2])
            guard path.hasPrefix("/System/Library/") else { continue }
            guard (path as NSString).lastPathComponent == name else { continue }
            out.append(pid)
        }
        return out.sorted()
    }

    /// The command the UI tells the user to paste into Terminal.
    static let diagnoseCommand = "brctl diagnose --no-reveal"

    /// `brctl diagnose` CANNOT run from a GUI process, ever.
    ///
    /// It shells out to `sudo` internally, and a process with no controlling
    /// terminal has nowhere to prompt for the password. Measured live in the
    /// dev app (2026-08-15) — the Run button failed every time with:
    ///
    ///     exit 1 — sudo: a terminal is required to read the password;
    ///     either use the -S option to read from standard input or configure an
    ///     askpass helper
    ///
    /// So there is no button. The Diagnostics card shows the command with Copy
    /// and Open Terminal instead. This throw is kept (rather than deleting the
    /// method) so any future caller finds out at the call site rather than by
    /// shipping the dead button again.
    func runDiagnose() throws -> Never {
        throw MaintenanceError.requiresTerminal(Self.diagnoseCommand)
    }

    /// No safe public command exists — deliberately unsupported (see decisions).
    func reindexMetadata() throws -> Never {
        throw MaintenanceError.notSupported("Metadata re-indexing has no safe public command")
    }

    /// No safe public command exists — deliberately unsupported (see decisions).
    func resetCloudDocs() throws -> Never {
        throw MaintenanceError.notSupported("Destructive CloudDocs resets are deliberately not offered")
    }

}

// MARK: - Trash

/// The ONLY delete Birdwatch performs. Two rules, both non-negotiable:
///
/// 1. **Move to Trash, never remove.** `FileManager.trashItem(at:resultingItemURL:)`
///    only. `removeItem` is a physical delete of a user's file and has no place
///    in a monitoring app — every delete here must be recoverable from Finder.
/// 2. **Whitelisted roots only.** The path must be strictly inside
///    `~/Library/Mobile Documents`, `~/Desktop` or `~/Documents`. Anything else
///    — including the roots themselves — is refused before any file operation.
///    The retry queue's paths come from our own pattern matching against bird's
///    redacted output, so "we resolved it" is never on its own a licence to
///    delete it.
nonisolated enum FileTrasher {

    /// Trailing-slash-free absolute roots, resolved through symlinks so the
    /// containment test compares like with like.
    static func allowedRoots(home: String = NSHomeDirectory()) -> [String] {
        ["Library/Mobile Documents", "Desktop", "Documents"].map {
            URL(fileURLWithPath: home).appending(path: $0).standardizedFileURL
                .resolvingSymlinksInPath().path
        }
    }

    /// Is `path` strictly under one of the allowed roots?
    ///
    /// Checked on BOTH the `..`-collapsed path and its symlink-resolved form:
    /// a symlink inside iCloud Drive pointing at `~/.ssh` must not become a
    /// licence to trash `~/.ssh`, and a `..` escape must not survive either.
    /// Equality with a root is refused too — nobody trashes iCloud Drive itself.
    static func isAllowed(path: String, home: String = NSHomeDirectory()) -> Bool {
        let roots = allowedRoots(home: home)
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        func inside(_ candidate: String) -> Bool {
            roots.contains { candidate != $0 && candidate.hasPrefix($0 + "/") }
        }
        return inside(standardized) && inside(resolved)
    }

    /// Is `path` an app's ubiquity document root — `~/Library/Mobile
    /// Documents/<container>/Documents`?
    ///
    /// macOS REFUSES to move one of these to the Trash, and every single row
    /// bird offers in the retry queue is one. Measured live in the dev app
    /// (2026-08-15), pressing the button on
    /// `~/Library/Mobile Documents/iCloud~com~explaineverything~explaineverything/Documents`:
    ///
    ///     trashItem failed: NSCocoaErrorDomain 3328   (NSFeatureUnsupportedError)
    ///     “Explain Every…” couldn’t be moved to the trash because the volume
    ///     “New Mac HD” doesn’t have one.
    ///
    /// It is the REGISTERED ROOT that is refused, not the location: a plain
    /// directory one level over — `~/Library/Mobile Documents/<container>/x` —
    /// trashes fine and lands in `~/Library/Mobile Documents/.Trash/x`
    /// (verified with the real `FileManager.trashItem` on this Mac the same
    /// day). NSWorkspace.recycle does not rescue it either; Finder never
    /// answered and the folder stayed put.
    ///
    /// So the button is not offered for these. Dead buttons don't ship.
    static func isUbiquityDocumentRoot(path: String, home: String = NSHomeDirectory()) -> Bool {
        let mobileDocuments = URL(fileURLWithPath: home)
            .appending(path: "Library/Mobile Documents").standardizedFileURL.path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "Documents" else { return false }
        // Exactly one component between Mobile Documents and Documents — the
        // container. Anything deeper is an ordinary folder inside the container.
        return url.deletingLastPathComponent().deletingLastPathComponent().path == mobileDocuments
    }

    /// Moves `path` to the Trash after the whitelist check, and returns WHERE
    /// it landed (abbreviated), or "" when macOS did not tell us.
    ///
    /// The destination is worth returning because it is not the one people
    /// assume. Measured live on this Mac (2026-08-15): trashing
    /// `~/Library/Mobile Documents/<container>/<dir>` succeeds and the item
    /// lands in `~/Library/Mobile Documents/.Trash/<name>` — iCloud Drive's own
    /// trash, on its own volume — not `~/.Trash`.
    ///
    /// `trasher` is injected so tests can prove the whitelist and the call
    /// wiring without depending on a Trash-capable volume: the sandboxed test
    /// temp directory is not always on the same volume as `~/.Trash`, and
    /// `trashItem` is documented to fail there. The refusal test uses the real
    /// FileManager trasher and asserts the file is still on disk.
    static func trash(
        path: String,
        home: String = NSHomeDirectory(),
        trasher: (URL) throws -> URL? = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
    ) throws -> String {
        guard isAllowed(path: path, home: home) else {
            logger.error("Refused to trash a path outside the allowed roots: \(path, privacy: .private)")
            throw MaintenanceError.pathNotAllowed(RedactedPathResolver.abbreviate(path))
        }
        let landed: URL?
        do {
            landed = try trasher(URL(fileURLWithPath: path))
        } catch {
            let ns = error as NSError
            // Domain + code are not user data, so they are logged publicly on
            // purpose: the previous `<private>` line made a real, reproducible
            // failure (NSCocoaErrorDomain 4 on a file-provider container root)
            // impossible to diagnose from the log.
            logger.error("trashItem failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) for \(path, privacy: .private)")
            throw error
        }
        logger.info("Moved an item to the Trash: \(path, privacy: .private) → \(landed?.path ?? "unknown", privacy: .private)")
        return landed.map { RedactedPathResolver.abbreviate($0.path) } ?? ""
    }

    /// A short, plain-English reason a move to the Trash did not happen.
    ///
    /// Written for someone looking at a row that did not disappear, so it says
    /// what macOS refused rather than quoting an NSError. The `NSFileNoSuchFile`
    /// case is the one that actually fires here: every retry row bird offers is
    /// an app container's `Documents` folder, which the CloudDocs file provider
    /// synthesises (mtime 0) — iCloud lists it, but there is no real directory
    /// on this disk for macOS to move.
    nonisolated static func plainReason(for error: Error) -> String {
        if case MaintenanceError.pathNotAllowed = error {
            return "it is outside the folders Birdwatch is allowed to touch"
        }
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else {
            return ns.localizedDescription
        }
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileWriteInvalidFileNameError:
            return "macOS found nothing to move — iCloud lists this folder, but it has no real directory on this disk"
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return "macOS did not permit it"
        case NSFeatureUnsupportedError:
            // 3328, worded by macOS as "the volume … doesn't have one". What it
            // means for the user is that this particular folder is one iCloud
            // manages, and nothing can move it — not Birdwatch, not Finder.
            return "macOS will not move it — iCloud owns this folder and it has no Trash to move it to"
        case NSFileWriteVolumeReadOnlyError:
            return "the folder it lives in is read-only"
        case NSFileWriteOutOfSpaceError:
            return "the disk is out of space"
        default:
            return ns.localizedDescription
        }
    }
}
