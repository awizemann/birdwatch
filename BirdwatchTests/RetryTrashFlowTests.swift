import Foundation
import Testing
@testable import Birdwatch

/// "Move to Trash" on a retry row, end to end.
///
/// The bug these cover — diagnosed live in the dev app on 2026-08-15, after two
/// wrong guesses:
///
/// 1. The move genuinely fails. Every row bird offers is an app's ubiquity
///    document root (`~/Library/Mobile Documents/<container>/Documents`), the
///    folders ARE real and empty on disk, and macOS refuses to trash them:
///    NSCocoaErrorDomain 3328, "the volume … doesn't have one". A plain folder
///    inside the same container trashes fine, so it is the registered root that
///    is refused. There is no button for those now.
/// 2. The outcome was reported where nobody was looking — at the bottom of a
///    ten-row card — and, on the success path, not for another 30–60 seconds,
///    because the store awaited a forced refresh (one snapshot takes ~26s on a
///    real account) before returning. Meanwhile the stale in-flight snapshot
///    put the row back.
///
/// So the rules tested here: the row goes ONLY when the file went, the answer
/// comes back in the same turn as the click, no snapshot can resurrect a
/// trashed row, and every refusal is sayable in English.
@Suite("Retry-queue trash flow")
struct RetryTrashFlowTests {

    // MARK: - Fixtures

    /// A container section with one pending item per id, all still listed by
    /// bird — the shape a fresh dump has right after the user trashed one.
    private func dump(ids: [String]) -> BrctlDump {
        let body = ids.map { id in
            #"""
                r:1 i:<\#(id)> al:1 up:needs-sync-up uv:0 st{p:<root[1]> n:"a{3}b.pdf" doc}
                > sync-up{[zone:1 sync-up-scheduled attempts:0 last:100.00h ago next:ready cleanup:ready]}
            """#
        }.joined(separator: "\n")
        return BrctlDumpParser.parse("""
        1 containers matching '*'
        -----------------------------------------------------
        \(body)
        """)
    }

    private func row(id: String, path: String? = "/x/\(UUID().uuidString)") -> RetryQueueItem {
        RetryQueueItem(
            id: id, name: "Folder", attempt: 0, maxAttempts: 62,
            path: path, absolutePath: path,
            matchConfidence: path == nil ? .none : .exact, isDirectory: true
        )
    }

    // MARK: - Forget persistence across dump refreshes

    // Fails if a fresh dump resurrects a row the user cleared. bird keeps
    // listing a trashed item until its OWN next scan, so "the dump is fresh" is
    // not evidence the item is back — which is exactly how the row reappeared
    // seconds after it was removed.
    @Test("A forgotten row stays gone while bird still lists the item")
    func forgottenRowSurvivesAFreshDump() {
        let fresh = SystemSyncSource.MappedDump(dump(ids: ["A", "B", "C"]))
        #expect(fresh.retryQueue.map(\.id).sorted() == ["A", "B", "C"])
        #expect(fresh.retryQueueTotal == 3)

        let applied = SystemSyncSource.applyingForgotten(["B"], to: fresh)

        #expect(applied.mapped.retryQueue.map(\.id).sorted() == ["A", "C"])
        // Both halves of "Showing N of M" have to lose it, or the card claims a
        // hidden item that no longer exists.
        #expect(applied.mapped.retryQueueTotal == 2)
        // Still listed by bird → still suppressed on the dump after this one.
        #expect(applied.keptIDs == ["B"])
    }

    // Fails if the suppression became permanent. Once bird re-scans and stops
    // listing the item, the override has done its job — keeping it would hide a
    // genuinely NEW retry that happens to reuse the id.
    @Test("The forgotten set is pruned once bird stops listing the item")
    func forgottenSetPrunesItself() {
        let rescanned = SystemSyncSource.MappedDump(dump(ids: ["A", "C"]))

        let applied = SystemSyncSource.applyingForgotten(["B"], to: rescanned)

        #expect(applied.keptIDs.isEmpty)
        #expect(applied.mapped.retryQueue.map(\.id).sorted() == ["A", "C"])
        // Nothing was hidden, so nothing may be subtracted from the total.
        #expect(applied.mapped.retryQueueTotal == 2)

        // …and an item that legitimately comes back later is shown again.
        let returned = SystemSyncSource.applyingForgotten(
            applied.keptIDs, to: SystemSyncSource.MappedDump(dump(ids: ["A", "B", "C"]))
        )
        #expect(returned.mapped.retryQueue.map(\.id).contains("B"))
    }

    // MARK: - Store ordering

    // Fails if the store ever forgets or refreshes before the file actually
    // moved: forgetting first would erase the row for an operation that then
    // threw, which is the "it said nothing and did nothing" bug in reverse.
    @Test("A successful trash answers at once, then runs forget → refresh")
    func successfulTrashOrdersItsWork() async {
        var snapshot = SyncSnapshot.minimal()
        snapshot.retryQueue = [row(id: "A"), row(id: "B")]
        snapshot.retryQueueTotal = 7
        let source = RecordingSource(snapshot: snapshot)
        let store = SyncStore(source: source, defaults: throwawayDefaults())
        await store.refresh(force: true)
        source.log.removeAll()

        let target = store.retryQueue[1]
        let outcome = await store.trashRetryQueueItem(target) { path in
            source.log.append("trash:\(path)")
            return "~/.Trash/Folder"
        }

        // The answer comes back in the SAME turn: it must not wait on the
        // source refresh, which joins whatever snapshot is in flight and takes
        // ~26s on a real account. That wait is why the card said nothing.
        #expect(outcome == .moved(name: "Folder", destination: "~/.Trash/Folder"))
        #expect(store.retryQueue.map(\.id) == ["A"])
        #expect(source.log == ["trash:\(target.absolutePath!)"])

        // …and the slow half still runs, in order, right behind it.
        await store.pendingRetryRefresh?.value
        #expect(source.log == ["trash:\(target.absolutePath!)", "forget:B", "snapshot"])
        // Gone, and it stays gone through the refresh that follows.
        #expect(store.retryQueue.map(\.id) == ["A"])
        // "Showing N of M" decrements too.
        #expect(store.retryQueueTotal == 6)
    }

    // THE "nothing happened" BUG. A snapshot that was already in flight when
    // the user hit Trash carries a retry queue collected BEFORE the folder
    // moved. On a real account one snapshot takes ~26s (brctl status times out
    // at 10s every cycle), so there is essentially always one in flight — and
    // when it landed it put the row straight back. Fails if the store ever
    // stops filtering trashed ids out of an incoming snapshot.
    @Test("A stale snapshot landing after the trash cannot resurrect the row")
    func staleSnapshotCannotResurrectARow() async {
        var snapshot = SyncSnapshot.minimal()
        snapshot.retryQueue = [row(id: "A"), row(id: "B")]
        snapshot.retryQueueTotal = 2
        let source = RecordingSource(snapshot: snapshot)
        // Deliberately does NOT drop the row on forget — this is the source
        // still reporting the item, exactly as bird does until it re-scans.
        source.forgetIsANoOp = true
        let store = SyncStore(source: source, defaults: throwawayDefaults())
        await store.refresh(force: true)

        let outcome = await store.trashRetryQueueItem(store.retryQueue[1]) { _ in "~/.Trash/Folder" }
        #expect(outcome == .moved(name: "Folder", destination: "~/.Trash/Folder"))
        #expect(store.retryQueue.map(\.id) == ["A"])

        // The snapshot that was in flight lands, still listing B.
        await store.pendingRetryRefresh?.value
        await store.refresh(force: true)
        #expect(store.retryQueue.map(\.id) == ["A"], "the trashed row came back")
        #expect(store.retryQueueTotal == 1)

        // Once bird stops listing it the override is pruned, so a genuinely new
        // retry that reuses the id is shown again.
        source.snapshot.retryQueue = [row(id: "A")]
        source.snapshot.retryQueueTotal = 1
        await store.refresh(force: true)
        source.snapshot.retryQueue = [row(id: "A"), row(id: "B")]
        source.snapshot.retryQueueTotal = 2
        await store.refresh(force: true)
        #expect(store.retryQueue.map(\.id).sorted() == ["A", "B"])
    }

    // Fails if a refused delete still removes the row. The file is still on
    // disk; a row that vanishes anyway is a lie about a delete that never was.
    @Test("A failed trash keeps the row and surfaces a plain-English reason")
    func failedTrashKeepsTheRow() async {
        var snapshot = SyncSnapshot.minimal()
        snapshot.retryQueue = [row(id: "A")]
        snapshot.retryQueueTotal = 1
        let source = RecordingSource(snapshot: snapshot)
        let store = SyncStore(source: source, defaults: throwawayDefaults())
        await store.refresh(force: true)
        source.log.removeAll()

        let outcome = await store.trashRetryQueueItem(store.retryQueue[0]) { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }

        guard case .failed(let name, let reason) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(name == "Folder")
        #expect(reason.contains("no real directory on this disk"))
        #expect(store.retryQueue.map(\.id) == ["A"])
        #expect(store.retryQueueTotal == 1)
        // Nothing was forgotten and nothing was refreshed — the source's view
        // of the world did not change, because the world did not change.
        #expect(source.log.isEmpty)
    }

    // Fails if a row with no resolved path is ever handed to the file system.
    @Test("A row with no resolved location is refused before any file operation")
    func unresolvedRowIsRefused() async {
        var snapshot = SyncSnapshot.minimal()
        snapshot.retryQueue = [row(id: "A", path: nil)]
        let source = RecordingSource(snapshot: snapshot)
        let store = SyncStore(source: source, defaults: throwawayDefaults())
        await store.refresh(force: true)

        var asked = false
        let outcome = await store.trashRetryQueueItem(store.retryQueue[0]) { _ in
            asked = true
            return ""
        }

        #expect(asked == false)
        #expect(outcome == .failed(name: "Folder", reason: "Birdwatch has no resolved location for this item"))
        #expect(store.retryQueue.map(\.id) == ["A"])
    }

    // MARK: - What macOS will not let us move

    // THE "Move to Trash did nothing" BUG. Every row bird offers on a real Mac
    // is an app's ubiquity document root, and macOS refuses to trash those —
    // measured live: NSCocoaErrorDomain 3328, "the volume … doesn't have one".
    // Fails if the button ever comes back for one, or disappears for a folder
    // that CAN be moved (a plain directory inside the same container trashes
    // fine — also verified on the real filesystem).
    @Test("Ubiquity document roots are recognised; ordinary folders are not", arguments: [
        ("/h/Library/Mobile Documents/iCloud~com~acme~app/Documents", true),
        ("/h/Library/Mobile Documents/com~apple~CloudDocs/Documents", true),
        ("/h/Library/Mobile Documents/iCloud~com~acme~app/Documents/Reports", false),
        ("/h/Library/Mobile Documents/iCloud~com~acme~app/scratch", false),
        ("/h/Library/Mobile Documents/com~apple~CloudDocs/Work/Documents", false),
        ("/h/Documents", false),
    ])
    func ubiquityRootDetection(path: String, isRoot: Bool) {
        #expect(FileTrasher.isUbiquityDocumentRoot(path: path, home: "/h") == isRoot)
    }

    // Fails if the UI ever prints "the volume doesn't have one" at a user, or
    // silently offers a button for a folder nothing can move.
    @Test("A row nothing can move says why, instead of showing a button")
    @MainActor
    func managedRootExplainsItself() {
        let home = NSHomeDirectory()
        var managed = row(id: "A", path: "\(home)/Library/Mobile Documents/iCloud~com~acme~app/Documents")
        managed.sizeBytes = 0
        managed.itemCount = 0
        #expect(DiagnosticsView.noTrashReason(managed)?.contains("iCloud owns this folder") == true)

        var ordinary = row(id: "B", path: "\(home)/Library/Mobile Documents/iCloud~com~acme~app/scratch")
        ordinary.sizeBytes = 0
        ordinary.itemCount = 0
        #expect(DiagnosticsView.noTrashReason(ordinary) == nil)

        // Unmeasured rows already say their own thing in the size line.
        #expect(DiagnosticsView.noTrashReason(row(id: "C")) == nil)
    }

    // MARK: - Reasons

    // Fails if the UI goes back to printing an NSError at the user. Each of
    // these is a distinct thing the user can act on (or stop trying to).
    @Test("NSError codes map to reasons a person can act on", arguments: [
        (NSFileNoSuchFileError, "no real directory on this disk"),
        (NSFileWriteNoPermissionError, "did not permit"),
        (NSFileWriteVolumeReadOnlyError, "read-only"),
        // 3328 — the one every retry row actually produced.
        (NSFeatureUnsupportedError, "iCloud owns this folder"),
    ])
    func plainReasons(code: Int, fragment: String) {
        let reason = FileTrasher.plainReason(
            for: NSError(domain: NSCocoaErrorDomain, code: code)
        )
        #expect(reason.contains(fragment))
        #expect(!reason.contains("NSCocoaErrorDomain"))
    }

    @Test("A whitelist refusal says so in the user's terms")
    func refusalReason() {
        let reason = FileTrasher.plainReason(for: MaintenanceError.pathNotAllowed("~/x"))
        #expect(reason == "it is outside the folders Birdwatch is allowed to touch")
    }

    // MARK: - Helpers

    private func throwawayDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bw-trash-\(UUID().uuidString)")!
    }
}

/// Records the ORDER of everything the store asks a source to do — the part of
/// this flow that cannot be asserted from the resulting state alone.
final class RecordingSource: SyncSource, @unchecked Sendable {
    var snapshot: SyncSnapshot
    var log: [String] = []
    /// Models a source that keeps reporting the item after the move — which is
    /// what bird does until its own next scan.
    var forgetIsANoOp = false

    init(snapshot: SyncSnapshot) { self.snapshot = snapshot }

    func currentSnapshot() async -> SyncSnapshot {
        log.append("snapshot")
        return snapshot
    }

    func forgetRetryQueueItem(id: String) async {
        log.append("forget:\(id)")
        guard !forgetIsANoOp else { return }
        await MainActor.run {
            snapshot.retryQueue.removeAll { $0.id == id }
            // Mirrors SystemSyncSource: the forgotten item leaves the total
            // too, or the next snapshot restores the count the store dropped.
            snapshot.retryQueueTotal = max(snapshot.retryQueue.count, snapshot.retryQueueTotal - 1)
        }
    }

    func logStream(appID: String) -> AsyncStream<LogLine> { AsyncStream { $0.finish() } }
    func conflictDetail(issueID: String) async -> ConflictDetail? { nil }
}
