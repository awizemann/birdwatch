import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "clouddocs")

/// Why a `brctl` read produced nothing — kept so the UI can say what actually
/// happened (a timeout is not a missing permission, C1).
nonisolated enum BrctlReadFailure: Error, Sendable, Equatable {
    case timedOut(seconds: Int)
    case failed(String)

    init(_ error: Error, timeout: Duration) {
        switch error as? RunnerError {
        case .timeout: self = .timedOut(seconds: Int(timeout.components.seconds))
        case .launchFailed: self = .failed("could not be launched")
        case .nonZeroExit(let code, _): self = .failed("exited with status \(code)")
        // A partial status/dump is not parsed: its missing tail is exactly
        // where the container line or Desktop & Documents flag may sit.
        case .outputTruncated: self = .failed("output exceeded the capture limit")
        case nil: self = .failed("failed")
        }
    }

    /// Completes "brctl dump …" / "the latest read …".
    var summary: String {
        switch self {
        case .timedOut(let seconds): "timed out after \(seconds) s"
        case .failed(let reason): reason
        }
    }
}

/// Runs `brctl` and parses its output. Actor-isolated on purpose: callers
/// (SyncStore on the MainActor) hop here, so spawn+parse never touch main.
/// Failures (iCloud offline, missing Full Disk Access, format drift) degrade
/// to a typed failure — logged, never fatal.
actor CloudDocsSource {
    private let runner: any ProcessRunning

    init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }
    private static let brctlPath = "/usr/bin/brctl"
    /// `brctl status` blocks 15–28 s while bird is busy (measured 17–28 s even
    /// idle on the macOS 27 GA reference Mac). Killing it early does NOT free
    /// bird: the request keeps running daemon-side and a `brctl dump -i`
    /// issued next queues behind it (measured 18 s after a 10 s kill). So it
    /// gets enough time to finish, and it only ever runs from the background
    /// dump refresh, never the snapshot path.
    static let statusTimeout: Duration = .seconds(45)

    func status() async -> Result<BrctlStatus, BrctlReadFailure> {
        let started = ContinuousClock.now
        do {
            let out = try await runner.run(
                toolPath: Self.brctlPath,
                arguments: ["status", "com.apple.CloudDocs"],
                timeout: Self.statusTimeout
            )
            let status = BrctlParser.parseStatus(out)
            let seconds = (ContinuousClock.now - started).components.seconds
            logger.info("brctl status read in \(seconds, privacy: .public)s; Desktop & Documents synced: \(SystemSyncSource.desktopDocumentsSynced(status), privacy: .public)")
            return .success(status)
        } catch {
            logger.warning("brctl status failed: \(RunnerError.publicSummary(of: error), privacy: .public) \(RunnerError.privateDetail(of: error), privacy: .private)")
            return .failure(BrctlReadFailure(error, timeout: Self.statusTimeout))
        }
    }

    func quotaRemaining() async -> Int64? {
        do {
            let out = try await runner.run(toolPath: Self.brctlPath, arguments: ["quota"], timeout: .seconds(10))
            guard let bytes = BrctlParser.parseQuota(out) else {
                logger.warning("brctl quota output did not match expected format")
                return nil
            }
            return bytes
        } catch {
            logger.warning("brctl quota failed: \(RunnerError.publicSummary(of: error), privacy: .public) \(RunnerError.privateDetail(of: error), privacy: .private)")
            return nil
        }
    }
}

/// The last `brctl status` read and what it still lets us say. `brctl status`
/// is the ONLY source of the Desktop & Documents flag (`brctl dump -i` does
/// not print it — verified on macOS 27 GA), so a failed read keeps the last
/// good answer and says it is last-known rather than flipping the feature
/// off (which hid the row and re-armed the FSEvents watcher every cycle).
nonisolated struct CloudDocsStatusCache: Sendable, Equatable {
    /// The toggle rarely changes, and every read costs bird 15–28 s.
    static let refreshInterval: TimeInterval = 300

    private(set) var lastGood: BrctlStatus?
    private(set) var lastGoodAt: Date?
    private(set) var lastFailure: BrctlReadFailure?
    private(set) var lastAttempt: Date?

    /// Gated on the last ATTEMPT, so a failing brctl backs off too.
    func isDue(now: Date) -> Bool {
        lastAttempt.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
    }

    mutating func markAttempt(at now: Date) { lastAttempt = now }

    mutating func record(_ result: Result<BrctlStatus, BrctlReadFailure>, at now: Date) {
        switch result {
        case .success(let status):
            lastGood = status
            lastGoodAt = now
            lastFailure = nil
        case .failure(let failure):
            lastFailure = failure                 // lastGood survives: last-known
        }
    }

    /// What can honestly be said about the Desktop & Documents feature.
    func desktopDocuments(now: Date) -> DesktopDocumentsFlag {
        guard let lastGood, let at = lastGoodAt else {
            guard let lastFailure else {
                return .unknown("not read yet — brctl status runs in the background after the first brctl dump and takes 15–30 s")
            }
            return .unknown("brctl status \(lastFailure.summary), so it could not be read")
        }
        let note = lastFailure.map {
            "Last-known setting, confirmed by brctl status \(SystemSyncSource.ageText(now.timeIntervalSince(at))); the latest read \($0.summary)."
        }
        return SystemSyncSource.desktopDocumentsSynced(lastGood) ? .on(lastKnown: note) : .off(lastKnown: note)
    }

    /// Only a confirmed ON touches ~/Desktop and ~/Documents (and earns a TCC
    /// prompt); unknown and off both leave them alone. A failed read keeps
    /// the last good answer, so the watcher does not flap.
    var desktopDocumentsSynced: Bool {
        if case .on = desktopDocuments(now: Date()) { return true }
        return false
    }
}

/// Desktop & Documents is tri-state: until `brctl status` has answered, it is
/// UNKNOWN — never shown as off (C1). `lastKnown` is set when the latest read
/// failed and the answer is the previous good one.
nonisolated enum DesktopDocumentsFlag: Sendable, Equatable {
    case unknown(String)
    case on(lastKnown: String?)
    case off(lastKnown: String?)
}
