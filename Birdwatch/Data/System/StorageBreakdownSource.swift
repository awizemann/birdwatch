import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "StorageBreakdownSource")

/// File-type breakdown of the LOCAL iCloud footprint.
///
/// Honesty boundary (Phase 6 research): macOS exposes no per-service iCloud
/// usage to a third-party app. What *is* measurable is what those files occupy
/// on THIS Mac — allocated bytes under the ubiquity containers plus Desktop &
/// Documents. Evicted (dataless) files occupy almost nothing, and Photos and
/// device backups never live here at all, so this total is a floor on the
/// account's cloud usage, never the account's usage. Every surface that shows
/// it says so.
///
/// Cost discipline mirrors `AppContainerSource.localSizes`: `@concurrent`, off
/// the snapshot path, single-flight behind a 5-minute cache in
/// SystemSyncSource, hard entry cap, per-item fault tolerant.
enum StorageBreakdownSource {

    /// Hard cap on entries visited across the whole pass. This machine's
    /// containers hold tens of thousands of files; beyond this we stop, log,
    /// and report a partial figure rather than walking forever.
    nonisolated static let entryCap = 100_000

    // MARK: - Classification (pure)

    /// Extension → category. Lowercased internally; unknown/empty → `.other`.
    nonisolated static func category(forExtension ext: String) -> StorageCategory {
        switch ext.lowercased() {
        case "pdf", "pages", "doc", "docx", "rtf", "rtfd", "txt", "md", "markdown",
             "key", "numbers", "xls", "xlsx", "csv", "tsv", "ppt", "pptx", "odt",
             "ods", "odp", "epub", "tex", "pub":
            .documents
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp",
             "webp", "psd", "svg", "raw", "cr2", "nef", "dng", "ico", "icns", "ai":
            .images
        case "mov", "mp4", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg",
             "mpeg", "3gp", "hevc", "prores":
            .video
        case "mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "alac", "ogg",
             "opus", "wma", "mid", "midi", "m4b", "caf":
            .audio
        case "zip", "dmg", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "pkg",
             "iso", "sit", "sitx", "cpgz", "zst":
            .archives
        case "swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "c", "h",
             "cpp", "hpp", "m", "mm", "java", "kt", "sh", "zsh", "bash", "pl",
             "php", "html", "css", "json", "yaml", "yml", "toml", "xml", "plist",
             "sqlite", "sqlite3", "db", "sql", "log", "ipynb":
            .codeData
        case "app", "photoslibrary", "bundle", "framework", "xcodeproj",
             "xcworkspace", "playground", "rtfdbundle", "musiclibrary",
             "tvlibrary", "photolibrary", "logicx", "band", "fcpbundle", "aplibrary":
            .appsPackages
        default:
            .other
        }
    }

    // MARK: - Aggregation (I/O, off-main; pure w.r.t. its input directories)

    /// Deep, capped, per-item fault-tolerant sum of **allocated** bytes per
    /// category over `directories`.
    ///
    /// - Package directories (`.app`, `.photoslibrary`, …) are counted ONCE, by
    ///   their own allocated size, and their descendants are never visited
    ///   (`.skipsPackageDescendants` + an explicit `isPackage` check).
    /// - Dot-files, and everything under a dot-directory, are skipped by NAME.
    ///   Not `.skipsHiddenFiles`: macOS sets the hidden flag on most iCloud
    ///   container directories, so that option pruned ~90% of the containers'
    ///   subtrees and under-counted the footprint. Not `skipDescendants()`
    ///   either: it ends the whole enumeration early on fileprovider volumes.
    /// - Symlinks are not followed and directories contribute nothing on their own.
    ///
    /// Returns totals plus whether the entry cap truncated the walk.
    nonisolated static func totals(
        ofDirectories directories: [URL], cap: Int = entryCap
    ) -> (totals: [StorageCategory: Int64], isPartial: Bool) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        let keySet = Set(keys)
        var totals: [StorageCategory: Int64] = [:]
        var visited = 0
        var isPartial = false

        for directory in directories {
            if isPartial || Task.isCancelled { break }
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { failed, error in
                    logger.debug("breakdown skipped \(failed.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    return true      // per-item fault tolerance: keep walking
                }
            ) else { continue }

            for case let item as URL in enumerator {
                visited += 1
                if visited > cap {
                    logger.notice("storage breakdown hit the \(cap, privacy: .public)-entry cap; reporting a partial figure")
                    isPartial = true
                    break
                }
                if Task.isCancelled { isPartial = true; break }
                guard !isUnderDotName(item, level: enumerator.level) else { continue }
                guard let values = try? item.resourceValues(forKeys: keySet),
                      values.isSymbolicLink != true else { continue }

                if values.isPackage == true, values.isDirectory == true {
                    // One item, one category, the whole bundle's bytes.
                    let bytes = values.totalFileAllocatedSize.map(Int64.init) ?? packageSize(of: item)
                    totals[category(forExtension: item.pathExtension), default: 0] += bytes
                    continue
                }
                guard values.isRegularFile == true else { continue }
                guard let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { continue }
                totals[category(forExtension: item.pathExtension), default: 0] += Int64(allocated)
            }
        }
        return (totals, isPartial)
    }

    /// True when `item`, or any ancestor of it below the walk's root, is a
    /// dot-name. `level` is the enumerator's depth (1 = a direct child), so a
    /// dot in the root's own path (or the /private/var symlink resolution of
    /// a temp root) never counts.
    nonisolated static func isUnderDotName(_ item: URL, level: Int) -> Bool {
        item.pathComponents.suffix(max(level, 1)).contains { $0.hasPrefix(".") }
    }

    /// Allocated bytes inside a package, used only when the package URL itself
    /// reports no size (the common case for directories).
    nonisolated static func packageSize(of url: URL) -> Int64 {
        AppContainerSource.allocatedSize(ofDirectory: url, cap: 20_000)
    }

    /// The directories that make up the local iCloud footprint. Desktop and
    /// Documents are only iCloud data when "Desktop & Documents" sync is ON
    /// (brctl status reports it); touching them otherwise earns a TCC prompt
    /// for folders the app has no business reading.
    nonisolated static func scanRoots(
        homeDirectory: String = UserHome.path,
        includeDesktopDocuments: Bool
    ) -> [URL] {
        let home = URL(fileURLWithPath: homeDirectory)
        var roots = [home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)]
        if includeDesktopDocuments {
            roots.append(home.appendingPathComponent("Desktop", isDirectory: true))
            roots.append(home.appendingPathComponent("Documents", isDirectory: true))
        }
        return roots
    }

    /// Serial queue for the blocking breakdown walk (see `BlockingWork`).
    nonisolated static let walkQueue = DispatchQueue(label: "com.wizemann.birdwatch.scan.storage-breakdown", qos: .utility)

    /// Full pass over the real footprint. Never on the snapshot path, and the
    /// blocking walk runs on its own queue so a hung read never holds a
    /// cooperative-pool thread.
    nonisolated static func currentTotals(
        homeDirectory: String = UserHome.path,
        includeDesktopDocuments: Bool
    ) async -> (totals: [StorageCategory: Int64], isPartial: Bool) {
        let roots = scanRoots(homeDirectory: homeDirectory, includeDesktopDocuments: includeDesktopDocuments)
        let result = await BlockingWork.run(on: walkQueue) {
            let walked = totals(ofDirectories: roots)
            return Totals(totals: walked.totals, isPartial: walked.isPartial)
        }
        return (result.totals, result.isPartial)
    }

    /// Sendable carrier for the walk's result across the queue bridge.
    private nonisolated struct Totals: Sendable {
        let totals: [StorageCategory: Int64]
        let isPartial: Bool
    }

    // MARK: - Segments (pure)

    /// Category totals → display segments, largest first, empty buckets dropped.
    nonisolated static func segments(from totals: [StorageCategory: Int64]) -> [StorageSegment] {
        StorageCategory.allCases
            .compactMap { category in
                guard let bytes = totals[category], bytes > 0 else { return nil }
                return StorageSegment(name: category.displayName, colorHex: category.colorHex, bytes: bytes)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Plan cap (pure)

    /// Apple's iCloud / iCloud+ storage tiers (decimal bytes, as Apple markets
    /// them): 5 GB free, then 50 GB / 200 GB / 2 TB / 6 TB / 12 TB.
    nonisolated static let tiers: [(bytes: Int64, name: String)] = [
        (5_000_000_000, "iCloud 5 GB"),
        (50_000_000_000, "iCloud+ 50 GB"),
        (200_000_000_000, "iCloud+ 200 GB"),
        (2_000_000_000_000, "iCloud+ 2 TB"),
        (6_000_000_000_000, "iCloud+ 6 TB"),
        (12_000_000_000_000, "iCloud+ 12 TB"),
    ]

    /// The 2 TB that Apple One Premier includes. An iCloud+ plan bought on
    /// top of it STACKS (e.g. 2 TB + 6 TB = 8 TB), so totals between and
    /// above the single tiers are real plans.
    nonisolated static let stackBaseBytes: Int64 = 2_000_000_000_000

    /// Every total a plan can have, smallest first: the single tiers, plus
    /// Apple One Premier's 2 TB stacked with each paid iCloud+ tier. Kept to
    /// that one stack on purpose — enough for the common 2 + 6 = 8 TB case
    /// without inventing combinations; anything else is a custom size.
    nonisolated static let purchasablePlans: [(bytes: Int64, name: String)] = {
        let stacked = tiers.dropFirst().map { tier in
            (bytes: stackBaseBytes + tier.bytes,
             name: "iCloud+ \(Format.capacity(stackBaseBytes + tier.bytes)) (2 TB + \(tierSize(tier.name)))")
        }
        return (tiers + stacked).sorted { $0.bytes < $1.bytes }
    }()

    /// "iCloud+ 6 TB" → "6 TB".
    private nonisolated static func tierSize(_ name: String) -> String {
        name.replacingOccurrences(of: "iCloud+ ", with: "").replacingOccurrences(of: "iCloud ", with: "")
    }

    /// Every purchasable total that could be the plan for a given floor:
    /// those from the floor up to and including the next SINGLE tier at or
    /// above it (a bigger total is never the simplest explanation). With no
    /// single tier that large, every purchasable total at or above the floor.
    nonisolated static func planCandidates(floorBytes: Int64) -> [(bytes: Int64, name: String)] {
        let ceiling = tiers.first(where: { $0.bytes >= floorBytes })?.bytes ?? Int64.max
        return purchasablePlans.filter { $0.bytes >= floorBytes && $0.bytes <= ceiling }
    }

    /// The plan, when the evidence picks exactly one.
    ///
    /// `remainingBytes` is bird's live `brctl quota` figure (account-wide), so
    /// used + remaining is a LOWER BOUND on the plan: `usedBytes` is only this
    /// Mac's footprint (evicted files, Photos and backups are missing). The
    /// plan is derived only when exactly ONE purchasable total lies between
    /// that floor and the next single tier — e.g. a 1.8 TB floor is 2 TB. When
    /// several fit (a 3 TB floor could be 4 TB stacked or 6 TB; Alan's
    /// 6.9 TB floor could be 8 TB stacked or 12 TB) nothing is derived: a
    /// guessed cap would make "account used" wrong by terabytes. nil then,
    /// when remaining is unknown, or when no plan Apple sells is that large.
    nonisolated static func derivePlan(
        usedBytes: Int64, remainingBytes: Int64?
    ) -> (capBytes: Int64, tierName: String)? {
        guard let remainingBytes, remainingBytes >= 0 else { return nil }
        let candidates = planCandidates(floorBytes: max(usedBytes, 0) + remainingBytes)
        guard candidates.count == 1, let plan = candidates.first else { return nil }
        return (plan.bytes, plan.name)
    }

    /// TRUE when the quota is known but more than one plan fits it, so the
    /// plan (and with it account usage) is left for the user to confirm.
    nonisolated static func planIsAmbiguous(usedBytes: Int64, remainingBytes: Int64?) -> Bool {
        guard let remainingBytes, remainingBytes >= 0 else { return false }
        return planCandidates(floorBytes: max(usedBytes, 0) + remainingBytes).count > 1
    }

    // MARK: - Account usage (pure)

    /// TRUE account-wide usage: `cap − remaining`.
    ///
    /// `remainingBytes` is bird's live `brctl quota` figure, which IS account
    /// scoped (Photos, Messages, backups and every other device included). With
    /// the plan cap known, the subtraction reproduces the number System
    /// Settings shows — no private API and no per-service guessing.
    ///
    /// nil when either half is unknown. `.capBelowRemaining` is the
    /// contradictory case where iCloud reports MORE remaining than the cap
    /// (a plan setting that is too small — e.g. a 2 TB choice on a stacked
    /// 8 TB plan): no usage is computed at all, since "0 used" would be an
    /// invented fact (C1).
    nonisolated enum AccountUsage: Equatable, Sendable {
        case used(Int64)
        case capBelowRemaining
        var bytes: Int64? { if case .used(let b) = self { b } else { nil } }
    }

    nonisolated static func accountUsed(
        capBytes: Int64?, remainingBytes: Int64?
    ) -> AccountUsage? {
        guard let capBytes, capBytes > 0, let remainingBytes, remainingBytes >= 0 else { return nil }
        let used = capBytes - remainingBytes
        return used < 0 ? .capBelowRemaining : .used(used)
    }

    /// Human tier label for an arbitrary cap (used for a custom/override value).
    nonisolated static func planName(forCap capBytes: Int64) -> String {
        if let tier = purchasablePlans.first(where: { $0.bytes == capBytes }) { return tier.name }
        return capBytes >= 1_000_000_000_000
            ? "iCloud+ \(Format.capacity(capBytes))"
            : "iCloud \(Format.capacity(capBytes))"
    }

    // MARK: - Assembly (pure)

    /// Category totals + quota → the StorageInfo the UI renders.
    nonisolated static func makeStorageInfo(
        totals: [StorageCategory: Int64],
        remainingBytes: Int64?,
        planCapOverride: Int64?,
        isPartial: Bool = false
    ) -> StorageInfo? {
        let segments = segments(from: totals)
        guard !segments.isEmpty else { return nil }
        let used = segments.reduce(0) { $0 + $1.bytes }
        let derived = derivePlan(usedBytes: used, remainingBytes: remainingBytes)

        let cap: Int64?
        let source: StorageCapSource
        let name: String
        if let planCapOverride, planCapOverride > 0 {
            cap = planCapOverride
            source = .userChosen
            name = planName(forCap: planCapOverride)
        } else if let derived {
            cap = derived.capBytes
            source = .derived
            name = derived.tierName
        } else {
            cap = nil
            source = .unknown
            name = planIsAmbiguous(usedBytes: used, remainingBytes: remainingBytes)
                ? "iCloud plan not confirmed"
                : "iCloud plan size unknown"
        }
        let ambiguous = (planCapOverride ?? 0) <= 0 && derived == nil
            && planIsAmbiguous(usedBytes: used, remainingBytes: remainingBytes)

        let account = accountUsed(capBytes: cap, remainingBytes: remainingBytes)

        let priceLine: String
        switch source {
        case .userChosen:
            priceLine = "Set by you"
        case .derived:
            // With the account tier on screen the remaining figure is already
            // in the headline, so the plan card just names its provenance.
            priceLine = account != nil
                ? "Derived from your iCloud quota"
                : (remainingBytes.map {
                    "Derived from \(Format.capacity($0)) remaining reported by iCloud"
                } ?? "Derived from your account's remaining quota")
        case .unknown:
            priceLine = ambiguous
                ? "More than one plan fits what iCloud reports available — confirm yours to see account usage"
                : "iCloud didn't report a remaining quota — set your plan to see how much is left"
        }

        return StorageInfo(
            totalBytes: cap,
            segments: segments,
            planName: name,
            planPriceLine: isPartial ? priceLine + " · partial scan" : priceLine,
            capSource: source,
            remainingBytes: remainingBytes,
            accountUsedBytes: account?.bytes,
            planCapBelowRemaining: account == .capBelowRemaining,
            planIsAmbiguous: ambiguous
        )
    }
}
