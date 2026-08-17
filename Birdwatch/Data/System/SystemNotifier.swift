import Foundation
import UserNotifications
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "notifier")

/// Posts system notification banners for newly detected issues. Provisional
/// authorization: banners arrive quietly without an upfront permission prompt;
/// the user promotes or silences them from Notification Center.
///
/// Two invariants:
/// - Authorization is requested ONCE per launch (`authorization`, a memoized
///   Task every caller awaits) instead of on every post.
/// - Posts are serialized through `queue`, so a batch of issues detected in one
///   refresh reaches Notification Center in the order it was derived.
@MainActor
enum SystemNotifier {

    private static var authorizationTask: Task<Bool, Never>?
    /// Tail of the post chain; each post awaits the previous one.
    private static var queue: Task<Void, Never> = Task {}

    private static func authorization() async -> Bool {
        if let existing = authorizationTask { return await existing.value }
        let task = Task { () -> Bool in
            do {
                return try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .provisional])
            } catch {
                let ns = error as NSError
                logger.warning("notification authorization failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                return false
            }
        }
        authorizationTask = task
        return await task.value
    }

    static func post(title: String, body: String, id: String) {
        post([(title: title, body: body, id: id)])
    }

    /// Posts a batch in order. Batches themselves are ordered relative to each
    /// other by the shared queue.
    static func post(_ batch: [(title: String, body: String, id: String)]) {
        guard !batch.isEmpty else { return }
        let previous = queue
        queue = Task {
            await previous.value
            guard await authorization() else { return }
            let center = UNUserNotificationCenter.current()
            for item in batch {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                do {
                    try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
                } catch {
                    let ns = error as NSError
                    logger.warning("notification post failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}
