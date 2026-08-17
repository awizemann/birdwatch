import Foundation
import Testing
@testable import Birdwatch

private func transfer(_ id: String, direction: TransferDirection = .upload, progress: Double = 0.5) -> TransferItem {
    TransferItem(id: id, appID: "icloud-drive", name: id, location: "~/Documents", sizeBytes: 1_000, direction: direction, progress: progress)
}

@Suite("Activity diff")
struct ActivityDiffTests {

    @Test("New upload appears → exactly one uploading event")
    func newUpload() {
        let events = ActivityLog.diff(old: [], new: [transfer("a.key", direction: .upload)])
        #expect(events.count == 1)
        #expect(events[0].kind == .upload)
        #expect(events[0].title == "Uploading a.key")
        #expect(events[0].symbolName == "arrow.up.circle")
    }

    @Test("New download appears → downloading event with down arrow")
    func newDownload() {
        let events = ActivityLog.diff(old: [], new: [transfer("b.zip", direction: .download)])
        #expect(events.count == 1)
        #expect(events[0].title == "Downloading b.zip")
        #expect(events[0].symbolName == "arrow.down.circle")
    }

    @Test("Transfer disappears before completing → one done event")
    func disappeared() {
        let item = transfer("a.key", direction: .upload, progress: 0.4)
        let events = ActivityLog.diff(old: [item], new: [])
        #expect(events.count == 1)
        #expect(events[0].kind == .done)
        #expect(events[0].title == "a.key uploaded")
        #expect(events[0].symbolName == "checkmark.circle")
    }

    @Test("Downloaded item disappears → 'downloaded' wording")
    func disappearedDownload() {
        let events = ActivityLog.diff(old: [transfer("b.zip", direction: .download, progress: 0.9)], new: [])
        #expect(events.first?.title == "b.zip downloaded")
    }

    @Test("Unchanged snapshot → no events")
    func unchanged() {
        let items = [transfer("a.key"), transfer("b.zip", direction: .download)]
        #expect(ActivityLog.diff(old: items, new: items).isEmpty)
    }

    @Test("Progress hits 1.0 while still present → done exactly once, never repeated")
    func doneOnce() {
        let inFlight = transfer("a.key", progress: 0.7)
        let done = transfer("a.key", progress: 1.0)
        let first = ActivityLog.diff(old: [inFlight], new: [done])
        #expect(first.count == 1)
        #expect(first[0].kind == .done)
        // Still present and still done on the next diff → nothing new.
        #expect(ActivityLog.diff(old: [done], new: [done]).isEmpty)
        // And its eventual disappearance emits nothing either.
        #expect(ActivityLog.diff(old: [done], new: []).isEmpty)
    }

    @Test("Record stamps, orders newest-first, and caps the buffer")
    func recordBuffer() {
        let log = ActivityLog()
        log.record([transfer("first")])
        let events = log.record([])   // first disappears → done event on top
        #expect(events.count == 2)
        #expect(events[0].kind == .done)
        #expect(events[1].kind == .upload)

        // Cap: flood with unique appearing transfers, one per snapshot.
        for i in 0..<(ActivityLog.capacity + 20) {
            log.record([transfer("file-\(i)")])
        }
        #expect(log.events.count == ActivityLog.capacity)
    }
}

@Suite("Conflict source mapping")
struct ConflictSourceTests {

    @Test("Issue id is stable across scans for the same path")
    func stableIssueID() {
        let path = "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Q3 Report.pages"
        #expect(ConflictSource.issueID(forPath: path) == ConflictSource.issueID(forPath: path))
        #expect(ConflictSource.issueID(forPath: path).hasPrefix("conflict-"))
        #expect(ConflictSource.issueID(forPath: path) != ConflictSource.issueID(forPath: path + "x"))
    }

    @Test("Conflicted-copy URL keeps name and extension")
    func conflictedCopyNaming() {
        let url = ConflictSource.conflictedCopyURL(for: URL(fileURLWithPath: "/nonexistent-dir/Report.pages"))
        #expect(url.lastPathComponent == "Report (conflicted copy).pages")
    }
}
