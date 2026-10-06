import Foundation
import Testing
@testable import Birdwatch

/// `Deadline.run` must return AT the deadline even when the work ignores
/// cancellation — the task-group version it replaced waited out a blocking
/// scan (0.5s deadline, 3s return). Every test here asserts on the RESULT:
/// the blocked work can only finish when the test releases it, after the
/// assertion, so a non-nil answer or a hang is the failure — no wall-clock
/// measurement (C8).
@Suite("Deadline", .timeLimit(.minutes(1)))
struct DeadlineTests {

    /// Stands in for a hung read: never finishes until the test releases the
    /// gate and never looks at cancellation. The blocking wait happens on a
    /// GCD thread, NOT a cooperative-pool thread, so these parallel tests
    /// cannot starve the pool (and the deadline's timer) on a small CI runner.
    private nonisolated static func block(on gate: DispatchSemaphore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                gate.wait()
                continuation.resume()
            }
        }
    }

    // Fails on the old withTaskGroup race: the group awaits the blocked child,
    // so `run` never returns before `release` — the suite's time limit trips.
    @Test("A blocking, non-cooperative operation is abandoned at the deadline")
    func blockingOperationReturnsNil() async {
        let gate = DispatchSemaphore(value: 0)
        let result = await Deadline.run(seconds: 0.05) { () -> Int in
            await Self.block(on: gate)   // ignores cancellation
            return 42
        }
        #expect(result == nil)
        gate.signal()     // let the abandoned work drain so nothing leaks
    }

    @Test("The fallback overload returns the fallback when the deadline wins")
    func fallbackOnTimeout() async {
        let gate = DispatchSemaphore(value: 0)
        let result = await Deadline.run(seconds: 0.05, fallback: [String]()) { () -> [String] in
            await Self.block(on: gate)
            return ["late"]
        }
        #expect(result.isEmpty)
        gate.signal()
    }

    @Test("A finished operation's value wins over a distant deadline")
    func fastOperationReturnsValue() async {
        let result = await Deadline.run(seconds: 3600) { 7 }
        #expect(result == 7)
    }

    // The loser is cancelled, not just ignored: cooperative work sees the
    // cancellation and stops. The stream only yields from the cancellation
    // path, so a missing cancel hangs until the time limit.
    @Test("The abandoned operation is cancelled")
    func loserIsCancelled() async {
        let (cancelled, signal) = AsyncStream.makeStream(of: Bool.self)
        let result = await Deadline.run(seconds: 0.05) { () -> Int in
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                signal.yield(Task.isCancelled)
                signal.finish()
            }
            return 1
        }
        #expect(result == nil)
        var iterator = cancelled.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    // A cancelled caller gets nil without waiting for either racer: the work
    // is blocked and the deadline is an hour away.
    @Test("Cancelling the caller returns nil without waiting out the deadline")
    func callerCancellation() async {
        let gate = DispatchSemaphore(value: 0)
        let caller = Task {
            await Deadline.run(seconds: 3600) { () -> Int in
                await Self.block(on: gate)
                return 1
            }
        }
        caller.cancel()
        let result = await caller.value
        #expect(result == nil)
        gate.signal()
    }
}
