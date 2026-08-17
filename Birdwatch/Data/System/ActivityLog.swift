import Foundation

/// One derived feed entry before it is stamped with an id and a date.
/// Pure output of `ActivityLog.diff` so the derivation is headless-testable.
struct ActivityEventDescriptor: Sendable, Hashable {
    let kind: ActivityKind
    let title: String
    let detail: String
    let symbolName: String
}

/// Derives the Activity feed from successive transfer snapshots.
///
/// @MainActor deliberately: owned by SystemSyncSource next to
/// UbiquityTransferSource and fed from `currentSnapshot()`, which runs on the
/// caller's (SyncStore's) MainActor. The diff itself is a pure nonisolated
/// static function; this class only stamps and buffers events.
@MainActor
final class ActivityLog {
    nonisolated static let capacity = 200

    private(set) var events: [ActivityEvent] = []
    private var previous: [TransferItem] = []
    private var counter = 0

    /// Feed the latest transfer snapshot; returns the full feed, newest first,
    /// capped at `capacity`.
    @discardableResult
    func record(_ transfers: [TransferItem], now: Date = Date()) -> [ActivityEvent] {
        let descriptors = Self.diff(old: previous, new: transfers)
        previous = transfers
        guard !descriptors.isEmpty else { return events }
        let stamped = descriptors.map { d -> ActivityEvent in
            counter += 1
            return ActivityEvent(
                id: "activity-\(counter)", kind: d.kind, title: d.title,
                detail: d.detail, date: now, symbolName: d.symbolName
            )
        }
        events = Array((stamped + events).prefix(Self.capacity))
        return events
    }

    // MARK: - Pure diff (nonisolated for headless tests)

    /// Events implied by moving from `old` to `new`:
    /// - id appears (not yet done) → "Uploading/Downloading <name>"
    /// - id appears already done, or reaches progress 1.0 while present, or
    ///   vanishes before reaching 1.0 → "<name> uploaded/downloaded"
    /// A transfer that already emitted its done event (was done in `old`)
    /// never emits again — neither while it lingers nor when it disappears.
    nonisolated static func diff(old: [TransferItem], new: [TransferItem]) -> [ActivityEventDescriptor] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        var out: [ActivityEventDescriptor] = []
        for item in new {
            if let prior = oldByID[item.id] {
                if item.isDone && !prior.isDone { out.append(.finished(item)) }
            } else {
                out.append(item.isDone ? .finished(item) : .started(item))
            }
        }
        for item in old where !newIDs.contains(item.id) && !item.isDone {
            out.append(.finished(item))
        }
        return out
    }
}

extension ActivityEventDescriptor {
    /// Start events are tinted by direction. `ActivityKind` has no `.download`
    /// case (and adding one would ripple through every view's tint/legend
    /// mapping), so downloads use the neutral `.info` rather than lying with
    /// `.upload`; uploads keep `.upload`.
    nonisolated static func started(_ item: TransferItem) -> ActivityEventDescriptor {
        ActivityEventDescriptor(
            kind: item.direction == .upload ? .upload : .info,
            title: "\(item.direction == .upload ? "Uploading" : "Downloading") \(item.name)",
            detail: item.location,
            symbolName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        )
    }

    nonisolated static func finished(_ item: TransferItem) -> ActivityEventDescriptor {
        ActivityEventDescriptor(
            kind: .done,
            title: "\(item.name) \(item.direction == .upload ? "uploaded" : "downloaded")",
            detail: item.location,
            symbolName: "checkmark.circle"
        )
    }
}
