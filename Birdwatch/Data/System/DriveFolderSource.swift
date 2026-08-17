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

    /// Shallow enumeration of the CloudDocs container. `@concurrent` so callers
    /// on the MainActor never pay for the directory I/O.
    @concurrent
    static func currentFolders(transfers: [TransferItem]) async -> [DriveFolder] {
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
            folders.append(makeFolder(
                name: url.lastPathComponent,
                itemCount: count,
                transferLocations: transfers.map(\.location)
            ))
        }
        return folders
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
