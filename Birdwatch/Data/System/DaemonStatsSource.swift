import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "DaemonStatsSource")

/// Samples CPU/memory for the iCloud sync daemons via `ps`.
actor DaemonStatsSource {

    private static let roles: [String: String] = [
        "bird": "CloudDocs sync engine",
        "cloudd": "CloudKit sync",
        "fileproviderd": "File Provider host",
    ]

    private let runner: any ProcessRunning

    /// Injected so tests can COUNT spawns; production gets the real runner.
    init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }

    /// `ps` columns shared with BandwidthSource's pid discovery, so one spawn
    /// per refresh cycle can feed both (see `sampleRaw`).
    static let psArguments = ["-axo", "pid,pcpu,rss,comm"]

    func sample(psOutput: String? = nil) async -> [DaemonStat] {
        let output: String
        if let psOutput { output = psOutput } else { output = await sampleRaw() }
        return Self.parse(psOutput: output)
    }

    /// One `ps` spawn, drained through ProcessRunner (drain-as-wait, output cap,
    /// cancellation + SIGTERM/SIGKILL escalation). Returns "" on failure, which
    /// the pure parsers already treat as "no daemons".
    func sampleRaw() async -> String {
        do {
            return try await runner.run(toolPath: "/bin/ps", arguments: Self.psArguments, timeout: .seconds(10))
        } catch {
            logger.error("ps sample failed: \(String(describing: error), privacy: .public)")
            return ""
        }
    }

    /// Keeps only real system daemons (/System/Library/…, basename exactly
    /// bird/cloudd/fileproviderd); iOS-simulator copies under
    /// /Library/Developer/CoreSimulator ship the same basenames and must be dropped.
    nonisolated static func parse(psOutput: String) -> [DaemonStat] {
        var byName: [String: DaemonStat] = [:]
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Double(fields[2]) else { continue }
            let path = String(fields[3])
            guard path.hasPrefix("/System/Library/") else { continue }
            let name = (path as NSString).lastPathComponent
            guard let role = roles[name] else { continue }

            if var existing = byName[name] {
                existing.cpuPercent += cpu
                existing.memoryMB += rssKB / 1024
                existing.pid = min(existing.pid ?? pid, pid)
                byName[name] = existing
            } else {
                byName[name] = DaemonStat(name: name, role: role, cpuPercent: cpu, memoryMB: rssKB / 1024, pid: pid)
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

}
