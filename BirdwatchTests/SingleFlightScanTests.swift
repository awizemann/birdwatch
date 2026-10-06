import Foundation
import os
import Testing
@testable import Birdwatch

/// SingleFlightScan's three promises, asserted on results only (C8): scans
/// block on gates the test releases, so a hang — not a stopwatch — is the
/// failure mode, bounded by the suite's time limit.
@Suite("Single-flight scan", .timeLimit(.minutes(1)))
struct SingleFlightScanTests {

    @Test("A scan that finishes in time returns its fresh result")
    func freshResult() async {
        let scan = SingleFlightScan(label: "test.fresh") { 7 }
        #expect(await scan.value(within: 3600) == 7)
    }

    // Fails if a refresh starts a second scan while one is in flight (the
    // pile-up), or if a late result is dropped instead of served next cycle
    // (a scan slower than the deadline would read empty forever).
    @Test("One scan in flight at a time; a late result is served on the next cycle")
    func singleFlightAndLateResult() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        let scan = SingleFlightScan(label: "test.late") { () -> Int in
            let n = calls.withLock { count -> Int in count += 1; return count }
            (n == 1 ? firstGate : secondGate).wait()
            return n
        }

        #expect(await scan.value(within: 0.05) == nil, "nothing has ever finished")
        #expect(await scan.value(within: 0.05) == nil)
        #expect(calls.withLock { $0 } == 1, "the second cycle waited on the first scan")

        firstGate.signal()
        await scan.waitForInFlight()

        // Next cycle: a new scan starts and blocks, so the late first result
        // is what comes back.
        #expect(await scan.value(within: 0.05) == 1)
        #expect(calls.withLock { $0 } == 2)
        secondGate.signal()
    }

    // Fails if every refresh parks another waiter on a hung scan (one leaked
    // Task per cycle for as long as the mount stays hung).
    @Test("A hung scan holds at most one waiter, however many cycles ask")
    func oneWaiterPerHungScan() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let gate = DispatchSemaphore(value: 0)
        let scan = SingleFlightScan(label: "test.waiters") { () -> Int in
            let n = calls.withLock { count -> Int in count += 1; return count }
            if n == 1 { gate.wait() }   // only the first scan hangs
            return n
        }
        let first = await scan.reading(within: 0.05)
        #expect(first.value == nil)
        #expect(first.isOverdue)
        for _ in 0..<20 {
            let reading = await scan.reading(within: 0.05)
            #expect(reading.isOverdue)
            #expect(await scan.pendingWaiters <= 1)
        }
        #expect(await scan.pendingWaiters == 1)

        gate.signal()
        await scan.waitForInFlight()
        #expect(calls.withLock { $0 } == 1, "no second scan while the first was hung")
        // The finished scan cleared overdue; the next cycle's fresh scan is
        // current and carries a timestamp.
        let after = await scan.reading(within: 3600)
        #expect(after.value == 2)
        #expect(!after.isOverdue)
        #expect(after.completedAt != nil)
    }

    // The reviewer's repro: with at least as many hung scans as cores, a
    // pool-thread implementation starves Task.sleep and no deadline fires.
    // Each scan blocks on its own queue here, so every deadline still returns.
    @Test("More hung scans than cores still all return at their deadline")
    func hungScansDoNotStarveThePool() async {
        let gate = DispatchSemaphore(value: 0)
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let scans = (0..<count).map { i in
            SingleFlightScan(label: "test.hung.\(i)") { () -> Int in
                gate.wait()
                return i
            }
        }
        let results = await withTaskGroup(of: Int?.self) { group in
            for scan in scans { group.addTask { await scan.value(within: 0.05) } }
            var collected: [Int?] = []
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == count)
        #expect(results.allSatisfy { $0 == nil })
        for _ in 0..<count { gate.signal() }
    }
}
