import Foundation
import Testing
@testable import Birdwatch

/// Applications rows exposed no title to accessibility (found in a live AX
/// dump). Each row is now one element with this label and identifier.
@MainActor
@Suite("Applications row accessibility")
struct AppRowAccessibilityTests {

    private func app(
        id: String = "container-icloud-md-obsidian", name: String = "Obsidian",
        backend: SyncBackend = .cloudDocs, status: AppSyncStatus = .notSyncing(items: 3),
        statusLine: String = "Scheduled in bird's retry queue", size: LocalSize? = nil
    ) -> AppSyncState {
        AppSyncState(
            id: id, name: name, tileColorHex: "0a84ff", backend: backend, isApple: false,
            status: status, statusLine: statusLine, lastActivity: nil,
            itemCount: nil, pendingItems: nil, localSize: size, locationPath: ""
        )
    }

    private func label(_ app: AppSyncState) -> String {
        AppRowAccessibility.label(app: app, display: SyncStatusDisplay(app: app, progressIsIndeterminate: false))
    }

    @Test("Name, backend, status, status line and the measured size, in that order")
    func fullLabel() {
        let row = app(size: LocalSize(bytes: 1_500_000_000))
        let display = SyncStatusDisplay(app: row, progressIsIndeterminate: false)
        let text = label(row)
        #expect(text.hasPrefix("Obsidian, CloudDocs, \(display.label), Scheduled in bird's retry queue, "))
        #expect(text.hasSuffix("on this Mac"))
        #expect(text.contains(LocalSizeText.text(LocalSize(bytes: 1_500_000_000))))
    }

    @Test("No size clause until a size is measured; a partial walk says 'At least'")
    func sizeClause() {
        #expect(!label(app(size: nil)).contains("on this Mac"))
        #expect(!label(app(size: LocalSize(bytes: 0))).contains("on this Mac"))
        #expect(label(app(size: LocalSize(bytes: 2_000_000, isPartial: true))).contains("At least"))
    }

    @Test("An empty status line adds no empty clause")
    func emptyStatusLine() {
        let text = label(app(statusLine: ""))
        #expect(!text.contains(", ,"))
        #expect(!text.hasSuffix(", "))
    }

    @Test("The identifier is the row's id, so it survives refreshes and re-sorts")
    func identifier() {
        #expect(AppRowAccessibility.identifier(app()) == "app-row-container-icloud-md-obsidian")
        #expect(AppRowAccessibility.identifier(app(id: "icloud-drive")) == "app-row-icloud-drive")
    }
}
