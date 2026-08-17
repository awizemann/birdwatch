import Foundation

// MARK: - Model

/// One scheduled/retried operation attached to an item in `brctl dump`.
/// Rendered by bird as `> <kind>{[<state> attempts:N last:X ago next:Y cleanup:Z]}`
/// or, for superseded records, `> <kind>{[N old]}`.
nonisolated struct BrctlDumpOperation: Sendable, Equatable {
    nonisolated enum Kind: String, Sendable, Equatable {
        case syncUp = "sync-up"
        case upload
        case downloader
        case apply
        case unknown
    }

    var kind: Kind
    /// Raw state word(s) between `[` and `attempts:` — "active", "inactive",
    /// "sync-up-scheduled", … Kept verbatim; bird invents new ones freely.
    var state: String?
    var attempts: Int?
    /// Seconds since the last attempt (`last:3.83m ago`).
    var lastAttemptAgo: TimeInterval?
    /// `next:ready` → true. `next:12.5m` → false with `nextRetryIn` set.
    var isReadyToRetry: Bool = false
    var nextRetryIn: TimeInterval?
    var cleanupIn: TimeInterval?
    var zone: Int?
    /// `> upload{[1 old]}` — count of superseded records, no live scheduling.
    var supersededCount: Int?

    var isActive: Bool { state?.contains("active") == true && state?.contains("inactive") != true }
    /// A retry that has already failed at least once.
    var isRetrying: Bool { (attempts ?? 0) > 0 }
}

/// Aggregate progress line: `> upload{needs:(count:1, size:… (62914560)) done:(count:0, size:0 bytes)}`
nonisolated struct BrctlDumpProgress: Sendable, Equatable {
    var kind: BrctlDumpOperation.Kind
    var needsCount: Int
    var needsBytes: Int64
    var doneCount: Int
    var doneBytes: Int64
}

/// An item in the client-truth tree that is not `up:idle`, plus any operations
/// bird scheduled for it. File names in the dump are length-redacted by bird
/// (`n:"b{5}2.bin"`), so only the extension is real — never treat `redactedName`
/// as a display name.
nonisolated struct BrctlPendingItem: Sendable, Equatable {
    var itemID: String
    var rank: Int?
    var appLibraryID: Int?
    /// `needs-upload`, `needs-sync-up`, … (never `idle` — idle items are dropped).
    var uploadState: String
    var isDirectory: Bool = false
    var redactedName: String?
    var fileExtension: String?
    var byteSize: Int64?
    var deviceIndex: Int?
    /// The redacted app-library identifier from the block header that precedes
    /// this item (`i{4}d.c{1}m.m{7}t.O{4}e.E{3}l` for `[171]`). Redacted the
    /// same way names are, but it identifies a *container*, and containers are
    /// real directories in `~/Library/Mobile Documents` — so this is what
    /// `RedactedPathResolver` uses to place an item on disk.
    var containerPattern: String?
    var operations: [BrctlDumpOperation] = []
    var progress: BrctlDumpProgress?

    var attempts: Int { operations.compactMap(\.attempts).max() ?? 0 }
    var isRetrying: Bool { operations.contains(where: \.isRetrying) }
    /// Operations that describe live scheduling — `{[N old]}` records are
    /// bookkeeping for already-finished work and carry no state.
    var interestingOperations: [BrctlDumpOperation] { operations.filter { $0.supersededCount == nil } }
}

/// `<BRCSyncBudgetThrottle { m:0.0 h:19.6 d:98.3 }>` and the scheduler's
/// `global sync up budget: budget available { … m:0.0% (0.5) h:0.0% (20.0) d:0.0% (98.7) }`.
nonisolated struct BrctlSyncBudget: Sendable, Equatable {
    /// Free-text verdict preceding the braces, e.g. "budget available".
    var verdict: String?
    var minuteUsedPercent: Double?
    var hourUsedPercent: Double?
    var dayUsedPercent: Double?
    var minuteValue: Double?
    var hourValue: Double?
    var dayValue: Double?
    var measuredAgo: TimeInterval?
}

nonisolated struct BrctlSchedulerState: Sendable, Equatable {
    var clientItemCount: Int?
    var serverItemCount: Int?
    var outputMayBeTruncated: Bool = false
    var pushEnvironment: String?
    var budget: BrctlSyncBudget?
    var periodicSync: String?
    var availableQuotaBytes: Int64?
    var containerMetadata: String?
    var sharedDB: String?
    var zoneHealth: String?
    /// "idle" or a pipe-joined flag set like "itemsNeedUpload|nonIdleItems".
    var syncStatus: String?
    var sideCar: String?
    var pcsMigration: String?

    var syncStatusFlags: [String] { syncStatus.map { $0.split(separator: "|").map(String.init) } ?? [] }
    var isIdle: Bool { syncStatus == "idle" }
}

nonisolated struct BrctlSystemState: Sendable, Equatable {
    var network: String?
    var disk: String?
    var power: String?
    var optimizeStorage: String?
    var cellular: String?
    /// Length-redacted, e.g. `A{15}o`. Never display.
    var redactedDeviceName: String?
}

nonisolated struct BrctlClientState: Sendable, Equatable {
    var availableQuotaBytes: Int64?
    var nonPurgeableSpaceBytes: Int64?
    var purgeableSpaceBytes: Int64?
    var serverChangeToken: String?
    var lastMetadataSyncDate: Date?
    var periodicSyncDate: Date?
    var lastQuotaFetchDate: Date?
    var budget: BrctlSyncBudget?
    var hasCompletedPCSMigration: Bool?
}

/// `SyncHealthReport:` — a fixed set of named error slots, each `none` or an
/// error description. The only per-category error surface bird exposes here.
nonisolated struct BrctlSyncHealthReport: Sendable, Equatable {
    /// Category → raw value, `none` entries dropped.
    var errors: [String: String] = [:]
    var isHealthy: Bool { errors.isEmpty }
}

/// One entry of the `devices:` list. `redactedName` is always length-redacted
/// (`A{15}o`); bird exposes no device class, OS build, or last-seen here.
nonisolated struct BrctlDumpDevice: Sendable, Equatable {
    var index: Int
    var redactedName: String
    var nameIsRedacted: Bool
}

/// Derived from `device:N` + `mt:` on item lines: how many items each device
/// index authored and when it last touched one. Only meaningful on a full
/// (non-`-i`) dump, and counts are lower bounds when the dump is truncated.
nonisolated struct BrctlDeviceActivity: Sendable, Equatable {
    var index: Int
    var itemCount: Int
    var lastModified: Date?
}

/// `global progress {f:0.5742 uc:37932224/66060288}`
nonisolated struct BrctlGlobalProgress: Sendable, Equatable {
    var fraction: Double?
    var uploadedBytes: Int64?
    var totalBytes: Int64?
}

nonisolated struct BrctlDump: Sendable, Equatable {
    var dumpDate: Date?
    var databaseVersion: Int?
    var fsType: String?
    var accountSessionError: String?
    /// `BRCloudDocsErrorDomain:116` — the domain/code pair from the same
    /// `error_info` NSError, kept separate because the description carries the
    /// account UUID and must be redacted before display.
    var accountSessionErrorCode: String?
    var clientState = BrctlClientState()
    var scheduler = BrctlSchedulerState()
    var system = BrctlSystemState()
    var devices: [BrctlDumpDevice] = []
    var pendingItems: [BrctlPendingItem] = []
    var deviceActivity: [BrctlDeviceActivity] = []
    var syncHealth = BrctlSyncHealthReport()
    var globalProgress: BrctlGlobalProgress?
    /// App-library id → redacted container identifier, from the `+ app library:`
    /// list and the `----PATTERN[id]----` block headers. Folded onto each
    /// pending item's `containerPattern` at the end of the parse.
    var appLibraryPatterns: [Int: String] = [:]
    /// bird printed `- not done dumping items -`: the item tree is incomplete.
    var itemsTruncated: Bool = false

    var retryingItems: [BrctlPendingItem] { pendingItems.filter(\.isRetrying) }
}

// MARK: - Parser

/// Pure parsers for `brctl dump` output. No I/O, no isolation.
///
/// Forward-compatible by construction: every field is optional, unknown lines
/// are skipped, and no input can throw. brctl's dump format is undocumented and
/// drifts between OS releases, so a miss must degrade to "unknown", never crash.
///
/// Cost note for callers: `brctl dump -i` (itemless) is ~2s and still contains
/// the header, scheduler, devices, client-truth tree and every scheduled
/// operation. A full `brctl dump` is ~40s / ~90 MB and gets truncated on large
/// accounts; only `deviceActivity` needs it.
nonisolated enum BrctlDumpParser {

    static func parse(_ raw: String) -> BrctlDump {
        let text = BrctlParser.stripANSI(raw)
        var dump = BrctlDump()
        var section = Section.header
        var lastItemIndex: Int?
        var idleAnchorLine: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "- not done dumping items -" { dump.itemsTruncated = true; continue }
            if let library = parseAppLibraryIdentifier(trimmed) {
                // Block headers and the `+ app library:` list agree; whichever
                // comes first wins, so a later duplicate must not clobber it.
                dump.appLibraryPatterns[library.id] = dump.appLibraryPatterns[library.id] ?? library.pattern
                lastItemIndex = nil
                continue
            }
            if let next = Section(header: trimmed) { section = next; lastItemIndex = nil; continue }
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" }) { continue }

            switch section {
            case .header:
                parseHeaderLine(trimmed, into: &dump)
            case .clientState:
                parseClientStateLine(trimmed, into: &dump.clientState)
            case .devices:
                if let device = parseDeviceLine(trimmed) { dump.devices.append(device) }
            case .system:
                parseSystemLine(trimmed, into: &dump.system)
            case .scheduler:
                parseSchedulerLine(trimmed, into: &dump.scheduler)
            case .syncHealth:
                parseSyncHealthLine(trimmed, into: &dump.syncHealth)
            case .containers:
                if trimmed.hasPrefix("> ") {
                    // An idle item was only remembered as a raw line; a `>` line
                    // means it is worth the cost of full field extraction.
                    if lastItemIndex == nil, let idle = idleAnchorLine, let item = parseItemLine(idle) {
                        dump.pendingItems.append(item)
                        lastItemIndex = dump.pendingItems.count - 1
                    }
                    applyOperationLine(trimmed, toItemAt: lastItemIndex, in: &dump)
                } else if isItemLine(trimmed) {
                    lastItemIndex = nil
                    idleAnchorLine = nil
                    if isIdleItemLine(trimmed) {
                        // ~99% of item lines. Defer the ~8 regex extractions.
                        idleAnchorLine = trimmed
                    } else if let item = parseItemLine(trimmed) {
                        dump.pendingItems.append(item)
                        lastItemIndex = dump.pendingItems.count - 1
                    }
                } else {
                    lastItemIndex = nil
                    idleAnchorLine = nil
                }
                accumulateDeviceActivity(trimmed, into: &dump)
            case .other:
                if trimmed.hasPrefix("global progress") {
                    dump.globalProgress = parseGlobalProgress(trimmed)
                }
                accumulateDeviceActivity(trimmed, into: &dump)
            }
        }

        // Idle items are kept only while parsing, to anchor their `>` operation
        // lines (bird schedules `apply` retries on items whose `up:` state is
        // already idle). Drop the ones that turned out to carry nothing.
        dump.pendingItems.removeAll { $0.uploadState == "idle" && $0.interestingOperations.isEmpty }
        for index in dump.pendingItems.indices {
            guard let library = dump.pendingItems[index].appLibraryID else { continue }
            dump.pendingItems[index].containerPattern = dump.appLibraryPatterns[library]
        }
        dump.deviceActivity.sort { $0.index < $1.index }
        return dump
    }

    /// Both spellings of the app-library identifier:
    ///   `----------------------i{4}d.c{1}m.m{7}t.O{4}e.E{3}l[171]----------------------`
    ///   `+ app library: <c{1}m.a{3}e.s{5}x[51] NA {s:no-documents…}>`
    /// The pattern is length-redacted like every name bird prints, but it names
    /// a container directory, which `RedactedPathResolver` can match on disk.
    static func parseAppLibraryIdentifier(_ line: String) -> (pattern: String, id: Int)? {
        if let m = line.firstMatch(of: /^-{4,}(\S+?)\[(\d+)\]-{4,}$/), let id = Int(m.2) {
            return (String(m.1), id)
        }
        if let m = line.firstMatch(of: /^\+\s*app library:\s*<(\S+?)\[(\d+)\]\s/), let id = Int(m.2) {
            return (String(m.1), id)
        }
        return nil
    }

    // MARK: Sections

    private enum Section {
        case header, clientState, devices, system, scheduler, containers, syncHealth, other

        init?(header line: String) {
            switch line {
            case "client_state": self = .clientState
            case "devices:": self = .devices
            case "system": self = .system
            case "scheduler": self = .scheduler
            case "users:", "server_state", "boot_history": self = .other
            case "SyncHealthReport:": self = .syncHealth
            case "Aggregated Telemetry:", "analytics metrics", "apps monitor",
                 "Named Throttle History", "Pending Aggregated Telemetry",
                 "client_pkg_upload_items", "Special Sync Contexts":
                self = .other
            default:
                if line.hasSuffix("containers matching '*'") { self = .containers; return }
                if line.hasSuffix("xpc clients:") || line.hasSuffix("misc operations:") { self = .other; return }
                return nil
            }
        }
    }

    // MARK: Header

    private static func parseHeaderLine(_ line: String, into dump: inout BrctlDump) {
        if let m = line.firstMatch(of: /^dump taken at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4})/) {
            dump.dumpDate = parseOffsetDate(String(m.1))
        } else if let m = line.firstMatch(of: /^database version: (\d+)/) {
            dump.databaseVersion = Int(m.1)
        } else if let m = line.firstMatch(of: /^fsType: (\S+)/) {
            dump.fsType = String(m.1)
        } else if let m = line.firstMatch(of: /NSDescription = \\"([^\\]+)\\"/) {
            dump.accountSessionError = String(m.1)
            if let d = line.firstMatch(of: /<NSError:[^(]*\(([A-Za-z]+Domain:\d+)\)/) {
                dump.accountSessionErrorCode = String(d.1)
            }
        }
    }

    // MARK: client_state

    private static func parseClientStateLine(_ line: String, into state: inout BrctlClientState) {
        guard let m = line.firstMatch(of: /^"?([A-Za-z-]+)"?\s*=\s*(.+);$/) else { return }
        let key = String(m.1)
        var value = String(m.2)
        if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }

        switch key {
        case "availableQuota": state.availableQuotaBytes = Int64(value)
        case "nonPurgeableSpace": state.nonPurgeableSpaceBytes = Int64(value)
        case "purgeableSpace": state.purgeableSpaceBytes = Int64(value)
        case "hasCompletedPCSMigration": state.hasCompletedPCSMigration = value == "1"
        case "lastQuotaFetchDate": state.lastQuotaFetchDate = parseUTCDate(value)
        case "periodicSyncDate": state.periodicSyncDate = parseUTCDate(value)
        case "syncUpBudget": state.budget = parseBudget(value)
        case "containerMetadataSync":
            if let t = value.firstMatch(of: /data=([A-Za-z0-9+\/=]+)/) { state.serverChangeToken = String(t.1) }
            if let d = value.firstMatch(of: /lastSyncDate:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/) {
                state.lastMetadataSyncDate = parseLocalDate(String(d.1))
            }
        default: break
        }
    }

    // MARK: devices

    /// `o "A{15}o" (5)`
    static func parseDeviceLine(_ line: String) -> BrctlDumpDevice? {
        guard let m = line.firstMatch(of: /^o\s+"(.*)"\s+\((\d+)\)$/), let index = Int(m.2) else { return nil }
        let name = String(m.1)
        return BrctlDumpDevice(
            index: index,
            redactedName: name,
            nameIsRedacted: name.contains(/\{\d+\}/)
        )
    }

    // MARK: system / scheduler

    private static func parseSystemLine(_ line: String, into state: inout BrctlSystemState) {
        guard let (key, value) = plusKeyValue(line) else { return }
        switch key {
        case "network": state.network = value
        case "disk": state.disk = value
        case "power": state.power = value
        case "optimize storage": state.optimizeStorage = value
        case "cellular": state.cellular = value
        case "device name": state.redactedDeviceName = value
        default: break
        }
    }

    private static func parseSchedulerLine(_ line: String, into state: inout BrctlSchedulerState) {
        if line.hasPrefix("warning:"), line.contains("truncated") {
            state.outputMayBeTruncated = true
            return
        }
        guard let (key, value) = plusKeyValue(line) else { return }
        switch key {
        case "items":
            if let m = value.firstMatch(of: /client:.*?\((\d+)\)/) { state.clientItemCount = Int(m.1) }
            if let m = value.firstMatch(of: /server:.*?\((\d+)\)/) { state.serverItemCount = Int(m.1) }
        case "push environment": state.pushEnvironment = value
        case "global sync up budget": state.budget = parseBudget(value)
        case "periodic sync": state.periodicSync = value
        case "available quota":
            if let m = value.firstMatch(of: /\((\d+)\)/) { state.availableQuotaBytes = Int64(m.1) }
        case "container-metadata": state.containerMetadata = value
        case "sharedb": state.sharedDB = value
        case "zone-health": state.zoneHealth = value
        case "sync status": state.syncStatus = value
        case "side-car": state.sideCar = value
        case "pcs-migration": state.pcsMigration = value
        default: break
        }
    }

    /// `+ key:   value` → ("key", "value"), value whitespace-trimmed.
    private static func plusKeyValue(_ line: String) -> (String, String)? {
        guard let m = line.firstMatch(of: /^\+\s*([^:]+):\s*(.*)$/) else { return nil }
        let value = String(m.2).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return (String(m.1).trimmingCharacters(in: .whitespaces), value)
    }

    // MARK: budget

    /// Accepts both spellings:
    ///   `<BRCSyncBudgetThrottle {  m:0.0  h:19.6  d:98.3  }>`
    ///   `budget available {  0:03:15s ago  m:0.0% (0.0)  h:0.0% (19.6)  d:0.0% (98.3)  }`
    static func parseBudget(_ raw: String) -> BrctlSyncBudget? {
        guard raw.contains("{") else { return nil }
        var budget = BrctlSyncBudget()
        if let m = raw.firstMatch(of: /^([a-z][a-z ]*[a-z])\s*\{/) { budget.verdict = String(m.1) }
        if let m = raw.firstMatch(of: /(\d+):(\d{2}):(\d{2})s ago/) {
            budget.measuredAgo = (Double(m.1) ?? 0) * 3600 + (Double(m.2) ?? 0) * 60 + (Double(m.3) ?? 0)
        }
        for match in raw.matches(of: /\b([mhd]):([0-9.]+)(%)?(?:\s*\(([0-9.]+)\))?/) {
            let percentForm = match.3 != nil
            let first = Double(match.2)
            let paren = match.4.flatMap { Double($0) }
            let used = percentForm ? first : nil
            let value = percentForm ? paren : first
            switch match.1 {
            case "m": budget.minuteUsedPercent = used; budget.minuteValue = value
            case "h": budget.hourUsedPercent = used; budget.hourValue = value
            default: budget.dayUsedPercent = used; budget.dayValue = value
            }
        }
        return budget
    }

    // MARK: SyncHealthReport

    private static func parseSyncHealthLine(_ line: String, into report: inout BrctlSyncHealthReport) {
        guard let m = line.firstMatch(of: /^([A-Za-z]+Error):\s*(.+)$/) else { return }
        let value = String(m.2).trimmingCharacters(in: .whitespaces)
        guard value != "none" else { return }
        report.errors[String(m.1)] = value
    }

    // MARK: items

    /// A client-truth item line (`r:… i:<ID> … up:<state> …`). Idle items parse
    /// too — `parse` uses them to anchor trailing `>` operation lines and drops
    /// the ones that carry none.
    /// Cheap literal test used to classify the ~130k item lines of a full dump
    /// without paying for a regex on each.
    static func isItemLine(_ line: String) -> Bool {
        line.contains("up:") && line.contains("i:<")
    }

    /// `up:idle` items are the overwhelming majority and are only retained when
    /// an operation line follows, so recognising them must stay allocation-free.
    static func isIdleItemLine(_ line: String) -> Bool {
        line.contains("up:idle ")
    }

    static func parseItemLine(_ line: String) -> BrctlPendingItem? {
        guard isItemLine(line) else { return nil }
        guard let state = line.firstMatch(of: /\bup:([a-z][a-z-]*)/) else { return nil }
        guard let id = line.firstMatch(of: /\bi:<([^>]+)>/) else { return nil }

        var item = BrctlPendingItem(itemID: String(id.1), uploadState: String(state.1))
        if let m = line.firstMatch(of: /^r:(\d+)/) { item.rank = Int(m.1) }
        if let m = line.firstMatch(of: /\bal:(\d+)/) { item.appLibraryID = Int(m.1) }
        item.isDirectory = line.contains(/\bdir\b/)
        if let m = line.firstMatch(of: /\bn:"([^"]*)"/) {
            let name = String(m.1)
            item.redactedName = name
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                item.fileExtension = String(name[name.index(after: dot)...])
            }
        }
        // Prefer the exact byte count in parentheses; `sz:0 bytes` has none.
        if let m = line.firstMatch(of: /\bsz:[^(]*\((\d+)\)/) {
            item.byteSize = Int64(m.1)
        } else if let m = line.firstMatch(of: /\bsz:(\d+) bytes/) {
            item.byteSize = Int64(m.1)
        }
        if let m = line.firstMatch(of: /\bdevice:(\d+)/) { item.deviceIndex = Int(m.1) }
        return item
    }

    private static func applyOperationLine(_ line: String, toItemAt index: Int?, in dump: inout BrctlDump) {
        guard let index, dump.pendingItems.indices.contains(index) else { return }
        if let progress = parseProgressLine(line) {
            dump.pendingItems[index].progress = progress
        } else if let operation = parseOperationLine(line) {
            dump.pendingItems[index].operations.append(operation)
        }
    }

    /// `> upload{needs:(count:1, size:62.9 MB (62914560)) done:(count:0, size:0 bytes)}`
    static func parseProgressLine(_ line: String) -> BrctlDumpProgress? {
        guard let m = line.firstMatch(of: /^>\s*([a-z-]+)\{needs:\((.*?)\)\s*done:\((.*?)\)\s*\}/) else { return nil }
        func pair(_ text: String) -> (Int, Int64) {
            let count = text.firstMatch(of: /count:(\d+)/).flatMap { Int($0.1) } ?? 0
            let bytes = text.firstMatch(of: /size:[^(]*\((\d+)\)/).flatMap { Int64($0.1) }
                ?? text.firstMatch(of: /size:(\d+) bytes/).flatMap { Int64($0.1) }
                ?? 0
            return (count, bytes)
        }
        let needs = pair(String(m.2))
        let done = pair(String(m.3))
        return BrctlDumpProgress(
            kind: BrctlDumpOperation.Kind(rawValue: String(m.1)) ?? .unknown,
            needsCount: needs.0, needsBytes: needs.1,
            doneCount: done.0, doneBytes: done.1
        )
    }

    /// `> apply{[ inactive attempts:1 last:3.83m ago cleanup:56.15m]}`
    /// `> sync-up{[zone:1 sync-up-scheduled attempts:0 last:1805.75h ago next:ready cleanup:ready]}`
    /// `> upload{[1 old]}`
    static func parseOperationLine(_ line: String) -> BrctlDumpOperation? {
        guard let m = line.firstMatch(of: /^>\s*([a-z-]+)\{\[(.*)\]\}/) else { return nil }
        let kind = BrctlDumpOperation.Kind(rawValue: String(m.1)) ?? .unknown
        let body = String(m.2)
        var operation = BrctlDumpOperation(kind: kind)

        if let old = body.firstMatch(of: /^(\d+) old$/) {
            operation.supersededCount = Int(old.1)
            return operation
        }
        if let m = body.firstMatch(of: /\bzone:(\d+)/) { operation.zone = Int(m.1) }
        if let m = body.firstMatch(of: /\battempts:(\d+)/) { operation.attempts = Int(m.1) }
        if let m = body.firstMatch(of: /\blast:([0-9.]+[smhd]) ago/) { operation.lastAttemptAgo = parseDuration(String(m.1)) }
        if let m = body.firstMatch(of: /\bnext:(\S+?)(?:\s|$|\])/) {
            let next = String(m.1)
            operation.isReadyToRetry = next == "ready"
            operation.nextRetryIn = parseDuration(next)
        }
        if let m = body.firstMatch(of: /\bcleanup:(\S+?)(?:\s|$|\])/) { operation.cleanupIn = parseDuration(String(m.1)) }
        // State = the leading words before `attempts:`, minus the zone token.
        let head = body.split(separator: "attempts:", maxSplits: 1).first.map(String.init) ?? body
        let words = head.split(separator: " ").map(String.init).filter { !$0.hasPrefix("zone:") }
        if !words.isEmpty { operation.state = words.joined(separator: " ") }
        return operation
    }

    // MARK: device activity

    /// Hand-rolled scan rather than a regex: this runs on every one of ~130k
    /// item lines in a full dump, where the equivalent backtracking regex costs
    /// ~0.3ms/line (≈40s) against ~0.02ms here.
    private static func accumulateDeviceActivity(_ line: String, into dump: inout BrctlDump) {
        guard let ct = line.range(of: "ct{") else { return }
        let tail = line[ct.upperBound...]
        guard let mtRange = tail.range(of: "mt:"),
              let deviceRange = tail.range(of: "device:"),
              let epoch = TimeInterval(digits(in: tail, from: mtRange.upperBound)),
              let index = Int(digits(in: tail, from: deviceRange.upperBound)) else { return }
        let date = Date(timeIntervalSince1970: epoch)
        if let existing = dump.deviceActivity.firstIndex(where: { $0.index == index }) {
            dump.deviceActivity[existing].itemCount += 1
            if let last = dump.deviceActivity[existing].lastModified, last >= date { return }
            dump.deviceActivity[existing].lastModified = date
        } else {
            dump.deviceActivity.append(BrctlDeviceActivity(index: index, itemCount: 1, lastModified: date))
        }
    }

    private static func digits(in text: Substring, from start: Substring.Index) -> String {
        String(text[start...].prefix(while: \.isNumber))
    }

    // MARK: global progress

    /// `global progress {f:0.5742 uc:37932224/66060288}` / `global progress {none}`
    static func parseGlobalProgress(_ line: String) -> BrctlGlobalProgress? {
        guard !line.contains("{none}") else { return nil }
        var progress = BrctlGlobalProgress()
        if let m = line.firstMatch(of: /\bf:([0-9.]+)/) { progress.fraction = Double(m.1) }
        if let m = line.firstMatch(of: /\buc:(\d+)\/(\d+)/) {
            progress.uploadedBytes = Int64(m.1)
            progress.totalBytes = Int64(m.2)
        }
        return progress.fraction == nil && progress.uploadedBytes == nil ? nil : progress
    }

    // MARK: scalars

    /// "3.83m" → 229.8, "1805.75h", "9.89s", "2.5d". "ready"/unknown → nil.
    static func parseDuration(_ text: String) -> TimeInterval? {
        guard let m = text.firstMatch(of: /^([0-9.]+)([smhd])$/), let value = Double(m.1) else { return nil }
        switch m.2 {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        default: return value * 86_400
        }
    }

    private static func parseOffsetDate(_ text: String) -> Date? {
        formatter("yyyy-MM-dd HH:mm:ss.SSSZ", zone: nil).date(from: text)
    }

    private static func parseUTCDate(_ text: String) -> Date? {
        formatter("yyyy-MM-dd HH:mm:ss Z", zone: nil).date(from: text)
    }

    private static func parseLocalDate(_ text: String) -> Date? {
        formatter("yyyy-MM-dd HH:mm:ss", zone: .current).date(from: text)
    }

    private static func formatter(_ format: String, zone: TimeZone?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let zone { formatter.timeZone = zone }
        formatter.dateFormat = format
        return formatter
    }
}
