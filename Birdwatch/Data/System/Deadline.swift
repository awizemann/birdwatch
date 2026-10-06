import Foundation
import os

/// Time-boxes async work and RETURNS AT THE DEADLINE, even when the work never
/// checks for cancellation.
///
/// Why not a task group: a group always awaits every child before it returns,
/// so racing a blocking scan (`contentsOfDirectory` on cold placeholders)
/// against a sleep still waited out the scan — a 0.5s deadline came back after
/// 3s. Here the work runs in an unstructured Task that is cancelled and then
/// ABANDONED, not awaited; the caller resumes as soon as either the work or the
/// deadline finishes.
///
/// Cost of abandoning: a non-cooperative operation keeps running in the
/// background until it finishes on its own, and its result is dropped. Only use
/// this for read-only work whose late completion is harmless.
nonisolated enum Deadline {

    /// `operation`'s result, or nil if `seconds` elapse first (or the caller is
    /// cancelled). The loser is cancelled and never awaited.
    static func run<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let race = Race<T>()
        let work = Task { race.finish(await operation()) }
        let timer = Task {
            // Cancelled when the work wins; finish(nil) is then a no-op.
            try? await Task.sleep(for: .seconds(seconds))
            race.finish(nil)
        }
        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            race.finish(nil)
        }
        work.cancel()
        timer.cancel()
        return result
    }

    /// `operation`'s result, or `fallback` if the deadline wins.
    static func run<T: Sendable>(
        seconds: Double, fallback: T, _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await run(seconds: seconds, operation) ?? fallback
    }

    /// One-shot rendezvous between the waiter and up to three finishers (work,
    /// timer, caller cancellation). The first `finish` wins; a finish that
    /// lands before `wait` is buffered, so the continuation is always resumed
    /// exactly once and never leaked.
    /// Synchronization: all mutable state lives in an OSAllocatedUnfairLock.
    nonisolated private final class Race<T: Sendable>: Sendable {
        private enum State: Sendable {
            case idle
            case waiting(CheckedContinuation<T?, Never>)
            case finished(T?)
            case consumed
        }

        private let state = OSAllocatedUnfairLock(initialState: State.idle)

        func finish(_ value: T?) {
            let waiter = state.withLock { state -> CheckedContinuation<T?, Never>? in
                switch state {
                case .idle:
                    state = .finished(value)
                    return nil
                case .waiting(let continuation):
                    state = .consumed
                    return continuation
                case .finished, .consumed:
                    return nil
                }
            }
            waiter?.resume(returning: value)
        }

        func wait() async -> T? {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> T?? in
                    switch state {
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case .finished(let value):
                        state = .consumed
                        return .some(value)
                    case .waiting, .consumed:
                        preconditionFailure("Deadline.Race waited on twice")
                    }
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
