import Foundation

nonisolated struct BrctlAppLine: Sendable, Equatable {
    var name: String
    var isCurrent: Bool
}

nonisolated struct BrctlStatus: Sendable, Equatable {
    var clientState: String?
    var serverState: String?
    var lastSync: Date?
    var isIdle: Bool = false
    var tokenInfo: String?
    var apps: [BrctlAppLine] = []
}

/// Pure parsers for `brctl` output. No I/O, no isolation. Forward-compatible:
/// unknown lines/fields are skipped, never thrown on — brctl's format is
/// undocumented and drifts between OS releases.
nonisolated enum BrctlParser {

    static func parseStatus(_ raw: String) -> BrctlStatus {
        let text = stripANSI(raw)
        var status = BrctlStatus()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            if line.contains("{client:") || line.contains("client:") && line.contains("server:") {
                parseContainerLine(line, into: &status)
            } else if line.contains("current=") {
                if let app = parseAppLine(line) { status.apps.append(app) }
            }
            // Anything else (header counts, future fields): skipped.
        }
        return status
    }

    /// "220606297196 bytes of quota remaining in personal account"
    static func parseQuota(_ raw: String) -> Int64? {
        let text = stripANSI(raw)
        guard let match = text.firstMatch(of: /(\d+)\s+bytes of quota remaining/) else { return nil }
        return Int64(match.1)
    }

    /// brctl colorizes state words; strip CSI sequences before tokenizing.
    static func stripANSI(_ input: String) -> String {
        input.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
    }

    // MARK: - Pieces

    private static func parseContainerLine(_ line: String, into status: inout BrctlStatus) {
        if let m = line.firstMatch(of: /client:([^\s{}]+)/) {
            status.clientState = String(m.1)
            status.isIdle = m.1 == "idle"
        }
        if let m = line.firstMatch(of: /server:([^\s{}]+)/) {
            status.serverState = String(m.1)
        }
        if let m = line.firstMatch(of: /last-sync:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)/) {
            status.lastSync = parseDate(String(m.1))
        }
        // Token info kept raw (e.g. "token:unkown-token-size:36 (Hwo…)") —
        // shown verbatim in diagnostics, never interpreted.
        if let m = line.firstMatch(of: /token:\S+(?:\s+\([^)]*\))?/) {
            status.tokenInfo = String(m.0)
        }
    }

    /// "Desktop & Documents: current=YES lastEnabled=(never) …"
    private static func parseAppLine(_ line: String) -> BrctlAppLine? {
        guard let m = line.firstMatch(of: /^\s*(.+?):\s+current=(YES|NO)\b/) else { return nil }
        return BrctlAppLine(name: String(m.1), isCurrent: m.2 == "YES")
    }

    /// brctl prints local wall-clock time without a zone; interpret in the
    /// current timezone.
    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = string.contains(".")
            ? "yyyy-MM-dd HH:mm:ss.SSS"
            : "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }
}
