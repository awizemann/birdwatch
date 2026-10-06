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
    nonisolated static func scanFolders() -> [DriveFolder] {
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
            return []
        }

        var folders: [DriveFolder] = []
        for url in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            var count = 0
            do {
                let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                count = min(entries.count, itemCountCap)
            } catch {
                let ns = error as NSError
                logger.warning("item count failed for \(url.lastPathComponent, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
            folders.append(makeFolder(name: url.lastPathComponent, itemCount: count, transferLocations: []))
        }
        return folders
    }

    /// Re-derives each folder's sync status from THIS cycle's transfers, so a
    /// cached scan never carries a stale "syncing" state.
    nonisolated static func applying(transfers: [TransferItem], to folders: [DriveFolder]) -> [DriveFolder] {
        let locations = transfers.map(\.location)
        return folders.map { makeFolder(name: $0.name, itemCount: $0.itemCount, transferLocations: locations) }
    }

    // MARK: - Pure mapping (separated from I/O for testability)

    /// A folder is .syncing when any in-flight transfer's display location falls
    /// under `~/Library/Mobile Documents/com~apple~CloudDocs/<name>`.
    nonisolated static func makeFolder(name: String, itemCount: Int, transferLocations: [String]) -> DriveFolder {
        let folderLocation = "~/Library/Mobile Documents/com~apple~CloudDocs/" + name
        let syncing = transferLocations.contains {
            $0 == folderLocation || $0.hasPrefix(folderLocation + "/")
        }
        return DriveFolder(
            id: name,
            name: name,
            itemCount: itemCount,
            status: syncing ? .syncing(progress: 0) : .upToDate
        )
    }
}
