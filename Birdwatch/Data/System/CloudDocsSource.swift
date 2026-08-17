import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "clouddocs")

/// Runs `brctl` and parses its output. Actor-isolated on purpose: callers
/// (SyncStore on the MainActor) hop here, so spawn+parse never touch main.
/// Failures (iCloud offline, missing Full Disk Access, format drift) degrade
/// to nil — logged, never fatal.
actor CloudDocsSource {
    private let runner = ProcessRunner()
    private static let brctlPath = "/usr/bin/brctl"

    func status() async -> BrctlStatus? {
        do {
            let out = try await runner.run(
                toolPath: Self.brctlPath,
                arguments: ["status", "com.apple.CloudDocs"]
            )
            return BrctlParser.parseStatus(out)
        } catch {
            logger.warning("brctl status failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func quotaRemaining() async -> Int64? {
        do {
            let out = try await runner.run(toolPath: Self.brctlPath, arguments: ["quota"])
            guard let bytes = BrctlParser.parseQuota(out) else {
                logger.warning("brctl quota output did not match expected format")
                return nil
            }
            return bytes
        } catch {
            logger.warning("brctl quota failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
