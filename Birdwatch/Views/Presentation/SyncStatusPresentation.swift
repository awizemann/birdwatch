import Foundation

// View decisions about sync state, pulled out of view bodies so a test can
// hold them (see the "extract view-body decisions" convention). Every type
// here answers one question: what may this screen honestly SAY (C1).

// MARK: - One app's / one folder's status

/// Label, bar and spinner for one app row or Drive folder.
///
/// The live ubiquity channel is boolean, so most "syncing" rows carry no real
/// percentage. Such a row reads "Syncing…" over an indeterminate bar — never
/// "Syncing 0%" over an empty one.
struct SyncStatusDisplay: Equatable {
    enum Bar: Equatable {
        case determinate(Double)
        case indeterminate
    }

    /// Colour role; the view layer maps it to a palette colour.
    enum Tone: Equatable { case confirmed, working, neutral, warning, error }

    let label: String
    /// nil: no bar at all (nothing in flight, or work with no progress).
    let bar: Bar?
    let showsSpinner: Bool
    let tone: Tone

    /// - Parameter backend: decides what an idle row may claim. CloudDocs
    ///   reports transfers per file, so idle there is "Up to date"; CloudKit
    ///   and File Provider only ever show activity, so idle is "No activity
    ///   seen" — the same words the popover uses for them.
    /// - Parameter progressIsIndeterminate: the store's per-app / per-folder
    ///   decision (`SyncStore.progressIsIndeterminate`).
    init(status: AppSyncStatus, backend: SyncBackend, progressIsIndeterminate: Bool) {
        switch status {
        case .syncing(let progress):
            // A zero mean is never shown as a measurement, whatever the flag
            // says: with nothing carrying a fraction, 0 is an absence.
            if progressIsIndeterminate || progress <= 0 {
                label = "Syncing…"
                bar = .indeterminate
            } else {
                label = "Syncing \(Int((progress * 100).rounded()))%"
                bar = .determinate(progress)
            }
            showsSpinner = true
            tone = .working
        case .active:
            label = "Active"
            bar = nil
            showsSpinner = true
            tone = .working
        case .upToDate:
            let confirmable = Self.canConfirmIdle(backend)
            label = confirmable ? "Up to date" : "No activity seen"
            bar = nil
            showsSpinner = false
            tone = confirmable ? .confirmed : .neutral
        case .paused:
            label = "Paused"
            bar = nil
            showsSpinner = false
            tone = .warning
        case .issue:
            label = "Needs attention"
            bar = nil
            showsSpinner = false
            tone = .error
        }
    }

    /// Only CloudDocs reports per-file transfer state; the others report
    /// activity at best, so their quiet is not a confirmed "synced".
    static func canConfirmIdle(_ backend: SyncBackend) -> Bool { backend == .cloudDocs }
}

// MARK: - Overview hero / popover header

/// What the Overview hero (and the popover's overall bar) may claim.
///
/// Birdwatch cannot prove every app is synced — CloudKit and File Provider
/// expose no such signal — so the idle state says "no activity detected",
/// never "everything is up to date". A paused monitor shows a paused ring,
/// not "0% SYNCED".
struct OverviewHeroDisplay: Equatable {
    enum Ring: Equatable {
        case percent(Double)
        case indeterminate
        case paused
        case idle
    }

    enum Tone: Equatable { case paused, working, idle }

    let title: String
    let subtitle: String
    let ring: Ring
    let tone: Tone
    /// The overall bar is shown only while something is in flight.
    let showsBar: Bool
    var barIsIndeterminate: Bool { ring == .indeterminate }

    init(
        state: SyncStore.OverallState,
        progress: Double,
        progressIsIndeterminate: Bool,
        inFlightCount: Int,
        pendingFileCount: Int
    ) {
        switch state {
        case .paused:
            title = "Monitoring paused"
            subtitle = "macOS does not offer a supported way to pause iCloud sync itself — Birdwatch has stopped watching."
            ring = .paused
            tone = .paused
            showsBar = false
        case .syncing(let appCount):
            if progressIsIndeterminate || progress <= 0 {
                title = "Syncing \(Plural.count(inFlightCount, "file"))"
                subtitle = "macOS reports these as in progress without a percentage."
                ring = .indeterminate
            } else {
                title = "Syncing \(Plural.count(appCount, "app"))"
                subtitle = "\(Plural.count(pendingFileCount, "file")) remaining"
                ring = .percent(progress)
            }
            tone = .working
            showsBar = true
        case .active(let appCount):
            title = "Activity in \(Plural.count(appCount, "app"))"
            subtitle = "iCloud reports work in progress, but no percentage or file count."
            ring = .indeterminate
            tone = .working
            showsBar = true
        case .idle:
            title = "No sync activity detected"
            subtitle = "Nothing is transferring right now."
            ring = .idle
            tone = .idle
            showsBar = false
        }
    }
}

/// The popover's summary lines.
enum PopoverSummary {
    static func headerTitle(_ state: SyncStore.OverallState) -> String {
        switch state {
        case .paused: "Monitoring paused"
        case .syncing(let appCount): "Syncing \(Plural.count(appCount, "app"))"
        case .active(let appCount): "Activity in \(Plural.count(appCount, "app"))"
        case .idle: "No sync activity"
        }
    }

    /// Idle apps in the same words their rows use (`SyncStatusDisplay`):
    /// CloudDocs apps are "up to date", CloudKit / File Provider apps only
    /// "no activity seen". nil when there are none.
    static func idleAppsLine(_ apps: [AppSyncState]) -> String? {
        let idle = apps.filter { $0.status == .upToDate }
        let confirmed = idle.filter { SyncStatusDisplay.canConfirmIdle($0.backend) }.count
        let unconfirmed = idle.count - confirmed
        var parts: [String] = []
        if confirmed > 0 { parts.append("\(Plural.count(confirmed, "app")) up to date") }
        if unconfirmed > 0 {
            parts.append(confirmed > 0
                ? "\(unconfirmed) with no activity seen"
                : "\(Plural.count(unconfirmed, "app")) with no activity seen")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1 issue needs attention" / "3 issues need attention".
    static func issuesLine(count: Int) -> String {
        count == 1 ? "1 issue needs attention" : "\(count) issues need attention"
    }
}

// MARK: - Freshness

/// "Updated 30s ago". Coarse on purpose: the label is refreshed by a 15 s
/// TimelineView, so a per-second count would be both wrong and expensive.
enum FreshnessLabel {
    static func text(lastRefresh: Date?, now: Date) -> String {
        guard let lastRefresh else { return "Not updated yet" }
        let age = max(0, now.timeIntervalSince(lastRefresh))
        if age < 15 { return "Updated just now" }
        if age < 60 { return "Updated \(Int(age) / 15 * 15)s ago" }
        return "Updated \(Age.compact(age)) ago"
    }
}

// MARK: - App detail tiles

/// The detail grid's three counts. A backend that doesn't report a figure
/// gets "Not reported by <daemon>", never a placeholder zero; a capped count
/// or a capped size walk is stated as a floor.
enum AppDetailFacts {
    static func itemTile(_ app: AppSyncState) -> (label: String, value: String) {
        switch app.itemCount {
        case .indexed(let count):
            return ("Items indexed", "\(count.formatted()) item\(count == 1 ? "" : "s")")
        case .topLevel(let count, let isCapped):
            let value = isCapped ? "\(count.formatted())+ items" : "\(count.formatted()) item\(count == 1 ? "" : "s")"
            return ("Top-level items", value)
        case nil:
            return ("Items", notReported(app))
        }
    }

    static func pendingValue(_ app: AppSyncState) -> String {
        guard let pending = app.pendingItems else { return notReported(app) }
        return pending == 0 ? "None" : "\(pending.formatted()) item\(pending == 1 ? "" : "s")"
    }

    static func localSizeValue(_ app: AppSyncState) -> String {
        guard let size = app.localSize else {
            // CloudDocs rows are measured by the background size pass; the
            // other backends keep their data where Birdwatch doesn't walk.
            return app.backend == .cloudDocs ? "Measuring…" : notReported(app)
        }
        return LocalSizeText.text(size)
    }

    /// The recency tile. Work in flight says so; otherwise the real date of
    /// the last activity — never a bare "Active now" that hides how old the
    /// evidence is. CloudKit evidence is log activity, not a confirmed sync.
    static func lastActivityTile(_ app: AppSyncState, now: Date) -> (label: String, value: String) {
        let label = app.backend == .cloudDocs ? "Last synced" : "Last activity"
        if app.status.isSyncing { return (label, "Syncing now") }
        guard let last = app.lastActivity else { return (label, "—") }
        return (label, Format.relative.localizedString(for: last, relativeTo: now))
    }

    private static func notReported(_ app: AppSyncState) -> String {
        "Not reported by \(app.backend.daemonName)"
    }
}

/// "1.2 GB", "At least 1.2 GB" when the size walk stopped at its cap, or
/// "Couldn't measure" when the folder could not be read at all.
enum LocalSizeText {
    static func text(_ size: LocalSize) -> String {
        if size.isUnreadable { return "Couldn't measure" }
        return size.isPartial ? "At least \(Format.size(size.bytes))" : Format.size(size.bytes)
    }
}

/// A Drive folder's count: "12 items", "500+ items", or "Not readable".
extension DriveFolder {
    var itemCountText: String {
        guard let itemCount else { return "Not readable" }
        if itemCountIsCapped { return "\(itemCount)+ items" }
        return "\(itemCount) item\(itemCount == 1 ? "" : "s")"
    }
}

// MARK: - Small shared wording helpers

enum Plural {
    /// "1 app", "3 apps".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

enum Age {
    /// "45s", "12m", "3h", "2d" — the same compact style as the CloudKit
    /// status lines ("Last synced 12m ago").
    static func compact(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3_600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3_600)h"
        default: return "\(s / 86_400)d"
        }
    }
}
