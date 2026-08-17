import Foundation
import AppKit
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "cloudkit-apps")

// MARK: - Observed model

/// What cloudd's log actually says an app is doing right now. Every field is
/// observed — a container that never appears simply has no entry (absence is
/// the signal; Birdwatch never invents a row for an app that isn't syncing).
nonisolated enum CloudKitActivityState: String, Sendable, nonisolated Hashable {
    case transferring   // CKDUpload/DownloadAssetsOperation in the recent window
    case pushing        // CKDModifyRecordsOperation in the recent window
    case throttled      // cloudd parked the container's queue
    case idle           // seen in the window, nothing recent
}

/// Aggregated log evidence for one CloudKit *container*.
nonisolated struct CloudKitContainerActivity: Sendable, nonisolated Hashable {
    var containerID: String
    var bundleID: String?
    var lastActivity: Date?
    var lastAssetTransfer: Date?
    var lastModifyRecords: Date?
    var lastFetch: Date?
    var lastThrottle: Date?
    var operationCount: Int = 0
}

/// Aggregated log evidence for one *app* (one bundle id may own several
/// containers — Safari has CloudTabs, History, Settings, Bookmarks).
nonisolated struct CloudKitAppActivity: Sendable, nonisolated Hashable {
    var bundleID: String
    var containers: [String]
    var lastActivity: Date?
    var state: CloudKitActivityState
    var operationCount: Int
}

// MARK: - Parser (pure, nonisolated, fixture-tested)

/// Parses `log show --predicate 'subsystem == "com.apple.cloudkit"'` plain-text
/// output. Wide predicate + in-code filtering on purpose: CONTAINS predicates
/// measured slower than filtering here (see the Phase 5 research note).
///
/// Two passes, because attribution needs a lookup table built from the whole
/// window first:
///   1. `containerID=… applicationBundleID=…` (cloudd's TCC-approval lines) give
///      container → bundle. Client operation lines carry both `container=` and
///      `operationGroupID=`, giving group → container.
///   2. Every operation line is attributed to a container directly (`container=`)
///      or through its operation group — this is the ONLY way cloudd's own
///      `CKDUploadAssetsOperation` lines (which log no container) can be
///      credited to an app.
nonisolated enum CloudKitLogParser {

    /// Recency window for "actively moving data" states.
    static let activeWindow: TimeInterval = 300      // 5 minutes
    /// Recency window for a throttle to still be worth reporting.
    static let throttleWindow: TimeInterval = 600    // 10 minutes

    // MARK: Field extraction

    /// Value of `key=` up to the first terminator (`,`, `;`, `>`, whitespace).
    static func value(of key: String, in line: Substring) -> String? {
        guard let range = line.range(of: key + "=") else { return nil }
        let rest = line[range.upperBound...]
        let end = rest.firstIndex { $0 == "," || $0 == ";" || $0 == ">" || $0 == " " } ?? rest.endIndex
        let raw = rest[rest.startIndex..<end]
        return raw.isEmpty ? nil : String(raw)
    }

    /// `com.apple.photos.cloud:Production` → `com.apple.photos.cloud`.
    static func normalizeContainer(_ id: String) -> String {
        id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
    }

    /// True when `needle` occurs in `haystack`, compared byte-wise over UTF-8.
    ///
    /// `String.contains` walks grapheme clusters and normalizes; over a 30-minute
    /// cloudd window (hundreds of thousands of lines, several passes each) that
    /// dominated the parse. The log is ASCII, so a naive byte scan is both
    /// correct here and an order of magnitude cheaper.
    static func containsUTF8(_ haystack: Substring, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first else { return true }
        let utf8 = haystack.utf8
        var start = utf8.startIndex
        while let hit = utf8[start...].firstIndex(of: first) {
            var cursor = utf8.index(after: hit)
            var offset = 1
            var matched = true
            while offset < needle.count {
                guard cursor < utf8.endIndex, utf8[cursor] == needle[offset] else { matched = false; break }
                cursor = utf8.index(after: cursor)
                offset += 1
            }
            if matched { return true }
            start = utf8.index(after: hit)
        }
        return false
    }

    private static let containerBytes = Array("container".utf8)
    private static let ckBytes = Array("CK".utf8)

    /// Cheap byte-level gate run before ANY other work on a line.
    ///
    /// Every downstream step needs either an attribution key (`container=`,
    /// `containerID=`) or an operation class (`<CK…Operation:`). A line with
    /// neither can never contribute, so rejecting it here skips the timestamp
    /// parse, the field extraction, and the case-insensitive throttle scan —
    /// which is the bulk of the cost on a window that is mostly noise.
    static func isInteresting(_ line: Substring) -> Bool {
        containsUTF8(line, containerBytes) || containsUTF8(line, ckBytes)
    }

    /// Leading `log show` timestamp: `2026-08-14 15:43:09.855209-0400`.
    static func timestamp(in line: Substring) -> Date? {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        return formatter.date(from: "\(fields[0]) \(fields[1])")
    }

    /// POSIX-fixed parser for the log's timestamp column. `nonisolated(unsafe)`
    /// is safe here: DateFormatter is documented thread-safe for reads once
    /// configured, and this one is never mutated after initialization.
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    /// Operation class on a line: `<CKDUploadAssetsOperation:` → `UploadAssets`,
    /// `<CKModifyRecordsOperation:` → `ModifyRecords`. Client (`CK…`) and daemon
    /// (`CKD…`) spellings collapse to the same kind.
    static func operationKind(in line: Substring) -> String? {
        guard let open = line.range(of: "<CK") else { return nil }
        let rest = line[open.lowerBound...].dropFirst()      // drop "<"
        let end = rest.firstIndex { !$0.isLetter && !$0.isNumber } ?? rest.endIndex
        var token = String(rest[rest.startIndex..<end])
        guard token.hasSuffix("Operation") else { return nil }
        token.removeLast("Operation".count)
        if token.hasPrefix("CKD") { token.removeFirst(3) } else if token.hasPrefix("CK") { token.removeFirst(2) }
        return token.isEmpty ? nil : token
    }

    static func isAssetTransfer(_ kind: String) -> Bool {
        kind == "UploadAssets" || kind == "DownloadAssets"
    }

    static func isThrottle(_ line: Substring) -> Bool {
        line.range(of: "throttle", options: .caseInsensitive) != nil
    }

    // MARK: Aggregation

    /// Per-container aggregation over the whole window. Pure and total: garbage
    /// in yields an empty result, never a crash.
    static func containerActivity(_ output: String) -> [String: CloudKitContainerActivity] {
        var bundleForContainer: [String: String] = [:]
        var containerForGroup: [String: String] = [:]
        // PREFILTER: both passes below run over the same lines, so pay the
        // byte-level gate once. On a real 30m cloudd window this drops the
        // large majority of lines before any timestamp parse or field scan.
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
            .filter(isInteresting)

        // Pass 1 — attribution tables.
        for line in lines {
            if line.contains("containerID="), line.contains("applicationBundleID="),
               let container = value(of: "containerID", in: line),
               let bundle = value(of: "applicationBundleID", in: line) {
                bundleForContainer[normalizeContainer(container)] = bundle
            }
            if let container = value(of: "container", in: line),
               let group = value(of: "operationGroupID", in: line) {
                containerForGroup[group] = normalizeContainer(container)
            }
        }

        // Pass 2 — credit every operation line to a container.
        var result: [String: CloudKitContainerActivity] = [:]
        func touch(_ containerID: String, _ mutate: (inout CloudKitContainerActivity) -> Void) {
            var entry = result[containerID]
                ?? CloudKitContainerActivity(containerID: containerID, bundleID: bundleForContainer[containerID])
            entry.bundleID = entry.bundleID ?? bundleForContainer[containerID]
            mutate(&entry)
            result[containerID] = entry
        }

        for line in lines {
            // Establish that the line is attributable BEFORE paying for the
            // DateFormatter round-trip — the timestamp parse was the single
            // most expensive per-line step and most lines never get credited.
            let container: String? = value(of: "container", in: line).map(normalizeContainer)
                ?? value(of: "containerID", in: line).map(normalizeContainer)
                ?? value(of: "operationGroupID", in: line).flatMap { containerForGroup[$0] }
            guard let containerID = container else { continue }
            guard let when = timestamp(in: line) else { continue }

            touch(containerID) { entry in
                entry.lastActivity = max(entry.lastActivity ?? when, when)
                if isThrottle(line) { entry.lastThrottle = max(entry.lastThrottle ?? when, when) }
                guard let kind = operationKind(in: line) else { return }
                entry.operationCount += 1
                if isAssetTransfer(kind) {
                    entry.lastAssetTransfer = max(entry.lastAssetTransfer ?? when, when)
                } else if kind == "ModifyRecords" {
                    entry.lastModifyRecords = max(entry.lastModifyRecords ?? when, when)
                } else if kind.hasPrefix("Fetch") {
                    entry.lastFetch = max(entry.lastFetch ?? when, when)
                }
            }
        }
        return result
    }

    /// Container evidence rolled up per bundle id, with the derived state.
    static func parse(_ output: String, now: Date = Date()) -> [CloudKitAppActivity] {
        let containers = containerActivity(output)
        var byBundle: [String: [CloudKitContainerActivity]] = [:]
        for entry in containers.values {
            guard let bundle = entry.bundleID else { continue }   // unattributable → dropped
            byBundle[bundle, default: []].append(entry)
        }
        return byBundle.map { bundle, entries in
            CloudKitAppActivity(
                bundleID: bundle,
                containers: entries.map(\.containerID).sorted(),
                lastActivity: entries.compactMap(\.lastActivity).max(),
                state: state(for: entries, now: now),
                operationCount: entries.reduce(0) { $0 + $1.operationCount }
            )
        }.sorted { $0.bundleID < $1.bundleID }
    }

    /// Precedence per the Phase 5 spec: transferring → pushing → throttled → idle.
    static func state(for entries: [CloudKitContainerActivity], now: Date) -> CloudKitActivityState {
        func isRecent(_ date: Date?, _ window: TimeInterval) -> Bool {
            guard let date else { return false }
            let age = now.timeIntervalSince(date)
            return age >= 0 && age <= window
        }
        if entries.contains(where: { isRecent($0.lastAssetTransfer, activeWindow) }) { return .transferring }
        if entries.contains(where: { isRecent($0.lastModifyRecords, activeWindow) }) { return .pushing }
        if entries.contains(where: { isRecent($0.lastThrottle, throttleWindow) }) { return .throttled }
        return .idle
    }
}

// MARK: - Bundle → app mapping

/// Bundle ids observed in the log are frequently *daemons* (cloudphotod syncs
/// for Photos). This table maps the ones with a well-known user-facing app;
/// anything else must resolve through LaunchServices or it is skipped.
nonisolated enum CloudKitAppMapping {

    /// daemon bundle id → user-facing app bundle id.
    static let daemonToApp: [String: String] = [
        "com.apple.cloudphotod": "com.apple.Photos",
        "com.apple.imagent": "com.apple.MobileSMS",
        "com.apple.imtransferagent": "com.apple.MobileSMS",
        "com.apple.remindd": "com.apple.reminders",
        "com.apple.Safari": "com.apple.Safari",
        "com.apple.notesd": "com.apple.Notes",
    ]

    /// Already represented by a first-class row elsewhere in the app list.
    /// `bird` is iCloud Drive / Desktop & Documents — never a second row.
    static let skippedBundles: Set<String> = ["com.apple.bird"]

    /// Stable ids for the apps that other parts of Birdwatch address by name
    /// (SystemSyncSource.logStream(appID:) switches on these).
    static let stableIDs: [String: String] = [
        "com.apple.Photos": "photos",
        "com.apple.MobileSMS": "messages",
        "com.apple.Safari": "safari",
        "com.apple.Notes": "notes",
        "com.apple.reminders": "reminders",
    ]

    /// Design tiles for the apps the design system already named.
    static let tileColors: [String: String] = [
        "photos": "fe4f6d", "notes": "ffcc00", "messages": "34c759",
        "safari": "1e8fff", "reminders": "ff9500",
    ]

    /// The user-facing bundle id an observed bundle id resolves to, or nil when
    /// the row must be skipped entirely.
    static func userFacingBundleID(for bundleID: String) -> String? {
        if skippedBundles.contains(bundleID) { return nil }
        if let mapped = daemonToApp[bundleID] { return mapped }
        return bundleID
    }

    static func appID(forBundle bundleID: String) -> String {
        if let stable = stableIDs[bundleID] { return stable }
        let slug = bundleID.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "ck-" + String(slug)
    }

    static func tileColorHex(appID: String, name: String) -> String {
        tileColors[appID] ?? AppContainerSource.tileColorHex(forName: name)
    }

    static func isAppleBundle(_ bundleID: String) -> Bool { bundleID.hasPrefix("com.apple.") }

    // MARK: Row assembly (pure — the resolved display name is injected)

    static func statusLine(state: CloudKitActivityState, lastActivity: Date?, now: Date) -> String {
        switch state {
        case .transferring: return "Transferring now"
        case .pushing: return "Pushing changes"
        case .throttled: return "Throttled by iCloud"
        case .idle:
            guard let lastActivity else { return "No recent activity" }
            let age = now.timeIntervalSince(lastActivity)
            guard age >= 0 else { return "No recent activity" }
            if age < 60 { return "Last synced just now" }
            let minutes = Int(age / 60)
            if minutes < 60 { return "Last synced \(minutes)m ago" }
            return "Last synced \(minutes / 60)h ago"
        }
    }

    static let calloutSuffix = "Status here is derived from cloudd's own log (container activity, operation types, throttling) — CloudKit exposes no public per-item or per-app progress API, so Birdwatch reports activity and recency, never a made-up percentage."

    static func makeApp(
        activity: CloudKitAppActivity, bundleID: String, displayName: String, now: Date
    ) -> AppSyncState {
        let id = appID(forBundle: bundleID)
        let containerList = activity.containers.joined(separator: ", ")
        return AppSyncState(
            id: id,
            name: displayName,
            tileColorHex: tileColorHex(appID: id, name: displayName),
            backend: .cloudKit,
            isApple: isAppleBundle(bundleID),
            // No progress is knowable — never a fabricated percentage.
            status: .upToDate,
            statusLine: statusLine(state: activity.state, lastActivity: activity.lastActivity, now: now),
            lastActivity: activity.lastActivity,
            itemsIndexed: 0,
            pendingItems: 0,
            localSizeBytes: 0,
            locationPath: "",
            infoCallout: "\(displayName) syncs through CloudKit in \(activity.containers.count) container\(activity.containers.count == 1 ? "" : "s") (\(containerList)). \(calloutSuffix)"
        )
    }
}

// MARK: - Source

/// Reads the recent unified-log window for `com.apple.cloudkit` and turns it
/// into the observed CloudKit app rows. Actor-isolated so the ~2s `log show`
/// spawn and the parse never touch the MainActor.
actor CloudKitAppSource {
    private let runner = ProcessRunner()
    private static let logPath = "/usr/bin/log"
    /// LaunchServices lookups are stable for a session; cache them.
    private var resolved: [String: String?] = [:]

    /// Window fed to `log show`. 30m matches the research: long enough to see
    /// every app that syncs at all, short enough that the call stays ~2s.
    static let window = "30m"

    func currentApps(now: Date = Date()) async -> [AppSyncState] {
        let output: String
        do {
            output = try await runner.run(
                toolPath: Self.logPath,
                arguments: [
                    "show", "--last", Self.window,
                    "--predicate", #"subsystem == "com.apple.cloudkit""#,
                ],
                timeout: .seconds(30)
            )
        } catch {
            logger.warning("log show (cloudkit) failed: \(String(describing: error), privacy: .public)")
            return []
        }
        let activities = CloudKitLogParser.parse(output, now: now)
        var rows: [AppSyncState] = []
        var seen = Set<String>()
        for activity in activities {
            guard let facing = CloudKitAppMapping.userFacingBundleID(for: activity.bundleID) else { continue }
            guard let name = displayName(forBundle: facing) else { continue }   // no installed app → skip
            let id = CloudKitAppMapping.appID(forBundle: facing)
            guard seen.insert(id).inserted else { continue }                    // daemon aliases collapse
            rows.append(CloudKitAppMapping.makeApp(
                activity: activity, bundleID: facing, displayName: name, now: now
            ))
        }
        logger.info("observed \(rows.count, privacy: .public) CloudKit apps from \(activities.count, privacy: .public) bundle ids")
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// LaunchServices resolution: presence AND name in one lookup. Returns nil
    /// when nothing is installed for the id — which is exactly the signal used
    /// to drop headless daemons that have no user-facing app.
    ///
    /// NSWorkspace is not MainActor-isolated (no `NS_SWIFT_UI_ACTOR` in
    /// `NSWorkspace.h`), so this runs on the actor's executor, off main.
    private func displayName(forBundle bundleID: String) -> String? {
        if let cached = resolved[bundleID] { return cached }
        var name: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        resolved[bundleID] = name
        return name
    }
}
