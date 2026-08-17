import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "path-resolver")

/// How sure we are that a redacted dump item is a particular file on disk.
nonisolated enum PathMatchConfidence: Sendable, Hashable {
    /// Exactly one file on disk fits the redaction pattern (and size, for files).
    case exact
    /// Several files fit. `count` is how many.
    case ambiguous(count: Int)
    /// Nothing on disk fits — or bird gave us nothing to match against.
    case none
}

nonisolated struct ResolvedPath: Sendable, Hashable {
    /// Home-relative, `~`-abbreviated, for display.
    var displayPath: String
    /// Absolute path, for `Reveal in Finder`. nil when ambiguous with no shared parent.
    var absolutePath: String?
    var confidence: PathMatchConfidence
}

/// One real file or directory we found ourselves, on our own filesystem.
nonisolated struct PathCandidate: Sendable, Hashable {
    /// Absolute path.
    var path: String
    /// Last path component.
    var name: String
    var isDirectory: Bool
    /// File size in bytes; nil for directories.
    var sizeBytes: Int64?
    /// Top-level `~/Library/Mobile Documents` child this lives under, e.g.
    /// `iCloud~com~microsoft~Office~Excel`. nil when the candidate is outside
    /// the ubiquity root.
    var containerDirectoryName: String?
}

/// Recovers real paths for the length-redacted items in `brctl dump`.
///
/// WHY this is honest: bird redacts names as `D{7}s` — first character, hidden
/// length, last character, real extension. We never "un-redact" anything. We
/// enumerate OUR OWN filesystem and ask which real files fit the shape bird
/// printed. A single fit is a fact about our disk, reported as such; several
/// fits are reported as several; no fit is reported as no path at all.
///
/// The strongest signal is not the file name but the **app-library header** that
/// precedes each block of client items:
///
///     ----------------------i{4}d.c{1}m.m{7}t.O{4}e.E{3}l[171]----------------------
///
/// That is a redacted *container* identifier, and containers are directories in
/// `~/Library/Mobile Documents` whose names are the same identifier with `.`
/// written as `~`. Matching it narrows every item in the block to one container
/// before the name pattern is even considered — which is why the resolution rate
/// on a real account is 110 of 110 rather than a coin flip.
nonisolated enum RedactedPathResolver {

    /// Hard cap on entries visited in one pass. Same discipline as
    /// `StorageBreakdownSource`: stop, log, report what we have.
    static let entryCap = 50_000

    static var ubiquityRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
    }

    // MARK: - Pattern matching (pure)

    /// Does `name` fit bird's redaction `pattern`?
    ///
    /// `{n}` stands for exactly n hidden characters; everything else is literal.
    /// `D{7}s` fits `Documents` and nothing shorter or longer; `r{21}g.pdf` fits
    /// any 26-character name starting `r`, ending `g`, with extension `pdf`.
    /// A pattern with no braces is compared literally (bird leaves short names
    /// and our own test fixtures unredacted).
    static func matches(pattern: String, name: String) -> Bool {
        var patternIndex = pattern.startIndex
        var nameIndex = name.startIndex
        while patternIndex < pattern.endIndex {
            if pattern[patternIndex] == "{",
               let close = pattern[patternIndex...].firstIndex(of: "}"),
               let hidden = Int(pattern[pattern.index(after: patternIndex)..<close]) {
                guard let advanced = name.index(nameIndex, offsetBy: hidden, limitedBy: name.endIndex) else { return false }
                nameIndex = advanced
                patternIndex = pattern.index(after: close)
            } else {
                guard nameIndex < name.endIndex, name[nameIndex] == pattern[patternIndex] else { return false }
                nameIndex = name.index(after: nameIndex)
                patternIndex = pattern.index(after: patternIndex)
            }
        }
        return nameIndex == name.endIndex
    }

    /// Container identifiers are printed dot-separated (`i{4}d.c{1}m…`) but the
    /// directories on disk spell the separator `~`.
    static func matchesContainer(pattern: String, directoryName: String) -> Bool {
        matches(pattern: pattern, name: directoryName.replacingOccurrences(of: "~", with: "."))
    }

    // MARK: - Resolution (pure)

    /// Resolves each item against a candidate list. Pure: the caller supplies
    /// the filesystem, so this is fully testable against a temp directory.
    ///
    /// Returns only the items that matched something; a missing key means "no
    /// honest path", which callers must render as the redacted-only wording.
    static func resolve(
        items: [BrctlPendingItem],
        candidates: [PathCandidate]
    ) -> [String: ResolvedPath] {
        guard !items.isEmpty, !candidates.isEmpty else { return [:] }

        let byContainer = Dictionary(grouping: candidates) { $0.containerDirectoryName ?? "" }
        let containerNames = Array(Set(candidates.compactMap(\.containerDirectoryName)))
        // The same container pattern repeats across every item of a block.
        var containerCache: [String: [String]] = [:]

        var out: [String: ResolvedPath] = [:]
        for item in items {
            guard let namePattern = item.redactedName, !namePattern.isEmpty else { continue }

            var pool: [PathCandidate]
            if let containerPattern = item.containerPattern {
                let matched = containerCache[containerPattern] ?? {
                    let found = containerNames.filter { matchesContainer(pattern: containerPattern, directoryName: $0) }
                    containerCache[containerPattern] = found
                    return found
                }()
                // A named container that matches nothing on disk is a real
                // answer: the folder bird is stuck on is not materialised here.
                guard !matched.isEmpty else { continue }
                pool = matched.flatMap { byContainer[$0] ?? [] }
            } else {
                pool = candidates
            }

            let hits = pool.filter { candidate in
                guard candidate.isDirectory == item.isDirectory else { return false }
                guard matches(pattern: namePattern, name: candidate.name) else { return false }
                // Size is the disambiguator that makes a file match near-unique.
                // Only applied when bird printed one and we could read one.
                if !item.isDirectory, let expected = item.byteSize, let actual = candidate.sizeBytes {
                    return actual == expected
                }
                return true
            }

            switch hits.count {
            case 0:
                continue
            case 1:
                out[item.itemID] = ResolvedPath(
                    displayPath: abbreviate(hits[0].path),
                    absolutePath: hits[0].path,
                    confidence: .exact
                )
            default:
                // All ambiguous hits inside one folder still tell the user where
                // to look; spread across folders, we only report the count.
                let parents = Set(hits.map { ($0.path as NSString).deletingLastPathComponent })
                let sharedParent = parents.count == 1 ? parents.first : nil
                out[item.itemID] = ResolvedPath(
                    displayPath: sharedParent.map(abbreviate) ?? "",
                    absolutePath: sharedParent,
                    confidence: .ambiguous(count: hits.count)
                )
            }
        }
        return out
    }

    /// `/Users/x/Library/…` → `~/Library/…`. Never shows the account's short name.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - Measuring a resolved item

    /// What a resolved retry-queue row occupies on this disk.
    nonisolated struct Measurement: Sendable, Hashable {
        /// SHALLOW child count for a directory (what Finder's "N items" shows);
        /// nil for a regular file.
        var itemCount: Int?
        /// Allocated bytes. For a directory this is the sum over a DEEP walk,
        /// capped at `measureEntryCap` entries — `isPartial` says so.
        var sizeBytes: Int64
        /// The deep walk hit the cap, so `sizeBytes` is a floor, not a total.
        var isPartial: Bool = false
    }

    /// Entries visited by one directory measurement. Deliberately far below
    /// `entryCap`: this runs once per shown retry row (≤10), and a container
    /// holding a whole photo library must not turn the dump refresh into a
    /// minutes-long walk.
    static let measureEntryCap = 5_000

    private static let measureKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Measures one resolved path. Pure I/O against a real directory, so it is
    /// tested against a temp-dir fixture rather than the live account.
    ///
    /// Runs on the background dump-refresh Task, never on the paint path — the
    /// same rule as `candidates()`. Returns nil when the path has gone away
    /// (the stuck item was fixed between the dump and the walk), which the UI
    /// renders as no size line rather than "0 bytes".
    static func measure(path: String, cap: Int = measureEntryCap) -> Measurement? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: Set(measureKeys)) else { return nil }
        // A package (.pages, .photoslibrary) is one item to the user, so it is
        // sized like a file — but its bytes still need the deep walk.
        let isDirectory = values.isDirectory == true && values.isPackage != true
        guard isDirectory else {
            return Measurement(itemCount: nil, sizeBytes: Int64(allocatedSize(values)))
        }

        let shallow = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        var total: Int64 = 0
        var visited = 0
        var isPartial = false
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: measureKeys,
            options: [],                       // packages DO count toward the size
            errorHandler: { _, _ in true }     // per-item fault tolerance
        ) {
            for case let child as URL in enumerator {
                visited += 1
                if visited > cap {
                    isPartial = true
                    logger.notice("retry-row measurement hit the \(cap, privacy: .public)-entry cap; reporting a floor")
                    break
                }
                if Task.isCancelled { break }
                guard let childValues = try? child.resourceValues(forKeys: Set(measureKeys)),
                      childValues.isSymbolicLink != true else { continue }
                total += Int64(allocatedSize(childValues))
            }
        }
        return Measurement(itemCount: shallow.count, sizeBytes: total, isPartial: isPartial)
    }

    /// ALLOCATED, not logical: what the file actually costs on this disk.
    /// `totalFileAllocatedSize` includes resource forks; `fileAllocatedSize` is
    /// the fallback. A dataless (evicted) iCloud placeholder allocates ~0, which
    /// is the honest answer for bytes that are not here.
    private static func allocatedSize(_ values: URLResourceValues) -> Int {
        values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
    }

    // MARK: - Candidate enumeration (I/O)

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
    ]

    /// Every file and folder in `~/Library/Mobile Documents` we are willing to
    /// consider, capped and fault-tolerant.
    ///
    /// Runs once per dump refresh, on the same background Task that spawned
    /// `brctl dump` — never on the paint path. Packages are treated as single
    /// items, matching the storage walk, so a `.pages` bundle is a candidate
    /// but its innards are not.
    ///
    /// WHY NOT `.skipsHiddenFiles`: macOS sets the hidden flag on most iCloud
    /// container directories (Finder does not show `iCloud~com~apple~MobileSMS`
    /// as a folder). Passing that option prunes 196 of the 219 containers on
    /// this account — including every one the stuck items live in. Dot-files
    /// are filtered by name instead, which is all the option was wanted for.
    ///
    /// Two passes on purpose:
    ///
    /// 1. **Shallow**, by explicit `contentsOfDirectory` listings rather than a
    ///    depth-limited enumerator. `DirectoryEnumerator.skipDescendants()` on
    ///    this fileprovider-backed volume does not merely skip a subtree — it
    ///    ends the enumeration early (measured: 23 of 219 containers before it
    ///    stopped). Two flat listings are immune to that, and the containers
    ///    plus their `Documents` folders are precisely what bird gets stuck on.
    /// 2. **Deep**, on whatever budget is left, for files further down. A single
    ///    deep walk could never do the job alone: CloudDocs holds >16k items on
    ///    this account and would swallow the entire budget before the
    ///    alphabetically later containers were ever reached.
    static func candidates(root: URL? = nil, cap: Int = entryCap) -> [PathCandidate] {
        var out = shallowPass(root: root ?? ubiquityRoot, cap: cap)
        var seen = Set(out.map(\.path))
        let remaining = cap - out.count
        guard remaining > 0 else { return out }
        for candidate in deepPass(root: root ?? ubiquityRoot, cap: remaining) where !seen.contains(candidate.path) {
            seen.insert(candidate.path)
            out.append(candidate)
        }
        return out
    }

    /// Containers and their immediate children — two levels, no enumerator.
    private static func shallowPass(root: URL, cap: Int) -> [PathCandidate] {
        var out: [PathCandidate] = []
        for container in listing(of: root) {
            guard out.count < cap else { break }
            let name = container.lastPathComponent
            if let entry = candidate(for: container, container: name) { out.append(entry) }
            for child in listing(of: container) {
                guard out.count < cap else { break }
                if let entry = candidate(for: child, container: name) { out.append(entry) }
            }
        }
        return out
    }

    private static func deepPass(root: URL, cap: Int) -> [PathCandidate] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { failed, error in
                logger.debug("path resolver skipped \(failed.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                return true      // per-item fault tolerance: keep walking
            }
        ) else { return [] }

        var out: [PathCandidate] = []
        var visited = 0
        // The enumerator's own depth, not a path prefix: it hands back
        // fully-resolved paths (/private/var/… for a /var/… root), so a prefix
        // test breaks on symlinked roots. Depth 1 IS the container.
        var container: String?
        for case let item as URL in enumerator {
            visited += 1
            if enumerator.level <= 1 { container = item.lastPathComponent }
            if visited > cap {
                logger.notice("path resolver hit the \(cap, privacy: .public)-entry cap; resolving against a partial listing")
                break
            }
            if Task.isCancelled { break }
            guard !item.lastPathComponent.hasPrefix(".") else { continue }
            if let entry = candidate(for: item, container: container) { out.append(entry) }
        }
        return out
    }

    private static func listing(of directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants]
        )) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// nil for symlinks: following one would report a path that is not where
    /// the bytes actually live.
    private static func candidate(for url: URL, container: String?) -> PathCandidate? {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        guard values?.isSymbolicLink != true else { return nil }
        let isDirectory = values?.isDirectory == true && values?.isPackage != true
        return PathCandidate(
            path: url.path,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            sizeBytes: isDirectory ? nil : values?.fileSize.map(Int64.init),
            containerDirectoryName: container
        )
    }
}
