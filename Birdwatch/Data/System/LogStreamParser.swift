import Foundation

/// Pure parsing for one line of `log stream --style ndjson` output.
/// Nonisolated so any actor (or the readability-handler path) can call it synchronously.
nonisolated enum LogStreamParser {

    /// `log` ndjson timestamps look like "2026-08-14 10:22:33.123456-0700".
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
        return f
    }()

    /// Returns nil for the plain-text "Filtering the log data using …" header
    /// and any other non-JSON garbage — the stream must survive anything `log` emits.
    static func parse(line: String) -> LogLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let message = object["eventMessage"] as? String ?? ""
        let date: Date
        if let stamp = object["timestamp"] as? String, let parsed = dateFormatter.date(from: stamp) {
            date = parsed
        } else {
            date = Date()
        }
        return LogLine(id: UUID(), date: date, level: level(from: object["messageType"] as? String), message: message)
    }

    static func level(from messageType: String?) -> LogLevel {
        switch messageType {
        case "Debug": .debug
        case "Error", "Fault": .error
        default: .info
        }
    }
}
