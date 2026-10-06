import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "DriveFolderSource")

/// Top-level iCloud Drive folder rows derived from the local CloudDocs container.
/// A second NSMetadataQuery would be overkill for a shallow directory listing,
/// so this enumerates the filesystem directly — always off the main actor.
enum DriveFolderSource {

    /// Cap per-folder item counting so one huge folder can't make the scan expensive.
    nonisolated static let itemCountCap = 500

    nonisolated static var cloudDocsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Shallow enumeration of the CloudDocs container. BLOCKING — it can hang
    /// on cold File Provider placeholders, so it only ever runs on a
    /// `SingleFlightScan`'s own queue, never a cooperative-pool thread. Rows
    /// come back `.upToDate`; `applying(transfers:to:)` adds per-cycle status.
    /// nil when the iCloud Drive root itself can't be read — not an empty
    /// drive, and the UI must say so rather than show an empty table (C1).
    nonisolated static func scanFolders() -> [DriveFolder]? {
        let fm = FileManager.default
        let root = cloudDocsURL
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let ns = error as NSError
            logger.error("CloudDocs enumeration failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return nil
        }

        var folders: [DriveFolder] = []
        for url in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            // nil, not 0, when the folder can't be read: "0 items" would be a
            // fabricated count (C1).
            var count: Int?
            var capped = false
            do {
                let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                count = min(entries.count, itemCountCap)
                capped = entries.count > itemCountCap
            } catch {
                let ns = error as NSError
                logger.warning("item count failed for \(url.lastPathComponent, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
            folders.append(makeFolder(name: url.lastPathComponent, itemCount: count, transferLocations: [],
                                      itemCountIsCapped: capped))
        }
        return folders
    }

    /// Re-derives each folder's sync status from THIS cycle's transfers, so a
    /// cached scan never carries a stale "syncing" state.
    nonisolated static func applying(transfers: [TransferItem], to folders: [DriveFolder]) -> [DriveFolder] {
        // In flight only: a finished item lingers (completionGrace) at 1.0.
        let locations = transfers.filter { !$0.isDone }.map(\.location)
        return folders.map {
            makeFolder(name: $0.name, itemCount: $0.itemCount, transferLocations: locations,
                       itemCountIsCapped: $0.itemCountIsCapped)
        }
    }

    // MARK: - Pure mapping (separated from I/O for testability)

    /// A folder is .syncing when any in-flight transfer's display location falls
    /// under `~/Library/Mobile Documents/com~apple~CloudDocs/<name>`
    /// (`DriveFolder.folderName(containing:)`). The progress stays 0: the
    /// channel is boolean, and the view asks the store whether any transfer in
    /// the folder carries a real fraction.
    nonisolated static func makeFolder(
        name: String, itemCount: Int?, transferLocations: [String], itemCountIsCapped: Bool = false
    ) -> DriveFolder {
        let syncing = transferLocations.contains { DriveFolder.folderName(containing: $0) == name }
        return DriveFolder(
            id: name,
            name: name,
            itemCount: itemCount,
            status: syncing ? .syncing(progress: 0) : .upToDate,
            itemCountIsCapped: itemCountIsCapped
        )
    }
}
