import Foundation
import Testing
import os
@testable import Birdwatch

/// Real `log show --info --style ndjson` lines for the `com.apple.cloudkit`
/// OP/CK categories, captured on macOS 27.0 GA (26A428) on 2026-10-05. The
/// raw lines are verbatim except: one in-development third-party app was
/// renamed (`/Applications/ExampleNotes.app`, container
/// `iCloud.com.example.notes`), and `bootUUID`, the binary-identifying
/// `processImageUUID` / `senderImageUUID` / backtrace `imageUUID`, and
/// `traceID` were zeroed. Account-identifying lines (accountsd) and
/// scratch-build paths were left out of the excerpt.
///
/// The point of the capture: macOS 27 GA logs NO `applicationBundleID=` TCC
/// lines at all, so the only attribution left is the emitting process.
private nonisolated func gaFixture() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/cloudkit-log-ga-27.0.ndjson")
    return try String(contentsOf: url, encoding: .utf8)
}

/// The uid every fixture line was logged under.
private nonisolated let fixtureUID = 501

private nonisolated let exampleNotesPath = "/Applications/ExampleNotes.app/Contents/MacOS/ExampleNotes"

/// What `CloudKitProcessResolver` returned for each fixture path on the
/// capture machine (measured live). `secd` carries no embedded identifier, so
/// it resolves to nothing — that container stays honestly unattributed.
private nonisolated func capturedResolution(_ path: String) -> String? {
    [
        exampleNotesPath: "com.example.notes",
        "/System/Library/PrivateFrameworks/CloudPhotoLibrary.framework/Versions/A/Support/cloudphotod": "com.apple.cloudphotod",
        "/System/Library/PrivateFrameworks/IMCore.framework/imagent.app/Contents/MacOS/imagent": "com.apple.imagent",
        "/System/Library/PrivateFrameworks/SyncedDefaults.framework/Support/syncdefaultsd": "com.apple.syncdefaultsd",
        "/System/Library/PrivateFrameworks/UsageTracking.framework/Versions/A/UsageTrackingAgent": "com.apple.UsageTrackingAgent",
        "/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird": "com.apple.bird",
        "/System/Volumes/Preboot/Cryptexes/App/usr/libexec/SafariBookmarksSyncAgent": "com.apple.SafariBookmarksSyncAgent",
        "/System/Volumes/Preboot/Cryptexes/App/usr/libexec/com.apple.Safari.History": "com.apple.Safari.History",
        "/System/iOSSupport/System/Library/PrivateFrameworks/HomeEnergyDaemon.framework/Support/homeenergyd": "com.apple.homeenergyd",
        helperPath: "com.example.notes.synchelper",
    ][path]
}

/// Installed-app lookup stand-in: only real user-facing apps have a name.
private nonisolated func installedName(_ bundleID: String) -> String? {
    [
        "com.apple.Safari": "Safari", "com.apple.Photos": "Photos",
        "com.apple.MobileSMS": "Messages", "com.example.notes": "Example Notes",
    ][bundleID]
}

/// Production's user-facing test, over the stand-in installed-app table.
private nonisolated func isUserFacing(_ bundleID: String) -> Bool {
    CloudKitAppMapping.userFacingBundleID(for: bundleID).flatMap(installedName) != nil
}

/// Inside the fixture: Safari History's ModifyRecords (19:29:17) is < 5 min old.
private nonisolated let gaNow = ISO8601DateFormatter().date(from: "2026-10-05T19:31:00-04:00")!

/// A vendor sync helper outside any .app — resolves to a bundle with no app.
private nonisolated let helperPath = "/Library/Application Support/ExampleVendor/ExampleSyncHelper"

/// The fixture plus a SECOND emitter for Example Notes' container: the real
/// cloudphotod and homeenergyd operation lines (6 of them), re-pointed at
/// `iCloud.com.example.notes` and emitted by a helper with no app. The app
/// itself emitted 4 lines, so a plain line-count vote hands the container to
/// the helper. Only the container value and process path are rewritten.
private nonisolated func twoEmitterFixture() throws -> String {
    let escapedHelper = helperPath.replacingOccurrences(of: "/", with: #"\/"#)
    return try gaFixture().split(separator: "\n").map { line -> String in
        let line = String(line)
        guard line.contains("container=com.apple.photos.cloud") || line.contains("container=com.apple.homekit.events")
        else { return line }
        return line
            .replacingOccurrences(of: "container=com.apple.photos.cloud", with: "container=iCloud.com.example.notes")
            .replacingOccurrences(of: "container=com.apple.homekit.events", with: "container=iCloud.com.example.notes")
            .replacingOccurrences(
                of: #"\/System\/Library\/PrivateFrameworks\/CloudPhotoLibrary.framework\/Versions\/A\/Support\/cloudphotod"#,
                with: escapedHelper)
            .replacingOccurrences(
                of: #"\/System\/iOSSupport\/System\/Library\/PrivateFrameworks\/HomeEnergyDaemon.framework\/Support\/homeenergyd"#,
                with: escapedHelper)
    }.joined(separator: "\n")
}

private nonisolated let cloudd = "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"

@Suite("CloudKit attribution on macOS 27 GA")
struct CloudKitGAAttributionTests {

    /// Documents the drift; passes on old AND new code (not a falsifier —
    /// `processAttribution` and `helperCannotOutvoteApp` are).
    @Test("GA logs carry no TCC lines, so TCC-only rules attribute nothing")
    func tccRulesFindNothingOnGA() throws {
        let text = try gaFixture()
        #expect(!text.contains("applicationBundleID="))
        #expect(CloudKitLogParser.parse(text, now: gaNow).isEmpty)
    }

    @Test("ndjson lines decode to message, timestamp and emitting process")
    func ndjsonLines() throws {
        let lines = CloudKitLogParser.lines(try gaFixture())
        // 31 captured events; the empty-resource error mentions neither a
        // container nor an operation and is gated out before any JSON decode.
        #expect(lines.count == 30)
        #expect(lines.allSatisfy { $0.processImagePath != nil && $0.date != nil })
        #expect(!lines.contains { $0.text.contains("empty collection of resources") })
    }

    // FALSIFIER (C3): the pre-27 code attributed nothing here.
    @Test("Process evidence attributes the real GA containers to their emitting bundles")
    func processAttribution() throws {
        let map = CloudKitLogParser.containerActivity(try gaFixture(), bundleForImage: capturedResolution)
        #expect(map["com.apple.photos.cloud"]?.bundleID == "com.apple.cloudphotod")
        #expect(map["com.apple.SafariShared.CloudTabs"]?.bundleID == "com.apple.SafariBookmarksSyncAgent")
        #expect(map["com.apple.SafariShared.Settings"]?.bundleID == "com.apple.SafariBookmarksSyncAgent")
        #expect(map["com.apple.SafariShared.History"]?.bundleID == "com.apple.Safari.History")
        #expect(map["com.apple.messages.cloud"]?.bundleID == "com.apple.imagent")
        #expect(map["iCloud.com.example.notes"]?.bundleID == "com.example.notes")
        #expect(map["com.apple.clouddocs"]?.bundleID == "com.apple.bird")
        // secd's executable carries no identifier: seen, but never invented.
        #expect(map["com.apple.security.keychain"] != nil)
        #expect(map["com.apple.security.keychain"]?.bundleID == nil)
        #expect(map.count == 11)
    }

    // FALSIFIER: with a plain line-count vote the helper (6 lines) owned the
    // container, was then dropped as app-less, and Example Notes vanished.
    @Test("A chatty app-less helper cannot outvote the real app for its container")
    func helperCannotOutvoteApp() throws {
        let text = try twoEmitterFixture()
        let voteOnly = CloudKitLogParser.containerActivity(text, bundleForImage: capturedResolution)
        #expect(voteOnly["iCloud.com.example.notes"]?.bundleID == "com.example.notes.synchelper")
        let map = CloudKitLogParser.containerActivity(
            text, bundleForImage: capturedResolution, isUserFacing: isUserFacing)
        #expect(map["iCloud.com.example.notes"]?.bundleID == "com.example.notes")
    }

    @Test("Each distinct process path is resolved once")
    func resolverCalledOncePerPath() throws {
        var calls: [String: Int] = [:]
        _ = CloudKitLogParser.containerActivity(try gaFixture()) { path in
            calls[path, default: 0] += 1
            return capturedResolution(path)
        }
        #expect(!calls.isEmpty)
        #expect(calls.values.allSatisfy { $0 == 1 })
    }

    @Test("cloudd never owns a container, even when it logs `container=`")
    func clouddIsNeverOwner() throws {
        let photoLine = try #require(try gaFixture().split(separator: "\n")
            .first { $0.contains("cloudphotod") && $0.contains("container=") })
        let asCloudd = photoLine.replacingOccurrences(
            of: #"\/System\/Library\/PrivateFrameworks\/CloudPhotoLibrary.framework\/Versions\/A\/Support\/cloudphotod"#,
            with: cloudd.replacingOccurrences(of: "/", with: #"\/"#))
        #expect(asCloudd != String(photoLine))
        let map = CloudKitLogParser.containerActivity(asCloudd) { _ in "com.apple.cloudd" }
        #expect(map["com.apple.photos.cloud"] != nil)          // activity still counted
        #expect(map["com.apple.photos.cloud"]?.bundleID == nil) // but never "owned" by cloudd
    }

    @Test("Events logged by another uid (fast user switching) are ignored")
    func otherUsersAreIgnored() throws {
        let text = try gaFixture().split(separator: "\n").map { line in
            line.contains("ExampleNotes")
                ? line.replacingOccurrences(of: "\"userID\":501", with: "\"userID\":502")
                : String(line)
        }.joined(separator: "\n")
        let mine = CloudKitLogParser.containerActivity(text, userID: fixtureUID, bundleForImage: capturedResolution)
        #expect(mine["iCloud.com.example.notes"] == nil)
        #expect(mine["com.apple.photos.cloud"]?.bundleID == "com.apple.cloudphotod")
        let theirs = CloudKitLogParser.containerActivity(text, userID: 502, bundleForImage: capturedResolution)
        #expect(theirs.keys.sorted() == ["iCloud.com.example.notes"])
    }

    @Test("A cloudd TCC statement outranks process evidence for the same container")
    func tccOutranksProcess() throws {
        let tcc = "2026-10-05 19:00:00.000000-0400 0x1 Info 0x1 1031 0 cloudd: (CloudKitDaemon) [com.apple.cloudkit:CK] TCC approved access for container containerID=com.apple.photos.cloud:Production, applicationID=<CKDApplicationID: 0x1; applicationBundleID=com.apple.Photos>"
        let map = CloudKitLogParser.containerActivity(tcc + "\n" + (try gaFixture()), bundleForImage: capturedResolution)
        #expect(map["com.apple.photos.cloud"]?.bundleID == "com.apple.Photos")
    }

    @Test("Field values stop at newline, closing brace and closing paren", arguments: [
        ("resolvedConfig={ timeoutForRequest=60, container=iCloud.com.example.notes}", "iCloud.com.example.notes"),
        ("(container=iCloud.com.example.notes)", "iCloud.com.example.notes"),
        ("container=com.apple.UsageTracking:Production\n    \"com.apple.UsageTrackingAgent\"", "com.apple.UsageTracking:Production"),
    ])
    func valueTerminators(pair: (String, String)) {
        #expect(CloudKitLogParser.value(of: "container", in: Substring(pair.0)) == pair.1)
    }

    @Test("Safari's two sync agents merge into one Safari activity with every container")
    func safariAliasesMerge() throws {
        let activities = CloudKitLogParser.parse(try gaFixture(), now: gaNow, bundleForImage: capturedResolution)
        let merged = CloudKitAppMapping.mergedByUserFacingApp(activities)
        let safari = try #require(merged["com.apple.Safari"])
        #expect(safari.containers == [
            "com.apple.SafariShared.CloudTabs", "com.apple.SafariShared.History", "com.apple.SafariShared.Settings",
        ])
        #expect(safari.state == .pushing)       // History's ModifyRecords, 103 s before gaNow
        #expect(merged["com.apple.MobileSMS"] != nil)
        #expect(merged["com.apple.bird"] == nil)
    }

    @Test("Resolver: the outermost enclosing .app's bundle id")
    func resolverUsesOutermostApp() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ck-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appending(path: "Outer.app/Contents")
        let helper = outer.appending(path: "Library/LoginItems/Helper.app/Contents")
        for (contents, id) in [(outer, "com.example.outer"), (helper, "com.example.outer.helper")] {
            try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "x"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
        }
        let helperExe = helper.appending(path: "MacOS/x").path
        #expect(CloudKitProcessResolver.bundleID(forProcessImagePath: helperExe) == "com.example.outer")
        #expect(CloudKitProcessResolver.bundleID(forProcessImagePath: root.appending(path: "nope/daemon").path) == nil)
    }

    /// Reads the HOST's cloudd binary — a bare Mach-O with an embedded
    /// `__info_plist`, which a test cannot fabricate without a compiler. Skips
    /// (rather than fails) on a host where that binary is absent.
    @Test("Resolver: a bare daemon resolves through its embedded Info.plist",
          .enabled(if: FileManager.default.fileExists(atPath: cloudd), "host has no cloudd binary at the expected path"))
    func resolverReadsEmbeddedPlist() {
        #expect(CloudKitProcessResolver.bundleID(forProcessImagePath: cloudd) == "com.apple.cloudd")
    }
}

@Suite("CloudKit scan outcome")
struct CloudKitScanOutcomeTests {

    /// Replays one canned result per spawn, in order; records the arguments.
    actor StubRunner: ProcessRunning {
        private(set) var calls: [[String]] = []
        private(set) var timeouts: [Duration] = []
        private var results: [Result<String, RunnerError>]

        init(_ results: [Result<String, RunnerError>]) { self.results = results }

        func run(toolPath: String, arguments: [String], timeout: Duration) async throws -> String {
            calls.append(arguments)
            timeouts.append(timeout)
            return try (results.isEmpty ? .success("") : results.removeFirst()).get()
        }
    }

    private static func source(
        _ results: [Result<String, RunnerError>],
        resolveImage: @escaping @Sendable (String) -> String? = capturedResolution,
        resolveAppName: @escaping @Sendable (String) -> String? = installedName
    ) -> (CloudKitAppSource, StubRunner) {
        let runner = StubRunner(results)
        return (CloudKitAppSource(runner: runner, resolveImage: resolveImage,
                                  resolveAppName: resolveAppName, userID: fixtureUID), runner)
    }

    @Test("Real GA evidence yields real app rows, daemons and bird excluded")
    func observedRows() async throws {
        let (source, runner) = Self.source([.success(try gaFixture())])
        let scan = await source.scan(now: gaNow)
        #expect(scan.outcome == .observedApps)
        #expect(scan.apps.map(\.name) == ["Example Notes", "Messages", "Photos", "Safari"])
        #expect(scan.apps.first { $0.id == "safari" }?.statusLine == "Pushing changes")
        #expect(!scan.isStale && !scan.isTruncated && scan.observedAt == gaNow)
        let arguments = try #require(await runner.calls.first)
        #expect(arguments.contains("ndjson"))
        #expect(arguments.contains("--info"))
    }

    @Test("The real app keeps its row when an app-less helper emits more lines")
    func helperDoesNotHideRow() async throws {
        let (source, _) = Self.source([.success(try twoEmitterFixture())])
        let scan = await source.scan(now: gaNow)
        #expect(scan.apps.contains { $0.name == "Example Notes" })
    }

    @Test("Activity with no attributable evidence is reported, not shown as 'no apps'")
    func unattributed() async throws {
        let (source, _) = Self.source([.success(try gaFixture())], resolveImage: { _ in nil })
        let scan = await source.scan(now: gaNow)
        #expect(scan.apps.isEmpty)
        #expect(scan.outcome == .unattributed(containers: 11))
    }

    @Test("System-services-only still carries the unattributed count")
    func systemServicesOnly() async throws {
        let (source, _) = Self.source([.success(try gaFixture())], resolveAppName: { _ in nil })
        let scan = await source.scan(now: gaNow)
        #expect(scan.apps.isEmpty)
        #expect(scan.outcome == .systemServicesOnly(attributed: 10, unattributed: 1))   // secd's keychain
    }

    @Test("An empty window is no activity; a failed first scan is log-unavailable with no rows")
    func emptyAndFailed() async {
        let empty = await Self.source([.success("")]).0.scan(now: gaNow)
        #expect(empty.outcome == .noActivity)
        let failed = await Self.source([.failure(.launchFailed("x"))]).0.scan(now: gaNow)
        #expect(failed.outcome == .logUnavailable)
        #expect(failed.apps.isEmpty)
        #expect(!failed.isStale)
        #expect(failed.observedAt == nil)
    }

    @Test("A failed scan keeps the last good rows and says they are stale")
    func failureKeepsLastGoodRows() async throws {
        let (source, _) = Self.source([.success(try gaFixture()), .failure(.nonZeroExit(code: 1, stderr: ""))])
        let good = await source.scan(now: gaNow)
        let later = gaNow.addingTimeInterval(300)
        let failed = await source.scan(now: later)
        #expect(failed.outcome == .logUnavailable)
        #expect(failed.isStale)
        #expect(failed.apps == good.apps)
        #expect(failed.observedAt == gaNow)
    }

    @Test("currentApps returns the last good rows, not [], when the log read fails")
    func currentAppsSurvivesFailure() async throws {
        let (source, _) = Self.source([.success(try gaFixture()), .failure(.launchFailed("x"))])
        let first = await source.currentApps(now: gaNow)
        let second = await source.currentApps(now: gaNow)
        #expect(!first.isEmpty)
        #expect(second == first)
    }

    @Test("A window that overruns the capture cap is re-read over the shorter window")
    func cappedWindowFallsBack() async throws {
        let capped = String(repeating: "x", count: ProcessRunner.maxCapturedBytes)
        let (source, runner) = Self.source([.success(capped), .success(try gaFixture())])
        let scan = await source.scan(now: gaNow)
        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls.first?.contains(CloudKitAppSource.window) == true)
        #expect(calls.last?.contains(CloudKitAppSource.fallbackWindow) == true)
        #expect(scan.outcome == .observedApps)
        #expect(!scan.isTruncated)
    }

    @Test("A fallback read that ALSO overruns the cap is flagged truncated")
    func cappedFallbackIsFlagged() async throws {
        let capped = String(repeating: "x", count: ProcessRunner.maxCapturedBytes)
        let (source, runner) = Self.source([.success(capped), .success(capped + "\n" + (try gaFixture()))])
        let scan = await source.scan(now: gaNow)
        #expect(await runner.calls.count == 2)
        #expect(scan.isTruncated)
    }

    @Test("A timed-out 30m read falls back to 10m, with a bounded total timeout")
    func timeoutFallsBack() async throws {
        let (source, runner) = Self.source([.failure(.timeout), .success(try gaFixture())])
        let scan = await source.scan(now: gaNow)
        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls.last?.contains(CloudKitAppSource.fallbackWindow) == true)
        #expect(scan.outcome == .observedApps)
        let total = await runner.timeouts.reduce(Duration.zero, +)
        #expect(total <= .seconds(30))
    }

    @Test("Launch failures are not retried over the short window")
    func launchFailureNotRetried() async {
        let (source, runner) = Self.source([.failure(.launchFailed("x")), .success("")])
        _ = await source.scan(now: gaNow)
        #expect(await runner.calls.count == 1)
    }

    @Test("Failed lookups are retried next scan (an app installed mid-session gets its row)")
    func missesAreNotCached() async throws {
        let installed = OSAllocatedUnfairLock(initialState: false)
        let (source, _) = Self.source(
            [.success(try gaFixture()), .success(try gaFixture())],
            resolveImage: { path in
                path == exampleNotesPath && !installed.withLock({ $0 }) ? nil : capturedResolution(path)
            },
            resolveAppName: { bundle in
                bundle == "com.example.notes" && !installed.withLock({ $0 }) ? nil : installedName(bundle)
            }
        )
        let before = await source.scan(now: gaNow)
        #expect(!before.apps.contains { $0.name == "Example Notes" })
        installed.withLock { $0 = true }
        let after = await source.scan(now: gaNow)
        #expect(after.apps.contains { $0.name == "Example Notes" })
    }
}
