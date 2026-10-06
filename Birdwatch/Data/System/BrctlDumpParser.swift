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

    /// Performance shape (macOS 27 GA, 4.2 MB / ~14k-line `dump -i`): every
    /// line is classified on raw UTF-8 bytes — prefix and `memmem` checks — and
    /// only the few hundred lines that carry data become a `String` and meet a
    /// regex. Swift `Regex` costs tens of µs per call even on a miss, so a
    /// regex in the per-line path turns a ~0.1 s parse into tens of seconds.
    static func parse(_ raw: String) -> BrctlDump {
        let text = stripANSIBytes(raw)
        // Same bytes with every quoted `n:"…"` value blanked: field keys and
        // kind tokens are searched here so a file name can never be read as a
        // field. Offsets match `text`, which still supplies the name itself.
        var keyText = text
        maskQuotedNames(&keyText)
        var dump = BrctlDump()
        var section = Section.header
        var lastItemIndex: Int?

        text.withUnsafeBufferPointer { buffer in keyText.withUnsafeBufferPointer { keyBuffer in
            // A deferred `up:idle` item line, kept as bytes until a `>` line
            // proves it worth a full parse.
            var idleAnchor: ItemLine?
            var lineStart = 0
            while lineStart <= buffer.count {
                let lineEnd = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? buffer.count
                let range = trimmedRange(of: lineStart..<lineEnd, in: buffer)
                let line = Bytes(rebasing: buffer[range])
                let keys = Bytes(rebasing: keyBuffer[range])
                lineStart = lineEnd + 1

                if line.isEmpty { continue }
                if line.elementsEqual("- not done dumping items -".utf8) { dump.itemsTruncated = true; continue }
                if let library = appLibraryIdentifier(in: line) {
                    // Block headers and the `+ app library:` list agree; whichever
                    // comes first wins, so a later duplicate must not clobber it.
                    dump.appLibraryPatterns[library.id] = dump.appLibraryPatterns[library.id] ?? library.pattern
                    lastItemIndex = nil
                    continue
                }
                if let next = Section(header: string(line)) { section = next; lastItemIndex = nil; continue }
                if line.allSatisfy({ $0 == UInt8(ascii: "-") }) { continue }

                switch section {
                case .header:
                    parseHeaderLine(string(line), into: &dump)
                case .clientState:
                    parseClientStateLine(string(line), into: &dump.clientState)
                case .devices:
                    if let device = parseDeviceLine(string(line)) { dump.devices.append(device) }
                case .system:
                    parseSystemLine(string(line), into: &dump.system)
                case .scheduler:
                    parseSchedulerLine(string(line), into: &dump.scheduler)
                case .syncHealth:
                    parseSyncHealthLine(string(line), into: &dump.syncHealth)
                case .containers:
                    if hasPrefix(line, "> ") {
                        // `> dir-faults:N` (macOS 27) annotates a directory fault;
                        // it is not an operation and must not promote the anchor.
                        // (The operation grammar rejects it too; this skip makes
                        // the intent explicit and avoids a wasted item parse.)
                        if hasPrefix(line, "> dir-faults:") { continue }
                        // An idle item was only remembered as raw bytes; a `>` line
                        // means it is worth the cost of full field extraction.
                        if lastItemIndex == nil, let idle = idleAnchor, let item = parseItemLine(idle) {
                            dump.pendingItems.append(item)
                            lastItemIndex = dump.pendingItems.count - 1
                        }
                        applyOperationLine(line, toItemAt: lastItemIndex, in: &dump)
                    } else if isItemLine(keys) {
                        lastItemIndex = nil
                        idleAnchor = nil
                        if contains(keys, "up:idle ") {
                            // ~99% of item lines. Defer the full field extraction.
                            idleAnchor = ItemLine(text: line, keys: keys)
                        } else if let item = parseItemLine(ItemLine(text: line, keys: keys)) {
                            dump.pendingItems.append(item)
                            lastItemIndex = dump.pendingItems.count - 1
                        }
                    } else {
                        lastItemIndex = nil
                        idleAnchor = nil
                    }
                    accumulateDeviceActivity(keys, into: &dump)
                case .other:
                    if hasPrefix(line, "global progress") {
                        dump.globalProgress = parseGlobalProgress(string(line))
                    }
                    accumulateDeviceActivity(keys, into: &dump)
                }
            }
        } }

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
        var line = line
        return line.withUTF8 { appLibraryIdentifier(in: $0) }
    }

    /// Reference grammar for `appLibraryIdentifier(in:)`. Only consulted for
    /// candidate lines containing non-ASCII bytes, where `\S`/`\d` are Unicode-aware.
    private static func appLibraryIdentifierByRegex(_ line: String) -> (pattern: String, id: Int)? {
        if let m = line.firstMatch(of: /^-{4,}(\S+?)\[(\d+)\]-{4,}$/), let id = Int(m.2) {
            return (String(m.1), id)
        }
        if let m = line.firstMatch(of: /^\+\s*app library:\s*<(\S+?)\[(\d+)\]\s/), let id = Int(m.2) {
            return (String(m.1), id)
        }
        return nil
    }

    /// Hand-rolled equivalent of the two regexes above. It is tried on every
    /// line of the dump, where even a failing Swift `Regex` costs ~50–100 µs.
    private static func appLibraryIdentifier(in line: Bytes) -> (pattern: String, id: Int)? {
        let isBlockHeader = hasPrefix(line, "----")
        guard isBlockHeader || hasPrefix(line, "+") else { return nil }
        if line.contains(where: { $0 >= 0x80 }) { return appLibraryIdentifierByRegex(string(line)) }
        return isBlockHeader ? blockHeaderIdentifier(line) : appLibraryListIdentifier(line)
    }

    /// `^-{4,}(\S+?)\[(\d+)\]-{4,}$`. Everything after the matching `[` is
    /// digits, `]` and dashes, so it can only be the line's last `[`.
    private static func blockHeaderIdentifier(_ line: Bytes) -> (pattern: String, id: Int)? {
        guard let open = line.lastIndex(of: UInt8(ascii: "[")),
              let (id, close) = bracketedNumber(in: line, at: open),
              line.count - (close + 1) >= 4,
              line[(close + 1)...].allSatisfy({ $0 == UInt8(ascii: "-") }) else { return nil }
        let leadingDashes = line.prefix(while: { $0 == UInt8(ascii: "-") }).count
        // The greedy dash run leaves at least one character for the pattern.
        let start = min(leadingDashes, open - 1)
        guard start >= 4, !line[start..<open].contains(where: isASCIIWhitespace) else { return nil }
        return (string(Bytes(rebasing: line[start..<open])), id)
    }

    /// `^\+\s*app library:\s*<(\S+?)\[(\d+)\]\s` — the pattern is the shortest
    /// non-blank run ending at a `[digits]` that is followed by whitespace.
    private static func appLibraryListIdentifier(_ line: Bytes) -> (pattern: String, id: Int)? {
        var i = 1
        while i < line.count, isASCIIWhitespace(line[i]) { i += 1 }
        guard hasPrefix(Bytes(rebasing: line[i...]), "app library:") else { return nil }
        i += "app library:".utf8.count
        while i < line.count, isASCIIWhitespace(line[i]) { i += 1 }
        guard i < line.count, line[i] == UInt8(ascii: "<") else { return nil }
        let start = i + 1
        var k = start
        while k < line.count, !isASCIIWhitespace(line[k]) {
            if k > start, line[k] == UInt8(ascii: "["), let (id, close) = bracketedNumber(in: line, at: k),
               close + 1 < line.count, isASCIIWhitespace(line[close + 1]) {
                return (string(Bytes(rebasing: line[start..<k])), id)
            }
            k += 1
        }
        return nil
    }

    /// `[digits]` starting at `open` → (value, index of the `]`).
    private static func bracketedNumber(in line: Bytes, at open: Int) -> (Int, Int)? {
        var close = open + 1
        while close < line.count, (0x30...0x39).contains(line[close]) { close += 1 }
        guard close > open + 1, close < line.count, line[close] == UInt8(ascii: "]"),
              let value = Int(string(Bytes(rebasing: line[(open + 1)..<close]))) else { return nil }
        return (value, close)
    }

    /// The ASCII members of regex `\s`.
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    // MARK: Byte-level line scanning

    /// One trimmed line of the ANSI-stripped dump, as UTF-8 bytes. Only valid
    /// inside `parse`'s `withUnsafeBufferPointer` scope.
    private typealias Bytes = UnsafeBufferPointer<UInt8>

    /// An item line twice over: `text` for values (the name), `keys` — the same
    /// offsets with quoted names blanked — for locating fields and tokens.
    private struct ItemLine {
        var text: Bytes
        var keys: Bytes
    }

    /// Removes CSI sequences (`ESC [ params intermediates final`) in one pass
    /// over the UTF-8 bytes. Same grammar as `BrctlParser.stripANSI`'s regex;
    /// the regex rewrite of a 4 MB dump alone took seconds. Internal for tests.
    static func stripANSIBytes(_ raw: String) -> [UInt8] {
        var input = raw
        return input.withUTF8 { src in
            var out = [UInt8]()
            out.reserveCapacity(src.count)
            var i = 0
            while i < src.count {
                if src[i] == 0x1B, i + 1 < src.count, src[i + 1] == UInt8(ascii: "[") {
                    var j = i + 2
                    while j < src.count, (0x30...0x39).contains(src[j]) || src[j] == UInt8(ascii: ";") || src[j] == UInt8(ascii: "?") { j += 1 }
                    while j < src.count, (0x20...0x2F).contains(src[j]) { j += 1 }
                    // Parameter, intermediate and final byte ranges are disjoint,
                    // so greedy scanning never needs to backtrack.
                    if j < src.count, (0x40...0x7E).contains(src[j]) {
                        i = j + 1
                        continue
                    }
                }
                out.append(src[i])
                i += 1
            }
            return out
        }
    }

    /// `range` of `buffer` without leading/trailing `.whitespaces`. bird indents
    /// with ASCII spaces, so that is the fast path; a non-ASCII edge byte (an
    /// NBSP, say) falls back to a Unicode scalar trim, as the old String code did.
    private static func trimmedRange(of range: Range<Int>, in buffer: Bytes) -> Range<Int> {
        var start = range.lowerBound, end = range.upperBound
        while start < end, buffer[start] == 0x20 || buffer[start] == 0x09 { start += 1 }
        while end > start, buffer[end - 1] == 0x20 || buffer[end - 1] == 0x09 { end -= 1 }
        guard start < end, buffer[start] >= 0x80 || buffer[end - 1] >= 0x80 else { return start..<end }

        let scalars = string(Bytes(rebasing: buffer[start..<end])).unicodeScalars
        let isBlank = { (scalar: Unicode.Scalar) in CharacterSet.whitespaces.contains(scalar) }
        let leading = scalars.prefix(while: isBlank).reduce(0) { $0 + UTF8.width($1) }
        guard start + leading < end else { return end..<end }
        let trailing = scalars.reversed().prefix(while: isBlank).reduce(0) { $0 + UTF8.width($1) }
        return (start + leading)..<(end - trailing)
    }

    /// Overwrites the inside of every quoted `n:"…"` value with `x`, line by
    /// line. Mirrors the old `\bn:"([^"]*)"` scan: a value runs to the next
    /// `"` on the same line, and an unterminated one is left alone.
    static func maskQuotedNames(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var from = 0
            while from < buffer.count,
                  let hitPointer = memmem(base + from, buffer.count - from, "n:\"", 3) {
                let hit = base.distance(to: hitPointer.assumingMemoryBound(to: UInt8.self))
                from = hit + 1
                guard hit == 0 || !isWordByte(buffer[hit - 1]) else { continue }
                var close = hit + 3
                while close < buffer.count, buffer[close] != UInt8(ascii: "\""), buffer[close] != UInt8(ascii: "\n") {
                    close += 1
                }
                guard close < buffer.count, buffer[close] == UInt8(ascii: "\"") else { continue }
                for index in (hit + 3)..<close { buffer[index] = UInt8(ascii: "x") }
                from = close + 1
            }
        }
    }

    private static func string(_ bytes: Bytes) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static func hasPrefix(_ line: Bytes, _ prefix: StaticString) -> Bool {
        line.count >= prefix.utf8CodeUnitCount
            && memcmp(line.baseAddress!, prefix.utf8Start, prefix.utf8CodeUnitCount) == 0
    }

    /// Byte offset of the first occurrence of `needle` at or after `from`.
    private static func find(_ needle: StaticString, in line: Bytes, from: Int = 0) -> Int? {
        guard from < line.count, let base = line.baseAddress else { return nil }
        guard let hit = memmem(base + from, line.count - from, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
    }

    private static func contains(_ line: Bytes, _ needle: StaticString) -> Bool {
        find(needle, in: line) != nil
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

    /// Cheap literal pre-filter for a client-truth item line
    /// (`r:… i:<ID> … up:<state> …`), run on every line without a regex.
    /// Pass the name-masked bytes so a quoted name cannot qualify a line.
    private static func isItemLine(_ keys: Bytes) -> Bool {
        contains(keys, "up:") && contains(keys, "i:<")
    }

    /// Parses one item line. Idle items parse too — `parse` uses them to anchor
    /// trailing `>` operation lines and drops the ones that carry none.
    static func parseItemLine(_ line: String) -> BrctlPendingItem? {
        let text = Array(line.utf8)
        var keys = text
        maskQuotedNames(&keys)
        return text.withUnsafeBufferPointer { text in
            keys.withUnsafeBufferPointer { keys in parseItemLine(ItemLine(text: text, keys: keys)) }
        }
    }

    /// Byte scan of the fields below (regex spelling in each comment). Runs once
    /// per pending item, and a bulk upload can schedule thousands of them.
    /// Keys and tokens are found in `keys`, so a file name such as
    /// `"a device:7 dir.txt"` cannot pose as a field; only the name is read
    /// from `text`.
    private static func parseItemLine(_ item: ItemLine) -> BrctlPendingItem? {
        let line = item.keys
        guard isItemLine(line) else { return nil }
        // `\bup:([a-z][a-z-]*)`
        guard let state = firstValue(after: "up:", in: line, { start in
            guard start < line.count, isLowercase(line[start]) else { return nil }
            var end = start + 1
            while end < line.count, isLowercase(line[end]) || line[end] == UInt8(ascii: "-") { end += 1 }
            return start..<end
        }) else { return nil }
        // `\bi:<([^>]+)>`
        guard let id = firstValue(after: "i:<", in: line, { start in
            guard let close = line[start...].firstIndex(of: UInt8(ascii: ">")), close > start else { return nil }
            return start..<close
        }) else { return nil }

        var result = BrctlPendingItem(itemID: text(line, id), uploadState: text(line, state))
        // `^r:(\d+)`
        if hasPrefix(line, "r:"), let rank = digitRun(in: line, at: 2) { result.rank = Int(text(line, rank)) }
        // `\bal:(\d+)`
        if let library = firstValue(after: "al:", in: line, { digitRun(in: line, at: $0) }) {
            result.appLibraryID = Int(text(line, library))
        }
        // The kind is a bare space-delimited token after the name: `dir`, `doc`,
        // and on macOS 27 also `dir-fault` — a directory bird has not listed
        // yet (seen on `.Trash` entries, followed by a `> dir-faults:N` line).
        // It is still a folder on disk, which `RedactedPathResolver` matches
        // against, so both tokens mean directory.
        result.isDirectory = hasKindToken("dir", in: line) || hasKindToken("dir-fault", in: line)
        // `\bn:"([^"]*)"` — located in `keys`, read from `text`.
        if let name = firstValue(after: "n:\"", in: line, { start in
            line[start...].firstIndex(of: UInt8(ascii: "\"")).map { start..<$0 }
        }) {
            let name = text(item.text, name)
            result.redactedName = name
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                result.fileExtension = String(name[name.index(after: dot)...])
            }
        }
        // `sz:0 bytes` (`\bsz:(\d+) bytes`) first: it has no parenthesised
        // count, and the next field often does (`tsz:13 KB (13309)`). Otherwise
        // the exact count in parentheses, which must belong to this value —
        // `\bsz:[^(:]*\((\d+)\)`, i.e. no other `key:` before the `(`.
        let size = firstValue(after: "sz:", in: line, { start -> Range<Int>? in
            guard let digits = digitRun(in: line, at: start),
                  hasPrefix(Bytes(rebasing: line[digits.upperBound...]), " bytes") else { return nil }
            return digits
        }) ?? firstValue(after: "sz:", in: line, { start -> Range<Int>? in
            guard let open = line[start...].firstIndex(where: { $0 == UInt8(ascii: "(") || $0 == UInt8(ascii: ":") }),
                  line[open] == UInt8(ascii: "("),
                  let digits = digitRun(in: line, at: open + 1),
                  digits.upperBound < line.count, line[digits.upperBound] == UInt8(ascii: ")") else { return nil }
            return digits
        })
        if let size { result.byteSize = Int64(text(line, size)) }
        // `\bdevice:(\d+)`
        if let device = firstValue(after: "device:", in: line, { digitRun(in: line, at: $0) }) {
            result.deviceIndex = Int(text(line, device))
        }
        return result
    }

    /// `token` standing alone: preceded by the line start or whitespace and
    /// followed by whitespace, `}` or the line end. Deliberately narrower than
    /// the old `\bdir\b` (which also fired after `{`, `"`, `-`, …): bird always
    /// prints the kind after a space.
    private static func hasKindToken(_ token: StaticString, in line: Bytes) -> Bool {
        var from = 0
        while let hit = find(token, in: line, from: from) {
            let end = hit + token.utf8CodeUnitCount
            if hit == 0 || isASCIIWhitespace(line[hit - 1]),
               end == line.count || isASCIIWhitespace(line[end]) || line[end] == UInt8(ascii: "}") {
                return true
            }
            from = hit + 1
        }
        return false
    }

    private static func applyOperationLine(_ line: Bytes, toItemAt index: Int?, in dump: inout BrctlDump) {
        guard let index, dump.pendingItems.indices.contains(index) else { return }
        // Progress lines are rare; only they carry `{needs:(`, so the regex
        // never runs on the common operation lines.
        if contains(line, "{needs:("), let progress = parseProgressLine(string(line)) {
            dump.pendingItems[index].progress = progress
        } else if let operation = parseOperationLine(bytes: line) {
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
        var line = line
        return line.withUTF8 { parseOperationLine(bytes: $0) }
    }

    /// Byte scan of `^>\s*([a-z-]+)\{\[(.*)\]\}` and the body fields (regex
    /// spelling in each comment). One per pending item, like `parseItemLine`.
    private static func parseOperationLine(bytes line: Bytes) -> BrctlDumpOperation? {
        guard hasPrefix(line, ">") else { return nil }
        var kindStart = 1
        while kindStart < line.count, isASCIIWhitespace(line[kindStart]) { kindStart += 1 }
        var kindEnd = kindStart
        while kindEnd < line.count, isLowercase(line[kindEnd]) || line[kindEnd] == UInt8(ascii: "-") { kindEnd += 1 }
        guard kindEnd > kindStart, hasPrefix(Bytes(rebasing: line[kindEnd...]), "{[") else { return nil }
        // `(.*)` is greedy: the body runs to the line's last `]}`.
        let bodyStart = kindEnd + 2
        var bodyEnd = line.count - 2
        while bodyEnd >= bodyStart, !(line[bodyEnd] == UInt8(ascii: "]") && line[bodyEnd + 1] == UInt8(ascii: "}")) {
            bodyEnd -= 1
        }
        guard bodyEnd >= bodyStart else { return nil }

        let kind = BrctlDumpOperation.Kind(rawValue: text(line, kindStart..<kindEnd)) ?? .unknown
        let body = Bytes(rebasing: line[bodyStart..<bodyEnd])
        var operation = BrctlDumpOperation(kind: kind)

        // `^(\d+) old$`
        if let count = digitRun(in: body, at: 0),
           Bytes(rebasing: body[count.upperBound...]).elementsEqual(" old".utf8) {
            operation.supersededCount = Int(text(body, count))
            return operation
        }
        // `\bzone:(\d+)`, `\battempts:(\d+)`
        if let zone = firstValue(after: "zone:", in: body, { digitRun(in: body, at: $0) }) {
            operation.zone = Int(text(body, zone))
        }
        if let attempts = firstValue(after: "attempts:", in: body, { digitRun(in: body, at: $0) }) {
            operation.attempts = Int(text(body, attempts))
        }
        // `\blast:([0-9.]+[smhd]) ago`
        if let last = firstValue(after: "last:", in: body, { start -> Range<Int>? in
            var end = start
            while end < body.count, isDecimal(body[end]) { end += 1 }
            guard end > start, end < body.count, isDurationUnit(body[end]),
                  hasPrefix(Bytes(rebasing: body[(end + 1)...]), " ago") else { return nil }
            return start..<(end + 1)
        }) {
            operation.lastAttemptAgo = parseDuration(text(body, last))
        }
        // `\bnext:(\S+?)(?:\s|$|\])`
        if let next = firstValue(after: "next:", in: body, { schedulingWord(in: body, at: $0) }) {
            let next = text(body, next)
            operation.isReadyToRetry = next == "ready"
            operation.nextRetryIn = parseDuration(next)
        }
        // `\bcleanup:(\S+?)(?:\s|$|\])`
        if let cleanup = firstValue(after: "cleanup:", in: body, { schedulingWord(in: body, at: $0) }) {
            operation.cleanupIn = parseDuration(text(body, cleanup))
        }
        // State = the leading words before `attempts:`, minus the zone token.
        let bodyText = string(body)
        let head = bodyText.split(separator: "attempts:", maxSplits: 1).first.map(String.init) ?? bodyText
        let words = head.split(separator: " ").map(String.init).filter { !$0.hasPrefix("zone:") }
        if !words.isEmpty { operation.state = words.joined(separator: " ") }
        return operation
    }

    /// `(\S+?)(?:\s|$|\])` at `start`: at least one non-blank byte, then up to
    /// (not including) the next whitespace or `]`.
    private static func schedulingWord(in line: Bytes, at start: Int) -> Range<Int>? {
        guard start < line.count, !isASCIIWhitespace(line[start]) else { return nil }
        var end = start + 1
        while end < line.count, !isASCIIWhitespace(line[end]), line[end] != UInt8(ascii: "]") { end += 1 }
        return start..<end
    }

    // MARK: Byte-level field helpers

    /// The first occurrence of `key` at a word start (regex `\b`: line start or
    /// a preceding byte outside `[A-Za-z0-9_]`) whose following bytes `value`
    /// accepts — the same "keep searching" behaviour as `firstMatch(of:)`.
    /// Swift `Regex`'s default `\b` follows UAX #29, which also sees no word
    /// start in `up:sz:` (letter `:` letter); bird separates its keys with
    /// spaces, so the simpler ASCII rule gives identical results on real dumps.
    private static func firstValue(
        after key: StaticString, in line: Bytes, _ value: (Int) -> Range<Int>?
    ) -> Range<Int>? {
        var from = 0
        while let hit = find(key, in: line, from: from) {
            if hit == 0 || !isWordByte(line[hit - 1]), let range = value(hit + key.utf8CodeUnitCount) {
                return range
            }
            from = hit + 1
        }
        return nil
    }

    /// A non-empty ASCII digit run starting at `start`.
    private static func digitRun(in line: Bytes, at start: Int) -> Range<Int>? {
        var end = start
        while end < line.count, (0x30...0x39).contains(line[end]) { end += 1 }
        return end > start ? start..<end : nil
    }

    private static func text(_ line: Bytes, _ range: Range<Int>) -> String {
        string(Bytes(rebasing: line[range]))
    }

    /// Non-ASCII bytes count as word characters, so a key glued to a Unicode
    /// letter is never mistaken for a word start.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == UInt8(ascii: "_") || byte >= 0x80
    }

    private static func isLowercase(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) }
    private static func isDecimal(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) || byte == UInt8(ascii: ".") }
    private static func isDurationUnit(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "s") || byte == UInt8(ascii: "m") || byte == UInt8(ascii: "h") || byte == UInt8(ascii: "d")
    }

    // MARK: device activity

    /// Hand-rolled scan rather than a regex: this runs on every one of ~130k
    /// item lines in a full dump, where the equivalent backtracking regex costs
    /// ~0.3ms/line (≈40s) against ~0.02ms here.
    private static func accumulateDeviceActivity(_ line: Bytes, into dump: inout BrctlDump) {
        guard let ct = find("ct{", in: line) else { return }
        let tail = ct + 3
        guard let mt = find("mt:", in: line, from: tail),
              let device = find("device:", in: line, from: tail),
              let epoch = TimeInterval(digits(in: line, from: mt + 3)),
              let index = Int(digits(in: line, from: device + 7)) else { return }
        let date = Date(timeIntervalSince1970: epoch)
        if let existing = dump.deviceActivity.firstIndex(where: { $0.index == index }) {
            dump.deviceActivity[existing].itemCount += 1
            if let last = dump.deviceActivity[existing].lastModified, last >= date { return }
            dump.deviceActivity[existing].lastModified = date
        } else {
            dump.deviceActivity.append(BrctlDeviceActivity(index: index, itemCount: 1, lastModified: date))
        }
    }

    /// The ASCII digit run starting at `start` ("" when there is none).
    private static func digits(in line: Bytes, from start: Int) -> String {
        var end = start
        while end < line.count, (0x30...0x39).contains(line[end]) { end += 1 }
        return string(Bytes(rebasing: line[start..<end]))
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
    /// Byte form of `^([0-9.]+)([smhd])$`.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let bytes = Array(text.utf8)
        guard let unit = bytes.last, isDurationUnit(unit), bytes.count > 1,
              bytes.dropLast().allSatisfy(isDecimal),
              let value = Double(String(decoding: bytes.dropLast(), as: UTF8.self)) else { return nil }
        switch unit {
        case UInt8(ascii: "s"): return value
        case UInt8(ascii: "m"): return value * 60
        case UInt8(ascii: "h"): return value * 3600
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
