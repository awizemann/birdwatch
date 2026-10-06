import Foundation
import Testing
@testable import Birdwatch

@Suite("Metadata mapping")
struct MetadataMappingTests {

    private let home = "/Users/tester"

    // MARK: - appID mapping

    @Test func desktopPathMapsToDesktopDocuments() {
        #expect(UbiquityTransferSource.appID(forPath: "/Users/tester/Desktop/plan.pdf", homeDirectory: home) == "desktop-documents")
    }

    @Test func documentsPathMapsToDesktopDocuments() {
        #expect(UbiquityTransferSource.appID(forPath: "/Users/tester/Documents/notes/todo.md", homeDirectory: home) == "desktop-documents")
    }

    @Test func cloudDocsPathMapsToICloudDrive() {
        #expect(UbiquityTransferSource.appID(forPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Design/logo.sketch", homeDirectory: home) == "icloud-drive")
    }

    @Test func documentsNotDirectlyUnderHomeIsNotDesktopDocuments() {
        #expect(UbiquityTransferSource.appID(forPath: "/Users/tester/Projects/Documents/x.txt", homeDirectory: home) == "icloud-drive")
    }

    // MARK: - Display location

    @Test func locationIsTildeAbbreviatedParent() {
        #expect(UbiquityTransferSource.displayLocation(forPath: "/Users/tester/Desktop/plan.pdf", homeDirectory: home) == "~/Desktop")
        #expect(UbiquityTransferSource.displayLocation(forPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Design/logo.sketch", homeDirectory: home) == "~/Library/Mobile Documents/com~apple~CloudDocs/Design")
        #expect(UbiquityTransferSource.displayLocation(forPath: "/Users/tester/file.txt", homeDirectory: home) == "~")
    }

    // MARK: - Progress / direction

    /// Empirical: the ubiquity resource-value channel reports a BOOLEAN, not a
    /// percentage (the percent keys are unavailable on modern macOS). So an
    /// in-flight item is progress 0 and completion is signalled by the item
    /// leaving the list — never by progress reaching 1.
    @Test func inFlightItemsCarryNoProgressFigure() {
        let upload = UbiquityTransferSource.makeTransferItem(
            path: "/Users/tester/Documents/a.key", name: "a.key", sizeBytes: 10,
            isUploading: true, homeDirectory: home)
        #expect(upload.direction == .upload)
        #expect(upload.progress == 0.0)
        #expect(!upload.isDone)
        #expect(upload.appID == "desktop-documents")

        let download = UbiquityTransferSource.makeTransferItem(
            path: "/Users/tester/Desktop/b.zip", name: "b.zip", sizeBytes: 100,
            isUploading: false, homeDirectory: home)
        #expect(download.direction == .download)
        #expect(download.progress == 0.0)
        #expect(download.appID == "desktop-documents")
    }

    // MARK: - DriveFolder status derivation

    @Test func folderSyncingWhenTransferUnderIt() {
        let locations = ["~/Library/Mobile Documents/com~apple~CloudDocs/Design/Assets"]
        let folder = DriveFolderSource.makeFolder(name: "Design", itemCount: 12, transferLocations: locations)
        #expect(folder.status.isSyncing)
        #expect(folder.itemCount == 12)
    }

    @Test func folderUpToDateWhenNoTransfersUnderIt() {
        let locations = ["~/Library/Mobile Documents/com~apple~CloudDocs/DesignOld", "~/Desktop"]
        let folder = DriveFolderSource.makeFolder(name: "Design", itemCount: 3, transferLocations: locations)
        #expect(folder.status == .upToDate)
    }

    // A cached scan is re-decorated every cycle: fails if a folder keeps a
    // stale status from the scan or ignores this cycle's transfers.
    @Test func applyingTransfersReDerivesCachedFolderStatus() {
        let scanned = [
            DriveFolderSource.makeFolder(name: "Design", itemCount: 4, transferLocations: []),
            DriveFolderSource.makeFolder(name: "Notes", itemCount: 2, transferLocations: []),
        ]
        #expect(scanned.allSatisfy { $0.status == .upToDate })

        let transfer = TransferItem(
            id: "t", appID: "icloud-drive", name: "a.png",
            location: "~/Library/Mobile Documents/com~apple~CloudDocs/Design/Assets",
            sizeBytes: 1, direction: .upload, progress: 0)
        let busy = DriveFolderSource.applying(transfers: [transfer], to: scanned)
        #expect(busy.first { $0.name == "Design" }?.status.isSyncing == true)
        #expect(busy.first { $0.name == "Notes" }?.status == .upToDate)
        #expect(busy.map(\.itemCount) == [4, 2])

        let idle = DriveFolderSource.applying(transfers: [], to: busy)
        #expect(idle.allSatisfy { $0.status == .upToDate })
    }

    @Test func folderSyncingOnExactLocationMatch() {
        let folder = DriveFolderSource.makeFolder(
            name: "Design", itemCount: 1,
            transferLocations: ["~/Library/Mobile Documents/com~apple~CloudDocs/Design"])
        #expect(folder.status.isSyncing)
    }
}
