import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "single-flight-scan")

/// Runs blocking work on a GCD queue and suspends (never blocks) the caller
/// until it finishes. Use it for every blocking FileManager walk: a hung File
/// Provider read then holds a GCD thread, never one of the few
/// cooperative-pool threads that every Task — including `Task.sleep` and so
/// every deadline in the app — depends on.
nonisolated enum BlockingWork {
    static func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// A blocking filesystem scan, time-boxed on the snapshot path without ever
/// tying up Swift's cooperative thread pool.
///
/// Rules, each fixing a real failure:
/// - **Own serial queue** (via `BlockingWork`). Abandoned pool-thread scans
///   used to pile up every refresh until `Task.sleep` itself could not
///   resume, so no deadline in the app fired.
/// - **Single flight.** A refresh while a scan is still running waits on that
///   scan instead of starting another, so at most one is ever in flight.
/// - **Late results are kept.** A scan that finishes after the deadline still
///   lands in `latest`, so the next cycle serves it — a scan that always takes
///   longer than the deadline no longer shows empty forever.
/// - **One waiter per hung scan.** Once a scan misses a deadline it is
///   *overdue*: later calls return `latest` at once instead of each parking
///   another waiter on it (one leaked Task per refresh, for as long as the
///   mount stays hung). Overdue is logged once per scan and reported to the
///   caller with the result's age.
actor SingleFlightScan<Value: Sendable> {

    /// What a caller gets back: the value plus how fresh it is, so stale data
    /// can be labelled rather than passed off as current (C1).
    struct Reading: Sendable {
        /// nil only before any scan has ever finished.
        let value: Value?
        /// When `value`'s scan finished; nil with `value`.
        let completedAt: Date?
        /// True when a scan is running past its deadline and `value` is the
        /// previous result.
        let isOverdue: Bool
    }

    private let label: String
    private let queue: DispatchQueue
    private let scan: @Sendable () -> Value
    private var latest: Value?
    private var latestAt: Date?
    private var inFlight: Task<Value, Never>?
    private var overdue = false
    /// Waiters parked on the in-flight scan. Test hook for the one-waiter cap.
    private(set) var pendingWaiters = 0

    /// Cheap by design (C4): creating a queue does no I/O; the first scan
    /// starts on the first `reading(within:)`.
    init(label: String, scan: @escaping @Sendable () -> Value) {
        self.label = label
        queue = DispatchQueue(label: "com.wizemann.birdwatch.scan.\(label)", qos: .utility)
        self.scan = scan
    }

    /// The running scan's result if it finishes within `seconds`, otherwise the
    /// last completed result, flagged overdue. Starts a scan only when none is
    /// in flight; returns at once while the in-flight scan is already overdue.
    func reading(within seconds: Double) async -> Reading {
        if inFlight != nil, overdue {
            return Reading(value: latest, completedAt: latestAt, isOverdue: true)
        }
        let task = inFlight ?? start()
        pendingWaiters += 1
        // The waiter only suspends (no thread). If the deadline wins it stays
        // parked until the scan ends — which `overdue` caps at one per scan.
        let fresh = await Deadline.run(seconds: seconds) { [weak self] in
            let value = await task.value
            await self?.waiterFinished()
            return value
        }
        if let fresh {
            return Reading(value: fresh, completedAt: latestAt, isOverdue: false)
        }
        if inFlight != nil, !overdue {
            overdue = true
            logger.warning("scan \(self.label, privacy: .public) overdue after \(seconds, privacy: .public)s; serving the previous result")
        }
        return Reading(value: latest, completedAt: latestAt, isOverdue: inFlight != nil)
    }

    /// `reading(within:).value` for callers that only need the data.
    func value(within seconds: Double) async -> Value? {
        await reading(within: seconds).value
    }

    /// Waits for the scan in flight, if any, to land in `latest`. Lets a test
    /// order "late result arrives" before "next cycle" without sleeping (C8).
    func waitForInFlight() async {
        _ = await inFlight?.value
    }

    /// Drops the last result (Full Disk Access lost: it may no longer be
    /// served). A scan in flight still lands; callers that must not cache
    /// it gate on access themselves.
    func forget() {
        latest = nil
        latestAt = nil
    }

    /// Test hook: a scan has been started and has not landed yet.
    var isScanInFlightForTesting: Bool { inFlight != nil }

    private func start() -> Task<Value, Never> {
        let queue = queue
        let scan = scan
        overdue = false
        // Inherits this actor, so `finish` runs isolated; `inFlight` is set
        // below before the task can first run.
        let task = Task {
            let value = await BlockingWork.run(on: queue, scan)
            self.finish(value)
            return value
        }
        inFlight = task
        return task
    }

    private func finish(_ value: Value) {
        latest = value
        latestAt = Date()
        inFlight = nil
        overdue = false
    }

    private func waiterFinished() {
        pendingWaiters -= 1
    }
}
