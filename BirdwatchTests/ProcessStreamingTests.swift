import Foundation
import Testing
@testable import Birdwatch

/// `ProcessRunner.stream` (the `log stream` path) and the stdout truncation
/// signal. The spawns here are short-lived, harmless tools (`printf`, `false`,
/// `head`) or a path that does not exist; assertions are on outcomes, never on
/// elapsed time (C8). The generous lifetimes only bound a broken build.
@Suite("Process streaming and truncation")
struct ProcessStreamingTests {

    private static func collect(_ stream: AsyncThrowingStream<String, any Error>) async -> (lines: [String], error: (any Error)?) {
        var lines: [String] = []
        do {
            for try await line in stream { lines.append(line) }
            return (lines, nil)
        } catch {
            return (lines, error)
        }
    }

    // Fails on the old LogStreamSource, which logged the launch failure and
    // finished the stream normally — an empty console with no reason.
    @Test("A tool that cannot launch ends the stream with launchFailed")
    func launchFailureIsAnError() async {
        let stream = ProcessRunner.stream(
            toolPath: "/nonexistent/birdwatch-test-tool", arguments: [],
            lifetime: .seconds(30), transform: { $0 }
        )
        let (lines, error) = await Self.collect(stream)
        #expect(lines.isEmpty)
        guard case .launchFailed? = error as? RunnerError else {
            Issue.record("expected launchFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("Lines are split across the stream, including an unterminated last line")
    func linesAndTail() async {
        let stream = ProcessRunner.stream(
            toolPath: "/usr/bin/printf", arguments: ["alpha\\nbeta\\ngamma"],
            lifetime: .seconds(30), transform: { $0 }
        )
        let (lines, error) = await Self.collect(stream)
        #expect(error == nil)
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    @Test("transform drops what it does not accept")
    func transformFilters() async {
        let stream = ProcessRunner.stream(
            toolPath: "/usr/bin/printf", arguments: ["keep\\nskip\\nkeep\\n"],
            lifetime: .seconds(30), transform: { $0 == "skip" ? nil : $0.count }
        )
        var counts: [Int] = []
        do {
            for try await count in stream { counts.append(count) }
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(counts == [4, 4])
    }

    @Test("A non-zero exit ends the stream with nonZeroExit, not a silent finish")
    func nonZeroExitIsAnError() async {
        let stream = ProcessRunner.stream(
            toolPath: "/usr/bin/false", arguments: [], lifetime: .seconds(30), transform: { $0 }
        )
        let (_, error) = await Self.collect(stream)
        #expect(error as? RunnerError == .nonZeroExit(code: 1, stderr: ""))
    }

    // Fails on the old runner, which returned the first 4 MB as if it were
    // the whole output.
    @Test("run throws outputTruncated when stdout overruns the capture cap")
    func runSignalsTruncation() async {
        let runner = ProcessRunner()
        let bytes = ProcessRunner.maxCapturedBytes + 512 * 1024
        do {
            let output = try await runner.run(
                toolPath: "/usr/bin/head", arguments: ["-c", String(bytes), "/dev/zero"], timeout: .seconds(30)
            )
            Issue.record("expected outputTruncated, got \(output.utf8.count) bytes")
        } catch RunnerError.outputTruncated(let partial) {
            #expect(partial.utf8.count >= ProcessRunner.maxCapturedBytes)
            #expect(partial.utf8.count < bytes)
        } catch {
            Issue.record("expected outputTruncated, got \(error)")
        }
    }

    @Test("drain reports truncation only when bytes were actually dropped")
    func drainTruncationFlag() async {
        func drain(_ payload: Data, cap: Int) async -> (data: Data, chunks: Int, truncated: Bool) {
            let pipe = Pipe()
            let writer = pipe.fileHandleForWriting
            Thread.detachNewThread {
                writer.write(payload)       // blocks until drained; off the test's executor
                try? writer.close()
            }
            return await ProcessRunner.drain(pipe.fileHandleForReading, cap: cap)
        }
        let small = await drain(Data(repeating: 0x61, count: 1000), cap: 4096)
        #expect(!small.truncated)
        #expect(small.data.count == 1000)

        let big = await drain(Data(repeating: 0x61, count: 512 * 1024), cap: 4096)
        #expect(big.truncated)
        #expect(big.data.count < 512 * 1024)
    }
}

/// Child lifetime: the assertions are that the child process exited, awaited
/// through the stream's `onLaunch` hook — a `ChildExit` fed by the child's
/// termination handler, so nothing here polls or measures time (C8). The
/// exit sink is finished when the stream ends, so a child that never launched
/// fails the test instead of hanging it; the time limit is a backstop only.
@Suite("Process streaming lifecycle")
struct ProcessStreamLifecycleTests {

    // Fails if cancelling the consumer only abandons the stream: the
    // `log stream` child would keep running after the console went away.
    @Test("Cancelling the consumer kills the child", .timeLimit(.minutes(1)))
    func consumerCancellationKillsChild() async {
        let (exits, exitSink) = AsyncStream<ChildExit>.makeStream()
        let stream = ProcessRunner.stream(
            toolPath: "/bin/sleep", arguments: ["30"], lifetime: .seconds(60),
            transform: { $0 }, onLaunch: { exitSink.yield($0) }
        )
        let consumer = Task {
            defer { exitSink.finish() }
            do { for try await _ in stream {} } catch {}
        }
        var iterator = exits.makeAsyncIterator()
        guard let exit = await iterator.next() else {
            Issue.record("the child never launched")
            return
        }
        consumer.cancel()
        await consumer.value
        #expect(await exit.wait() == SIGTERM, "the child outlived its cancelled consumer")
    }

    @Test("The lifetime cap ends the stream with timeout and kills the child", .timeLimit(.minutes(1)))
    func lifetimeCapEndsStream() async {
        let (exits, exitSink) = AsyncStream<ChildExit>.makeStream()
        let stream = ProcessRunner.stream(
            toolPath: "/bin/sleep", arguments: ["30"], lifetime: .milliseconds(200),
            transform: { $0 }, onLaunch: { exitSink.yield($0) }
        )
        var thrown: (any Error)?
        do { for try await _ in stream {} } catch { thrown = error }
        exitSink.finish()
        #expect(thrown as? RunnerError == .timeout)
        var iterator = exits.makeAsyncIterator()
        guard let exit = await iterator.next() else {
            Issue.record("the child never launched")
            return
        }
        #expect(await exit.wait() == SIGTERM)
    }
}

/// The launch/cancel ordering `ProcessRunner.stream` relies on, tested on the
/// gate itself so no process is involved.
@Suite("Launch gate")
struct LaunchGateTests {

    // The C5 fix: the spawn moved off the caller onto the pump task, so a
    // consumer can cancel before it runs — and then nothing may be spawned.
    @Test("A cancel before launch means the launch never runs")
    func cancelBeforeLaunchNeverSpawns() {
        let gate = LaunchGate<Int>()
        #expect(gate.cancel() == nil, "nothing launched yet")
        var launches = 0
        var stopped: [Int] = []
        let handle = gate.launch({ launches += 1; return 7 }, stop: { stopped.append($0) })
        #expect(handle == nil)
        #expect(launches == 0)
        #expect(stopped.isEmpty)
    }

    @Test("A cancel that lands during the launch stops the fresh handle")
    func cancelDuringLaunchStops() {
        let gate = LaunchGate<Int>()
        var stopped: [Int] = []
        let handle = gate.launch({ _ = gate.cancel(); return 7 }, stop: { stopped.append($0) })
        #expect(handle == nil)
        #expect(stopped == [7])
    }

    @Test("A cancel after launch hands the handle back exactly once")
    func cancelAfterLaunchReturnsHandle() {
        let gate = LaunchGate<Int>()
        #expect(gate.launch({ 7 }, stop: { _ in }) == 7)
        #expect(gate.cancel() == 7)
        #expect(gate.cancel() == nil)
    }
}

@Suite("Line splitting")
struct LineSplitterTests {

    @Test("Lines split across chunks are reassembled exactly once")
    func splitAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("al".utf8)).isEmpty)
        #expect(splitter.append(Data("pha\nbe".utf8)) == ["alpha"])
        #expect(splitter.append(Data("ta\n\ngam".utf8)) == ["beta", ""])
        #expect(splitter.flush() == "gam")
        #expect(splitter.flush() == nil)
    }

    // Fails on the old LineBuffer, whose `pending` grew without limit while a
    // newline never came.
    @Test("An over-long line is dropped whole and the buffer stays bounded")
    func overlongLineIsBounded() {
        var splitter = LineSplitter()
        let chunk = Data(repeating: 0x78, count: 64 * 1024)
        for _ in 0..<10 {   // 640 KB with no newline
            #expect(splitter.append(chunk).isEmpty)
            #expect(splitter.pendingByteCount <= LineSplitter.maxLineBytes)
        }
        #expect(splitter.append(Data("tail-of-long\nnext\n".utf8)) == ["next"],
                "the rest of the over-long line is skipped, the next line survives")
        #expect(splitter.pendingByteCount == 0)
    }
}

@Suite("Log stream source")
struct LogStreamSourceTests {

    @Test("Each backend streams its own daemon, at info level", arguments: [
        (SyncBackend.cloudDocs, "subsystem == \"com.apple.clouddocs\""),
        (SyncBackend.cloudKit, "process == \"cloudd\""),
        (SyncBackend.fileProvider, "process == \"fileproviderd\""),
    ])
    func arguments(backend: SyncBackend, predicate: String) {
        let args = LogStreamSource.arguments(for: backend)
        #expect(args.starts(with: ["stream", "--style", "ndjson"]))
        #expect(args.contains("--level") && args.contains("info"))
        #expect(args.last == predicate)
    }
}
