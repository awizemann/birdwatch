import Foundation
import os

nonisolated enum RunnerError: Error, Equatable {
    case timeout
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    /// The tool exited 0 but wrote more than `ProcessRunner.maxCapturedBytes`
    /// to stdout, so the tail was dropped. `partial` is what was kept: a caller
    /// that can use a prefix (and says so) may; everyone else fails honestly
    /// instead of parsing a silently shortened output.
    case outputTruncated(partial: String)
}

extension RunnerError {
    /// The part of an error that is safe to log `.public`: the failure kind and
    /// exit code. stderr and launch details can carry paths and file names, so
    /// they only ever go out through `privateDetail(of:)` (C7).
    nonisolated static func publicSummary(of error: any Error) -> String {
        guard let runner = error as? RunnerError else {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
        switch runner {
        case .timeout: return "timed out"
        case .launchFailed: return "launch failed"
        case .nonZeroExit(let code, _): return "exit \(code)"
        case .outputTruncated: return "output exceeded the capture cap"
        }
    }

    /// The free-text part of an error (stderr, launch detail, or the
    /// description). Log it with `privacy: .private` only.
    nonisolated static func privateDetail(of error: any Error) -> String {
        switch error as? RunnerError {
        case .nonZeroExit(_, let stderr): return stderr
        case .launchFailed(let detail): return detail
        case .timeout, .outputTruncated: return ""
        case nil: return String(describing: error)
        }
    }
}

/// The spawn seam. Production is `ProcessRunner`; tests substitute a recording
/// stub to assert HOW MANY times a tool is spawned per refresh cycle — a fact
/// no output-level assertion can reach.
///
/// `timeout` is a requirement, not a defaulted convenience: C5 says every
/// system tool runs under one, and a protocol requirement cannot carry a
/// default, so every call through this seam names its own.
nonisolated protocol ProcessRunning: Sendable {
    func run(toolPath: String, arguments: [String], timeout: Duration) async throws -> String
}

/// Runs a tool at a fixed absolute path and returns its stdout. Actor-isolated
/// so the whole spawn/wait/read cycle runs on this actor's executor, never the
/// MainActor. (A plain `nonisolated async` function would also run off-main
/// today, on the global executor, because NonisolatedNonsendingByDefault /
/// SE-0461 is not enabled in this project; the actor states the intent without
/// depending on that setting.)
actor ProcessRunner: ProcessRunning {
    /// Cap on captured bytes per stream; a runaway tool keeps getting drained
    /// (so it never deadlocks on pipe backpressure) but we stop retaining.
    /// Overrunning it on stdout throws `RunnerError.outputTruncated`.
    static let maxCapturedBytes = 4 * 1024 * 1024

    /// Process/FileHandle aren't Sendable, but the operations we perform across
    /// tasks after launch (terminate, terminationStatus, pipe reads on distinct
    /// handles) are documented thread-safe. The box only ferries the references
    /// into task-group children. `terminationClaimed` is guarded by its own
    /// unfair lock.
    private final class LaunchBox: @unchecked Sendable {
        let process: Process
        let stdout: FileHandle
        let stderr: FileHandle
        private let terminationClaimed = OSAllocatedUnfairLock(initialState: false)
        init(process: Process, stdout: FileHandle, stderr: FileHandle) {
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
        }

        /// True exactly once: the first of several terminators (timeout,
        /// lifetime cap, cancellation, stream termination) does the work.
        func claimTermination() -> Bool {
            terminationClaimed.withLock { claimed in
                defer { claimed = true }
                return !claimed
            }
        }
    }

    private enum Piece: Sendable {
        case exit(Int32)
        case stdout(Data, truncated: Bool)
        case stderr(Data)
        case timedOut
    }

    func run(
        toolPath: String,
        arguments: [String] = [],
        timeout: Duration
    ) async throws -> String {
        let (process, outPipe, errPipe) = Self.makeProcess(toolPath: toolPath, arguments: arguments)

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

    private nonisolated static func makeProcess(
        toolPath: String, arguments: [String]
    ) -> (Process, stdout: Pipe, stderr: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        return (process, outPipe, errPipe)
    }

    private nonisolated static func race(
        box: LaunchBox,
        exitStream: AsyncStream<Int32>,
        timeout: Duration
    ) async throws -> String {
        return try await withThrowingTaskGroup(of: Piece.self) { group in
            group.addTask {
                let drained = await Self.drain(box.stdout)
                return .stdout(drained.data, truncated: drained.truncated)
            }
            group.addTask { .stderr(await Self.drain(box.stderr).data) }
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
            var stdoutTruncated = false
            var stderrData: Data?
            while let piece = try await group.next() {
                switch piece {
                case .timedOut:
                    Self.terminateAndEscalate(box)
                    group.cancelAll()
                    throw RunnerError.timeout
                case .exit(let code): exitCode = code
                case .stdout(let data, let truncated):
                    stdoutData = data
                    stdoutTruncated = truncated
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
                    let output = String(decoding: out, as: UTF8.self)
                    guard !stdoutTruncated else { throw RunnerError.outputTruncated(partial: output) }
                    return output
                }
            }
            // Unreachable: exit + both EOFs always arrive unless timeout threw.
            throw RunnerError.timeout
        }
    }

    // MARK: - Streaming

    /// How many transformed elements a stream holds while its consumer is
    /// busy; past this the OLDEST are dropped (a console shows the newest).
    nonisolated static let streamBufferLimit = 64

    private enum StreamPiece: Sendable {
        case stdoutClosed
        case stderr(Data)
        case exit(Int32)
        case timedOut
    }

    /// Runs a long-lived tool (`log stream`) and yields each stdout line that
    /// `transform` accepts, under the same rules as `run`: a launch failure,
    /// a non-zero exit (with its stderr) and the `lifetime` cap all END the
    /// stream with a `RunnerError` the consumer can show, and both the
    /// lifetime cap and consumer cancellation stop the child with SIGTERM
    /// escalating to SIGKILL (`terminateAndEscalate`).
    ///
    /// `lifetime` is C5's timeout for a tool that never exits on its own: the
    /// consumer restarts the stream when it wants to keep watching.
    /// `transform` runs off-main on the pipe-drain task, so it must be a
    /// nonisolated (static) function.
    ///
    /// The spawn happens on the pump task, never on the caller: the console
    /// creates this stream on the MainActor, and C5 keeps every spawn off it.
    /// `onLaunch` is a test hook: it receives the child's `ChildExit`, fed by
    /// the termination handler, so a test can await the child's death.
    nonisolated static func stream<Element: Sendable>(
        toolPath: String,
        arguments: [String],
        lifetime: Duration,
        transform: @escaping @Sendable (String) -> Element?,
        onLaunch: (@Sendable (ChildExit) -> Void)? = nil
    ) -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(streamBufferLimit)) { continuation in
            let gate = LaunchGate<Launched>()
            // Installed BEFORE the pump can launch anything. Fires on consumer
            // cancellation and after a normal finish: a cancel that beats the
            // launch makes the pump skip the spawn; otherwise a still-running
            // child is stopped (once — the lifetime cap may already have).
            continuation.onTermination = { _ in
                if let launched = gate.cancel(), launched.box.process.isRunning {
                    terminateAndEscalate(launched.box)
                }
            }
            Task {
                let launched: Launched?
                do {
                    launched = try gate.launch(
                        { try launch(toolPath: toolPath, arguments: arguments) },
                        stop: { terminateAndEscalate($0.box) }
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                // Cancelled before launch: nothing was spawned.
                guard let launched else { return }
                onLaunch?(launched.exit)
                do {
                    try await pumpLines(
                        box: launched.box, exitStream: launched.exitStream, lifetime: lifetime,
                        transform: transform, continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private struct Launched: Sendable {
        let box: LaunchBox
        let exitStream: AsyncStream<Int32>
        let exit: ChildExit
    }

    private nonisolated static func launch(toolPath: String, arguments: [String]) throws -> Launched {
        let (process, outPipe, errPipe) = makeProcess(toolPath: toolPath, arguments: arguments)
        let exit = ChildExit()
        let exitStream = makeExitStream(process, alsoSignal: exit)
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
        return Launched(box: box, exitStream: exitStream, exit: exit)
    }

    private nonisolated static func pumpLines<Element: Sendable>(
        box: LaunchBox,
        exitStream: AsyncStream<Int32>,
        lifetime: Duration,
        transform: @escaping @Sendable (String) -> Element?,
        continuation: AsyncThrowingStream<Element, any Error>.Continuation
    ) async throws {
        try await withThrowingTaskGroup(of: StreamPiece.self) { group in
            group.addTask {
                var splitter = LineSplitter()
                for await chunk in Self.chunks(of: box.stdout) {
                    for line in splitter.append(chunk) {
                        if let element = transform(line) { continuation.yield(element) }
                    }
                }
                if let tail = splitter.flush(), let element = transform(tail) {
                    continuation.yield(element)
                }
                return .stdoutClosed
            }
            group.addTask { .stderr(await Self.drain(box.stderr).data) }
            group.addTask {
                for await code in exitStream { return .exit(code) }
                return .exit(-1)
            }
            group.addTask {
                try await Task.sleep(for: lifetime)
                return .timedOut
            }

            var exitCode: Int32?
            var stderrData: Data?
            var stdoutClosed = false
            while let piece = try await group.next() {
                switch piece {
                case .timedOut:
                    Self.terminateAndEscalate(box)
                    group.cancelAll()
                    throw RunnerError.timeout
                case .stdoutClosed: stdoutClosed = true
                case .stderr(let data): stderrData = data
                case .exit(let code): exitCode = code
                }
                if let code = exitCode, let err = stderrData, stdoutClosed {
                    group.cancelAll()
                    guard code == 0 else {
                        throw RunnerError.nonZeroExit(code: code, stderr: String(decoding: err, as: UTF8.self))
                    }
                    return
                }
            }
            // Only reachable when the consumer cancelled (the sleep child threw
            // first); the stream is already terminated, so this goes nowhere.
            throw CancellationError()
        }
    }

    // MARK: - Termination

    /// SIGTERM first (lets the tool clean up), then SIGKILL after a 2s grace if
    /// it ignored it — a wedged child must never outlive its runner.
    private nonisolated static func terminateAndEscalate(_ box: LaunchBox) {
        guard box.claimTermination() else { return }
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

    private nonisolated static func makeExitStream(
        _ process: Process, alsoSignal childExit: ChildExit? = nil
    ) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                continuation.yield(status)
                continuation.finish()
                childExit?.record(status)
            }
        }
    }

    // MARK: - Pipe draining

    /// Async, non-blocking pipe drain (never Process.waitUntilExit / blocking
    /// reads on the cooperative pool). Reads to EOF; discards past `cap`.
    ///
    /// Chunked on purpose: `FileHandle.bytes` yields ONE BYTE per await, which
    /// measured ~73 KB/s — a 2 MB `log show` took 29s and blew every timeout.
    /// `readabilityHandler` delivers whole buffers instead. The handler is
    /// built in a nonisolated static helper because it fires off-main.
    ///
    /// Also reports how many chunks delivered the bytes and whether anything
    /// was dropped past `cap`. `run` discards the count; tests call THIS
    /// function (the one `run` uses, not a copy) and assert on it — a
    /// byte-at-a-time regression shows up as one chunk per byte, whatever the
    /// machine's speed.
    nonisolated static func drain(
        _ handle: FileHandle, cap: Int = maxCapturedBytes
    ) async -> (data: Data, chunks: Int, truncated: Bool) {
        var data = Data()
        var count = 0
        var truncated = false
        for await chunk in chunks(of: handle) {
            count += 1
            if data.count < cap { data.append(chunk) } else { truncated = true }
        }
        return (data, count, truncated)
    }

    /// The handle's output as whole readability-handler buffers, finishing at
    /// EOF. Shared by `drain` and `stream`.
    private nonisolated static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream<Data> { continuation in
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
    }
}

/// A child's exit status, awaitable by any number of waiters. Recorded by the
/// child's termination handler (the same one that feeds the runner), so
/// waiting on it is waiting on the real exit, not on time.
nonisolated final class ChildExit: Sendable {
    private struct State: Sendable {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ status: Int32) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int32, Never>] in
            state.status = status
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    /// The child's `terminationStatus` (the signal number when killed).
    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}

/// Orders a launch against a cancellation that may arrive from another thread
/// at any moment. A cancel before `launch` means the launch never runs; a
/// cancel during it (the spawn is not done under the lock) is seen when the
/// launch registers, and the fresh handle is stopped at once. Generic so the
/// ordering is testable without spawning anything.
nonisolated final class LaunchGate<Handle: Sendable>: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var handle: Handle?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Runs `launch` unless already cancelled. Returns the handle, or nil when
    /// cancelled (before the launch, or during it — then `stop` has run).
    func launch(_ launch: () throws -> Handle, stop: (Handle) -> Void) rethrows -> Handle? {
        guard !state.withLock({ $0.cancelled }) else { return nil }
        let handle = try launch()
        let cancelledMeanwhile = state.withLock { state -> Bool in
            if state.cancelled { return true }
            state.handle = handle
            return false
        }
        if cancelledMeanwhile {
            stop(handle)
            return nil
        }
        return handle
    }

    /// Marks the gate cancelled; returns the launched handle to stop, if any.
    func cancel() -> Handle? {
        state.withLock { state in
            state.cancelled = true
            defer { state.handle = nil }
            return state.handle
        }
    }
}

/// Splits raw pipe chunks into lines. Linear in the bytes fed (each chunk is
/// scanned once; the partial tail is the only thing carried over) and bounded:
/// a line longer than `maxLineBytes` is dropped whole rather than buffered
/// without limit — for ndjson a cut line could never parse anyway.
nonisolated struct LineSplitter {
    static let maxLineBytes = 256 * 1024

    private var pending = Data()
    /// Inside a line that already overran the cap: drop through its newline.
    private var discarding = false

    /// Bytes carried over to the next chunk (never more than `maxLineBytes`).
    var pendingByteCount: Int { pending.count }

    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if discarding {
                discarding = false
            } else {
                pending.append(data[start..<newline])
                if pending.count <= Self.maxLineBytes {
                    lines.append(String(decoding: pending, as: UTF8.self))
                }
            }
            pending.removeAll(keepingCapacity: true)
            start = data.index(after: newline)
        }
        if !discarding {
            pending.append(data[start...])
            if pending.count > Self.maxLineBytes {
                pending = Data()
                discarding = true
            }
        }
        return lines
    }

    /// The unterminated last line once the stream has ended, if any.
    mutating func flush() -> String? {
        defer { pending = Data(); discarding = false }
        guard !discarding, !pending.isEmpty else { return nil }
        return String(decoding: pending, as: UTF8.self)
    }
}
