import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "brctl-dump")

/// Runs `brctl dump -i` (itemless) and parses it with `BrctlDumpParser`.
///
/// WHY `-i`: the full dump is ~40s / ~90 MB and gets truncated anyway; the
/// itemless dump is ~2s and carries everything `brctl status` does (which
/// blocks 15–28s, so it can never back a live view) EXCEPT the per-app
/// `current=` lines — the Desktop & Documents flag exists only in status
/// (verified on macOS 27 GA). See the system-data-source ground-truth note.
///
/// WHY `-o <file>` rather than stdout: brctl DOES write the dump to stdout,
/// but it is ~4.8 MB on this account and ProcessRunner caps captured pipe
/// bytes at 4 MB — a truncated capture would silently drop the tail sections
/// (SyncHealthReport, global progress). Redirecting to a temp file sidesteps
/// the cap entirely; ANSI escapes survive the redirection, and the parser
/// strips them.
///
/// Actor-isolated so the spawn + the multi-megabyte parse never touch main.
actor BrctlDumpSource {
    private let runner: any ProcessRunning

    init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }
    private static let brctlPath = "/usr/bin/brctl"
    /// Measured ~2s alone. It used to time out because bird serves brctl
    /// requests one at a time: a `brctl status` that ProcessRunner had already
    /// killed kept bird busy for its remaining 15–28 s and the dump queued
    /// behind it (measured 18 s). Status now never runs concurrently with the
    /// dump (see SystemSyncSource's dump refresh), so 15 s is real headroom.
    static let timeout: Duration = .seconds(15)

    /// A parsed dump plus the CloudDocs container line it carries.
    nonisolated struct Read: Sendable {
        var dump: BrctlDump
        var cloudDocsState: BrctlStatus?
    }

    func currentDump() async -> Result<Read, BrctlReadFailure> {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "birdwatch-dump-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let started = ContinuousClock.now
        do {
            _ = try await runner.run(
                toolPath: Self.brctlPath,
                arguments: ["dump", "-i", "-o", url.path],
                timeout: Self.timeout
            )
        } catch {
            logger.warning("brctl dump -i failed: \(RunnerError.publicSummary(of: error), privacy: .public) \(RunnerError.privateDetail(of: error), privacy: .private)")
            return .failure(BrctlReadFailure(error, timeout: Self.timeout))
        }
        // Lossy on purpose: brctl's dump carries redacted file names and ANSI
        // escapes, and a single invalid UTF-8 byte anywhere in ~5 MB would make
        // the strict `String(contentsOf:encoding:)` initializer fail and kill
        // the entire diagnostics feature permanently. `String(decoding:as:)`
        // substitutes U+FFFD for bad bytes and keeps every parseable section.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let ns = error as NSError
            logger.warning("brctl dump -i produced no readable output file: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return .failure(.failed("produced no readable output"))
        }
        let text = String(decoding: data, as: UTF8.self)
        logger.info("brctl dump -i collected in \((ContinuousClock.now - started).components.seconds, privacy: .public)s (\(data.count, privacy: .public) bytes)")
        return .success(Read(dump: BrctlDumpParser.parse(text), cloudDocsState: BrctlParser.containerState(inDump: text)))
    }
}

// MARK: - Mapping (pure, testable)

/// Turns a parsed dump into the DTOs the UI consumes. Every value here is
/// something bird actually printed — nothing is inferred into a number that
/// the engine did not report.
/// Where one of bird's scheduled (not yet synced) items lives.
nonisolated enum RetryLocation: Sendable, Hashable {
    /// Inside an app's own container — that container row's id.
    case app(String)
    /// Inside a top-level iCloud Drive folder (its name).
    case driveFolder(String)
    /// A file directly in the iCloud Drive root — in no folder.
    case driveRootFile
    /// Somewhere in iCloud Drive; which folder is not known.
    case driveFolderUnknown
    /// No container or path could be matched on this disk.
    case unplaced
}

/// Every scheduled item's location, computed once per dump refresh. All of
/// them are bird's — so all of them keep the iCloud Drive row from reading
/// "Up to date" — and the placed ones also mark their own app or folder.
nonisolated struct RetryAttribution: Sendable, Hashable {
    var locations: [String: RetryLocation] = [:]
    /// Scheduled items beyond `BrctlDumpMapper.attributionCap`, not placed.
    var overflow: Int = 0

    /// Every scheduled item.
    var total: Int { locations.count + overflow }

    func count(appID: String) -> Int { locations.values.count { $0 == .app(appID) } }
    func count(folder: String) -> Int { locations.values.count { $0 == .driveFolder(folder) } }

    /// Items that may be in ANY Drive folder: no folder can be confirmed
    /// up to date while one of these exists.
    var unplacedForFolders: Int {
        overflow + locations.values.count { $0 == .driveFolderUnknown || $0 == .unplaced }
    }

    func removing(_ ids: Set<String>) -> RetryAttribution {
        var copy = self
        for id in ids { copy.locations[id] = nil }
        return copy
    }
}

nonisolated enum BrctlDumpMapper {

    /// bird gives up on an item after 62 attempts (documented in the retry
    /// queue UI as "attempt N of 62").
    static let maxAttempts = 62
    /// Rows shown in the Diagnostics retry card. A large account can have
    /// hundreds of scheduled operations; the stuck-items issue covers the tail.
    static let retryRowLimit = 10
    /// An item whose last attempt is older than this is "stuck" — bird is
    /// still scheduling it but nothing is moving. `attempts:0` counts: a
    /// sync-up scheduled 75 days ago has never even been tried.
    static let stuckThreshold: TimeInterval = 24 * 3600

    // MARK: Retry queue

    /// Items bird has scheduled work for. Idle items are included only when
    /// they carry a live retry (bird schedules `apply` retries on items whose
    /// upload state is already idle — those are real failures).
    static func pendingItems(_ dump: BrctlDump) -> [BrctlPendingItem] {
        dump.pendingItems.filter { $0.uploadState != "idle" || $0.isRetrying }
    }

    /// Most-failed first, then longest-waiting: on a healthy account every row
    /// is `attempts:0` and the wait is the only thing that distinguishes them.
    /// `candidates` is our own capped filesystem listing (see
    /// `RedactedPathResolver`). Pass `[]` and every row degrades to the
    /// redacted-only wording — the mapping stays pure and testable either way.
    static func retryQueue(from dump: BrctlDump, candidates: [PathCandidate] = []) -> [RetryQueueItem] {
        let rows = pendingItems(dump)
            .sorted {
                ($0.attempts, stalledAge($0) ?? 0, $0.itemID)
                    > ($1.attempts, stalledAge($1) ?? 0, $1.itemID)
            }
            .prefix(retryRowLimit)
        // Only the rows we actually show are worth resolving.
        let resolved = RedactedPathResolver.resolve(items: Array(rows), candidates: candidates)
        return rows.map { item in
            let match = resolved[item.itemID]
            return RetryQueueItem(
                id: item.itemID,
                name: displayName(for: item),
                attempt: item.attempts,
                maxAttempts: maxAttempts,
                lastAttemptAgo: stalledAge(item),
                path: match?.displayPath.isEmpty == false ? match?.displayPath : nil,
                absolutePath: match?.absolutePath,
                matchConfidence: match?.confidence ?? .none,
                isDirectory: item.isDirectory
            )
        }
    }

    /// Fills in `sizeBytes` / `itemCount` for the rows we resolved EXACTLY.
    ///
    /// Split out of `retryQueue` on purpose: that mapping is pure and unit
    /// tested, while this one touches the filesystem. `measure` is injected so
    /// the fold — which rows get measured, and how a nil measurement is handled
    /// — is testable against a temp-dir fixture without the live account.
    /// Ambiguous rows are never measured: their path is a shared PARENT folder,
    /// and sizing that would attribute a whole directory to one stuck item.
    static func measured(
        _ rows: [RetryQueueItem],
        measure: (String) -> RedactedPathResolver.Measurement? = { RedactedPathResolver.measure(path: $0) }
    ) -> [RetryQueueItem] {
        rows.map { row in
            guard row.matchConfidence == .exact, let path = row.absolutePath,
                  let measurement = measure(path) else { return row }
            var row = row
            row.sizeBytes = measurement.sizeBytes
            row.itemCount = measurement.itemCount
            row.sizeIsPartial = measurement.isPartial
            return row
        }
    }

    /// Every scheduled item, not just the rows that fit on the card.
    static func retryQueueTotal(from dump: BrctlDump) -> Int { pendingItems(dump).count }

    // MARK: Retry attribution (which row each scheduled item belongs to)

    /// Items placed per dump refresh. Beyond this they count as unplaced:
    /// still "not syncing" on iCloud Drive, just not pinned to a row.
    static let attributionCap = 5_000

    /// Where every scheduled item lives, as far as our own disk can say.
    ///
    /// The app-library header gives each item a CONTAINER (redacted, but
    /// matched structurally against the real `Mobile Documents` children —
    /// see `RedactedPathResolver`), which is enough to pin it to an app row
    /// even when its own name has no unique fit. Inside CloudDocs, a resolved
    /// path pins it to a top-level folder. Anything else stays unplaced and
    /// is never guessed into a row.
    static func retryAttribution(
        from dump: BrctlDump, candidates: [PathCandidate], homeDirectory: String = NSHomeDirectory()
    ) -> RetryAttribution {
        let items = pendingItems(dump)
        let placed = Array(items.prefix(attributionCap))
        let resolved = RedactedPathResolver.resolve(items: placed, candidates: candidates)
        let containerNames = Array(Set(candidates.compactMap(\.containerDirectoryName)))
        var containerCache: [String: String?] = [:]
        var locations: [String: RetryLocation] = [:]
        locations.reserveCapacity(placed.count)
        for item in placed {
            var container: String?
            if let pattern = item.containerPattern {
                if let cached = containerCache[pattern] {
                    container = cached
                } else {
                    let matched = containerNames.filter {
                        RedactedPathResolver.matchesContainer(pattern: pattern, directoryName: $0)
                    }
                    container = matched.count == 1 ? matched[0] : nil
                    containerCache[pattern] = container
                }
            }
            let match = resolved[item.itemID]
            if container == nil, let path = match?.absolutePath {
                container = AppContainerSource.containerDirectory(forPath: path, homeDirectory: homeDirectory)
            }
            locations[item.itemID] = location(
                container: container, match: match, isDirectory: item.isDirectory, homeDirectory: homeDirectory)
        }
        return RetryAttribution(locations: locations, overflow: items.count - placed.count)
    }

    private static func location(
        container: String?, match: ResolvedPath?, isDirectory: Bool, homeDirectory: String
    ) -> RetryLocation {
        guard let container else { return .unplaced }
        guard container == "com~apple~CloudDocs" else {
            return .app(AppContainerSource.appID(forDirectory: container))
        }
        let root = homeDirectory + "/Library/Mobile Documents/com~apple~CloudDocs"
        guard let path = match?.absolutePath, path.hasPrefix(root) else { return .driveFolderUnknown }
        let components = path.dropFirst(root.count).split(separator: "/").map(String.init)
        guard let first = components.first else {
            // An ambiguous match whose shared parent is the Drive root itself.
            return .driveFolderUnknown
        }
        // An exact match is the item itself: a top-level FILE is in no folder.
        if match?.confidence == .exact, components.count == 1, !isDirectory { return .driveRootFile }
        return .driveFolder(first)
    }

    /// bird length-redacts every file name (`n:"b{5}2.bin"`), so the extension
    /// is the ONLY real characters in it. Never show the redacted pattern.
    static func displayName(for item: BrctlPendingItem) -> String {
        if let ext = item.fileExtension, !ext.isEmpty { return ".\(ext) file" }
        return item.isDirectory ? "Folder" : "Item"
    }

    // MARK: Stuck items

    /// Age of the oldest scheduling attempt on an item, in seconds.
    static func stalledAge(_ item: BrctlPendingItem) -> TimeInterval? {
        item.interestingOperations.compactMap(\.lastAttemptAgo).max()
    }

    /// "N items haven't synced in D days" — derived, not read: bird prints the
    /// per-item age, the aggregate sentence is ours.
    static func stuckIssue(from dump: BrctlDump) -> IssueItem? {
        let stalled = pendingItems(dump).compactMap { item -> TimeInterval? in
            guard let age = stalledAge(item), age > stuckThreshold else { return nil }
            return age
        }
        guard let oldest = stalled.max() else { return nil }
        let days = max(1, Int((oldest / 86_400).rounded(.down)))
        let count = stalled.count
        return IssueItem(
            id: "issue-stuck-items",
            severity: .warning,
            title: "\(Plural.count(count, "item")) \(count == 1 ? "hasn't" : "haven't") synced in \(Plural.count(days, "day"))",
            meta: "iCloud Drive · reported by bird",
            reason: "bird still has \(Plural.count(count, "item")) scheduled for upload, but its last attempt on the oldest was \(Plural.count(days, "day")) ago. The item names are redacted by macOS, so Birdwatch can only report the count and the age.",
            action: .openDiagnostics,
            symbolName: "clock.badge.exclamationmark",
            appID: "icloud-drive"
        )
    }

    // MARK: Errors → issues

    static func issues(from dump: BrctlDump) -> [IssueItem] {
        var out: [IssueItem] = []
        if let accountIssue = accountIssue(from: dump) { out.append(accountIssue) }
        for (category, value) in dump.syncHealth.errors.sorted(by: { $0.key < $1.key }) {
            out.append(IssueItem(
                id: "issue-synchealth-\(category)",
                severity: .error,
                title: "\(humanized(category)) reported by bird",
                meta: "iCloud Drive · SyncHealthReport",
                reason: "bird's own health report lists this error under \(category): \(redact(value)). It is the only per-category error macOS exposes, so Birdwatch shows it verbatim rather than guessing at a cause.",
                action: .openDiagnostics,
                symbolName: "exclamationmark.triangle.fill",
                appID: "icloud-drive"
            ))
        }
        if let stuck = stuckIssue(from: dump) { out.append(stuck) }
        return out
    }

    private static func accountIssue(from dump: BrctlDump) -> IssueItem? {
        guard let description = dump.accountSessionError else { return nil }
        let code = dump.accountSessionErrorCode
        return IssueItem(
            id: "issue-account-session",
            severity: .error,
            title: "iCloud account session error",
            meta: "iCloud Drive · \(code ?? "reported by bird")",
            reason: "bird recorded an account-session error and has not cleared it: \(redact(description))\(code.map { " (\($0))" } ?? ""). Birdwatch reports it exactly as the engine stated it — there is no public API to interpret or clear it.",
            action: .openDiagnostics,
            symbolName: "person.crop.circle.badge.exclamationmark",
            appID: "icloud-drive"
        )
    }

    /// bird's error text embeds the account UUID; that is the user's identity
    /// and never belongs on screen or in a screenshot.
    static func redact(_ text: String) -> String {
        text.replacing(
            /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/,
            with: "«account id»"
        )
    }

    /// "syncUpSharedZoneError" → "Sync up shared zone error".
    static func humanized(_ camel: String) -> String {
        var out = ""
        for character in camel {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(character.uppercased()) : Character(character.lowercased()))
        }
        return out
    }

    // MARK: Engine

    /// Enriches the engine info (CloudDocs state from the dump's container
    /// line, or last-known `brctl status`) with the dump's internals.
    static func enrich(_ base: SyncEngineInfo, with dump: BrctlDump) -> SyncEngineInfo {
        var engine = base
        let budget = dump.scheduler.budget ?? dump.clientState.budget
        if let budget {
            // The PERCENT spelling only (`m:0.0% (0.5)`): the bare numbers are
            // raw budget values in bird's own units, not percentages, and
            // conflating them would invent a measurement.
            let parts = [
                budget.minuteUsedPercent.map { "\(percent($0))/min" },
                budget.hourUsedPercent.map { "\(percent($0))/hr" },
                budget.dayUsedPercent.map { "\(percent($0))/day" },
            ].compactMap { $0 }
            if !parts.isEmpty {
                engine.pushBudget = "Used \(parts.joined(separator: " · "))"
            } else if let verdict = budget.verdict {
                engine.pushBudget = verdict.capitalizedFirst
            }
            engine.pushThrottled = isThrottled(budget) || dump.syncHealth.errors.values.contains { $0.contains("throttled") }
        }
        if let client = dump.scheduler.clientItemCount {
            var line = "client \(count(client)) items"
            if let server = dump.scheduler.serverItemCount { line += " · server \(count(server))" }
            if dump.scheduler.outputMayBeTruncated || dump.itemsTruncated { line += " (bird truncated its dump)" }
            engine.metadataIndex = line
            engine.metadataHealthy = true
        }
        if let progress = dump.globalProgress, let fraction = progress.fraction {
            var line = "\(percent(fraction * 100)) of the current upload batch"
            if let done = progress.uploadedBytes, let total = progress.totalBytes, total > 0 {
                line += " · \(Format.capacity(done)) of \(Format.capacity(total))"
            }
            engine.globalProgressLine = line
        }
        return engine
    }

    static func isThrottled(_ budget: BrctlSyncBudget) -> Bool {
        if let verdict = budget.verdict, verdict.contains("throttl") { return true }
        return [budget.minuteUsedPercent, budget.hourUsedPercent, budget.dayUsedPercent]
            .compactMap { $0 }
            .contains { $0 >= 100 }
    }

    /// `value` is already in percent units (bird prints them that way):
    /// "0.5%" below 10 when fractional, else whole ("57%"). Only the digit
    /// rule lives here — the formatting is `Format.percent`, so the locale
    /// spelling ("0,5 %" in French) matches every other percentage.
    static func percent(_ value: Double, locale: Locale = .current) -> String {
        let digits = value < 10 && value != value.rounded() ? 1 : 0
        return Format.percent(value / 100, locale: locale, fractionLength: digits)
    }

    private static func count(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    // MARK: Devices

    /// Anonymous device attribution. device:0 is bird's placeholder for items
    /// that have never been uploaded, not a device — always excluded.
    static func deviceSummary(from dump: BrctlDump) -> DeviceActivitySummary? {
        let devices = dump.deviceActivity
            .filter { $0.index != 0 }
            .map { DeviceActivityItem(index: $0.index, itemCount: $0.itemCount, lastModified: $0.lastModified) }
        let sorted = DeviceActivitySummary.sortedByActivity(devices)
        guard !sorted.isEmpty else { return nil }
        return DeviceActivitySummary(
            devices: sorted,
            registeredDeviceCount: max(dump.devices.count, sorted.count),
            countsArePartial: true
        )
    }
}

private nonisolated extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
