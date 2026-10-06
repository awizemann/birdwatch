import Foundation

/// Streams `/usr/bin/log stream --style ndjson` filtered per backend, through
/// `ProcessRunner.stream` (C5: lifetime cap, SIGTERM→SIGKILL escalation, and
/// launch failures / non-zero exits surface as errors instead of a silently
/// empty console).
nonisolated enum LogStreamSource {

    nonisolated static func predicate(for backend: SyncBackend) -> String {
        switch backend {
        case .cloudDocs: "subsystem == \"com.apple.clouddocs\""
        case .cloudKit: "process == \"cloudd\""
        case .fileProvider: "process == \"fileproviderd\""
        }
    }

    /// `--level info`: on macOS 27 GA bird's clouddocs messages and most of
    /// cloudd's CK/Request messages are Info level (verified 2026-10-05 — a
    /// default-level clouddocs stream showed nothing while an `--level info`
    /// one carried every line), so without it the console sits empty.
    nonisolated static func arguments(for backend: SyncBackend) -> [String] {
        ["stream", "--style", "ndjson", "--level", "info", "--predicate", predicate(for: backend)]
    }

    /// One spawn's maximum life (C5). The console restarts the stream when it
    /// reaches this, so a detail view left open keeps streaming.
    nonisolated static let lifetime: Duration = .seconds(30 * 60)

    nonisolated static func stream(backend: SyncBackend) -> AsyncThrowingStream<LogLine, any Error> {
        ProcessRunner.stream(
            toolPath: "/usr/bin/log",
            arguments: arguments(for: backend),
            lifetime: lifetime,
            transform: { LogStreamParser.parse(line: $0) }
        )
    }
}
