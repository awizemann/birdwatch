import Foundation
import Testing
@testable import Birdwatch

/// Audit P2: "MaintenanceActions error mapping" was untested. Nothing here
/// spawns a process or signals anything: every test either returns before the
/// runner is reached or runs against `ScriptedRunner`, a fake that records the
/// `kill` it was asked for and answers `ps` from a script.
@Suite("MaintenanceActions")
struct MaintenanceActionsTests {

    /// Answers `/bin/ps` from a queue (the last answer repeats) and records
    /// every call. `/bin/kill` succeeds without doing anything — a real signal
    /// to a system daemon must never come from a test.
    actor ScriptedRunner: ProcessRunning {
        private var psAnswers: [Result<String, RunnerError>]
        private(set) var calls: [(tool: String, arguments: [String])] = []
        /// Cancels the CALLER's task when the kill arrives — the runner runs
        /// inside that task, so this is how a test cancels mid-restart without
        /// any timing.
        let cancelOnKill: Bool

        init(ps: [Result<String, RunnerError>], cancelOnKill: Bool = false) {
            self.psAnswers = ps
            self.cancelOnKill = cancelOnKill
        }

        var psCallCount: Int { calls.filter { $0.tool == "/bin/ps" }.count }
        var killArguments: [[String]] { calls.filter { $0.tool == "/bin/kill" }.map(\.arguments) }

        func run(toolPath: String, arguments: [String], timeout: Duration) async throws -> String {
            calls.append((toolPath, arguments))
            switch toolPath {
            case "/bin/ps":
                let answer = psAnswers.count > 1 ? psAnswers.removeFirst() : psAnswers[0]
                return try answer.get()
            case "/bin/kill":
                if cancelOnKill { withUnsafeCurrentTask { $0?.cancel() } }
                return ""
            default:
                Issue.record("unexpected tool \(toolPath)")
                return ""
            }
        }
    }

    /// `ps -axo pid,uid,comm` output with one host `bird` owned by us.
    private static func ps(birdPID: Int32) -> String {
        """
          PID   UID COMM
            1     0 /sbin/launchd
        \(birdPID)   \(getuid()) /System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/bird
        """
    }

    // Fails if an unknown daemon name ever falls through to launchctl with a
    // half-formed target instead of being rejected up front.
    @Test("restartDaemon rejects a daemon it has no verified launchd label for")
    func unknownDaemonThrowsBeforeSpawning() async throws {
        let runner = ScriptedRunner(ps: [.success("")])
        let actions = MaintenanceActions(runner: runner)
        await #expect(throws: MaintenanceError.unknownDaemon("mds")) {
            _ = try await actions.restartDaemon(name: "mds")
        }
        #expect(await runner.calls.isEmpty)
        // The three verified labels are the whole allow-list.
        #expect(MaintenanceActions.serviceLabels.keys.sorted() == ["bird", "cloudd", "fileproviderd"])
    }

    // The signal path end to end, against the fake: SIGTERM goes to exactly
    // the pid ps reported, and success is claimed only once a NEW pid shows up.
    @Test("restartDaemon signals the observed pid and reports the respawned one")
    func restartSignalsAndObservesRespawn() async throws {
        let runner = ScriptedRunner(ps: [.success(Self.ps(birdPID: 4242)), .success(Self.ps(birdPID: 5151))])
        let actions = MaintenanceActions(runner: runner, respawnPollInterval: .zero)
        let result = try await actions.restartDaemon(name: "bird")
        #expect(result == "Restarted (new pid 5151)")
        #expect(await runner.killArguments == [["-TERM", "4242"]])
        #expect(await runner.psCallCount == 2)
    }

    @Test("A daemon with no host process is reported, not signalled")
    func notRunningIsReported() async throws {
        let runner = ScriptedRunner(ps: [.success("  PID   UID COMM\n    1     0 /sbin/launchd\n")])
        let actions = MaintenanceActions(runner: runner)
        await #expect(throws: MaintenanceError.daemonNotRunning("bird")) {
            _ = try await actions.restartDaemon(name: "bird")
        }
        #expect(await runner.killArguments.isEmpty)
    }

    // Fails on the old `try?`: a failing ps read as "no pids" and the button
    // said "bird is not running" about a daemon that was running fine.
    @Test("A failing ps before the signal is reported as itself, not as 'not running'")
    func psFailureBeforeSignalPropagates() async throws {
        let runner = ScriptedRunner(ps: [.failure(.timeout)])
        let actions = MaintenanceActions(runner: runner)
        await #expect(throws: RunnerError.timeout) {
            _ = try await actions.restartDaemon(name: "bird")
        }
        #expect(await runner.killArguments.isEmpty)
    }

    // Fails on the old `try?`: a failing ps after the signal read as "no new
    // pid" and the restart was reported as "respawn not observed".
    @Test("A failing ps during the respawn poll is reported, not read as 'respawn not observed'")
    func psFailureDuringPollPropagates() async throws {
        let failure = RunnerError.nonZeroExit(code: 1, stderr: "ps: boom")
        let runner = ScriptedRunner(ps: [.success(Self.ps(birdPID: 4242)), .failure(failure)])
        let actions = MaintenanceActions(runner: runner, respawnPollInterval: .zero)
        await #expect(throws: failure) {
            _ = try await actions.restartDaemon(name: "bird")
        }
        #expect(await runner.psCallCount == 2)
    }

    // Fails on the old `try? Task.sleep`: once the caller was cancelled the
    // sleep returned at once and the loop spawned ps back-to-back for the
    // whole 12 s window (and this test would then also run ~12 s).
    @Test("Cancelling the caller ends the respawn poll without another ps")
    func cancellationStopsThePoll() async throws {
        let runner = ScriptedRunner(ps: [.success(Self.ps(birdPID: 4242))], cancelOnKill: true)
        let actions = MaintenanceActions(runner: runner, respawnPollInterval: .seconds(1))
        let task = Task { try await actions.restartDaemon(name: "bird") }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await runner.killArguments == [["-TERM", "4242"]])
        #expect(await runner.psCallCount == 1)
    }
}
