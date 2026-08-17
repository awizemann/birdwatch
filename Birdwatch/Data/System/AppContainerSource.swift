import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "AppContainerSource")

/// Per-app iCloud Drive containers under `~/Library/Mobile Documents`.
///
/// Research (live machine, Phase 5A): `brctl status <id>` is useless per app —
/// bird only tracks the `com.apple.CloudDocs` zone, so *any* id that isn't a
/// known zone either echoes the CloudDocs record ("1 containers matching …") or
/// errors with `BRCloudDocsErrorDomain:30 Client zone not found`. It also does
/// not exit promptly. So: no brctl per container, ever. Everything here comes
/// from a shallow, capped directory enumeration — one readdir per container.
enum AppContainerSource {

    /// Root of the ubiquity containers.
    nonisolated static var containersRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }

    /// Hard cap on containers examined per cycle — this machine has 219 and a
    /// pathological account could have far more.
    nonisolated static let containerCap = 400
    /// Cap on the shallow item count per container (never a deep tree walk).
    nonisolated static let itemCountCap = 500

    /// Container directory names that already have a first-class entry in the
    /// Applications list, or that are pure system plumbing with no app face.
    nonisolated static let excludedDirectoryNames: Set<String> = [
        "com~apple~CloudDocs",          // → "iCloud Drive"
        "com~apple~TextInput",
        "com~apple~system~spotlight",
        "com~apple~SafariShared~History",
        "com~apple~productkit~personalization",
        "com~apple~productkit~b389personalization",
        "debug",
    ]

    /// A cheap, Sendable description of one container (pure data, no I/O).
    struct Container: Sendable, Hashable {
        let directoryName: String       // e.g. "iCloud~md~obsidian"
        let id: String                  // e.g. "container-icloud-md-obsidian"
        let name: String                // e.g. "Obsidian"
        let isApple: Bool
        var itemCount: Int = 0
        var lastModified: Date?
    }

    // MARK: - Enumeration (I/O, off-main)

    /// Shallow scan: one `contentsOfDirectory` for the root plus at most one per
    /// container. Fault-tolerant per item — a container that fails to read is
    /// skipped, never the whole list. Containers with no visible content are
    /// dropped (dozens of accounts leave empty stubs behind forever).
    @concurrent
    static func currentContainers() async -> [Container] {
        let fm = FileManager.default
        let root = containersRoot
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        } catch {
            let ns = error as NSError
            logger.error("Mobile Documents enumeration failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return []
        }

        var result: [Container] = []
        result.reserveCapacity(min(entries.count, containerCap))
        for url in entries.prefix(containerCap) {
            if Task.isCancelled { break }
            let dir = url.lastPathComponent
            guard var container = makeContainer(directoryName: dir) else { continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            // Content lives in <container>/Documents for essentially every app;
            // fall back to the container root when it doesn't.
            let documents = url.appendingPathComponent("Documents", isDirectory: true)
            var count = 0
            var modified: Date?
            for candidate in [documents, url] {
                do {
                    let items = try fm.contentsOfDirectory(
                        at: candidate, includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )
                    let visible = items.filter { $0.lastPathComponent != "Documents" || candidate == documents }
                    if !visible.isEmpty {
                        count = min(visible.count, itemCountCap)
                        modified = visible.compactMap {
                            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        }.max()
                        break
                    }
                } catch {
                    let ns = error as NSError
                    logger.debug("container read failed \(dir, privacy: .private): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                }
            }
            guard count > 0 else { continue }       // empty stub — not an app the user has data in
            container.itemCount = count
            container.lastModified = modified
            result.append(container)
        }
        return result
    }

    // MARK: - Pure mapping (tested against real captured container names)

    /// Team-id prefix: exactly 10 uppercase alphanumerics containing a digit.
    nonisolated static func isTeamID(_ component: String) -> Bool {
        component.count == 10
            && component.allSatisfy { $0.isUppercase || $0.isNumber }
            && component.contains(where: \.isNumber)
    }

    /// Leading reverse-DNS roots that carry no app identity.
    nonisolated static let leadingNoise: Set<String> = [
        "icloud", "com", "net", "org", "io", "co", "me", "dk", "is", "us", "ph",
        "ca", "se", "it", "md", "space", "group", "host", "events", "de", "fr",
        "uk", "app", "dev", "iCloud-OB".lowercased(),
    ]

    /// Trailing components that describe plumbing rather than the app.
    nonisolated static let trailingNoise: Set<String> = [
        "app", "ios", "iphone", "ipad", "mobile", "client", "container",
        "icloudcontainer", "prod", "release", "sync", "shared", "data",
        "coredata", "clouddata", "backup", "backups", "encryptedbackups",
        "private", "preferences", "queries", "runtime", "cloudcontent",
        "appstore", "setapp", "client-only", "app-data", "reader", "ui",
    ]

    /// Container directory name → display name. Pure; no I/O.
    /// Returns nil for names that cannot yield anything presentable.
    nonisolated static func displayName(forDirectory dir: String) -> String? {
        var parts = dir.split(separator: "~", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        if isTeamID(parts[0]) { parts.removeFirst() }
        while parts.count > 1, leadingNoise.contains(parts[0].lowercased()) { parts.removeFirst() }
        while parts.count > 1, trailingNoise.contains(parts[parts.count - 1].lowercased()) { parts.removeLast() }
        guard var last = parts.last else { return nil }

        // Separators → spaces, collapse whitespace.
        last = last.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        var words = last.split(whereSeparator: { $0 == " " }).map(String.init)
        // Hyphenated plumbing suffixes too ("SnippetsLab-setapp").
        while words.count > 1, trailingNoise.contains(words[words.count - 1].lowercased()) { words.removeLast() }
        guard !words.isEmpty else { return nil }
        let pretty = words.map { word -> String in
            // Preserve deliberate camel/upper case ("TextEdit", "MobileSMS");
            // only fix an all-lowercase word.
            guard word.contains(where: \.isUppercase) == false else { return word }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        let trimmed = pretty.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Stable app id for a container directory. Pure; no I/O.
    nonisolated static func appID(forDirectory dir: String) -> String {
        let slug = dir.lowercased()
            .replacingOccurrences(of: "~", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "container-\(slug)"
    }

    /// Full pure mapping for one directory entry; nil when it should be skipped.
    nonisolated static func makeContainer(directoryName dir: String) -> Container? {
        guard !dir.isEmpty, !dir.hasPrefix("."), !excludedDirectoryNames.contains(dir) else { return nil }
        guard let name = displayName(forDirectory: dir) else { return nil }
        let lowered = dir.lowercased()
        let isApple = lowered.contains("com~apple~") || lowered.hasPrefix("com~apple")
        return Container(directoryName: dir, id: appID(forDirectory: dir), name: name, isApple: isApple)
    }

    // MARK: - Transfer attribution (pure)

    /// Directory name of the ubiquity container a path belongs to, if any.
    /// `~/Library/Mobile Documents/<dir>/…` → `<dir>`.
    nonisolated static func containerDirectory(
        forPath path: String, homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        let prefix = homeDirectory + "/Library/Mobile Documents/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let dir = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first,
              !dir.isEmpty else { return nil }
        return String(dir)
    }

    /// App id a transfer path attributes to, or nil when the caller should fall
    /// back to its own defaults (iCloud Drive / Desktop & Documents).
    nonisolated static func appID(forPath path: String, homeDirectory: String = NSHomeDirectory()) -> String? {
        guard let dir = containerDirectory(forPath: path, homeDirectory: homeDirectory) else { return nil }
        if dir == "com~apple~CloudDocs" { return "icloud-drive" }
        guard let container = makeContainer(directoryName: dir) else { return nil }
        return container.id
    }

    // MARK: - Local footprint ("On this Mac")

    /// Cap on entries visited per size pass. iCloud containers can hold tens of
    /// thousands of files; beyond this we stop and log rather than walk forever.
    nonisolated static let sizeEntryCap = 50_000

    /// Deep, capped, per-item fault-tolerant sum of **allocated** bytes.
    ///
    /// Allocated (not logical) size is the honest number for a monitoring tool:
    /// a dataless placeholder occupies almost nothing on disk, so a mostly
    /// evicted container correctly reports a small figure. This is the local
    /// footprint — never the cloud size.
    ///
    /// Pure w.r.t. its input directory, so tests drive it with a temp dir.
    nonisolated static func allocatedSize(ofDirectory url: URL, cap: Int = sizeEntryCap) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { failed, error in
                logger.debug("size walk skipped \(failed.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                return true      // per-item fault tolerance: keep walking
            }
        ) else { return 0 }

        var total: Int64 = 0
        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited > cap {
                logger.notice("size walk hit the \(cap, privacy: .public)-entry cap for \(url.lastPathComponent, privacy: .private); reporting a partial figure")
                break
            }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }

    /// Local footprint per app id: every container plus the two built-in
    /// CloudDocs rows. Runs OFF the snapshot path (see SystemSyncSource's
    /// 5-minute, single-flight container-size cache).
    @concurrent
    static func localSizes(
        containers: [Container], homeDirectory: String = NSHomeDirectory(),
        includeDesktopDocuments: Bool = false
    ) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        let home = URL(fileURLWithPath: homeDirectory)
        let root = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)

        sizes["icloud-drive"] = allocatedSize(ofDirectory: root.appendingPathComponent("com~apple~CloudDocs", isDirectory: true))
        // Only when Desktop & Documents sync is on — otherwise these are plain
        // local folders and reading them just triggers a TCC prompt.
        if includeDesktopDocuments {
            sizes["desktop-documents"] = allocatedSize(ofDirectory: home.appendingPathComponent("Desktop", isDirectory: true))
                + allocatedSize(ofDirectory: home.appendingPathComponent("Documents", isDirectory: true))
        }

        for container in containers {
            if Task.isCancelled { break }
            sizes[container.id] = allocatedSize(
                ofDirectory: root.appendingPathComponent(container.directoryName, isDirectory: true)
            )
        }
        return sizes
    }

    // MARK: - Tiles

    /// Design tile palette. Index chosen by a stable, platform-independent hash
    /// of the name (Swift's `hashValue` is seeded per process — unusable here).
    nonisolated static let tilePalette = [
        "30b0c7", "ffa62b", "fe4f6d", "ffcc00", "34c759",
        "1e8fff", "1a73e8", "d63d3d", "4b5bd6", "5e5ce6",
        "af52de", "ff9500", "00c7be", "8e8e93",
    ]

    /// FNV-1a over UTF-8: stable across launches and machines.
    nonisolated static func tileColorHex(forName name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return tilePalette[Int(hash % UInt64(tilePalette.count))]
    }

    // MARK: - App rows

    /// Containers → `AppSyncState` rows, sorted active-first then by name.
    nonisolated static func makeApps(
        containers: [Container], transfers: [TransferItem], localSizes: [String: Int64] = [:]
    ) -> [AppSyncState] {
        let byApp = Dictionary(grouping: transfers, by: \.appID)
        let rows = containers.map { container -> AppSyncState in
            let own = byApp[container.id] ?? []
            let syncing = !own.isEmpty
            let progress = syncing ? own.map(\.progress).reduce(0, +) / Double(own.count) : 1
            return AppSyncState(
                id: container.id,
                name: container.name,
                tileColorHex: tileColorHex(forName: container.name),
                backend: .cloudDocs,
                isApple: container.isApple,
                status: syncing ? .syncing(progress: progress) : .upToDate,
                statusLine: syncing
                    ? "\(own.count) file\(own.count == 1 ? "" : "s") in transfer"
                    : "\(container.itemCount) item\(container.itemCount == 1 ? "" : "s") in iCloud Drive",
                lastActivity: container.lastModified,
                itemsIndexed: container.itemCount,
                pendingItems: own.count,
                // Filled by the background size pass (5-min cache); 0 until it lands.
                localSizeBytes: localSizes[container.id] ?? 0,
                locationPath: "~/Library/Mobile Documents/\(container.directoryName)",
                infoCallout: "\(container.name) stores documents in its own iCloud Drive container. Counts are the container's top level, and \"On this Mac\" is allocated bytes actually stored locally — files still in the cloud (dataless placeholders) take almost no space, so this can be far smaller than the container's cloud size."
            )
        }
        return rows.sorted { lhs, rhs in
            let lActive = lhs.pendingItems > 0, rActive = rhs.pendingItems > 0
            if lActive != rActive { return lActive }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
