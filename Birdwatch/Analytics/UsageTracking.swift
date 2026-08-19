import Foundation
import OSLog
import Stats
import StatsCloudflare

/// The seam between the app and swift-stats. Injected (never a singleton) so
/// tests record events in memory and `--mock` / test runs / keyless dev builds
/// send nothing at all.
///
/// `nonisolated` because this module defaults to MainActor and the real
/// implementation wraps an actor.
nonisolated protocol UsageTracking: Sendable {
    /// Synchronous and ordered: swift-stats 0.2's `record()` takes the
    /// timestamp at the call, preserves arrival order, and hands off to the
    /// actor without a suspension — so a button handler never waits on disk.
    func record(_ event: UsageEvent)
    /// Driven from NSApplication notifications — swift-stats installs no
    /// lifecycle observers. Resign-active only flushes; we deliberately do not
    /// emit `app_background` (every ⌘-tab away would be an event).
    func applicationDidBecomeActive() async
    func flush() async
    /// The master opt-out. Persists inside the SDK.
    func setEnabled(_ enabled: Bool) async
    var isEnabled: Bool { get async }
}

/// swift-stats-backed tracker for shipping builds.
struct StatsUsageTracker: UsageTracking {
    let client: StatsClient

    func record(_ event: UsageEvent) {
        client.record(event.name, props: event.props.mapValues(\.statsValue))
    }
    func applicationDidBecomeActive() async { await client.applicationDidBecomeActive() }
    func flush() async { await client.flush() }
    func setEnabled(_ enabled: Bool) async { await client.setEnabled(enabled) }
    var isEnabled: Bool { get async { await client.isEnabled } }
}

/// Sends nothing, remembers nothing. Used when analytics is gated off.
struct NoopUsageTracker: UsageTracking {
    func record(_ event: UsageEvent) {}
    func applicationDidBecomeActive() async {}
    func flush() async {}
    func setEnabled(_ enabled: Bool) async {}
    var isEnabled: Bool { get async { false } }
}

nonisolated extension UsageValue {
    var statsValue: StatsValue {
        switch self {
        case .string(let s): .string(s)
        case .int(let i): .int(i)
        case .bool(let b): .bool(b)
        }
    }
}

/// Builds the tracker for this launch. Mirrors the Sparkle `updaterEnabled`
/// gates: nothing under XCTest, nothing for `--mock`, nothing without a write
/// key baked into Info.plist (BWStatsWriteKey ← BW_STATS_WRITE_KEY, see
/// project.yml). Constructing `StatsClient` does no I/O, so this is safe in
/// `App.init`.
enum UsageAnalytics {
    static let endpoint = "https://api.swiftstats.co"
    /// Chosen once, never changed: it only decorrelates the random install id
    /// across apps. Not a secret (swift-stats README, consumer checklist §3).
    static let installIdSalt = "birdwatch-2026-heron"

    private static let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "usage")

    static func makeTracker(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        writeKey: String? = Bundle.main.object(forInfoDictionaryKey: "BWStatsWriteKey") as? String
    ) -> any UsageTracking {
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestSessionIdentifier"] == nil,
              !arguments.contains("--mock")
        else { return NoopUsageTracker() }
        guard let writeKey, !writeKey.isEmpty, !writeKey.hasPrefix("$(") else {
            logger.info("Usage analytics disabled: no write key configured")
            return NoopUsageTracker()
        }
        do {
            let client = StatsClient(configuration: StatsConfiguration(
                appId: "com.wizemann.birdwatch",
                projectId: "birdwatch",
                installIdSalt: installIdSalt,
                sink: CloudflareSink(endpoint: try CloudflareEndpoint(string: endpoint), writeKey: writeKey),
                // .identity on (decision 2026-08-18): a hashed random UUID per
                // install so active-install and retention counts are real.
                // Disclosed in the Diagnostics toggle copy.
                consent: .all,
                // No .appBackground: on macOS "left the foreground" is every
                // ⌘-tab, which is noise. Sessions still close on the gap.
                autoEvents: [.appOpen, .sessions]
            ))
            return StatsUsageTracker(client: client)
        } catch {
            logger.error("Usage analytics disabled: \(error.localizedDescription, privacy: .public)")
            return NoopUsageTracker()
        }
    }
}
