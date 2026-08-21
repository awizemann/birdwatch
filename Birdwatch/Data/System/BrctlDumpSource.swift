import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "brctl-dump")

/// Runs `brctl dump -i` (itemless) and parses it with `BrctlDumpParser`.
///
/// WHY `-i`: the full dump is ~40s / ~90 MB and gets truncated anyway; the
/// itemless dump is ~2s and is a strict superset of `brctl status` (which
/// blocks 15–28s precisely while a sync is running, so it can never back a
/// live view). See the system-data-source ground-truth note.
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
    private let runner = ProcessRunner()
    private static let brctlPath = "/usr/bin/brctl"
    /// Measured ~2s; 15s leaves generous headroom for a busy engine while
    /// still bounding the background refresh.
    static let timeout: Duration = .seconds(15)

    func currentDump() async -> BrctlDump? {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "birdwatch-dump-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await runner.run(
                toolPath: Self.brctlPath,
                arguments: ["dump", "-i", "-o", url.path],
                timeout: Self.timeout
            )
        } catch {
            logger.warning("brctl dump -i failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        // Lossy on purpose: brctl's dump carries redacted file names and ANSI
        // escapes, and a single invalid UTF-8 byte anywhere in ~5 MB would make
        // the strict `String(contentsOf:encoding:)` initializer fail and kill
        // the entire diagnostics feature permanently. `String(decoding:as:)`
        // substitutes U+FFFD for bad bytes and keeps every parseable section.
        guard let data = try? Data(contentsOf: url) else {
            logger.warning("brctl dump -i produced no readable output file")
            return nil
        }
        return BrctlDumpParser.parse(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Mapping (pure, testable)

/// Turns a parsed dump into the DTOs the UI consumes. Every value here is
/// something bird actually printed — nothing is inferred into a number that
/// the engine did not report.
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
            title: count == 1
                ? "1 item hasn't synced in \(days) day\(days == 1 ? "" : "s")"
                : "\(count) items haven't synced in \(days) day\(days == 1 ? "" : "s")",
            meta: "iCloud Drive · reported by bird",
            reason: "bird still has \(count) item\(count == 1 ? "" : "s") scheduled for upload, but its last attempt on the oldest was \(days) day\(days == 1 ? "" : "s") ago. The item names are redacted by macOS, so Birdwatch can only report the count and the age.",
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

    /// Enriches the brctl-status-derived engine info with the dump's internals.
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
                line += " · \(Format.sizeNonisolated(done)) of \(Format.sizeNonisolated(total))"
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

    private static func percent(_ value: Double) -> String {
        String(format: value < 10 && value != value.rounded() ? "%.1f%%" : "%.0f%%", value)
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
