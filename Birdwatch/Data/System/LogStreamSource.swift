import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "LogStreamSource")

/// Streams `/usr/bin/log stream --style ndjson` filtered per backend.
actor LogStreamSource {

    nonisolated static func predicate(for backend: SyncBackend) -> String {
        switch backend {
        case .cloudDocs: "subsystem == \"com.apple.clouddocs\""
        case .cloudKit: "process == \"cloudd\""
        case .fileProvider: "process == \"fileproviderd\""
        }
    }

    nonisolated func stream(predicate: String) -> AsyncStream<LogLine> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["stream", "--style", "ndjson", "--predicate", predicate]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            // SIGTRAP hazard: readabilityHandler fires on a non-main dispatch queue.
            // This closure is created from nonisolated context and captures only
            // Sendable state (the continuation and a local buffer box) — creating it
            // in a @MainActor context would trap under Swift 6 isolation checking.
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    if let logLine = LogStreamParser.parse(line: line) {
                        continuation.yield(logLine)
                    }
                }
            }
            // Deliberately NO terminationHandler-finish: it races the readability
            // queue and can drop the final buffered lines (often the error output
            // explaining the death). EOF on the pipe — guaranteed once the writer
            // exits — is the single finish path above.
            continuation.onTermination = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                logger.error("Failed to launch log stream: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }
}

/// Accumulates raw pipe chunks and emits complete lines. Confined to the pipe's
/// readability queue (readabilityHandler calls are serialized per file handle),
/// hence @unchecked Sendable: synchronization is that single serial callback queue.
private nonisolated final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }
}
