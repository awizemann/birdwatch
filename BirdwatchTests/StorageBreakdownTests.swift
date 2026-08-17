import Foundation
import Testing
@testable import Birdwatch

@Suite("Storage breakdown — classification")
struct StorageCategoryTests {

    @Test("Documents extensions", arguments: [
        "pdf", "pages", "doc", "docx", "txt", "md", "key", "numbers", "xls", "xlsx", "rtf", "csv", "epub",
    ])
    func documents(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .documents)
    }

    @Test("Image extensions", arguments: [
        "jpg", "jpeg", "png", "heic", "gif", "tiff", "psd", "svg", "webp", "dng",
    ])
    func images(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .images)
    }

    @Test("Video extensions", arguments: ["mov", "mp4", "m4v", "avi", "mkv", "webm"])
    func video(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .video)
    }

    @Test("Audio extensions", arguments: ["mp3", "m4a", "wav", "aac", "flac", "aiff"])
    func audio(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .audio)
    }

    @Test("Archive extensions", arguments: ["zip", "dmg", "tar", "gz", "7z", "pkg", "iso"])
    func archives(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .archives)
    }

    @Test("Code & data extensions", arguments: [
        "swift", "js", "py", "json", "sqlite", "db", "plist", "yaml", "html", "sh",
    ])
    func codeData(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .codeData)
    }

    @Test("Package extensions", arguments: ["app", "photoslibrary", "bundle", "framework", "xcodeproj"])
    func packages(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .appsPackages)
    }

    @Test("Unknown and empty extensions fall to Other", arguments: ["", "qqq", "wat", "xyzzy"])
    func other(ext: String) {
        #expect(StorageBreakdownSource.category(forExtension: ext) == .other)
    }

    @Test("Classification is case-insensitive")
    func caseInsensitive() {
        #expect(StorageBreakdownSource.category(forExtension: "PDF") == .documents)
        #expect(StorageBreakdownSource.category(forExtension: "HEIC") == .images)
    }

    @Test("Every category has a distinct colour")
    func distinctPalette() {
        let hexes = StorageCategory.allCases.map(\.colorHex)
        #expect(Set(hexes).count == StorageCategory.allCases.count)
    }
}

@Suite("Storage breakdown — plan derivation")
struct DerivePlanTests {

    @Test("Snaps up to the nearest tier")
    func snapping() {
        // 199 GB total → 200 GB tier.
        let a = StorageBreakdownSource.derivePlan(usedBytes: 99_000_000_000, remainingBytes: 100_000_000_000)
        #expect(a?.capBytes == 200_000_000_000)
        #expect(a?.tierName == "iCloud+ 200 GB")

        // 201 GB total → next tier up is 2 TB (Apple sells nothing between).
        let b = StorageBreakdownSource.derivePlan(usedBytes: 101_000_000_000, remainingBytes: 100_000_000_000)
        #expect(b?.capBytes == 2_000_000_000_000)
        #expect(b?.tierName == "iCloud+ 2 TB")

        // 4.9 GB → free 5 GB tier.
        let c = StorageBreakdownSource.derivePlan(usedBytes: 900_000_000, remainingBytes: 4_000_000_000)
        #expect(c?.capBytes == 5_000_000_000)

        // Exactly on a tier boundary stays on that tier.
        let d = StorageBreakdownSource.derivePlan(usedBytes: 0, remainingBytes: 50_000_000_000)
        #expect(d?.capBytes == 50_000_000_000)
    }

    @Test("Unknown remaining quota derives nothing")
    func nilRemaining() {
        #expect(StorageBreakdownSource.derivePlan(usedBytes: 10_000_000_000, remainingBytes: nil) == nil)
    }

    @Test("Beyond the largest tier Apple sells, no plan is claimed")
    func aboveLargestTier() {
        #expect(StorageBreakdownSource.derivePlan(
            usedBytes: 12_000_000_000_000, remainingBytes: 1_000_000_000_000) == nil)
    }

    @Test("Custom caps get an honest label")
    func customLabel() {
        #expect(StorageBreakdownSource.planName(forCap: 200_000_000_000) == "iCloud+ 200 GB")
        #expect(StorageBreakdownSource.planName(forCap: 100_000_000_000) == "iCloud 100 GB")
        #expect(StorageBreakdownSource.planName(forCap: 3_000_000_000_000) == "iCloud+ 3.0 TB")
    }
}

@Suite("Storage breakdown — aggregation over a real temp tree")
struct StorageAggregationTests {

    /// Builds: notes.md + report.pdf (Documents), shot.png (Images), clip.mp4
    /// (Video), main.swift (Code & Data), blob.qqq (Other), a hidden file, and
    /// a Fake.app package with two files inside.
    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-storage-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        func write(_ name: String, bytes: Int, into directory: URL) throws {
            try Data(repeating: 0x41, count: bytes).write(to: directory.appendingPathComponent(name))
        }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        try write("notes.md", bytes: 1_000, into: root)
        try write("report.pdf", bytes: 2_000, into: nested)   // deep walk must find it
        try write("shot.png", bytes: 3_000, into: root)
        try write("clip.mp4", bytes: 4_000, into: root)
        try write("main.swift", bytes: 5_000, into: root)
        try write("blob.qqq", bytes: 6_000, into: root)
        try write(".hidden.png", bytes: 90_000, into: root)   // must be skipped

        let package = root.appendingPathComponent("Fake.app", isDirectory: true)
        try fm.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try write("Info.plist", bytes: 7_000, into: package.appendingPathComponent("Contents"))
        try write("binary", bytes: 8_000, into: package.appendingPathComponent("Contents"))
        return root
    }

    @Test("Per-category sums, hidden files skipped, package counted once")
    func aggregation() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = StorageBreakdownSource.totals(ofDirectories: [root])
        #expect(result.isPartial == false)
        let totals = result.totals

        // Allocated size rounds up to the block size, so assert bucket presence
        // and RELATIVE ordering rather than exact byte counts.
        #expect(totals[.documents] != nil)
        #expect(totals[.images] != nil)
        #expect(totals[.video] != nil)
        #expect(totals[.codeData] != nil)
        #expect(totals[.other] != nil)
        #expect(totals[.audio] == nil)          // nothing audio in the tree
        #expect(totals[.archives] == nil)

        // The package contributes to Apps & Packages, once, with its contents'
        // bytes — and its descendants never leak into Code & Data / Documents.
        let packageBytes = try #require(totals[.appsPackages])
        #expect(packageBytes >= 15_000)

        // .hidden.png (90 KB) would dwarf shot.png (3 KB) if it were counted.
        let images = try #require(totals[.images])
        #expect(images < 50_000)

        // Deep file found: Documents holds notes.md + the nested report.pdf.
        let documents = try #require(totals[.documents])
        #expect(documents >= 3_000)
    }

    @Test("The entry cap truncates rather than walking forever")
    func entryCap() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = StorageBreakdownSource.totals(ofDirectories: [root], cap: 2)
        #expect(result.isPartial)
    }

    @Test("A missing directory yields nothing and never throws")
    func missingDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent-birdwatch-\(UUID().uuidString)")
        #expect(StorageBreakdownSource.totals(ofDirectories: [missing]).totals.isEmpty)
    }

    @Test("Segments drop empty buckets and sort largest first")
    func segments() {
        let segments = StorageBreakdownSource.segments(from: [
            .documents: 10, .images: 50, .video: 0, .other: 30,
        ])
        #expect(segments.map(\.name) == ["Images", "Other", "Documents"])
        #expect(segments.map(\.bytes) == [50, 30, 10])
        #expect(segments.first?.colorHex == StorageCategory.images.colorHex)
    }
}

@Suite("Storage breakdown — StorageInfo assembly")
struct StorageInfoAssemblyTests {

    private let totals: [StorageCategory: Int64] = [.documents: 30_000_000_000, .images: 20_000_000_000]

    @Test("usedBytes is exactly the sum of the segments")
    func usedIsSegmentSum() throws {
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: totals, remainingBytes: 100_000_000_000, planCapOverride: nil))
        #expect(info.usedBytes == 50_000_000_000)
        #expect(info.usedBytes == info.segments.reduce(0) { $0 + $1.bytes })
    }

    @Test("Derived cap snaps and reports its provenance")
    func derived() throws {
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: totals, remainingBytes: 100_000_000_000, planCapOverride: nil))
        #expect(info.totalBytes == 200_000_000_000)     // 150 GB floor → 200 GB
        #expect(info.capSource == .derived)
        #expect(info.availableBytes == 150_000_000_000)
    }

    @Test("A user override beats the derived cap")
    func overridePrecedence() throws {
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: totals, remainingBytes: 100_000_000_000, planCapOverride: 2_000_000_000_000))
        #expect(info.totalBytes == 2_000_000_000_000)
        #expect(info.capSource == .userChosen)
        #expect(info.planName == "iCloud+ 2 TB")
    }

    @Test("No remaining quota and no override → cap unknown, bar scales to what was measured")
    func unknownCap() throws {
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: totals, remainingBytes: nil, planCapOverride: nil))
        #expect(info.totalBytes == nil)
        #expect(info.capSource == .unknown)
        #expect(info.availableBytes == nil)
        #expect(info.barDenominator == info.usedBytes)
    }

    @Test("Nothing measured yields no StorageInfo at all")
    func emptyTotals() {
        #expect(StorageBreakdownSource.makeStorageInfo(
            totals: [:], remainingBytes: 100, planCapOverride: nil) == nil)
    }

    @Test("SyncStore's overlay replaces the cap and keeps the measured segments")
    func storeOverlay() throws {
        let derived = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: totals, remainingBytes: 100_000_000_000, planCapOverride: nil))
        let overridden = try #require(SyncStore.applyPlanCap(6_000_000_000_000, to: derived))
        #expect(overridden.totalBytes == 6_000_000_000_000)
        #expect(overridden.capSource == .userChosen)
        #expect(overridden.segments == derived.segments)
        #expect(overridden.usedBytes == derived.usedBytes)
        // A nil/zero override leaves the derived info untouched.
        #expect(SyncStore.applyPlanCap(nil, to: derived)?.totalBytes == 200_000_000_000)
        #expect(SyncStore.applyPlanCap(0, to: derived)?.capSource == .derived)
        #expect(SyncStore.applyPlanCap(1, to: nil) == nil)
    }
}

// MARK: - Account tier (cap − live remaining quota)

@Suite("Storage breakdown — account tier")
struct StorageAccountTierTests {

    /// Alan's real account: 2 TB plan, brctl reports ~205 GB remaining, and
    /// System Settings shows "1.8 of 2 TB used".
    private let cap: Int64 = 2_000_000_000_000
    private let remaining: Int64 = 205_330_000_000
    private let localTotals: [StorageCategory: Int64] = [.documents: 61_000_000_000, .images: 30_000_000_000]

    @Test("Account usage is cap minus the live remaining quota")
    func accountUsedMath() throws {
        let account = try #require(StorageBreakdownSource.accountUsed(capBytes: cap, remainingBytes: remaining))
        #expect(account.bytes == 1_794_670_000_000)
        #expect(account.isClamped == false)
    }

    @Test("Either half unknown → no account figure at all")
    func accountUsedUnknown() {
        #expect(StorageBreakdownSource.accountUsed(capBytes: cap, remainingBytes: nil) == nil)
        #expect(StorageBreakdownSource.accountUsed(capBytes: nil, remainingBytes: remaining) == nil)
        #expect(StorageBreakdownSource.accountUsed(capBytes: nil, remainingBytes: nil) == nil)
        #expect(StorageBreakdownSource.accountUsed(capBytes: 0, remainingBytes: remaining) == nil)
        #expect(StorageBreakdownSource.accountUsed(capBytes: cap, remainingBytes: -1) == nil)
    }

    @Test("Remaining larger than the cap clamps to zero and raises the flag")
    func accountUsedClamped() throws {
        let account = try #require(StorageBreakdownSource.accountUsed(
            capBytes: 200_000_000_000, remainingBytes: 500_000_000_000))
        #expect(account.bytes == 0)
        #expect(account.isClamped)
    }

    @Test("makeStorageInfo carries the account tier when the quota allows it")
    func assemblyCarriesAccountTier() throws {
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: remaining, planCapOverride: cap))
        #expect(info.hasAccountTier)
        #expect(info.remainingBytes == remaining)
        #expect(info.accountUsedBytes == 1_794_670_000_000)
        #expect(info.isAccountUsedClamped == false)
        // Local measurement is untouched by the account math.
        #expect(info.usedBytes == 91_000_000_000)
        // Two honest segments that sum back to account usage.
        #expect(info.accountLocalSegmentBytes == 91_000_000_000)
        #expect(info.accountRemainderBytes == 1_703_670_000_000)
        let localSegment = try #require(info.accountLocalSegmentBytes)
        let remainder = try #require(info.accountRemainderBytes)
        #expect(localSegment + remainder == info.accountUsedBytes)
        #expect(info.localExceedsAccount == false)
        // The local bar rescales to itself once the account bar owns the cap.
        #expect(info.barDenominator == info.usedBytes)
    }

    @Test("No remaining quota → no account tier, local headline stands")
    func noQuotaNoTier() throws {
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: nil, planCapOverride: cap))
        #expect(info.accountUsedBytes == nil)
        #expect(info.remainingBytes == nil)
        #expect(info.hasAccountTier == false)
        #expect(info.accountLocalSegmentBytes == nil)
        #expect(info.accountRemainderBytes == nil)
        #expect(info.barDenominator == cap)
    }

    @Test("Local measurement above account usage caps the segment and zeroes the remainder")
    func localExceedsAccountClamp() throws {
        // Family sharing edge: the account reports only 10 GB used while this
        // Mac holds 91 GB of files.
        let info = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: cap - 10_000_000_000, planCapOverride: cap))
        #expect(info.accountUsedBytes == 10_000_000_000)
        #expect(info.accountLocalSegmentBytes == 10_000_000_000)
        #expect(info.accountRemainderBytes == 0)
        #expect(info.localExceedsAccount)
    }

    @Test("A user-chosen cap recomputes the account tier against the new cap")
    func overlayRecomputesAccountTier() throws {
        let derived = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: remaining, planCapOverride: nil))
        // derivePlan floors at local + remaining ≈ 296 GB → 2 TB tier here.
        #expect(derived.accountUsedBytes == 1_794_670_000_000)
        #expect(derived.planPriceLine == "Derived from your iCloud quota")

        let overridden = try #require(SyncStore.applyPlanCap(6_000_000_000_000, to: derived))
        #expect(overridden.remainingBytes == remaining)
        #expect(overridden.accountUsedBytes == 6_000_000_000_000 - remaining)
        #expect(overridden.planPriceLine == "Set by you")
    }

    @Test("Sidebar footer prefers the account figure, else the local one")
    func footerSelection() throws {
        let account = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: remaining, planCapOverride: cap))
        #expect(account.footerFigure == .account(used: 1_794_670_000_000, cap: cap))

        let localWithCap = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: nil, planCapOverride: cap))
        #expect(localWithCap.footerFigure == .local(used: 91_000_000_000, cap: cap))

        let noCap = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: nil, planCapOverride: nil))
        #expect(noCap.footerFigure == .localOnly(used: 91_000_000_000))

        // A clamped account figure is never trusted in the footer.
        let clamped = try #require(StorageBreakdownSource.makeStorageInfo(
            totals: localTotals, remainingBytes: 500_000_000_000, planCapOverride: 200_000_000_000))
        #expect(clamped.isAccountUsedClamped)
        #expect(clamped.footerFigure == .local(used: 91_000_000_000, cap: 200_000_000_000))
    }

    @Test("Footer progress divides by the cap and never leaves 0…1")
    func footerProgress() throws {
        #expect(StorageFooterFigure.account(used: 1_000, cap: 2_000).progress == 0.5)
        #expect(StorageFooterFigure.local(used: 500, cap: 2_000).progress == 0.25)
        #expect(StorageFooterFigure.account(used: 3_000, cap: 2_000).progress == 1)
        #expect(StorageFooterFigure.local(used: 10, cap: 0).progress == nil)
        #expect(StorageFooterFigure.localOnly(used: 10).progress == nil)
    }

    @Test("Plan-scale formatting reads like System Settings")
    func capacityFormatting() {
        #expect(Format.capacity(2_000_000_000_000) == "2 TB")
        #expect(Format.capacity(1_794_670_000_000) == "1.79 TB")
        #expect(Format.capacity(205_330_000_000) == "205.3 GB")
        #expect(Format.capacity(91_000_000_000) == "91 GB")
    }

    @Test("The mock fixture keeps working with no account tier")
    func mockPathUnaffected() {
        let info = StorageInfo(
            totalBytes: 200_000_000_000,
            segments: [StorageSegment(name: "Photos", colorHex: "fe4f6d", bytes: 84_300_000_000)],
            planName: "iCloud+ · 200 GB plan",
            planPriceLine: "$2.99/month"
        )
        #expect(info.hasAccountTier == false)
        #expect(info.accountUsedBytes == nil)
        #expect(info.remainingBytes == nil)
        #expect(info.barDenominator == 200_000_000_000)
        let expectedAvailable: Int64 = 200_000_000_000 - 84_300_000_000
        #expect(info.availableBytes == expectedAvailable)
        #expect(info.usedBytes == 84_300_000_000)
    }
}

@Suite("Storage breakdown — plan cap persistence", .serialized)
@MainActor
struct PlanCapPersistenceTests {

    private func makeStore() -> (SyncStore, UserDefaults, StubSyncSource) {
        let suiteName = "bw-plan-cap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var snapshot = SyncSnapshot.minimal()
        snapshot.storage = StorageBreakdownSource.makeStorageInfo(
            totals: [.documents: 30_000_000_000, .images: 20_000_000_000],
            remainingBytes: 100_000_000_000, planCapOverride: nil
        )
        snapshot.quotaRemainingBytes = 100_000_000_000
        let source = StubSyncSource(snapshot: snapshot)
        return (SyncStore(source: source, defaults: defaults), defaults, source)
    }

    @Test("A confirmed plan overrides the derived cap and survives the next snapshot")
    func overridePersists() async throws {
        let (store, defaults, _) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        await store.refresh(force: true)
        #expect(store.storage?.totalBytes == 200_000_000_000)
        #expect(store.storage?.capSource == .derived)
        #expect(store.planCapConfirmed == false)

        store.setPlanCap(2_000_000_000_000)
        #expect(store.planCapOverride == 2_000_000_000_000)
        #expect(store.planCapConfirmed)
        #expect(store.storage?.totalBytes == 2_000_000_000_000)
        #expect(store.storage?.capSource == .userChosen)
        // Segments are the measurement — an override must never touch them.
        #expect(store.storage?.usedBytes == 50_000_000_000)

        await store.refresh(force: true)
        #expect(store.storage?.totalBytes == 2_000_000_000_000)
    }

    @Test("Clearing the override restores the derived cap without a refresh")
    func clearingRestoresDerived() async throws {
        let (store, defaults, _) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        await store.refresh(force: true)
        store.setPlanCap(6_000_000_000_000)
        #expect(store.storage?.totalBytes == 6_000_000_000_000)

        store.setPlanCap(nil)
        #expect(store.planCapOverride == nil)
        #expect(store.storage?.totalBytes == 200_000_000_000)
        #expect(store.storage?.capSource == .derived)
        // Dismissing/answering is still remembered, so the prompt stays closed.
        #expect(store.planCapConfirmed)
    }
}
