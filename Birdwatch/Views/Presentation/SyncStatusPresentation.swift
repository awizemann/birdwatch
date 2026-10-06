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
                label = "Syncing \(Format.percent(progress))"
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
        case .unknown:
            // Not read yet: neutral, never red and never "Up to date".
            label = "State unknown"
            bar = nil
            showsSpinner = false
            tone = .neutral
        }
    }

    init(label: String, bar: Bar? = nil, showsSpinner: Bool = false, tone: Tone) {
        self.label = label
        self.bar = bar
        self.showsSpinner = showsSpinner
        self.tone = tone
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

    /// - Parameter unknownAppCount: apps whose sync state has not been read
    ///   yet (`AppSyncStatus.unknown`). The idle claim then says so instead of
    ///   implying it covers them.
    init(
        state: SyncStore.OverallState,
        progress: Double,
        progressIsIndeterminate: Bool,
        inFlightCount: Int,
        pendingFileCount: Int,
        unknownAppCount: Int = 0,
        unwatchedAppCount: Int = 0
    ) {
        switch state {
        case .paused:
            title = "Monitoring paused"
            subtitle = "macOS does not offer a supported way to pause iCloud sync itself — Birdwatch has stopped watching."
            ring = .paused
            tone = .paused
            showsBar = false
        case .syncing(let appCount, let alsoActive):
            let more = alsoActive > 0 ? " · activity in \(alsoActive) more" : ""
            if progressIsIndeterminate || progress <= 0 {
                title = "Syncing \(Plural.count(inFlightCount, "file"))" + more
                subtitle = "macOS reports these as in progress without a percentage."
                ring = .indeterminate
            } else {
                title = "Syncing \(Plural.count(appCount, "app"))" + more
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
            var parts = ["Nothing is transferring right now."]
            if unknownAppCount > 0 { parts.append("\(Plural.count(unknownAppCount, "app")) not read yet.") }
            if unwatchedAppCount > 0 {
                parts.append("\(Plural.count(unwatchedAppCount, "app")) not watched — needs Full Disk Access.")
            }
            subtitle = parts.joined(separator: " ")
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
        case .syncing(let appCount, let alsoActive):
            "Syncing \(Plural.count(appCount, "app"))" + (alsoActive > 0 ? " · activity in \(alsoActive) more" : "")
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
        // Not idle and not a problem: state not read yet (neutral).
        let unknown = apps.filter { $0.status == .unknown && !$0.needsFullDiskAccess }.count
        if unknown > 0 {
            parts.append(parts.isEmpty
                ? "\(Plural.count(unknown, "app")) with state unknown"
                : "\(unknown) with state unknown")
        }
        let unwatched = apps.filter(\.needsFullDiskAccess).count
        if unwatched > 0 {
            parts.append(parts.isEmpty
                ? "\(Plural.count(unwatched, "app")) not watched — needs Full Disk Access"
                : "\(unwatched) not watched — needs Full Disk Access")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1 issue needs attention" / "3 issues need attention".
    static func issuesLine(count: Int) -> String {
        "\(Plural.count(count, "issue")) \(count == 1 ? "needs" : "need") attention"
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
    /// Every figure of a row Birdwatch is deliberately not watching.
    static let notWatched = "Not watched without Full Disk Access"

    static func itemTile(_ app: AppSyncState) -> (label: String, value: String) {
        if app.needsFullDiskAccess { return ("Items", notWatched) }
        switch app.itemCount {
        case .indexed(let count):
            return ("Items indexed", Plural.count(count, "item"))
        case .topLevel(let count, let isCapped):
            let value = isCapped ? "\(count.formatted())+ items" : Plural.count(count, "item")
            return ("Top-level items", value)
        case nil:
            return ("Items", notReported(app))
        }
    }

    static func pendingValue(_ app: AppSyncState) -> String {
        if app.needsFullDiskAccess { return notWatched }
        guard let pending = app.pendingItems else { return notReported(app) }
        return pending == 0 ? "None" : Plural.count(pending, "item")
    }

    static func localSizeValue(_ app: AppSyncState) -> String {
        if app.needsFullDiskAccess { return notWatched }
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
        let label = app.lastActivityLabel ?? (app.backend == .cloudDocs ? "Last synced" : "Last activity")
        if app.status.isSyncing { return (label, "Syncing now") }
        guard let last = app.lastActivity else { return (label, "—") }
        let value = Format.relative.localizedString(for: last, relativeTo: now)
        return (label, app.lastActivityNote.map { "\(value) (\($0))" } ?? value)
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
        if itemCountIsCapped { return "\(itemCount.formatted())+ items" }
        return Plural.count(itemCount, "item")
    }
}

// MARK: - What the transfer lists can't see

/// Lines that qualify every transfer list and tile: monitoring paused, or a
/// row Birdwatch isn't watching (Desktop & Documents without Full Disk
/// Access). An empty list under either is not "nothing transferring".
enum TransferWatchNotes {
    static func qualifier(paused: Bool, unwatched: [AppSyncState]) -> String? {
        if paused { return "Monitoring is paused — transfers aren't being watched." }
        guard !unwatched.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: unwatched.map(\.name))
        return "\(names) transfers aren't watched without Full Disk Access."
    }

    /// Uploading / Downloading tiles: "—" when the figure can't be stated.
    static func tile(bytes: Int64, paused: Bool, unwatched: [AppSyncState]) -> (value: String, caption: String?) {
        if paused { return ("—", "Not watched while paused") }
        guard !unwatched.isEmpty else { return (Format.size(bytes), nil) }
        let caption = "Excludes \(ListFormatter.localizedString(byJoining: unwatched.map(\.name)))"
        return (bytes > 0 ? Format.size(bytes) : "—", caption)
    }
}

/// One Drive folder row. Folders inherit what the engine knows: while the
/// iCloud Drive state is unknown, or monitoring is paused, no folder is
/// green "Up to date"; Desktop/Documents folders that aren't watched say so.
enum DriveFolderDisplay {
    static func display(
        _ folder: DriveFolder, progressIsIndeterminate: Bool,
        engineStateUnknown: Bool, paused: Bool, desktopDocumentsUnwatched: Bool
    ) -> SyncStatusDisplay {
        if desktopDocumentsUnwatched, ["Desktop", "Documents"].contains(folder.name) {
            return SyncStatusDisplay(label: "Not watched — needs Full Disk Access", tone: .neutral)
        }
        let base = SyncStatusDisplay(status: folder.status, backend: .cloudDocs,
                                     progressIsIndeterminate: progressIsIndeterminate)
        guard base.tone == .confirmed else { return base }
        if paused { return SyncStatusDisplay(label: "Monitoring paused", tone: .neutral) }
        if engineStateUnknown { return SyncStatusDisplay(label: "State unknown", tone: .neutral) }
        return base
    }
}

// MARK: - Small shared wording helpers

/// English count phrases. The one place a noun agrees with its number, so no
/// screen hand-builds a `n == 1 ? "" : "s"` ternary (and none ships "1 apps").
/// The number is locale-grouped ("1,234 items"). Nonisolated: data sources
/// build user-facing reasons with it off the main actor.
nonisolated enum Plural {
    /// "1 app", "3 apps", "2 directories" (pass `plural` for irregular nouns).
    static func count(_ n: Int, _ singular: String, plural: String? = nil, locale: Locale = .current) -> String {
        "\(n.formatted(.number.locale(locale))) \(word(n, singular, plural: plural))"
    }

    /// The noun alone, agreeing with `n`: "item" / "items".
    static func word(_ n: Int, _ singular: String, plural: String? = nil) -> String {
        n == 1 ? singular : (plural ?? singular + "s")
    }
}

nonisolated enum Age {
    /// "45s", "12m", "3h", "2d" — the same compact style as the CloudKit
    /// status lines ("Last synced 12m ago"), truncated to whole units and
    /// written in the locale's narrow unit style.
    static func compact(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        guard seconds.isFinite else { return "—" }
        let s = Int(min(max(0, seconds), Format.maxCompactSeconds))
        switch s {
        case ..<60: return Format.compactUnit(s, .seconds, locale: locale)
        case ..<3_600: return Format.compactUnit(s / 60, .minutes, locale: locale)
        case ..<86_400: return Format.compactUnit(s / 3_600, .hours, locale: locale)
        default: return Format.compactUnit(s / 86_400, .days, locale: locale)
        }
    }
}
