import Foundation
import Testing
@testable import Birdwatch

// Each suite here pins one place the UI used to state a fabricated, capped or
// derived figure as a fact (C1/C2). Every test fails on the old behaviour —
// the old wording is quoted where it matters.

private func transfer(_ id: String, app: String = "a", location: String = "~", progress: Double) -> TransferItem {
    TransferItem(id: id, appID: app, name: id, location: location, sizeBytes: 10,
                 direction: .upload, progress: progress)
}

private func app(
    _ id: String, backend: SyncBackend = .cloudDocs, status: AppSyncStatus = .upToDate,
    itemCount: AppItemCount? = nil, pending: Int? = nil, size: LocalSize? = nil, lastActivity: Date? = nil
) -> AppSyncState {
    AppSyncState(
        id: id, name: id, tileColorHex: "0a84ff", backend: backend, isApple: true,
        status: status, statusLine: "", lastActivity: lastActivity,
        itemCount: itemCount, pendingItems: pending, localSize: size, locationPath: ""
    )
}

private func store(_ snapshot: SyncSnapshot, now: @escaping () -> Date = { Date() }) async -> SyncStore {
    let store = SyncStore(source: StubSyncSource(snapshot: snapshot), now: now, notifier: noBanners)
    await store.refresh(force: true)
    return store
}

// MARK: - 1. Boolean progress is never "Syncing 0%"

@MainActor
@Suite("Sync status display")
struct SyncStatusDisplayTests {
    @Test("A boolean-only syncing row reads \"Syncing…\" over an indeterminate bar, not \"Syncing 0%\"")
    func booleanProgressIsIndeterminate() {
        let display = SyncStatusDisplay(status: .syncing(progress: 0), backend: .cloudDocs, progressIsIndeterminate: true)
        #expect(display.label == "Syncing…")
        #expect(display.bar == .indeterminate)
        #expect(display.showsSpinner)
    }

    @Test("A zero mean is never a determinate 0%, even without the store's flag")
    func zeroIsNeverAMeasurement() {
        let display = SyncStatusDisplay(status: .syncing(progress: 0), backend: .cloudDocs, progressIsIndeterminate: false)
        #expect(display.label == "Syncing…")
        #expect(display.bar == .indeterminate)
    }

    @Test("A real fraction keeps its percentage")
    func realFractionIsDeterminate() {
        let display = SyncStatusDisplay(status: .syncing(progress: 0.42), backend: .cloudDocs, progressIsIndeterminate: false)
        #expect(display.label == "Syncing 42%")
        #expect(display.bar == .determinate(0.42))
    }

    @Test("CloudKit work without progress is \"Active\" with no bar")
    func activeHasNoBar() {
        let display = SyncStatusDisplay(status: .active, backend: .cloudDocs, progressIsIndeterminate: false)
        #expect(display.label == "Active")
        #expect(display.bar == nil)
        #expect(display.showsSpinner)
    }

    @Test("A Drive folder with only boolean transfers is indeterminate in the store")
    func folderIndeterminateDecision() async {
        var snap = SyncSnapshot.minimal()
        let inDesign = "~/Library/Mobile Documents/com~apple~CloudDocs/Design/sub"
        snap.transfers = [transfer("t1", location: inDesign, progress: 0)]
        snap.driveFolders = [DriveFolderSource.makeFolder(name: "Design", itemCount: 3, transferLocations: [inDesign])]
        let s = await store(snap)
        #expect(s.driveFolders[0].status == .syncing(progress: 0))
        #expect(s.progressIsIndeterminate(folderName: "Design"))
        #expect(!s.progressIsIndeterminate(folderName: "Notes"), "no transfers in the folder: nothing to be unsure about")
        let display = SyncStatusDisplay(status: s.driveFolders[0].status, backend: .cloudDocs,
                                        progressIsIndeterminate: s.progressIsIndeterminate(folderName: "Design"))
        #expect(display.label == "Syncing…")
    }
}

// MARK: - 2. Unreported counts and capped values

@MainActor
@Suite("Unreported and capped figures")
struct UnreportedFiguresTests {
    @Test("CloudKit rows say \"Not reported by cloudd\" instead of 0 items / None / Zero KB")
    func cloudKitNotReported() {
        let row = app("photos", backend: .cloudKit, status: .active)
        #expect(AppDetailFacts.itemTile(row) == ("Items", "Not reported by cloudd"))
        #expect(AppDetailFacts.pendingValue(row) == "Not reported by cloudd")
        #expect(AppDetailFacts.localSizeValue(row) == "Not reported by cloudd")
    }

    @Test("A CloudDocs row's size is \"Measuring…\" until the size pass lands")
    func cloudDocsSizeBeforePass() {
        let row = app("icloud-drive", pending: 0)
        #expect(AppDetailFacts.localSizeValue(row) == "Measuring…")
        #expect(AppDetailFacts.pendingValue(row) == "None", "bird's transfer count IS reported")
        #expect(AppDetailFacts.itemTile(row).value == "Not reported by bird")
    }

    @Test("An engine index keeps its label; a top-level listing does not borrow it")
    func itemLabels() {
        #expect(AppDetailFacts.itemTile(app("x", itemCount: .indexed(1_284))) == ("Items indexed", "1,284 items"))
        #expect(AppDetailFacts.itemTile(app("x", itemCount: .topLevel(7, isCapped: false))) == ("Top-level items", "7 items"))
    }

    @Test("Live CloudDocs and File Provider rows carry no placeholder zeros")
    func liveRowsHaveNoPlaceholders() {
        let apps = SystemSyncSource.buildApps(status: nil, transfers: [], fileProviderDomains: ["Dropbox"])
        let drive = apps.first { $0.id == "icloud-drive" }
        let dropbox = apps.first { $0.backend == .fileProvider }
        #expect(drive?.itemCount == nil)
        #expect(drive?.localSize == nil)
        #expect(drive?.pendingItems == 0)
        #expect(dropbox?.itemCount == nil)
        #expect(dropbox?.pendingItems == nil)
        #expect(dropbox?.localSize == nil)
    }

    @Test("A capped folder count reads \"500+ items\"; an unreadable folder is not \"0 items\"")
    func folderCounts() {
        let capped = DriveFolderSource.makeFolder(name: "Big", itemCount: 500, transferLocations: [], itemCountIsCapped: true)
        #expect(capped.itemCountText == "500+ items")
        // The cap survives re-deriving status from a cycle's transfers.
        #expect(DriveFolderSource.applying(transfers: [], to: [capped])[0].itemCountIsCapped)
        let unreadable = DriveFolderSource.makeFolder(name: "Locked", itemCount: nil, transferLocations: [])
        #expect(unreadable.itemCountText == "Not readable")
        #expect(DriveFolderSource.makeFolder(name: "One", itemCount: 1, transferLocations: []).itemCountText == "1 item")
    }

    @Test("A conflict scan that stops at its cap says so; a full scan does not")
    func conflictScanCap() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bw-conflict-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            try Data("x".utf8).write(to: root.appending(path: "file-\(index).txt"))
        }
        let capped = await ConflictSource.scanConflicts(root: root, maxItems: 2)
        #expect(capped?.isCapped == true)
        #expect(capped?.found.isEmpty == true)
        let full = await ConflictSource.scanConflicts(root: root, maxItems: 100)
        #expect(full?.isCapped == false)
    }

    @Test("The capped flag follows the last SUCCESSFUL conflict scan")
    func cappedFlagPropagates() {
        let source = SystemSyncSource()
        source.completeConflictScan([], resolvedBeforeScan: [], isCapped: true)
        #expect(source.conflictScanCapped)
        source.completeConflictScan(nil, resolvedBeforeScan: [])
        #expect(source.conflictScanCapped, "a failed scan keeps the previous result, cap and all")
        source.completeConflictScan([], resolvedBeforeScan: [], isCapped: false)
        #expect(!source.conflictScanCapped)
    }
}

// MARK: - 3. CloudKit activity is never "up to date"; idle is "no activity detected"

@MainActor
@Suite("Overall state and the hero")
struct OverallStateTests {
    @Test("A transferring CloudKit app makes the state .active, not \"all synced\"")
    func cloudKitActivityIsNotIdle() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let photos = app("photos", backend: .cloudKit, status: .active, lastActivity: now.addingTimeInterval(-30))
        let s = await store(.minimal(apps: [photos, app("notes")]), now: { now })
        #expect(s.overallState == .active(appCount: 1))
        let hero = OverviewHeroDisplay(state: s.overallState, progress: s.overallProgress,
                                       progressIsIndeterminate: s.overallProgressIsIndeterminate,
                                       inFlightCount: 0, pendingFileCount: 0)
        #expect(hero.title == "Activity in 1 app")
        #expect(hero.ring == .indeterminate)
        #expect(!hero.title.contains("up to date"))
    }

    @Test("Idle claims only what is known: \"No sync activity detected\"")
    func idleWording() {
        let hero = OverviewHeroDisplay(state: .idle, progress: 1, progressIsIndeterminate: false,
                                       inFlightCount: 0, pendingFileCount: 0)
        #expect(hero.title == "No sync activity detected")
        #expect(!hero.subtitle.contains("fully synced"))
        #expect(hero.ring == .idle)
        #expect(!hero.showsBar)
        #expect(PopoverSummary.headerTitle(.idle) == "No sync activity")
    }

    @Test("Paused shows a paused ring, never \"0% SYNCED\"")
    func pausedRing() async {
        let s = await store(.minimal(apps: [app("a", status: .syncing(progress: 0.4))]))
        s.togglePauseAll()
        #expect(s.overallProgress == 0, "the store's pause-aware progress is still 0…")
        let hero = OverviewHeroDisplay(state: s.overallState, progress: s.overallProgress,
                                       progressIsIndeterminate: s.overallProgressIsIndeterminate,
                                       inFlightCount: 0, pendingFileCount: 0)
        #expect(hero.ring == .paused, "…but the ring never renders it as a percentage")
        #expect(!hero.showsBar)
    }

    @Test("Syncing: plural-correct titles, percentage only when real")
    func syncingTitles() {
        let determinate = OverviewHeroDisplay(state: .syncing(appCount: 1), progress: 0.5,
                                              progressIsIndeterminate: false, inFlightCount: 2, pendingFileCount: 1)
        #expect(determinate.title == "Syncing 1 app")
        #expect(determinate.subtitle == "1 file remaining")
        #expect(determinate.ring == .percent(0.5))
        let boolean = OverviewHeroDisplay(state: .syncing(appCount: 2), progress: 0,
                                          progressIsIndeterminate: true, inFlightCount: 3, pendingFileCount: 3)
        #expect(boolean.title == "Syncing 3 files")
        #expect(boolean.ring == .indeterminate)
        #expect(boolean.barIsIndeterminate)
    }

    @Test("The popover's idle line uses the rows' own words per backend")
    func popoverIdleLine() {
        let mixed = [app("drive"), app("pages"), app("notes", backend: .cloudKit), app("box", backend: .fileProvider),
                     app("busy", status: .syncing(progress: 0.5))]
        #expect(PopoverSummary.idleAppsLine(mixed) == "2 apps up to date · 2 with no activity seen")
        #expect(PopoverSummary.idleAppsLine([app("notes", backend: .cloudKit)]) == "1 app with no activity seen")
        #expect(PopoverSummary.idleAppsLine([app("drive")]) == "1 app up to date")
        #expect(PopoverSummary.idleAppsLine([]) == nil)
    }

    @Test("Idle rows: \"Up to date\" only where the backend can confirm it")
    func idleLabelByBackend() {
        let drive = SyncStatusDisplay(status: .upToDate, backend: .cloudDocs, progressIsIndeterminate: false)
        #expect(drive.label == "Up to date")
        #expect(drive.tone == .confirmed)
        for backend in [SyncBackend.cloudKit, .fileProvider] {
            let display = SyncStatusDisplay(status: .upToDate, backend: backend, progressIsIndeterminate: false)
            #expect(display.label == "No activity seen")
            #expect(display.tone == .neutral, "never success green for an unconfirmable idle")
        }
    }

    @Test("Issue counts are plural-correct")
    func issuePlurals() {
        #expect(PopoverSummary.issuesLine(count: 1) == "1 issue needs attention")
        #expect(PopoverSummary.issuesLine(count: 3) == "3 issues need attention")
        #expect(Plural.count(1, "issue") == "1 issue")
    }
}

// MARK: - 4/5. Scan evidence

@MainActor
@Suite("Scan notices")
struct ScanNoticeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Each CloudKit outcome gets its own honest line")
    func cloudKitOutcomes() {
        func text(_ outcome: CloudKitScanOutcome, observedAt: Date? = nil, truncated: Bool = false) -> String? {
            CloudKitNotice.text(.scanned(outcome: outcome, isStale: observedAt != nil,
                                         observedAt: observedAt, isTruncated: truncated), now: now)
        }
        #expect(text(.observedApps) == nil)
        #expect(CloudKitNotice.text(.scanned(outcome: .observedApps, isStale: false, observedAt: now.addingTimeInterval(-10),
                                             isTruncated: false), now: now) == nil, "a fresh reading needs no age")
        #expect(CloudKitNotice.text(.scanned(outcome: .observedApps, isStale: false, observedAt: now.addingTimeInterval(-240),
                                             isTruncated: false), now: now)
                == "CloudKit status read from the system log 4m ago.")
        #expect(text(.noActivity) == "No CloudKit activity in the last 30 minutes.")
        #expect(text(.unattributed(containers: 4))?.contains("doesn't say which app") == true)
        #expect(text(.systemServicesOnly(attributed: 3, unattributed: 0))?.contains("only from system services") == true)
        #expect(text(.systemServicesOnly(attributed: 3, unattributed: 2))?.contains("2 containers") == true)
        #expect(text(.logUnavailable, observedAt: now.addingTimeInterval(-720))
                == "Couldn't read the system log — showing CloudKit results from 12m ago.")
        #expect(text(.logUnavailable)?.hasPrefix("Couldn't read the system log") == true)
        #expect(text(.observedApps, truncated: true)?.contains("newest activity may be missing") == true)
        #expect(CloudKitNotice.text(.scanning, now: now)?.contains("Reading the system log") == true)
        #expect(CloudKitNotice.text(nil, now: now) == nil, "fixture sources show no notice")
    }

    @Test("The scan outcome reaches the store instead of being dropped")
    func outcomeReachesStore() async {
        var snap = SyncSnapshot.minimal()
        snap.cloudKitScan = CloudKitScanState(CloudKitScan(apps: [], outcome: .unattributed(containers: 2), observedAt: now))
        snap.folderScan = ScanFreshness(completedAt: nil, isOverdue: true)
        snap.containerScan = ScanFreshness(completedAt: now, isOverdue: false)
        snap.conflictScanCap = 2_000
        snap.issueProducers = [.quota: []]
        let s = await store(snap)
        #expect(s.cloudKitScan == .scanned(outcome: .unattributed(containers: 2), isStale: false, observedAt: now, isTruncated: false))
        #expect(s.folderScan?.completedAt == nil)
        #expect(s.containerScan?.completedAt == now)
        #expect(s.conflictScanCap == 2_000)
        #expect(s.deliveredIssueProducers == [.quota])
    }

    @Test("An unreadable iCloud Drive root says so instead of an empty table")
    func unreadableRoot() {
        let notice = ScanFreshnessNotice.text(ScanFreshness(completedAt: now, isOverdue: false, isUnreadable: true),
                                              subject: "iCloud Drive folders", now: now)
        #expect(notice?.hasPrefix("Couldn't read iCloud Drive folders") == true)
    }

    @Test("Before the first scan lands: \"Still scanning\", not an empty list")
    func stillScanning() {
        #expect(ScanFreshnessNotice.text(ScanFreshness(completedAt: nil, isOverdue: true), subject: "iCloud Drive folders", now: now)
                == "Still scanning iCloud Drive folders…")
    }

    @Test("An overdue rescan states the result's age; a fresh one adds nothing")
    func overdue() {
        let old = ScanFreshness(completedAt: now.addingTimeInterval(-600), isOverdue: true)
        #expect(ScanFreshnessNotice.text(old, subject: "app containers", now: now)?.contains("last scanned 10m ago") == true)
        #expect(ScanFreshnessNotice.text(ScanFreshness(completedAt: now, isOverdue: false), subject: "x", now: now) == nil)
        #expect(ScanFreshnessNotice.text(nil, subject: "x", now: now) == nil)
    }
}

// MARK: - 6. Derived plan cap

@MainActor
@Suite("Derived plan cap labels")
struct StorageCapLabelTests {
    @Test("A derived cap is labelled in the footer, headline and VoiceOver")
    func derivedIsLabelled() {
        let figure = StorageFooterFigure.account(used: 147_000_000_000, cap: 200_000_000_000)
        #expect(StorageCapLabel.footerText(figure, capIsEstimated: true).hasPrefix("≈ "))
        #expect(StorageCapLabel.footerAccessibilityValue(figure, capIsEstimated: true).contains("estimated"))
        #expect(StorageCapLabel.accountHeadline(used: 1, cap: 2, capIsEstimated: true).contains("estimated plan"))
        #expect(StorageCapLabel.usageHeadline(used: 1, cap: 2, capIsEstimated: true).contains("estimated plan"))
        #expect(StorageCapLabel.availableText(1, capIsEstimated: true).hasPrefix("≈ "))
    }

    @Test("A chosen cap, or no cap, reads plainly")
    func chosenIsPlain() {
        let figure = StorageFooterFigure.local(used: 5_000_000_000, cap: 50_000_000_000)
        #expect(!StorageCapLabel.footerText(figure, capIsEstimated: false).contains("≈"))
        #expect(!StorageCapLabel.footerAccessibilityValue(figure, capIsEstimated: false).contains("estimated"))
        #expect(StorageCapLabel.footerText(.localOnly(used: 5_000_000_000), capIsEstimated: true) == "5.0 GB on this Mac",
                "no cap shown → nothing to label")
        #expect(StorageCapLabel.usageHeadline(used: 1, cap: nil, capIsEstimated: true).contains("on this Mac"))
    }
}

// MARK: - 7. Bandwidth

@MainActor
@Suite("Bandwidth honesty")
struct BandwidthHonestyTests {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private static func at(_ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: hour, minute: minute))!
    }

    @Test("A failed sample is \"Unavailable\", not a measured 0 B/s")
    func failedSampleIsUnavailable() {
        var s = BandwidthSource.advance(state: .init(), readings: [1: .init(bytesIn: 0, bytesOut: 0)],
                                        now: Self.at(10), calendar: Self.utc)
        s = BandwidthSource.advance(state: s, readings: [:], now: Self.at(10, 1), calendar: Self.utc, measured: false)
        let summary = BandwidthSource.summary(from: s)
        #expect(summary.lastSampleFailed)
        #expect(!summary.rateIsMeasured)
        #expect(BandwidthPresentation.rateText(summary) == "Unavailable")
    }

    @Test("The first sample is a baseline (\"Measuring…\"); two good samples make a rate")
    func baselineThenRate() {
        var s = BandwidthSource.advance(state: .init(), readings: [1: .init(bytesIn: 0, bytesOut: 0)],
                                        now: Self.at(10), calendar: Self.utc)
        #expect(BandwidthPresentation.rateText(BandwidthSource.summary(from: s)) == "Measuring…")
        s = BandwidthSource.advance(state: s, readings: [1: .init(bytesIn: 600, bytesOut: 0)],
                                    now: Self.at(10, 1), calendar: Self.utc)
        let summary = BandwidthSource.summary(from: s)
        #expect(summary.rateIsMeasured)
        #expect(BandwidthPresentation.rateText(summary) == "≈ \(Format.size(10))/s")
    }

    @Test("Only successfully sampled hours are observed")
    func observedHours() {
        var s = BandwidthSource.advance(state: .init(), readings: [1: .init(bytesIn: 0, bytesOut: 0)],
                                        now: Self.at(8, 59), calendar: Self.utc)
        #expect(!BandwidthSource.summary(from: s).hours[8].isObserved, "a baseline measures no traffic")
        s = BandwidthSource.advance(state: s, readings: [1: .init(bytesIn: 0, bytesOut: 0)],
                                    now: Self.at(9), calendar: Self.utc)
        s = BandwidthSource.advance(state: s, readings: [:], now: Self.at(11), calendar: Self.utc, measured: false)
        let hours = BandwidthSource.summary(from: s).hours
        #expect(hours[9].isObserved)
        #expect(!hours[10].isObserved, "never sampled")
        #expect(!hours[11].isObserved, "every sample in it failed")
        #expect(!hours[23].isObserved, "still to come")
    }

    @Test("Unobserved and silent hours draw nothing — no 2 pt stub")
    func noStubs() {
        #expect(BandwidthPresentation.barHeight(bytes: 0, isObserved: true, available: 90, maxBytes: 100) == 0)
        #expect(BandwidthPresentation.barHeight(bytes: 50, isObserved: false, available: 90, maxBytes: 100) == 0)
        #expect(BandwidthPresentation.barHeight(bytes: 1, isObserved: true, available: 90, maxBytes: 1_000) == 2)
    }

    @Test("An all-zero day names no \"busiest hour 0:00\"")
    func noFakeBusiestHour() {
        let zeros = (0..<24).map { BandwidthHourSample(hour: $0, uploadedBytes: 0, downloadedBytes: 0, isObserved: $0 >= 8 && $0 <= 10) }
        let value = BandwidthPresentation.chartSummary(zeros)
        #expect(!value.contains("busiest"))
        #expect(value.contains("no traffic recorded"))
        #expect(value.hasPrefix("Estimated"))
        let busy = zeros.map { $0.hour == 9 ? BandwidthHourSample(hour: 9, uploadedBytes: 5, downloadedBytes: 0) : $0 }
        #expect(BandwidthPresentation.chartSummary(busy).contains("busiest hour 9:00"))
        #expect(BandwidthPresentation.chartSummary([]) == "No hours observed yet today")
    }

    @Test("Totals carry the estimate mark, and the chart is not \"Last 24 hours\"")
    func labels() {
        let observed = [BandwidthHourSample(hour: 9, uploadedBytes: 0, downloadedBytes: 0, isObserved: true)]
        #expect(BandwidthPresentation.totalText(1_000, hours: observed).hasPrefix("≈ "))
        #expect(BandwidthPresentation.chartTitle == "Today, since Birdwatch started")
    }

    @Test("With no hour observed, totals are \"—\", not \"≈ Zero KB\"")
    func noObservationNoTotal() {
        let unobserved = (0..<24).map { BandwidthHourSample(hour: $0, uploadedBytes: 0, downloadedBytes: 0, isObserved: false) }
        #expect(BandwidthPresentation.totalText(0, hours: unobserved) == "—")
        #expect(BandwidthPresentation.totalText(0, hours: []) == "—")
    }

    @Test("The popover sparkline summary counts only observed hours")
    func sparklineObservedOnly() {
        let hours = [
            BandwidthHourSample(hour: 0, uploadedBytes: 0, downloadedBytes: 0, isObserved: false),
            BandwidthHourSample(hour: 1, uploadedBytes: 0, downloadedBytes: 0, isObserved: true),
        ]
        #expect(Sparkline.summary(of: hours) == "1 hour, no traffic recorded")
    }
}

// MARK: - 8. Devices, 9. Issues, 10. Freshness

@MainActor
@Suite("Headlines, empty states and freshness")
struct HeadlineTests {
    @Test("Devices states registered, writers and active separately, plural-correct")
    func devicesHeadline() {
        #expect(DevicesHeadline.text(registered: 5, wroteItems: 3, activeThisWeek: 1, countsArePartial: false)
                == "5 devices registered · 3 have written items · 1 active this week")
        #expect(DevicesHeadline.text(registered: 1, wroteItems: 1, activeThisWeek: 0, countsArePartial: false)
                == "1 device registered · 1 has written items · 0 active this week")
    }

    @Test("A truncated dump makes the writer and activity counts floors")
    func devicesPartial() {
        #expect(DevicesHeadline.text(registered: 34, wroteItems: 31, activeThisWeek: 4, countsArePartial: true)
                == "34 devices registered · at least 31 have written items · at least 4 active this week")
    }

    @Test("Issues empty state: clean only when nothing limits the answer")
    func issuesEmptyClean() {
        let clean = IssuesEmptyState(fullDiskAccess: .granted, isPaused: false,
                                     deliveredProducers: [.quota, .conflicts, .dump], conflictScanCap: nil)
        #expect(clean.title == "No issues detected")
        #expect(clean.isClean)
        #expect(!clean.lines.joined().contains("syncing normally"))
        #expect(IssuesEmptyState(fullDiskAccess: .granted, isPaused: false,
                                 deliveredProducers: nil, conflictScanCap: nil).isClean, "fixture: everything delivered")
    }

    @Test("Issues empty state names missing FDA, a paused monitor and a capped scan")
    func issuesEmptyQualified() {
        let state = IssuesEmptyState(fullDiskAccess: .denied, isPaused: true,
                                     deliveredProducers: [.quota, .conflicts, .dump], conflictScanCap: 2_000)
        #expect(!state.isClean)
        #expect(state.lines.count == 3)
        #expect(state.lines.contains { $0.contains("paused") })
        #expect(state.lines.contains { $0.contains("Full Disk Access") })
        #expect(state.lines.contains { $0.contains("2,000") })
        #expect(!IssuesEmptyState(fullDiskAccess: .unknown, isPaused: false,
                                  deliveredProducers: nil, conflictScanCap: nil).isClean)
    }

    @Test("Before the scans deliver, the empty state is not a green check")
    func issuesEmptyBeforeScans() {
        let state = IssuesEmptyState(fullDiskAccess: .granted, isPaused: false,
                                     deliveredProducers: [.quota], conflictScanCap: nil)
        #expect(!state.isClean)
        #expect(state.lines == ["The conflict scan hasn't completed yet.", "Sync engine state hasn't been read yet."])
    }

    @Test("Freshness is coarse and honest about never having loaded")
    func freshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(FreshnessLabel.text(lastRefresh: nil, now: now) == "Not updated yet")
        #expect(FreshnessLabel.text(lastRefresh: now.addingTimeInterval(-5), now: now) == "Updated just now")
        #expect(FreshnessLabel.text(lastRefresh: now.addingTimeInterval(-37), now: now) == "Updated 30s ago")
        #expect(FreshnessLabel.text(lastRefresh: now.addingTimeInterval(-180), now: now) == "Updated 3m ago")
    }

    @Test("The store exposes when the last snapshot landed")
    func lastRefreshExposed() async {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let s = SyncStore(source: StubSyncSource(snapshot: .minimal()), now: { fixed }, notifier: noBanners)
        #expect(s.lastRefresh == nil)
        await s.refresh(force: true)
        #expect(s.lastRefresh == fixed)
    }
}
