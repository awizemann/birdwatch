import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "BandwidthSource")

/// Estimates iCloud network usage by sampling `nettop` for the sync daemons.
///
/// nettop's per-process bytes_in/bytes_out counters are CUMULATIVE since the
/// process started, so this actor keeps the previous reading per pid and works
/// on deltas. All rolling state (today's totals, current rate, 24-hour buffer)
/// is in-memory only — it rebuilds over the session and is honestly labeled
/// "Estimated" in the UI. Every failure degrades to zero deltas, never a crash.
actor BandwidthSource {

    /// Daemons whose traffic we attribute to iCloud sync.
    private static let daemonNames: Set<String> = ["bird", "cloudd", "fileproviderd"]

    private let runner = ProcessRunner()
    private var state = State()

    // MARK: - Rolling state (pure value; advanced by a pure static func)

    struct State: Sendable {
        /// Last cumulative reading per pid (bytes in / bytes out).
        var lastCumulative: [Int32: Reading] = [:]
        var lastSampleAt: Date?
        /// Start of the calendar day the totals belong to.
        var dayStart: Date?
        var uploadedTodayBytes: Int64 = 0
        var downloadedTodayBytes: Int64 = 0
        var currentRateBytesPerSec: Int64 = 0
        /// Indexed by hour-of-day; only hours of the CURRENT day are non-zero
        /// (the whole buffer resets on day rollover).
        var hourUploaded = [Int64](repeating: 0, count: 24)
        var hourDownloaded = [Int64](repeating: 0, count: 24)
    }

    struct Reading: Sendable, Equatable {
        var bytesIn: Int64
        var bytesOut: Int64
    }

    // MARK: - Sampling

    /// - Parameter psOutput: raw `ps` output to reuse instead of spawning our
    ///   own. Pass `DaemonStatsSource.sampleRaw()` so one cycle costs one `ps`
    ///   instead of two. `nil` keeps the standalone behaviour.
    func sample(psOutput: String? = nil) async -> BandwidthSummary {
        let pids = await discoverDaemonPids(psOutput: psOutput)
        guard !pids.isEmpty else {
            logger.warning("no iCloud daemons found; bandwidth stays at last state")
            state = Self.advance(state: state, readings: [:], now: Date())
            return Self.summary(from: state)
        }
        var arguments = ["-P", "-x", "-L", "1"]
        for pid in pids { arguments += ["-p", String(pid)] }
        do {
            // Multi-pid syntax verified on this machine: repeated -p flags,
            // one CSV row per process that has (or had) network activity —
            // idle processes are simply absent from the output.
            let csv = try await runner.run(toolPath: "/usr/bin/nettop", arguments: arguments)
            let readings = Dictionary(
                Self.parseNettop(csv: csv).map { ($0.pid, Reading(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut)) },
                uniquingKeysWith: { a, b in Reading(bytesIn: a.bytesIn + b.bytesIn, bytesOut: a.bytesOut + b.bytesOut) }
            )
            state = Self.advance(state: state, readings: readings, now: Date())
        } catch {
            logger.error("nettop sample failed: \(String(describing: error), privacy: .public)")
            state = Self.advance(state: state, readings: [:], now: Date())
        }
        return Self.summary(from: state)
    }

    /// Pids of the real /System/Library iCloud daemons via `ps`.
    ///
    /// NOTE: DaemonStatsSource.parse is deliberately NOT reused here — it
    /// aggregates multi-instance daemons (cloudd runs several copies) down to
    /// a single lowest pid per name, and bandwidth needs EVERY pid. This is a
    /// minimal pid extraction that applies the same two guards documented
    /// there: /System/Library/ path prefix (drops iOS-simulator copies of the
    /// same daemons) and exact basename match.
    private func discoverDaemonPids(psOutput: String? = nil) async -> [Int32] {
        if let psOutput { return Self.extractDaemonPids(psOutput: psOutput) }
        do {
            let output = try await runner.run(toolPath: "/bin/ps", arguments: ["-axo", "pid,comm"])
            return Self.extractDaemonPids(psOutput: output)
        } catch {
            logger.error("ps pid discovery failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Column-count tolerant: accepts both `pid,comm` and the shared
    /// `pid,pcpu,rss,comm` layout (pid first, executable path last), so the
    /// same output can serve DaemonStatsSource and this source.
    nonisolated static func extractDaemonPids(psOutput: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]) else { return nil }
            let path = String(fields[fields.count - 1])
            guard path.hasPrefix("/System/Library/"),
                  daemonNames.contains((path as NSString).lastPathComponent) else { return nil }
            return pid
        }.sorted()
    }

    // MARK: - Parsing (pure)

    /// Parses `nettop -P -x -L 1` CSV. Header-tolerant and garbage-tolerant:
    /// any line that doesn't look like "time,name.pid,…,bytes_in,bytes_out,…"
    /// is skipped. Verified header on this machine:
    /// `time,,interface,state,bytes_in,bytes_out,…` — bytes are columns 4/5.
    nonisolated static func parseNettop(csv: String) -> [(pid: Int32, bytesIn: Int64, bytesOut: Int64)] {
        csv.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 6,
                  let dotIndex = fields[1].lastIndex(of: "."),
                  let pid = Int32(fields[1][fields[1].index(after: dotIndex)...]),
                  let bytesIn = Int64(fields[4]),
                  let bytesOut = Int64(fields[5]) else { return nil }
            return (pid: pid, bytesIn: bytesIn, bytesOut: bytesOut)
        }
    }

    // MARK: - State math (pure)

    /// Advances the rolling state with one set of cumulative readings.
    /// - Cumulative → delta per pid; a counter that went DOWN (daemon restart,
    ///   pid reuse) yields 0, never a negative.
    /// - Unseen pids (first sample) yield 0 — a baseline, not traffic.
    /// - Day rollover resets today's totals and the whole hour buffer.
    nonisolated static func advance(
        state: State,
        readings: [Int32: Reading],
        now: Date,
        calendar: Calendar = .current
    ) -> State {
        var next = state

        // Day rollover check before accumulating.
        let dayStart = calendar.startOfDay(for: now)
        if next.dayStart != dayStart {
            next.dayStart = dayStart
            next.uploadedTodayBytes = 0
            next.downloadedTodayBytes = 0
            next.hourUploaded = [Int64](repeating: 0, count: 24)
            next.hourDownloaded = [Int64](repeating: 0, count: 24)
        }

        var deltaIn: Int64 = 0
        var deltaOut: Int64 = 0
        for (pid, reading) in readings {
            if let last = state.lastCumulative[pid] {
                deltaIn += max(0, reading.bytesIn - last.bytesIn)
                deltaOut += max(0, reading.bytesOut - last.bytesOut)
            }
            // First sighting of a pid establishes the baseline only.
        }
        next.lastCumulative = readings

        next.downloadedTodayBytes += deltaIn
        next.uploadedTodayBytes += deltaOut
        let hour = calendar.component(.hour, from: now)
        if (0..<24).contains(hour) {
            next.hourDownloaded[hour] += deltaIn
            next.hourUploaded[hour] += deltaOut
        }

        if let last = state.lastSampleAt {
            let elapsed = now.timeIntervalSince(last)
            next.currentRateBytesPerSec = elapsed > 0
                ? Int64(Double(deltaIn + deltaOut) / elapsed)
                : 0
        } else {
            next.currentRateBytesPerSec = 0
        }
        next.lastSampleAt = now
        return next
    }

    nonisolated static func summary(from state: State) -> BandwidthSummary {
        BandwidthSummary(
            uploadedTodayBytes: state.uploadedTodayBytes,
            downloadedTodayBytes: state.downloadedTodayBytes,
            currentRateBytesPerSec: state.currentRateBytesPerSec,
            hours: (0..<24).map {
                BandwidthHourSample(
                    hour: $0,
                    uploadedBytes: state.hourUploaded[$0],
                    downloadedBytes: state.hourDownloaded[$0]
                )
            }
        )
    }
}
