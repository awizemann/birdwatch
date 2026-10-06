import Foundation
@testable import Birdwatch

/// Test oracle: the regex implementation `BrctlDumpParser` used before its
/// byte-scanning rewrite (commit 21f8446), kept verbatim except for the
/// deliberate behaviour changes listed below. `BrctlDumpOracleTests` requires
/// the production parser to agree with it on every fixture line and on a
/// deterministic set of mutations.
///
/// Deliberate differences from the original regex code, each marked `CHANGE`:
/// 1. `\b` uses the simple word-boundary rule. Swift `Regex`'s default (UAX #29)
///    sees no word start in glued keys such as `pcs:up:`; bird never glues
///    keys, and the byte scanner uses the ASCII rule.
/// 2. Quoted `n:"…"` values are masked before searching for field keys and
///    kind tokens, so a file name cannot be read as a field.
/// 3. `sz:N bytes` is tried before the parenthesised count, and the count may
///    not cross another `key:` (`\bsz:[^(:]*\(`), so `sz:0 bytes tsz:13 KB
///    (13309)` is 0.
/// 4. Kind token: `dir` or `dir-fault` after whitespace (not `\bdir\b`).
/// Not modelled (inputs avoid them): CRLF line endings — the old Character
/// split kept `\r\n` as one Character and never split such a dump, the byte
/// parser splits on `\n`; and non-ASCII bytes directly before a key, which the
/// byte scanner always treats as word characters.
nonisolated enum ReferenceBrctlDumpParser {

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
                let keys = maskQuotedNames(trimmed) // CHANGE 2
                if trimmed.hasPrefix("> ") {
                    if lastItemIndex == nil, let idle = idleAnchorLine, let item = parseItemLine(idle) {
                        dump.pendingItems.append(item)
                        lastItemIndex = dump.pendingItems.count - 1
                    }
                    applyOperationLine(trimmed, toItemAt: lastItemIndex, in: &dump)
                } else if isItemLine(keys) {
                    lastItemIndex = nil
                    idleAnchorLine = nil
                    if keys.contains("up:idle ") {
                        idleAnchorLine = trimmed
                    } else if let item = parseItemLine(trimmed) {
                        dump.pendingItems.append(item)
                        lastItemIndex = dump.pendingItems.count - 1
                    }
                } else {
                    lastItemIndex = nil
                    idleAnchorLine = nil
                }
                accumulateDeviceActivity(keys, into: &dump)
            case .other:
                if trimmed.hasPrefix("global progress") {
                    dump.globalProgress = parseGlobalProgress(trimmed)
                }
                accumulateDeviceActivity(maskQuotedNames(trimmed), into: &dump)
            }
        }

        dump.pendingItems.removeAll { $0.uploadState == "idle" && $0.interestingOperations.isEmpty }
        for index in dump.pendingItems.indices {
            guard let library = dump.pendingItems[index].appLibraryID else { continue }
            dump.pendingItems[index].containerPattern = dump.appLibraryPatterns[library]
        }
        dump.deviceActivity.sort { $0.index < $1.index }
        return dump
    }

    /// CHANGE 2: every `n:"…"` value's characters replaced with `x`.
    static func maskQuotedNames(_ line: String) -> String {
        var masked = line
        for match in line.matches(of: (/\bn:"([^"]*)"/).wordBoundaryKind(.simple)).reversed() {
            let value = match.1
            masked.replaceSubrange(value.startIndex..<value.endIndex,
                                   with: String(repeating: "x", count: value.count))
        }
        return masked
    }

    static func parseAppLibraryIdentifier(_ line: String) -> (pattern: String, id: Int)? {
        if let m = line.firstMatch(of: /^-{4,}(\S+?)\[(\d+)\]-{4,}$/), let id = Int(m.2) {
            return (String(m.1), id)
        }
        if let m = line.firstMatch(of: /^\+\s*app library:\s*<(\S+?)\[(\d+)\]\s/), let id = Int(m.2) {
            return (String(m.1), id)
        }
        return nil
    }

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
        case "syncUpBudget": state.budget = BrctlDumpParser.parseBudget(value)
        case "containerMetadataSync":
            if let t = value.firstMatch(of: /data=([A-Za-z0-9+\/=]+)/) { state.serverChangeToken = String(t.1) }
            if let d = value.firstMatch(of: /lastSyncDate:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/) {
                state.lastMetadataSyncDate = parseLocalDate(String(d.1))
            }
        default: break
        }
    }

    private static func parseDeviceLine(_ line: String) -> BrctlDumpDevice? {
        guard let m = line.firstMatch(of: /^o\s+"(.*)"\s+\((\d+)\)$/), let index = Int(m.2) else { return nil }
        let name = String(m.1)
        return BrctlDumpDevice(index: index, redactedName: name, nameIsRedacted: name.contains(/\{\d+\}/))
    }

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
        case "global sync up budget": state.budget = BrctlDumpParser.parseBudget(value)
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

    private static func plusKeyValue(_ line: String) -> (String, String)? {
        guard let m = line.firstMatch(of: /^\+\s*([^:]+):\s*(.*)$/) else { return nil }
        let value = String(m.2).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return (String(m.1).trimmingCharacters(in: .whitespaces), value)
    }

    private static func parseSyncHealthLine(_ line: String, into report: inout BrctlSyncHealthReport) {
        guard let m = line.firstMatch(of: /^([A-Za-z]+Error):\s*(.+)$/) else { return }
        let value = String(m.2).trimmingCharacters(in: .whitespaces)
        guard value != "none" else { return }
        report.errors[String(m.1)] = value
    }

    private static func isItemLine(_ line: String) -> Bool {
        line.contains("up:") && line.contains("i:<")
    }

    static func parseItemLine(_ line: String) -> BrctlPendingItem? {
        let keys = maskQuotedNames(line) // CHANGE 2
        guard isItemLine(keys) else { return nil }
        guard let state = keys.firstMatch(of: (/\bup:([a-z][a-z-]*)/).wordBoundaryKind(.simple)) else { return nil }
        guard let id = keys.firstMatch(of: (/\bi:<([^>]+)>/).wordBoundaryKind(.simple)) else { return nil }

        var item = BrctlPendingItem(itemID: String(id.1), uploadState: String(state.1))
        if let m = keys.firstMatch(of: /^r:(\d+)/) { item.rank = Int(m.1) }
        if let m = keys.firstMatch(of: (/\bal:(\d+)/).wordBoundaryKind(.simple)) { item.appLibraryID = Int(m.1) }
        item.isDirectory = keys.contains(/(?:^|\s)dir(?:-fault)?(?:\s|\}|$)/) // CHANGE 4
        // The value comes from the unmasked line: the first unmasked match is
        // the first masked region.
        if let m = line.firstMatch(of: (/\bn:"([^"]*)"/).wordBoundaryKind(.simple)) {
            let name = String(m.1)
            item.redactedName = name
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                item.fileExtension = String(name[name.index(after: dot)...])
            }
        }
        // CHANGE 3
        if let m = keys.firstMatch(of: (/\bsz:(\d+) bytes/).wordBoundaryKind(.simple)) {
            item.byteSize = Int64(m.1)
        } else if let m = keys.firstMatch(of: (/\bsz:[^(:]*\((\d+)\)/).wordBoundaryKind(.simple)) {
            item.byteSize = Int64(m.1)
        }
        if let m = keys.firstMatch(of: (/\bdevice:(\d+)/).wordBoundaryKind(.simple)) { item.deviceIndex = Int(m.1) }
        return item
    }

    private static func applyOperationLine(_ line: String, toItemAt index: Int?, in dump: inout BrctlDump) {
        guard let index, dump.pendingItems.indices.contains(index) else { return }
        if let progress = BrctlDumpParser.parseProgressLine(line) {
            dump.pendingItems[index].progress = progress
        } else if let operation = parseOperationLine(line) {
            dump.pendingItems[index].operations.append(operation)
        }
    }

    static func parseOperationLine(_ line: String) -> BrctlDumpOperation? {
        guard let m = line.firstMatch(of: /^>\s*([a-z-]+)\{\[(.*)\]\}/) else { return nil }
        let kind = BrctlDumpOperation.Kind(rawValue: String(m.1)) ?? .unknown
        let body = String(m.2)
        var operation = BrctlDumpOperation(kind: kind)

        if let old = body.firstMatch(of: /^(\d+) old$/) {
            operation.supersededCount = Int(old.1)
            return operation
        }
        if let m = body.firstMatch(of: (/\bzone:(\d+)/).wordBoundaryKind(.simple)) { operation.zone = Int(m.1) }
        if let m = body.firstMatch(of: (/\battempts:(\d+)/).wordBoundaryKind(.simple)) { operation.attempts = Int(m.1) }
        if let m = body.firstMatch(of: (/\blast:([0-9.]+[smhd]) ago/).wordBoundaryKind(.simple)) {
            operation.lastAttemptAgo = parseDuration(String(m.1))
        }
        if let m = body.firstMatch(of: (/\bnext:(\S+?)(?:\s|$|\])/).wordBoundaryKind(.simple)) {
            let next = String(m.1)
            operation.isReadyToRetry = next == "ready"
            operation.nextRetryIn = parseDuration(next)
        }
        if let m = body.firstMatch(of: (/\bcleanup:(\S+?)(?:\s|$|\])/).wordBoundaryKind(.simple)) {
            operation.cleanupIn = parseDuration(String(m.1))
        }
        let head = body.split(separator: "attempts:", maxSplits: 1).first.map(String.init) ?? body
        let words = head.split(separator: " ").map(String.init).filter { !$0.hasPrefix("zone:") }
        if !words.isEmpty { operation.state = words.joined(separator: " ") }
        return operation
    }

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

    private static func parseGlobalProgress(_ line: String) -> BrctlGlobalProgress? {
        guard !line.contains("{none}") else { return nil }
        var progress = BrctlGlobalProgress()
        if let m = line.firstMatch(of: /\bf:([0-9.]+)/) { progress.fraction = Double(m.1) }
        if let m = line.firstMatch(of: /\buc:(\d+)\/(\d+)/) {
            progress.uploadedBytes = Int64(m.1)
            progress.totalBytes = Int64(m.2)
        }
        return progress.fraction == nil && progress.uploadedBytes == nil ? nil : progress
    }

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
