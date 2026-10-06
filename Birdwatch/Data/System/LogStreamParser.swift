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
    ///
    /// Also nil for JSON objects that are not log events: `log stream` ends
    /// with a `{"count":N,"finished":1}` trailer (captured in the fixture),
    /// and an object with no parseable `timestamp` would otherwise need a
    /// made-up time (C1). Every real event carries both fields.
    static func parse(line: String) -> LogLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        guard let message = object["eventMessage"] as? String,
              let stamp = object["timestamp"] as? String,
              let date = dateFormatter.date(from: stamp) else { return nil }
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
