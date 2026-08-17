import Foundation

nonisolated enum RunnerError: Error, Equatable {
    case timeout
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
}

/// Runs a tool at a fixed absolute path and returns its stdout. Actor-isolated
/// so callers hop off the MainActor for the whole spawn/wait/read cycle
/// (SE-0461: a `nonisolated async` version would run on the caller's actor).
actor ProcessRunner {
    /// Cap on captured bytes per stream; a runaway tool keeps getting drained
    /// (so it never deadlocks on pipe backpressure) but we stop retaining.
    static let maxCapturedBytes = 4 * 1024 * 1024

    /// Process/FileHandle aren't Sendable, but the operations we perform across
    /// tasks after launch (terminate, terminationStatus, pipe reads on distinct
    /// handles) are documented thread-safe. The box only ferries the references
    /// into task-group children.
    private final class LaunchBox: @unchecked Sendable {
        let process: Process
        let stdout: FileHandle
        let stderr: FileHandle
        init(process: Process, stdout: FileHandle, stderr: FileHandle) {
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    private enum Piece: Sendable {
        case exit(Int32)
        case stdout(Data)
        case stderr(Data)
        case timedOut
    }

    func run(
        toolPath: String,
        arguments: [String] = [],
        timeout: Duration = .seconds(10)
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Bridge terminationHandler → continuation BEFORE launch so a fast exit
        // can't race the handler installation. Built from a nonisolated helper:
        // the handler fires off-main and must not close over actor state.
        let exitStream = Self.makeExitStream(process)

        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(String(describing: error))
        }

        let box = LaunchBox(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        // Caller cancellation must stop the child process, not just abandon it.
        return try await withTaskCancellationHandler {
            try await Self.race(box: box, exitStream: exitStream, timeout: timeout)
        } onCancel: {
            Self.terminateAndEscalate(box)
        }
    }

    private nonisolated static func race(
        box: LaunchBox,
        exitStream: AsyncStream<Int32>,
        timeout: Duration
    ) async throws -> String {
        return try await withThrowingTaskGroup(of: Piece.self) { group in
            group.addTask { .stdout(try await Self.drain(box.stdout)) }
            group.addTask { .stderr(try await Self.drain(box.stderr)) }
            group.addTask {
                for await code in exitStream { return .exit(code) }
                return .exit(-1)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            var exitCode: Int32?
            var stdoutData: Data?
            var stderrData: Data?
            while let piece = try await group.next() {
                switch piece {
                case .timedOut:
                    Self.terminateAndEscalate(box)
                    group.cancelAll()
                    throw RunnerError.timeout
                case .exit(let code): exitCode = code
                case .stdout(let data): stdoutData = data
                case .stderr(let data): stderrData = data
                }
                if let code = exitCode, let out = stdoutData, let err = stderrData {
                    group.cancelAll()
                    guard code == 0 else {
                        throw RunnerError.nonZeroExit(
                            code: code,
                            stderr: String(decoding: err, as: UTF8.self)
                        )
                    }
                    return String(decoding: out, as: UTF8.self)
                }
            }
            // Unreachable: exit + both EOFs always arrive unless timeout threw.
            throw RunnerError.timeout
        }
    }

    /// SIGTERM first (lets the tool clean up), then SIGKILL after a 2s grace if
    /// it ignored it — a wedged child must never outlive its runner.
    private nonisolated static func terminateAndEscalate(_ box: LaunchBox) {
        let pid = box.process.processIdentifier
        box.process.terminate()
        guard pid > 0 else { return }
        // Task.detached is DELIBERATE, not an oversight. Every caller of this
        // is on its way out — a timeout throws and `group.cancelAll()` runs
        // immediately after — so a structured child would be cancelled before
        // the 2s sleep elapsed and the SIGKILL escalation would never fire,
        // leaving a wedged brctl/log process alive forever. The escalation must
        // outlive its cancelled parent, which is exactly what detached buys.
        // Bounded by construction: one 2s sleep, then it exits.
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if box.process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private nonisolated static func makeExitStream(_ process: Process) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
    }

    /// Async, non-blocking pipe drain (never Process.waitUntilExit / blocking
    /// reads on the cooperative pool). Reads to EOF; discards past the cap.
    ///
    /// Chunked on purpose: `FileHandle.bytes` yields ONE BYTE per await, which
    /// measured ~73 KB/s — a 2 MB `log show` took 29s and blew every timeout.
    /// `readabilityHandler` delivers whole buffers instead. The handler is
    /// built in this nonisolated static helper because it fires off-main.
    private nonisolated static func drain(_ handle: FileHandle) async throws -> Data {
        let chunks = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { readable in
                let chunk = readable.availableData
                if chunk.isEmpty {
                    readable.readabilityHandler = nil     // EOF
                    continuation.finish()
                } else {
                    continuation.yield(chunk)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
        var data = Data()
        for await chunk in chunks {
            if data.count < maxCapturedBytes { data.append(chunk) }
        }
        return data
    }
}
