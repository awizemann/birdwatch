import Foundation

// What a screen says about the background scans behind it, so an empty or old
// list is never passed off as a current, complete answer (C1).

// MARK: - CloudKit section

/// The Applications screen's CloudKit line. nil when there is nothing to add
/// (rows were observed from a full, fresh read — or a fixture source).
enum CloudKitNotice {
    static func text(_ state: CloudKitScanState?, now: Date) -> String? {
        guard let state else { return nil }
        guard case let .scanned(outcome, _, observedAt, isTruncated) = state else {
            return "Reading the system log for CloudKit activity…"
        }
        let truncatedNote = "The log was too large to read in full, so the newest activity may be missing."
        let base: String?
        switch outcome {
        case .logUnavailable:
            // Never append the truncation note: nothing was read this time.
            guard let observedAt else {
                return "Couldn't read the system log, so CloudKit apps can't be shown right now."
            }
            return "Couldn't read the system log — showing CloudKit results from \(Age.compact(now.timeIntervalSince(observedAt))) ago."
        case .observedApps:
            // The log is read every ~5 minutes; say how old this reading is
            // once it is more than a moment old.
            if let observedAt, now.timeIntervalSince(observedAt) >= 60 {
                base = "CloudKit status read from the system log \(Age.compact(now.timeIntervalSince(observedAt))) ago."
            } else {
                base = nil
            }
        case .noActivity:
            base = "No CloudKit activity in the last 30 minutes."
        case .unattributed(let containers):
            base = "CloudKit activity seen in \(Plural.count(containers, "container")), but this macOS doesn't say which app owns \(containers == 1 ? "it" : "them")."
        case .systemServicesOnly(let attributed, let unattributed):
            base = unattributed > 0
                ? "CloudKit activity seen only from system services, plus \(Plural.count(unattributed, "container")) this macOS doesn't tie to an app."
                : "CloudKit activity seen only from system services (\(Plural.count(attributed, "container"))), not from apps."
        }
        guard isTruncated else { return base }
        return base.map { "\($0) \(truncatedNote)" } ?? truncatedNote
    }
}

// MARK: - Directory scans

/// "Still scanning…" before a scan's first result lands (the list would
/// otherwise just be empty), and the result's age once a rescan is overdue.
enum ScanFreshnessNotice {
    /// - Parameter subject: what was scanned, e.g. "iCloud Drive folders".
    static func text(_ freshness: ScanFreshness?, subject: String, now: Date) -> String? {
        guard let freshness else { return nil }
        if freshness.isUnreadable {
            return "Couldn't read \(subject), so this list may be incomplete. Check Full Disk Access in Diagnostics."
        }
        guard let completedAt = freshness.completedAt else {
            return "Still scanning \(subject)…"
        }
        guard freshness.isOverdue else { return nil }
        return "Rescanning \(subject) is taking a while — last scanned \(Age.compact(now.timeIntervalSince(completedAt))) ago."
    }
}

// MARK: - Issues empty state

/// The Issues screen with nothing listed. "No issues detected" is the most it
/// can say, and it says why the answer may be incomplete: a missing Full Disk
/// Access grant, paused monitoring, or a conflict scan that stopped early.
struct IssuesEmptyState: Equatable {
    let title: String
    let lines: [String]
    /// TRUE only when nothing qualifies the empty list — the green check.
    let isClean: Bool

    /// - Parameter deliveredProducers: issue producers that have delivered a
    ///   successful result; nil for a fixture source (everything delivered).
    /// - Parameter conflictScanCap: the cap, when the conflict scan stopped at it.
    init(
        fullDiskAccess: PermissionState?, isPaused: Bool,
        deliveredProducers: Set<IssueProducer>?, conflictScanCap: Int?
    ) {
        let lines = Self.qualifiers(fullDiskAccess: fullDiskAccess, isPaused: isPaused,
                                    deliveredProducers: deliveredProducers, conflictScanCap: conflictScanCap)
        title = "No issues detected"
        isClean = lines.isEmpty
        self.lines = isClean ? ["Birdwatch hasn't found anything that needs your attention."] : lines
    }

    /// Why the issue list (empty or not) may be incomplete. Shared by the
    /// empty state, the lines above a non-empty list, and the Overview tile.
    static func qualifiers(
        fullDiskAccess: PermissionState?, isPaused: Bool,
        deliveredProducers: Set<IssueProducer>?, conflictScanCap: Int?
    ) -> [String] {
        var lines: [String] = []
        if isPaused {
            lines.append("Monitoring is paused, so new issues aren't being detected.")
        }
        // The cause before its symptoms.
        switch fullDiskAccess {
        case .denied:
            lines.append("Full Disk Access isn't granted, so Birdwatch can't check iCloud Drive for conflicts or read bird's state.")
        case .unknown:
            lines.append("Birdwatch couldn't confirm Full Disk Access, so some checks may not have run.")
        case .granted, nil:
            break
        }
        // A producer that hasn't delivered (still running, or failing) has
        // checked nothing — its silence is not "no issues".
        if let delivered = deliveredProducers {
            if !delivered.contains(.conflicts) {
                lines.append("The conflict scan hasn't completed yet.")
            }
            if !delivered.contains(.dump) {
                lines.append("Sync engine state hasn't been read yet.")
            }
        }
        if let cap = conflictScanCap {
            lines.append("The conflict check stopped after \(cap.formatted()) items, so files beyond that weren't checked.")
        }
        return lines
    }
}

/// The Overview "Issues" tile. A bare "0" is a claim that nothing is wrong;
/// when checks are incomplete it is "—" (none found, but not fully checked),
/// and a non-zero count says it may be incomplete.
enum IssuesTile {
    static func display(count: Int, qualifiers: [String]) -> (value: String, caption: String?) {
        guard !qualifiers.isEmpty else { return ("\(count)", nil) }
        return count == 0 ? ("—", "None found — not fully checked") : ("\(count)", "May be incomplete")
    }
}

/// Activity feed with no events yet.
enum ActivityEmptyState {
    static func text(paused: Bool) -> String {
        paused
            ? "Monitoring is paused — no new activity is being recorded."
            : "No sync activity seen since Birdwatch started."
    }
}
