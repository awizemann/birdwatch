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

/// Parses `log show --predicate 'subsystem == "com.apple.cloudkit" …'` output in
/// either the plain default style (the macOS 26 beta fixture) or
/// `--style ndjson` (what the source requests). Equality predicates + in-code
/// filtering on purpose: CONTAINS predicates measured slower than filtering
/// here (see the Phase 5 research note).
///
/// Two passes, because attribution needs a lookup table built from the whole
/// window first:
///   1. Container → bundle, from two kinds of evidence:
///      - cloudd's TCC-approval lines (`containerID=… applicationBundleID=…`),
///        authoritative wherever they exist (macOS 15/26);
///      - the EMITTING client process of `container=` operation lines (ndjson
///        `processImagePath`, resolved to a bundle id by an injected resolver).
///        macOS 27.0 GA no longer logs the TCC lines at all, so this is the
///        only attribution left there. cloudd itself never owns a container.
///      Client operation lines carry both `container=` and `operationGroupID=`,
///      giving group → container.
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
        // `\n`, `}` and `)` too: ndjson messages are multi-line (scheduler
        // activities print `relatedApplications=(\n …)`) and wrap fields in
        // `resolvedConfig={ … }`.
        let end = rest.firstIndex {
            $0 == "," || $0 == ";" || $0 == ">" || $0 == " " || $0 == "\n" || $0 == "}" || $0 == ")"
        } ?? rest.endIndex
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

    /// POSIX-fixed parser for the log's timestamp column. DateFormatter is
    /// Sendable in this SDK (thread-safe once configured) and this one is never
    /// mutated after initialization, so a plain static let suffices.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    /// Operation class on a line: `<CKDUploadAssetsOperation:` → `UploadAssets`,
    /// `<CKModifyRecordsOperation:` → `ModifyRecords`. Client (`CK…`) and daemon
    /// (`CKD…`) spellings collapse to the same kind.
    static func operationKind(in line: Substring) -> String? {
        if let kind = codeOperationKind(in: line) { return kind }
        guard let open = line.range(of: "<CK") else { return nil }
        let rest = line[open.lowerBound...].dropFirst()      // drop "<"
        let end = rest.firstIndex { !$0.isLetter && !$0.isNumber } ?? rest.endIndex
        var token = String(rest[rest.startIndex..<end])
        guard token.hasSuffix("Operation") else { return nil }
        token.removeLast("Operation".count)
        if token.hasPrefix("CKD") { token.removeFirst(3) } else if token.hasPrefix("CK") { token.removeFirst(2) }
        return token.isEmpty ? nil : token
    }

    private static let codeOperationPrefix = "<_TtGC12CloudKitCode13CodeOperation"

    /// macOS 27 GA: some clients (cloudphotod's asset downloads) run CloudKit's
    /// Swift `CodeOperation<Request, Response>` instead of a `CK…Operation`
    /// class, and the log prints its mangled generic name:
    /// `<_TtGC12CloudKitCode13CodeOperationV22CloudKitImplementation23ResourceDownloadRequestVS1_24ResourceDownloadResponse_:`
    /// The kind is the first length-prefixed identifier ending in `Request`,
    /// minus that suffix (`ResourceDownload`). Anything that does not decode
    /// cleanly is not an operation we recognise — nil, never a guess.
    static func codeOperationKind(in line: Substring) -> String? {
        guard let open = line.range(of: codeOperationPrefix) else { return nil }
        var rest = line[open.upperBound...]
        while let next = rest.first {
            if next.isNumber {
                // `<len><identifier>`: is this the request type?
                let digits = rest.prefix { $0.isNumber }
                guard let length = Int(digits), length > 0 else { return nil }
                rest = rest.dropFirst(digits.count)
                let identifier = rest.prefix(length)
                guard identifier.count == length,
                      identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
                rest = rest.dropFirst(length)
                if identifier.hasSuffix("Request"), identifier.count > "Request".count {
                    return String(identifier.dropLast("Request".count))
                }
            } else if next == "S" {
                // Substitution `S<n>_` refers back to an earlier identifier.
                rest = rest.dropFirst()
                rest = rest.drop { $0.isNumber }
                if rest.first == "_" { rest = rest.dropFirst() }
            } else if next.isLetter || next == "_" {
                rest = rest.dropFirst()        // mangling marker (`V`, `_`)
            } else {
                return nil                     // `:` / space: the name ended
            }
        }
        return nil
    }

    /// `ResourceDownload` is the GA CodeOperation spelling of an asset
    /// download (captured from cloudphotod; see the photos-download fixture).
    static func isAssetTransfer(_ kind: String) -> Bool {
        kind == "UploadAssets" || kind == "DownloadAssets" || kind == "ResourceDownload"
    }

    static func isThrottle(_ line: Substring) -> Bool {
        line.range(of: "throttle", options: .caseInsensitive) != nil
    }

    // MARK: Line model

    /// One log event, whichever style it arrived in.
    struct Line: Sendable {
        /// The plain-style line, or the ndjson `eventMessage`.
        var text: Substring
        /// ndjson `timestamp`; nil for plain lines, whose timestamp leads `text`.
        var timestampText: Substring? = nil
        /// ndjson `processImagePath` of the EMITTING process; nil for plain lines.
        var processImagePath: String? = nil

        var date: Date? { CloudKitLogParser.timestamp(in: timestampText ?? text) }
    }

    /// The ndjson fields the parser reads; every other key is ignored.
    private struct NDJSONEvent: Decodable {
        var eventMessage: String?
        var timestamp: String?
        var processImagePath: String?
        var userID: Int?
    }

    private static let operationOpenBytes = Array("<CK".utf8)

    /// Splits `log show` output into events, keeping only the ones that can
    /// contribute (see `isInteresting`). ndjson lines are byte-gated BEFORE the
    /// JSON decode, so noise never pays for it. The trailing ndjson summary
    /// object (no `eventMessage`) drops out naturally.
    ///
    /// `userID`, when given, keeps only ndjson events logged by that uid: the
    /// unified log is system-wide, so under fast user switching another
    /// logged-in user's apps would otherwise surface as this user's rows.
    /// (Measured on macOS 27 GA: the only other uids logging CloudKit are
    /// root and `_accessoryupdater` system daemons.) Plain-style lines carry
    /// no uid and are kept.
    static func lines(_ output: String, userID: Int? = nil) -> [Line] {
        let decoder = JSONDecoder()
        var result: [Line] = []
        var undecodable = 0
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard raw.first == "{" else {
                if isInteresting(raw) { result.append(Line(text: raw)) }
                continue
            }
            guard containsUTF8(raw, containerBytes) || containsUTF8(raw, operationOpenBytes) else { continue }
            let event: NDJSONEvent
            do {
                event = try decoder.decode(NDJSONEvent.self, from: Data(raw.utf8))
            } catch {
                undecodable += 1
                continue
            }
            if let userID, event.userID != userID { continue }
            guard let message = event.eventMessage else { continue }
            let text = Substring(message)
            guard isInteresting(text) else { continue }
            result.append(Line(
                text: text,
                timestampText: event.timestamp.map { Substring($0) },
                processImagePath: event.processImagePath
            ))
        }
        if undecodable > 0 {
            logger.warning("skipped \(undecodable, privacy: .public) undecodable ndjson log lines")
        }
        return result
    }

    /// cloudd logs `container=` while acting FOR a client; it never owns one.
    static func isCloudKitDaemon(_ processImagePath: String) -> Bool {
        processImagePath.split(separator: "/").last == "cloudd"
    }

    // MARK: Aggregation

    /// Per-container aggregation over the whole window. Pure and total: garbage
    /// in yields an empty result, never a crash.
    ///
    /// `bundleForImage` turns an emitting process's executable path into a
    /// bundle id (production: `CloudKitProcessResolver`). It is called at most
    /// once per distinct path, and only for containers that cloudd's TCC lines
    /// did not already attribute. The default attributes nothing by process.
    ///
    /// `isUserFacing` says whether a resolved bundle has an app the user would
    /// recognise (production: maps via `daemonToApp` or resolves through
    /// LaunchServices). Owners are chosen among user-facing candidates FIRST,
    /// so a chatty helper with no app can never outvote the real app and then
    /// vanish at row assembly, taking the app's row with it. Only when no
    /// candidate is user-facing does the plain line-count vote apply (that
    /// keeps system-service attribution for the scan outcome).
    static func containerActivity(
        _ output: String,
        userID: Int? = nil,
        bundleForImage: (String) -> String? = { _ in nil },
        isUserFacing: (String) -> Bool = { _ in false }
    ) -> [String: CloudKitContainerActivity] {
        var bundleForContainer: [String: String] = [:]
        var containerForGroup: [String: String] = [:]
        var linesPerImage: [String: [String: Int]] = [:]     // container → image path → lines
        // PREFILTER: both passes below run over the same lines, so pay the
        // byte-level gate once. On a real 30m cloudd window this drops the
        // large majority of lines before any timestamp parse or field scan.
        let lines = lines(output, userID: userID)

        // Pass 1 — attribution tables.
        for line in lines {
            let text = line.text
            if text.contains("containerID="), text.contains("applicationBundleID="),
               let container = value(of: "containerID", in: text),
               let bundle = value(of: "applicationBundleID", in: text) {
                bundleForContainer[normalizeContainer(container)] = bundle
            }
            if let container = value(of: "container", in: text).map(normalizeContainer) {
                if let group = value(of: "operationGroupID", in: text) {
                    containerForGroup[group] = container
                }
                if let image = line.processImagePath, !image.isEmpty, !isCloudKitDaemon(image) {
                    linesPerImage[container, default: [:]][image, default: 0] += 1
                }
            }
        }

        // Process evidence fills only what cloudd made no TCC statement about.
        // A container several processes touch goes to the user-facing bundle
        // that emitted the most lines for it; failing that, to the bundle with
        // the most lines (ties: lowest bundle id, for determinism).
        var resolvedImages: [String: String?] = [:]
        var userFacing: [String: Bool] = [:]
        func facing(_ bundle: String) -> Bool {
            if let known = userFacing[bundle] { return known }
            let answer = isUserFacing(bundle)
            userFacing[bundle] = answer
            return answer
        }
        for (container, images) in linesPerImage where bundleForContainer[container] == nil {
            var linesPerBundle: [String: Int] = [:]
            for (image, count) in images {
                let bundle: String?
                if let cached = resolvedImages[image] {
                    bundle = cached
                } else {
                    bundle = bundleForImage(image)
                    resolvedImages[image] = bundle
                }
                if let bundle { linesPerBundle[bundle, default: 0] += count }
            }
            func byVote(_ lhs: (key: String, value: Int), _ rhs: (key: String, value: Int)) -> Bool {
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }
            let owner = linesPerBundle.filter { facing($0.key) }.max(by: byVote)
                ?? linesPerBundle.max(by: byVote)
            if let owner { bundleForContainer[container] = owner.key }
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
            let text = line.text
            // Establish that the line is attributable BEFORE paying for the
            // DateFormatter round-trip — the timestamp parse was the single
            // most expensive per-line step and most lines never get credited.
            let container: String? = value(of: "container", in: text).map(normalizeContainer)
                ?? value(of: "containerID", in: text).map(normalizeContainer)
                ?? value(of: "operationGroupID", in: text).flatMap { containerForGroup[$0] }
            guard let containerID = container else { continue }
            guard let when = line.date else { continue }

            touch(containerID) { entry in
                entry.lastActivity = max(entry.lastActivity ?? when, when)
                if isThrottle(text) { entry.lastThrottle = max(entry.lastThrottle ?? when, when) }
                guard let kind = operationKind(in: text) else { return }
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
    static func parse(
        _ output: String, now: Date = Date(), bundleForImage: (String) -> String? = { _ in nil }
    ) -> [CloudKitAppActivity] {
        activities(from: containerActivity(output, bundleForImage: bundleForImage), now: now)
    }

    /// The roll-up half of `parse`, for callers that also need the raw
    /// per-container map (the source classifies the scan outcome from it).
    static func activities(
        from containers: [String: CloudKitContainerActivity], now: Date
    ) -> [CloudKitAppActivity] {
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
        // macOS 27 GA: Safari's CloudKit traffic is emitted by these two agents
        // (embedded Info.plist ids). On the macOS 26 beta cloudd's TCC lines
        // attributed the very same SafariShared.* containers to com.apple.Safari
        // (cloudkit-log-sample.txt), so the mapping is observed, not guessed.
        "com.apple.SafariBookmarksSyncAgent": "com.apple.Safari",
        "com.apple.Safari.History": "com.apple.Safari",
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

    /// Collapses observed bundle ids that resolve to the same user-facing app
    /// (Safari's two sync agents, imagent + imtransferagent) into ONE activity,
    /// keyed by the user-facing bundle id. Merging — rather than keeping the
    /// first alias — keeps every container and the strongest observed state.
    /// Skipped bundles (bird) are absent from the result.
    static func mergedByUserFacingApp(_ activities: [CloudKitAppActivity]) -> [String: CloudKitAppActivity] {
        func rank(_ state: CloudKitActivityState) -> Int {
            switch state {
            case .transferring: return 3
            case .pushing: return 2
            case .throttled: return 1
            case .idle: return 0
            }
        }
        var merged: [String: CloudKitAppActivity] = [:]
        for activity in activities {
            guard let facing = userFacingBundleID(for: activity.bundleID) else { continue }
            guard var existing = merged[facing] else {
                merged[facing] = CloudKitAppActivity(
                    bundleID: facing, containers: activity.containers, lastActivity: activity.lastActivity,
                    state: activity.state, operationCount: activity.operationCount)
                continue
            }
            existing.containers = Array(Set(existing.containers + activity.containers)).sorted()
            existing.lastActivity = [existing.lastActivity, activity.lastActivity].compactMap { $0 }.max()
            if rank(activity.state) > rank(existing.state) { existing.state = activity.state }
            existing.operationCount += activity.operationCount
            merged[facing] = existing
        }
        return merged
    }

    // MARK: Row assembly (pure — the resolved display name is injected)

    /// Age-free on purpose: the line is computed once per scan (every ~5 min)
    /// and shown next to the row's LIVE relative `lastActivity`, so a baked-in
    /// "now" or "12m ago" would go stale and disagree with it. `now` only
    /// rejects a future-dated `lastActivity`.
    static func statusLine(state: CloudKitActivityState, lastActivity: Date?, now: Date) -> String {
        switch state {
        case .transferring: return "Transferring"
        case .pushing: return "Pushing changes"
        case .throttled: return "Throttled by iCloud"
        case .idle:
            guard let lastActivity, now.timeIntervalSince(lastActivity) >= 0 else { return "No recent activity" }
            return "Last activity in cloudd's log"
        }
    }

    /// Transferring, pushing and throttled are all work in flight with no
    /// progress figure; only an idle container is quiet.
    static func status(for state: CloudKitActivityState) -> AppSyncStatus {
        switch state {
        case .transferring, .pushing, .throttled: .active
        case .idle: .upToDate
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
            // No progress is knowable — never a fabricated percentage — but
            // observed work is not "up to date" either.
            status: status(for: activity.state),
            statusLine: statusLine(state: activity.state, lastActivity: activity.lastActivity, now: now),
            lastActivity: activity.lastActivity,
            // cloudd reports none of these to a third-party app.
            itemCount: nil,
            pendingItems: nil,
            localSize: nil,
            locationPath: "",
            infoCallout: "\(displayName) syncs through CloudKit in \(activity.containers.count) container\(activity.containers.count == 1 ? "" : "s") (\(containerList)). \(calloutSuffix)"
        )
    }
}

// MARK: - Process → bundle resolution

/// Turns the executable path an ndjson log line names (`processImagePath`)
/// into a bundle id, from the file system alone — no LaunchServices guessing:
///   - inside an `.app`: the OUTERMOST enclosing app's Info.plist (a helper
///     nested in `Foo.app/Contents/…` syncs on behalf of Foo);
///   - a bare daemon executable: its embedded `__info_plist` section, which
///     carries the same ids cloudd's TCC lines used to log
///     (`com.apple.cloudphotod`, `com.apple.syncdefaultsd`, `com.apple.bird`).
/// Nil when the path no longer exists or carries no identifier.
nonisolated enum CloudKitProcessResolver {
    static func bundleID(forProcessImagePath path: String) -> String? {
        let components = (path as NSString).pathComponents
        if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appPath = NSString.path(withComponents: Array(components[...appIndex]))
            return Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
        }
        let url = URL(fileURLWithPath: path) as CFURL
        let info = CFBundleCopyInfoDictionaryForURL(url) as? [String: Any]
        return info?["CFBundleIdentifier"] as? String
    }
}

// MARK: - Scan outcome

/// What one scan could honestly say. An empty row list is ambiguous on its
/// own — "nothing syncs through CloudKit" and "this macOS stopped logging the
/// evidence that ties containers to apps" look identical — so the source
/// reports which one it is (C1: no silent empty list).
nonisolated enum CloudKitScanOutcome: Sendable, Hashable {
    /// At least one row, attributed from real log evidence.
    case observedApps
    /// No rows: `attributed` containers belong to system services with no
    /// user-facing app (keychain, KVS, bird…), and `unattributed` containers
    /// could not be tied to anything — a non-zero second count means an app
    /// MAY be syncing that Birdwatch cannot name, so it is not a clean zero.
    case systemServicesOnly(attributed: Int, unattributed: Int)
    /// Containers were active but NONE could be tied to any process or app —
    /// the log no longer carries attribution on this OS. Not "no apps".
    case unattributed(containers: Int)
    /// The window held no CloudKit container activity at all.
    case noActivity
    /// `log show` itself failed (timeout, launch failure, non-zero exit).
    /// The scan's rows, if any, are the last good ones (`isStale`).
    case logUnavailable
}

nonisolated struct CloudKitScan: Sendable {
    var apps: [AppSyncState]
    var outcome: CloudKitScanOutcome
    /// True when `apps` are carried over from an earlier successful scan
    /// because this one could not read the log — kept rather than dropped so
    /// a transient `log show` failure never reads as "nothing syncs".
    var isStale: Bool = false
    /// When the evidence behind `apps` was read (nil: never read successfully).
    var observedAt: Date?
    /// True when even the short fallback window overran the capture cap, so
    /// the parse saw only the OLDEST part of the window and the newest
    /// activity may be missing.
    var isTruncated: Bool = false
}

// MARK: - Source

/// Reads the recent unified-log window for `com.apple.cloudkit` and turns it
/// into the observed CloudKit app rows. Actor-isolated so the ~2s `log show`
/// spawn, the parse and the per-path bundle lookups never touch the MainActor.
actor CloudKitAppSource {
    private let runner: any ProcessRunning
    private let resolveImage: @Sendable (String) -> String?
    private let resolveAppName: @Sendable (String) -> String?
    private let userID: Int
    private static let logPath = "/usr/bin/log"
    /// Successful bundle and LaunchServices lookups are stable for a session;
    /// cache them. Misses are NOT cached: a path read mid-update (a Sparkle
    /// swap) or an app installed mid-session must get another chance.
    private var appNames: [String: String] = [:]
    private var imageBundles: [String: String] = [:]
    /// Rows from the last scan that actually read the log.
    private var lastGood: (apps: [AppSyncState], at: Date)?

    /// Window fed to `log show`. 30m matches the research: long enough to see
    /// every app that syncs at all, short enough that the call stays ~2s.
    static let window = "30m"
    /// Fallback when the 30m read times out or overruns ProcessRunner's
    /// capture cap. The runner keeps the HEAD of stdout, i.e. the OLDEST
    /// events, so a capped window would silently lose exactly the recent
    /// activity that drives the state — a shorter window is the honest fix.
    static let fallbackWindow = "10m"
    /// Timeouts for the two reads. Worst case (primary times out, fallback
    /// times out) is 30 s of spawn — the same bound the single read had.
    static let primaryTimeout: Duration = .seconds(20)
    static let fallbackTimeout: Duration = .seconds(10)

    init(
        runner: any ProcessRunning = ProcessRunner(),
        resolveImage: @escaping @Sendable (String) -> String? = CloudKitProcessResolver.bundleID(forProcessImagePath:),
        resolveAppName: @escaping @Sendable (String) -> String? = CloudKitAppSource.launchServicesName(forBundle:),
        userID: Int = Int(getuid())
    ) {
        self.runner = runner
        self.resolveImage = resolveImage
        self.resolveAppName = resolveAppName
        self.userID = userID
    }

    /// ndjson, because only ndjson carries the emitting `processImagePath` —
    /// the plain style shows a bare process name. `--info` because cloudd
    /// logs most CK messages at Info on macOS 27. OP + CK are the only
    /// categories that carry `container=` / TCC evidence; equality predicates
    /// on them halve the bytes without the CONTAINS penalty. Measured on
    /// macOS 27.0 GA: 1.4–3.4 s for 30m (startup-dominated), ~140 KB.
    static func arguments(window: String) -> [String] {
        [
            "show", "--last", window, "--info", "--style", "ndjson",
            "--predicate", #"subsystem == "com.apple.cloudkit" AND (category == "OP" OR category == "CK")"#,
        ]
    }

    func currentApps(now: Date = Date()) async -> [AppSyncState] {
        await scan(now: now).apps
    }

    func scan(now: Date = Date()) async -> CloudKitScan {
        let output: String
        let isTruncated: Bool
        do {
            (output, isTruncated) = try await readWindow()
        } catch {
            logger.warning("log show (cloudkit) failed: \(RunnerError.publicSummary(of: error), privacy: .public) \(RunnerError.privateDetail(of: error), privacy: .private); keeping \(self.lastGood?.apps.count ?? 0, privacy: .public) last-good rows")
            return CloudKitScan(
                apps: lastGood?.apps ?? [], outcome: .logUnavailable,
                isStale: lastGood != nil, observedAt: lastGood?.at
            )
        }

        let containers = CloudKitLogParser.containerActivity(
            output,
            userID: userID,
            bundleForImage: { self.bundleID(forImage: $0) },
            isUserFacing: { bundle in
                guard let facing = CloudKitAppMapping.userFacingBundleID(for: bundle) else { return false }
                return self.appName(forBundle: facing) != nil
            }
        )
        let activities = CloudKitLogParser.activities(from: containers, now: now)
        var rows: [AppSyncState] = []
        for (facing, activity) in CloudKitAppMapping.mergedByUserFacingApp(activities) {
            guard let name = appName(forBundle: facing) else { continue }   // no installed app → skip
            rows.append(CloudKitAppMapping.makeApp(
                activity: activity, bundleID: facing, displayName: name, now: now
            ))
        }
        rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let attributed = containers.values.filter { $0.bundleID != nil }.count
        let outcome: CloudKitScanOutcome
        if containers.isEmpty {
            outcome = .noActivity
        } else if !rows.isEmpty {
            outcome = .observedApps
        } else if attributed == 0 {
            outcome = .unattributed(containers: containers.count)
            logger.warning("\(containers.count, privacy: .public) CloudKit containers active but none attributable to an app on this OS")
        } else {
            outcome = .systemServicesOnly(attributed: attributed, unattributed: containers.count - attributed)
        }
        logger.info("observed \(rows.count, privacy: .public) CloudKit apps from \(activities.count, privacy: .public) bundle ids, \(attributed, privacy: .public)/\(containers.count, privacy: .public) containers attributed")
        lastGood = (rows, now)
        return CloudKitScan(apps: rows, outcome: outcome, observedAt: now, isTruncated: isTruncated)
    }

    /// The 30m read, falling back to 10m when it times out or overruns the
    /// capture cap. A fallback that ALSO overruns is reported, not hidden.
    /// Launch failures and non-zero exits are not retried — they would fail
    /// the same way.
    private func readWindow() async throws -> (output: String, isTruncated: Bool) {
        do {
            let (output, capped) = try await readLog(window: Self.window, timeout: Self.primaryTimeout)
            guard capped else { return (output, false) }
            logger.warning("cloudkit log window \(Self.window, privacy: .public) hit the capture cap; retrying \(Self.fallbackWindow, privacy: .public)")
        } catch RunnerError.timeout {
            logger.warning("cloudkit log window \(Self.window, privacy: .public) timed out; retrying \(Self.fallbackWindow, privacy: .public)")
        }
        let (output, capped) = try await readLog(window: Self.fallbackWindow, timeout: Self.fallbackTimeout)
        if capped {
            logger.warning("cloudkit fallback window \(Self.fallbackWindow, privacy: .public) also hit the capture cap; newest activity may be missing")
        }
        return (output, capped)
    }

    static func isCapped(_ output: String) -> Bool {
        output.utf8.count >= ProcessRunner.maxCapturedBytes
    }

    /// The runner reports an overrun as `RunnerError.outputTruncated`; this
    /// read can use the kept prefix, so it takes it and flags it capped. A
    /// cap-sized plain result (a stub runner) is flagged the same way.
    private func readLog(window: String, timeout: Duration) async throws -> (output: String, capped: Bool) {
        do {
            let output = try await runner.run(toolPath: Self.logPath, arguments: Self.arguments(window: window), timeout: timeout)
            return (output, Self.isCapped(output))
        } catch RunnerError.outputTruncated(let partial) {
            return (partial, true)
        }
    }

    private func bundleID(forImage path: String) -> String? {
        if let cached = imageBundles[path] { return cached }
        let bundle = resolveImage(path)
        if let bundle { imageBundles[path] = bundle }
        return bundle
    }

    private func appName(forBundle bundleID: String) -> String? {
        if let cached = appNames[bundleID] { return cached }
        let name = resolveAppName(bundleID)
        if let name { appNames[bundleID] = name }
        return name
    }

    /// LaunchServices resolution: presence AND name in one lookup. Returns nil
    /// when nothing is installed for the id — which is exactly the signal used
    /// to drop headless daemons that have no user-facing app.
    ///
    /// NSWorkspace is not MainActor-isolated (no `NS_SWIFT_UI_ACTOR` in
    /// `NSWorkspace.h`), so this runs on the actor's executor, off main.
    nonisolated static func launchServicesName(forBundle bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}

