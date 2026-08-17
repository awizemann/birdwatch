import Foundation
import Testing
@testable import Birdwatch

/// Hand-redacted excerpt of a real `brctl dump -i` capture (macOS 26 / bird
/// 5168.0.55). Personal file names replaced with REDACTED-N.ext; bird's own
/// length-redactions (`A{15}o`) left intact because the parser must cope with them.
private nonisolated func dumpFixture() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/brctl-dump-excerpt.txt")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("BrctlDumpParser")
struct BrctlDumpParserTests {

    // MARK: - Header

    @Test func parsesHeaderAndTruncationFlag() throws {
        let dump = BrctlDumpParser.parse(try dumpFixture())

        #expect(dump.databaseVersion == 34104)
        #expect(dump.fsType == "FPFS")
        #expect(dump.itemsTruncated == true)
        #expect(dump.accountSessionError?.hasPrefix("Can't get persona") == true)

        let expected = try #require(ISO8601DateFormatter().date(from: "2026-08-15T00:52:23Z"))
        let actual = try #require(dump.dumpDate)
        #expect(abs(actual.timeIntervalSince(expected)) < 1)
    }

    // MARK: - Retry queue

    @Test func extractsRetryQueueWithAttemptCounts() throws {
        let dump = BrctlDumpParser.parse(try dumpFixture())

        // Three non-idle items plus one idle item that carries a live `apply`
        // retry. The two idle items whose only annotation is `{[1 old]}` are dropped.
        #expect(dump.pendingItems.count == 4)
        #expect(dump.pendingItems.map(\.uploadState)
            == ["needs-upload", "needs-sync-up", "needs-sync-up", "idle"])

        // Only the item with attempts:3 counts as retrying — attempts:0 is a
        // first try, not a retry, and attempts:1 on the apply is.
        let retrying = dump.retryingItems.map(\.itemID)
        #expect(retrying == ["documents[148]", "15478C83"])
    }

    @Test func parsesScheduledSyncUpOperation() throws {
        let line = "> sync-up{[zone:1 sync-up-scheduled attempts:3 last:12.5m ago next:4.25m cleanup:ready]}"
        let operation = try #require(BrctlDumpParser.parseOperationLine(line))

        #expect(operation.kind == .syncUp)
        #expect(operation.zone == 1)
        #expect(operation.state == "sync-up-scheduled")
        #expect(operation.attempts == 3)
        #expect(operation.lastAttemptAgo == 750)
        #expect(operation.isReadyToRetry == false)
        #expect(operation.nextRetryIn == 255)
        // `cleanup:ready` is not a duration — must be nil, not 0.
        #expect(operation.cleanupIn == nil)
        #expect(operation.isRetrying == true)
        #expect(operation.supersededCount == nil)
    }

    @Test func distinguishesActiveFromInactiveOperations() throws {
        let active = try #require(BrctlDumpParser.parseOperationLine(
            "> upload{[ active attempts:0 last:7.56s ago next:ready cleanup:59.87m]}"))
        #expect(active.isActive == true)
        #expect(active.isRetrying == false)
        #expect(active.isReadyToRetry == true)
        #expect(active.lastAttemptAgo == 7.56)
        let cleanup = try #require(active.cleanupIn)
        #expect(cleanup == 59.87 * 60)

        // "inactive" must not be read as "active" by substring match.
        let inactive = try #require(BrctlDumpParser.parseOperationLine(
            "> apply{[ inactive attempts:1 last:3.83m ago cleanup:56.15m]}"))
        #expect(inactive.kind == .apply)
        #expect(inactive.isActive == false)
        #expect(inactive.isRetrying == true)
        #expect(inactive.isReadyToRetry == false)
        #expect(inactive.nextRetryIn == nil)
    }

    @Test func supersededRecordsCarryNoSchedulingState() throws {
        let operation = try #require(BrctlDumpParser.parseOperationLine("> upload{[1 old]}"))
        #expect(operation.supersededCount == 1)
        #expect(operation.attempts == nil)
        #expect(operation.state == nil)
        #expect(operation.isRetrying == false)
    }

    @Test func unknownOperationKindDegradesInsteadOfFailing() throws {
        let operation = try #require(BrctlDumpParser.parseOperationLine(
            "> future-op{[ inactive attempts:9 last:1.5d ago next:ready cleanup:ready]}"))
        #expect(operation.kind == .unknown)
        #expect(operation.attempts == 9)
        #expect(operation.lastAttemptAgo == 129_600)
    }

    @Test func parsesUploadProgressAggregate() throws {
        let dump = BrctlDumpParser.parse(try dumpFixture())
        let item = try #require(dump.pendingItems.first { $0.itemID == "E0A2E171" })
        let progress = try #require(item.progress)

        #expect(progress.kind == .upload)
        #expect(progress.needsCount == 1)
        #expect(progress.needsBytes == 62_914_560)
        #expect(progress.doneCount == 0)
        // "0 bytes" has no parenthesised exact count — must still read as 0.
        #expect(progress.doneBytes == 0)

        // Exact bytes come from the parentheses, never the "62.9 MB" prefix.
        #expect(item.byteSize == 62_914_560)
        #expect(item.fileExtension == "bin")
        #expect(item.attempts == 0)
    }

    @Test func itemLineKeepsOnlyExtensionFromRedactedName() throws {
        let dump = BrctlDumpParser.parse(try dumpFixture())
        let directory = try #require(dump.pendingItems.first { $0.itemID == "documents[171]" })

        #expect(directory.isDirectory == true)
        #expect(directory.fileExtension == nil)
        #expect(directory.byteSize == nil)
        #expect(directory.appLibraryID == 171)
        #expect(directory.rank == 1_338_265)
    }

    @Test func operationsAreNotMisattributedAcrossItems() throws {
        // A `>` line following a non-item line must be discarded rather than
        // attached to whichever item was seen last.
        let text = """
        1 containers matching '*'
        -----------------------------------------------------
        r:1 i:<AAAA> al:1 up:needs-upload uv:1 st{p:<root[1]> n:"REDACTED-1.bin" doc}
        ----------------------c{1}m.a{3}e.C{7}s[1]----------------------
        > upload{[ active attempts:7 last:1.0m ago next:ready cleanup:ready]}
        """
        let dump = BrctlDumpParser.parse(text)
        #expect(dump.pendingItems.count == 1)
        #expect(dump.pendingItems[0].operations.isEmpty)
        #expect(dump.pendingItems[0].attempts == 0)
    }

    // MARK: - Sync engine internals

    @Test func parsesSchedulerBlock() throws {
        let scheduler = BrctlDumpParser.parse(try dumpFixture()).scheduler

        #expect(scheduler.clientItemCount == 133_111)
        #expect(scheduler.serverItemCount == 133_000)
        #expect(scheduler.outputMayBeTruncated == true)
        #expect(scheduler.pushEnvironment == "production")
        #expect(scheduler.availableQuotaBytes == 223_208_176_210)
        #expect(scheduler.periodicSync == "idle")
        #expect(scheduler.pcsMigration == "complete")
        #expect(scheduler.isIdle == false)
        #expect(scheduler.syncStatusFlags == ["itemsNeedUpload", "nonIdleItems"])
    }

    @Test func parsesBothBudgetSpellings() throws {
        let scheduler = try #require(BrctlDumpParser.parse(try dumpFixture()).scheduler.budget)
        #expect(scheduler.verdict == "budget available")
        #expect(scheduler.measuredAgo == 70)
        #expect(scheduler.hourUsedPercent == 0.0)
        #expect(scheduler.hourValue == 20.0)
        #expect(scheduler.dayValue == 98.7)

        // The client_state spelling has no percentages: the bare number is the
        // value, not a percent.
        let throttle = try #require(BrctlDumpParser.parseBudget("<BRCSyncBudgetThrottle {  m:0.0  h:19.6  d:98.3  }>"))
        #expect(throttle.hourUsedPercent == nil)
        #expect(throttle.hourValue == 19.6)
        #expect(throttle.dayValue == 98.3)
        #expect(throttle.measuredAgo == nil)
    }

    @Test func parsesClientStateTokensAndSpace() throws {
        let state = BrctlDumpParser.parse(try dumpFixture()).clientState

        #expect(state.availableQuotaBytes == 223_208_176_210)
        #expect(state.nonPurgeableSpaceBytes == 249_667_584)
        #expect(state.purgeableSpaceBytes == 0)
        #expect(state.hasCompletedPCSMigration == true)
        #expect(state.serverChangeToken == "HwoDCK4NGAAiFgimn5XE2LjJ99QBEJ7spvKu/8D+twEoAA==")
        #expect(state.lastMetadataSyncDate != nil)
        #expect(state.budget?.hourValue == 19.6)

        let quotaFetch = try #require(ISO8601DateFormatter().date(from: "2026-06-02T02:48:22Z"))
        #expect(state.lastQuotaFetchDate == quotaFetch)
    }

    @Test func parsesGlobalProgress() throws {
        let progress = try #require(BrctlDumpParser.parse(try dumpFixture()).globalProgress)
        #expect(progress.fraction == 0.5742)
        #expect(progress.uploadedBytes == 37_932_224)
        #expect(progress.totalBytes == 66_060_288)

        #expect(BrctlDumpParser.parseGlobalProgress("global progress {none}") == nil)
    }

    @Test func parsesSystemBlock() throws {
        let system = BrctlDumpParser.parse(try dumpFixture()).system
        #expect(system.network == "online")
        #expect(system.disk == "healthy (APFS)")
        #expect(system.power == "healthy")
        #expect(system.optimizeStorage == "disabled")
        #expect(system.cellular == "enabled")
        #expect(system.redactedDeviceName == "A{15}o")
    }

    // MARK: - Error states

    @Test func syncHealthReportDropsNoneAndKeepsRealErrors() throws {
        let health = BrctlDumpParser.parse(try dumpFixture()).syncHealth
        #expect(health.isHealthy == false)
        #expect(health.errors.count == 1)
        #expect(health.errors["syncUpError"]?.contains("throttled") == true)
        #expect(health.errors["uploadError"] == nil)
    }

    // MARK: - Devices

    @Test func deviceNamesAreFlaggedAsRedacted() throws {
        let devices = BrctlDumpParser.parse(try dumpFixture()).devices
        #expect(devices.count == 5)
        #expect(devices.map(\.index) == [1, 2, 5, 8, 30])
        // Every name bird prints here is length-redacted; the flag exists so the
        // UI can refuse to display them.
        #expect(devices.filter(\.nameIsRedacted).count == devices.count)
        #expect(devices[2].redactedName == "A{15}o")

        // A hypothetical unredacted name must not be flagged.
        let plain = try #require(BrctlDumpParser.parseDeviceLine(#"o "Studio Display" (7)"#))
        #expect(plain.nameIsRedacted == false)
        #expect(plain.index == 7)
    }

    @Test func derivesDeviceActivityFromItemLines() throws {
        let dump = BrctlDumpParser.parse(try dumpFixture())
        let byIndex = Dictionary(uniqueKeysWithValues: dump.deviceActivity.map { ($0.index, $0) })

        // device:11 authored two items; the later mt wins.
        let eleven = try #require(byIndex[11])
        #expect(eleven.itemCount == 2)
        #expect(eleven.lastModified == Date(timeIntervalSince1970: 1_773_707_197))

        #expect(byIndex[30]?.itemCount == 1)
        // device:0 is bird's placeholder on a not-yet-uploaded item. It is
        // collected like any other index; callers must exclude it before
        // presenting a device list.
        #expect(byIndex[0]?.itemCount == 1)
    }

    // MARK: - Robustness

    @Test func toleratesEmptyAndGarbageInput() {
        #expect(BrctlDumpParser.parse("") == BrctlDump())

        let garbage = BrctlDumpParser.parse("????\n> \nup:\ndevices:\n  o \"\" (x)\n")
        #expect(garbage.pendingItems.isEmpty)
        #expect(garbage.devices.isEmpty)
    }

    @Test func stripsANSIBeforeTokenizing() throws {
        let colored = "1 containers matching '*'\n"
            + "r:9 i:<BBBB> al:1 up:\u{1B}[31mneeds-upload\u{1B}[39m uv:1 st{n:\"REDACTED-9.pdf\" doc}"
        let dump = BrctlDumpParser.parse(colored)
        #expect(dump.pendingItems.first?.uploadState == "needs-upload")
        #expect(dump.pendingItems.first?.fileExtension == "pdf")
    }

    @Test func durationUnitsAndNonDurations() {
        #expect(BrctlDumpParser.parseDuration("7.56s") == 7.56)
        let minutes = BrctlDumpParser.parseDuration("3.83m") ?? 0
        #expect(abs(minutes - 229.8) < 0.0001)
        #expect(BrctlDumpParser.parseDuration("1805.75h") == 1_805.75 * 3600)
        #expect(BrctlDumpParser.parseDuration("2.5d") == 216_000)
        #expect(BrctlDumpParser.parseDuration("ready") == nil)
        #expect(BrctlDumpParser.parseDuration("") == nil)
    }
}

// MARK: - App-library identifiers

@Suite("BrctlDumpParser app libraries")
struct BrctlDumpAppLibraryTests {

    @Test func parsesBlockHeaderIdentifier() throws {
        let parsed = try #require(BrctlDumpParser.parseAppLibraryIdentifier(
            "----------------------i{4}d.c{1}m.m{7}t.O{4}e.E{3}l[171]----------------------"
        ))
        #expect(parsed.pattern == "i{4}d.c{1}m.m{7}t.O{4}e.E{3}l")
        #expect(parsed.id == 171)
    }

    @Test func parsesAppLibraryListIdentifier() throws {
        let parsed = try #require(BrctlDumpParser.parseAppLibraryIdentifier(
            "+ app library: <c{1}m.a{3}e.s{5}x[51] NA {s:no-documents|l-root} ino:(null)>"
        ))
        #expect(parsed.pattern == "c{1}m.a{3}e.s{5}x")
        #expect(parsed.id == 51)
    }

    @Test func nonHeaderLinesAreNotIdentifiers() {
        #expect(BrctlDumpParser.parseAppLibraryIdentifier("-----------------------------------------------------") == nil)
        #expect(BrctlDumpParser.parseAppLibraryIdentifier("+ sync status: idle") == nil)
        #expect(BrctlDumpParser.parseAppLibraryIdentifier("r:0 i:<root[1]> al:1 up:idle") == nil)
    }

    @Test func headerIsFoldedOntoEachItemInTheBlock() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/brctl-dump-excerpt.txt")
        let dump = BrctlDumpParser.parse(try String(contentsOf: url, encoding: .utf8))

        #expect(dump.appLibraryPatterns[171] == "i{4}d.c{1}m.m{7}t.O{4}e.E{3}l")
        #expect(dump.appLibraryPatterns[148] == "i{4}d.c{1}m.f{7}s.c{5}p")

        let excel = try #require(dump.pendingItems.first { $0.itemID == "documents[171]" })
        #expect(excel.containerPattern == "i{4}d.c{1}m.m{7}t.O{4}e.E{3}l")
        // A header line must not swallow the operation line of the item before it.
        let upload = try #require(dump.pendingItems.first { $0.itemID == "E0A2E171" })
        #expect(upload.progress?.needsCount == 1)
        #expect(upload.containerPattern == "c{1}m.a{3}e.C{7}s")
    }
}
