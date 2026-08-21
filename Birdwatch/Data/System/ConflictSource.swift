import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "conflict-source")

/// Real conflict detection and resolution over NSFileVersion.
///
/// Detection walks ~/Library/Mobile Documents/com~apple~CloudDocs (capped,
/// package contents skipped, hidden skipped, per-item fault-tolerant) and asks
/// each regular file for unresolved conflict versions. Resolution follows the
/// documented NSFileVersion dance — user data is sacred (§8): nothing is ever
/// deleted except through the explicit keep-current / keep-version / keep-both
/// semantics below.
enum ConflictSource {

    /// Version-id sentinel meaning "keep the file as it is on disk".
    nonisolated static let currentVersionID = "current"
    /// Version-id sentinel meaning "keep every version" (conflicts are
    /// duplicated alongside as "<name> (conflicted copy)").
    nonisolated static let keepBothVersionID = "both"

    nonisolated static let maxItemsVisited = 2000

    struct FoundConflict: Sendable {
        let issue: IssueItem
        let detail: ConflictDetail
    }

    // MARK: - Detection

    @concurrent nonisolated static func findConflicts(
        root: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    ) async -> [FoundConflict] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                let ns = error as NSError
                logger.warning("conflict scan: cannot read \(url.path, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                return true   // one bad URL never aborts the scan
            }
        ) else {
            logger.warning("conflict scan: cannot enumerate \(root.path, privacy: .private)")
            return []
        }

        var visited = 0
        var found: [FoundConflict] = []
        // NSEnumerator's makeIterator is unavailable in async contexts (Swift
        // 6.2 sendability); nextObject() is the supported equivalent.
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxItemsVisited {
                logger.info("conflict scan: cap of \(maxItemsVisited) items reached, stopping")
                break
            }
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                // Coordinated read: bird may be mid-write; an uncoordinated
                // probe can see a torn state or race the version store.
                guard let conflicts = try coordinatedUnresolvedVersions(of: url),
                      !conflicts.isEmpty else { continue }
                found.append(makeFound(fileURL: url, conflicts: conflicts))
            } catch {
                let ns = error as NSError
                logger.warning("conflict scan: skipping \(url.path, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                continue
            }
        }
        return found
    }

    /// `NSFileVersion.unresolvedConflictVersionsOfItem` inside a coordinated
    /// read. Throws whatever the coordinator reports (via NSErrorPointer) or
    /// the accessor threw.
    private nonisolated static func coordinatedUnresolvedVersions(of url: URL) throws -> [NSFileVersion]? {
        var versions: [NSFileVersion]?
        try coordinate(.read(url, options: [.withoutChanges])) {
            versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url)
        }
        return versions
    }

    private enum CoordinatedAccess {
        case read(URL, options: NSFileCoordinator.ReadingOptions)
        case write(URL, options: NSFileCoordinator.WritingOptions)
    }

    /// Bridges NSFileCoordinator's synchronous, NSErrorPointer-based callback
    /// API: the accessor's own throw wins, otherwise a coordination failure is
    /// rethrown. The accessor runs synchronously on this thread before the
    /// coordinate call returns, so the local captures are safe.
    private nonisolated static func coordinate(
        _ access: CoordinatedAccess,
        accessor: () throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var accessorError: Error?
        var coordinationError: NSError?
        let run: (URL) -> Void = { _ in
            do { try accessor() } catch { accessorError = error }
        }
        switch access {
        case .read(let url, let options):
            coordinator.coordinate(readingItemAt: url, options: options, error: &coordinationError, byAccessor: run)
        case .write(let url, let options):
            coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError, byAccessor: run)
        }
        if let accessorError { throw accessorError }
        if let coordinationError { throw coordinationError }
    }

    /// Defense in depth: resolution only ever mutates files inside the
    /// CloudDocs container. A cached detail whose path was tampered with (or a
    /// symlink escape) must never reach `replaceItem`/`removeOtherVersions`.
    nonisolated static func isUnderCloudDocsRoot(
        _ fileURL: URL,
        root: URL = DriveFolderSource.cloudDocsURL
    ) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return filePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private nonisolated static func makeFound(fileURL: URL, conflicts: [NSFileVersion]) -> FoundConflict {
        let tiles = ["0a84ff", "af52de", "30b0c7", "ffa62b", "34c759"]

        func size(of url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        var versions: [ConflictVersion] = []
        let current = NSFileVersion.currentVersionOfItem(at: fileURL)
        let currentDevice = current?.localizedNameOfSavingComputer ?? "This Mac"
        versions.append(ConflictVersion(
            id: currentVersionID,
            deviceName: currentDevice,
            tileColorHex: tiles[0],
            modified: current?.modificationDate
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast,
            sizeBytes: size(of: fileURL),
            // We cannot know WHAT changed — never invent it.
            changeNote: "Edited on \(currentDevice)"
        ))
        for (index, version) in conflicts.enumerated() {
            let device = version.localizedNameOfSavingComputer ?? "Unknown device"
            versions.append(ConflictVersion(
                id: versionID(for: version),
                deviceName: device,
                tileColorHex: tiles[(index + 1) % tiles.count],
                modified: version.modificationDate ?? .distantPast,
                sizeBytes: size(of: version.url),
                changeNote: "Edited on \(device)"
            ))
        }

        let detail = ConflictDetail(
            fileName: fileURL.lastPathComponent,
            location: UbiquityTransferSource.displayLocation(forPath: fileURL.path),
            versions: versions,
            fileURL: fileURL
        )
        let issue = IssueItem(
            id: issueID(forPath: fileURL.path),
            severity: .conflict,
            title: "Sync conflict in \(fileURL.deletingLastPathComponent().lastPathComponent)",
            meta: "\(fileURL.lastPathComponent) · \(versions.count) versions",
            reason: "This file was edited on more than one device, so iCloud kept every version instead of guessing. Review them and choose which to keep — nothing has been lost.",
            action: .reviewVersions,
            symbolName: "doc.on.doc",
            // Attributed to the owning CloudDocs app so per-app mute can
            // suppress the banner (same mapping the transfer rows use).
            appID: UbiquityTransferSource.appID(forPath: fileURL.path)
        )
        return FoundConflict(issue: issue, detail: detail)
    }

    /// Stable issue id: same path → same id across scans. FNV-1a, NOT
    /// String.hashValue (which is per-process randomized).
    nonisolated static func issueID(forPath path: String) -> String {
        "conflict-" + fnv1a(path)
    }

    /// Stable id for one conflict version, derived from its version-store URL.
    nonisolated static func versionID(for version: NSFileVersion) -> String {
        "version-" + fnv1a(version.url.path)
    }

    private nonisolated static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }

    // MARK: - Resolution

    /// Resolves the conflict on `fileURL` according to `keepVersionID`:
    /// - `currentVersionID`: the on-disk file wins; other versions are removed
    ///   and every unresolved version is marked resolved.
    /// - a conflict version id: that version replaces the on-disk file first,
    ///   then other versions are removed and all are marked resolved.
    /// - `keepBothVersionID`: each conflict version is duplicated alongside as
    ///   "<name> (conflicted copy)" before removal, so no bytes are lost. A
    ///   copy that fails is logged and skipped — one unreadable version never
    ///   aborts preservation of the others.
    ///
    /// Every mutation runs inside an `NSFileCoordinator` coordinated write
    /// (`.forReplacing` when a version replaces the file, `.forMerging` for the
    /// keep-current / keep-both dances) so `bird` cannot be mid-write on the
    /// file we are rewriting.
    @discardableResult
    ///
    /// `root` is a pure test seam only: it defaults to the real CloudDocs
    /// container, so every production call behaves exactly as before.
    @concurrent nonisolated static func resolve(
        fileURL: URL,
        keepVersionID: String,
        root: URL = DriveFolderSource.cloudDocsURL
    ) async -> Bool {
        // Defense in depth: never mutate anything outside the CloudDocs root.
        guard isUnderCloudDocsRoot(fileURL, root: root) else {
            logger.error("resolve: refusing to mutate a path outside CloudDocs: \(fileURL.path, privacy: .private)")
            return false
        }
        do {
            guard let unresolved = try coordinatedUnresolvedVersions(of: fileURL),
                  !unresolved.isEmpty else {
                logger.info("resolve: no unresolved versions for \(fileURL.path, privacy: .private) — already resolved")
                return true
            }
            return applyResolution(
                fileURL: fileURL, keepVersionID: keepVersionID, unresolved: unresolved, root: root
            )
        } catch {
            let ns = error as NSError
            logger.error("resolve failed for \(fileURL.path, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// The mutating half of `resolve`, split out from the *discovery* of the
    /// unresolved versions so it can be exercised against REAL `NSFileVersion`
    /// objects (`NSFileVersion.addOfItem` can create versions on a scratch
    /// file, but only iCloud can flag one as an unresolved *conflict*). Every
    /// mutation below — `replaceItem`, `removeOtherVersionsOfItem`, the
    /// conflicted-copy claim — is the production API, not a stand-in.
    ///
    /// Synchronous and `nonisolated`: `NSFileVersion` is not `Sendable`, so
    /// the version list must never cross an isolation boundary.
    nonisolated static func applyResolution(
        fileURL: URL,
        keepVersionID: String,
        unresolved: [NSFileVersion],
        root: URL = DriveFolderSource.cloudDocsURL
    ) -> Bool {
        // Repeated on this path too: it is the one that actually writes, and
        // it is reachable without going through `resolve`.
        guard isUnderCloudDocsRoot(fileURL, root: root) else {
            logger.error("applyResolution: refusing to mutate a path outside CloudDocs: \(fileURL.path, privacy: .private)")
            return false
        }
        do {
            switch keepVersionID {
            case currentVersionID:
                break   // the on-disk file already is the kept version
            case keepBothVersionID:
                for version in unresolved {
                    do {
                        try coordinate(.write(fileURL, options: [.forMerging])) {
                            let dest = try claimConflictedCopy(of: version.url, nextTo: fileURL)
                            logger.info("resolve: preserved conflict version as \(dest.lastPathComponent, privacy: .private)")
                        }
                    } catch {
                        // Keep going: preserving the remaining versions is
                        // strictly better than aborting with some lost.
                        let ns = error as NSError
                        logger.error("resolve: could not preserve one conflict version of \(fileURL.path, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                    }
                }
            default:
                guard let winner = unresolved.first(where: { versionID(for: $0) == keepVersionID }) else {
                    logger.error("resolve: no version matching id \(keepVersionID, privacy: .public) for \(fileURL.path, privacy: .private)")
                    return false
                }
                try coordinate(.write(fileURL, options: [.forReplacing])) {
                    try winner.replaceItem(at: fileURL)
                }
            }
            try coordinate(.write(fileURL, options: [.forMerging])) {
                try NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
                for version in unresolved { version.isResolved = true }
            }
            return true
        } catch {
            let ns = error as NSError
            logger.error("resolve failed for \(fileURL.path, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// "<name> (conflicted copy).ext" for attempt 0, then
    /// "<name> (conflicted copy 2).ext", "… 3" and so on.
    ///
    /// PURE: it never touches the filesystem, so it cannot go stale between a
    /// check and a create. Choosing a free name is `claimConflictedCopy`'s job,
    /// and it does it by claiming, not by asking.
    nonisolated static func conflictedCopyURL(for fileURL: URL, attempt: Int = 0) -> URL {
        let dir = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension
        let base = fileURL.deletingPathExtension().lastPathComponent
        let suffix = attempt == 0 ? " (conflicted copy)" : " (conflicted copy \(attempt + 1))"
        var candidate = dir.appending(path: base + suffix)
        if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
        return candidate
    }

    /// A directory holding this many conflicted copies of one file is
    /// pathological; failing loudly beats looping forever.
    nonisolated static let maxConflictedCopyAttempts = 1000

    /// Copies `sourceURL` (a conflict version's store URL) next to `fileURL`
    /// under the first free "(conflicted copy)" name, and claims that name
    /// ATOMICALLY. Returns the URL actually claimed.
    ///
    /// The bytes land on a hidden temporary in the same directory first, then
    /// `renamex_np` with `RENAME_EXCL` moves them into place: the kernel
    /// refuses the rename when the name is taken, so no racing writer (`bird`,
    /// a second resolve, the user) can slip in between "is this name free?"
    /// and "create it" — the check-then-act window this replaces could litter
    /// or clobber. `FileManager.fileExists` cannot close that window even
    /// single-threaded: it FOLLOWS symlinks, so a dangling symlink at the
    /// candidate name reads as free and the copy then fails, losing that
    /// version. `renamex_np` operates on the link itself and reports EEXIST.
    ///
    /// Rename (not `link`) so directory-shaped versions — packages such as
    /// `.rtfd` — are preserved too; `link(2)` refuses directories.
    nonisolated static func claimConflictedCopy(of sourceURL: URL, nextTo fileURL: URL) throws -> URL {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let temp = dir.appending(path: ".bw-conflicted-copy-\(UUID().uuidString)")
        try fm.copyItem(at: sourceURL, to: temp)
        var claimed = false
        // The temporary must never survive a failure — a stray dotfile in the
        // user's CloudDocs folder would sync to every device. If even the
        // cleanup fails, say so (C7): a leaked temp is a real, visible symptom.
        defer {
            if !claimed {
                do { try fm.removeItem(at: temp) } catch {
                    let ns = error as NSError
                    logger.error("resolve: could not remove the conflicted-copy temporary \(temp.path, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                }
            }
        }

        for attempt in 0..<maxConflictedCopyAttempts {
            let candidate = conflictedCopyURL(for: fileURL, attempt: attempt)
            if renamex_np(temp.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                claimed = true
                return candidate
            }
            let code = errno
            // EEXIST is the ordinary "that number is taken" answer; anything
            // else (permissions, read-only volume) is real and must surface.
            guard code == EEXIST else { throw posixError(code, path: candidate.path) }
        }
        throw posixError(EEXIST, path: conflictedCopyURL(for: fileURL, attempt: maxConflictedCopyAttempts - 1).path)
    }

    private nonisolated static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: String(cString: strerror(code))
        ])
    }
}
