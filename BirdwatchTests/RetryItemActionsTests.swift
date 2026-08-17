import Foundation
import Testing
@testable import Birdwatch

/// The retry-queue row's two new powers: knowing how big a stuck item is, and
/// being able to throw an empty one away. Both are file operations on a user's
/// real documents, so the rules they obey are tested harder than the wiring.
@Suite("Retry item size + trash")
struct RetryItemActionsTests {

    // MARK: - Fixtures

    /// A fresh temp directory, removed after the test.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bw-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    // MARK: - Measurement

    // Fails if an empty folder ever reports nil or a non-zero size — that row is
    // exactly the one whose "Move to Trash" button becomes the primary action,
    // so "0 items" must be a measured fact, not an absence of data.
    @Test("An empty folder measures as 0 items and 0 bytes")
    func emptyFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let measurement = try #require(RedactedPathResolver.measure(path: dir.path))
        #expect(measurement.itemCount == 0)
        #expect(measurement.sizeBytes == 0)
        #expect(measurement.isPartial == false)
    }

    // Fails if the shallow count starts counting descendants, or the size stops
    // walking them: the UI says "N items · SIZE", where N is what Finder shows
    // at that level and SIZE is everything underneath.
    @Test("A folder counts its immediate children but sizes the whole subtree")
    func folderCountAndSize() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(1_000, to: dir.appending(path: "a.bin"))
        try write(2_000, to: dir.appending(path: "b.bin"))
        let nested = dir.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(4_000, to: nested.appending(path: "c.bin"))

        let measurement = try #require(RedactedPathResolver.measure(path: dir.path))
        // a.bin, b.bin, nested — the nested file is NOT a shallow child.
        #expect(measurement.itemCount == 3)
        // Allocated, not logical: the filesystem rounds each file up to a block,
        // so the total is at least the bytes written and never less.
        #expect(measurement.sizeBytes >= 7_000)
        #expect(measurement.isPartial == false)
    }

    // Fails if a regular file ever grows an item count — "1 item · 4 KB" for a
    // single .bin file would be nonsense on the row.
    @Test("A regular file measures as a size with no item count")
    func regularFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "stuck.bin")
        try write(3_000, to: file)

        let measurement = try #require(RedactedPathResolver.measure(path: file.path))
        #expect(measurement.itemCount == nil)
        #expect(measurement.sizeBytes >= 3_000)
    }

    // Fails if the cap stops being enforced — an unbounded walk of a container
    // holding a photo library would stall the whole dump refresh.
    @Test("The deep walk respects its entry cap and admits the size is a floor")
    func capRespected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<20 { try write(1_000, to: dir.appending(path: "f\(index).bin")) }

        let full = try #require(RedactedPathResolver.measure(path: dir.path))
        let capped = try #require(RedactedPathResolver.measure(path: dir.path, cap: 5))
        #expect(full.isPartial == false)
        #expect(capped.isPartial == true)
        #expect(capped.sizeBytes < full.sizeBytes, "a capped walk must report less than the whole")
        // The shallow count is a single listing, so it stays exact either way.
        #expect(capped.itemCount == 20)
    }

    // Fails if a vanished path starts reporting zero instead of nothing: the row
    // would claim "Empty folder" about something that is not there at all.
    @Test("A path that no longer exists measures as nil, not zero")
    func missingPath() {
        #expect(RedactedPathResolver.measure(path: "/nonexistent/bw-\(UUID().uuidString)") == nil)
    }

    // MARK: - Measurement fold

    // Fails if an ambiguous row is ever measured: its path is a shared PARENT
    // folder, so sizing it would attribute a whole directory to one stuck item.
    @Test("Only exactly-resolved rows are measured")
    func measuredFoldSkipsUnresolvedRows() {
        var asked: [String] = []
        let rows = [
            RetryQueueItem(id: "exact", name: ".bin file", attempt: 1, maxAttempts: 62,
                           absolutePath: "/x/exact", matchConfidence: .exact, isDirectory: true),
            RetryQueueItem(id: "ambiguous", name: ".bin file", attempt: 1, maxAttempts: 62,
                           absolutePath: "/x/parent", matchConfidence: .ambiguous(count: 3)),
            RetryQueueItem(id: "unresolved", name: ".bin file", attempt: 1, maxAttempts: 62),
        ]
        let out = BrctlDumpMapper.measured(rows) { path in
            asked.append(path)
            return RedactedPathResolver.Measurement(itemCount: 0, sizeBytes: 0)
        }
        #expect(asked == ["/x/exact"])
        #expect(out[0].itemCount == 0)
        #expect(out[1].sizeBytes == nil)
        #expect(out[2].sizeBytes == nil)
    }

    // MARK: - Trash whitelist

    // The whole safety story. Fails if any path outside the three roots ever
    // becomes trashable — the roots themselves included, because nobody deletes
    // iCloud Drive by clicking a diagnostics row.
    @Test("The whitelist admits only paths strictly inside the three allowed roots")
    func whitelistBoundaries() {
        let home = "/Users/tester"
        #expect(FileTrasher.isAllowed(path: "\(home)/Desktop/report.pdf", home: home))
        #expect(FileTrasher.isAllowed(path: "\(home)/Documents/notes/a.txt", home: home))
        #expect(FileTrasher.isAllowed(path: "\(home)/Library/Mobile Documents/iCloud~x/Documents", home: home))

        #expect(!FileTrasher.isAllowed(path: "\(home)/Desktop", home: home), "the root itself is not trashable")
        #expect(!FileTrasher.isAllowed(path: "\(home)/Library/Mobile Documents", home: home))
        #expect(!FileTrasher.isAllowed(path: "\(home)/Downloads/x.zip", home: home))
        #expect(!FileTrasher.isAllowed(path: "\(home)/.ssh/id_rsa", home: home))
        #expect(!FileTrasher.isAllowed(path: "/etc/hosts", home: home))
        #expect(!FileTrasher.isAllowed(path: "\(home)/Desktop/../.ssh/id_rsa", home: home),
                "a `..` escape must be collapsed before the containment test")
        #expect(!FileTrasher.isAllowed(path: "\(home)/DesktopEvil/x", home: home),
                "prefix matching must not treat a sibling name as containment")
    }

    // Fails if a refusal ever becomes a delete. Uses the REAL FileManager
    // trasher (no injection) precisely so that a broken whitelist would move the
    // file for real — and then asserts the file is still exactly where it was.
    @Test("A path outside the whitelist is refused and nothing is moved")
    func refusalLeavesTheFileAlone() throws {
        let dir = try makeTempDir()   // temp dir is NOT under any allowed root
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "keepme.txt")
        try write(64, to: file)

        #expect(throws: MaintenanceError.self) {
            _ = try FileTrasher.trash(path: file.path)
        }
        #expect(FileManager.default.fileExists(atPath: file.path),
                "the refused file must still be on disk, untouched")
    }

    // Fails if the allowed branch stops calling the trasher, or starts passing a
    // different URL than the one confirmed.
    //
    // WHY an injected trasher: `FileManager.trashItem` needs the item to be on a
    // volume with a Trash, and the test temp directory is not guaranteed to be
    // one. Rather than skip the assertion, the test relocates `home` to a temp
    // directory (so a real allowed root exists) and injects the mover, which
    // leaves the whitelist — the part that can hurt a user — exercised for real.
    @Test("An allowed path is handed to the trasher exactly once")
    func allowedPathIsTrashed() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let file = desktop.appending(path: "stuck.bin")
        try write(64, to: file)

        var moved: [URL] = []
        let landed = home.appending(path: ".Trash/stuck.bin")
        let result = try FileTrasher.trash(path: file.path, home: home.path) {
            moved.append($0)
            return landed
        }
        // The DESTINATION comes back, not a fixed sentence: items inside
        // ~/Library/Mobile Documents land in iCloud Drive's own trash, not
        // ~/.Trash, and the row's success line has to be able to say so.
        #expect(result == RedactedPathResolver.abbreviate(landed.path))
        #expect(moved.map(\.path) == [file.path])
    }

    // Fails if a trasher that reports no destination breaks the call. macOS is
    // allowed to leave `resultingItemURL` nil; that is a missing detail, not a
    // failed move.
    @Test("A move with no reported destination still succeeds, silently")
    func trashWithoutADestination() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let file = desktop.appending(path: "stuck.bin")
        try write(64, to: file)

        #expect(try FileTrasher.trash(path: file.path, home: home.path) { _ in nil } == "")
    }

    // MARK: - Row wording

    // Fails if the row ever invents a number. "Empty folder" and "no line at
    // all" are different answers and the UI must keep telling them apart.
    // MainActor because `Format` owns non-Sendable formatters and lives on main.
    @MainActor
    @Test("The row's size line says empty, counts items, or says nothing")
    func sizeLineWording() {
        func item(size: Int64?, count: Int?, partial: Bool = false) -> RetryQueueItem {
            RetryQueueItem(id: "x", name: ".bin file", attempt: 0, maxAttempts: 62,
                           sizeBytes: size, itemCount: count, sizeIsPartial: partial)
        }
        #expect(DiagnosticsView.sizeLine(item(size: nil, count: nil)) == nil)
        #expect(DiagnosticsView.sizeLine(item(size: 0, count: 0)) == "Empty folder")
        #expect(DiagnosticsView.sizeLine(item(size: 5_000, count: 1))?.hasPrefix("1 item · ") == true)
        #expect(DiagnosticsView.sizeLine(item(size: 5_000, count: 4))?.hasPrefix("4 items · ") == true)
        // A file has no count, so it is just a size — never "0 items".
        let fileLine = try? #require(DiagnosticsView.sizeLine(item(size: 5_000, count: nil)))
        #expect(fileLine?.contains("item") == false)
        #expect(DiagnosticsView.sizeLine(item(size: 5_000, count: nil, partial: true))?.hasSuffix("+") == true,
                "a capped walk must mark its size as a floor")
    }
}

/// The restart mechanism. Researched live on macOS 27 with SIP engaged:
/// `launchctl kickstart -k` and `launchctl stop` both fail with exit 150 for
/// com.apple.bird / com.apple.cloudd / com.apple.FileProvider, while a plain
/// SIGTERM to the process is honoured and launchd respawns it within ~500 ms.
/// These tests pin the pid selection, which is the part that decides who gets
/// the signal.
@Suite("Daemon restart targeting")
struct DaemonRestartTargetingTests {

    /// Real shape of `ps -axo pid,uid,comm` on the reference Mac: a root
    /// `cloudd --system`, the user's own three daemons, and Simulator copies.
    private let psOutput = """
      798     0 /System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd
     1031   501 /System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd
     1098   501 /System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird
     1103   501 /System/Library/PrivateFrameworks/FileProvider.framework/Support/fileproviderd
    54475   501 /Library/Developer/CoreSimulator/Volumes/iOS_24A5370g/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/iCloudDriveCore.framework/bird
    55912   501 /Library/Developer/CoreSimulator/Volumes/iOS_23C54/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.2.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd
    """

    // Fails if a Simulator daemon or the root `cloudd --system` ever lands in
    // the kill list: the first would tear down someone's running simulator, the
    // second would only earn an EPERM and report a phantom failure.
    @Test("Only this user's real system daemons are signalled")
    func pidSelection() {
        #expect(MaintenanceActions.hostPIDs(name: "bird", psOutput: psOutput, uid: 501) == [1098])
        #expect(MaintenanceActions.hostPIDs(name: "cloudd", psOutput: psOutput, uid: 501) == [1031],
                "the root cloudd --system is not ours to restart")
        #expect(MaintenanceActions.hostPIDs(name: "fileproviderd", psOutput: psOutput, uid: 501) == [1103])
        #expect(MaintenanceActions.hostPIDs(name: "bird", psOutput: psOutput, uid: 502).isEmpty)
        #expect(MaintenanceActions.hostPIDs(name: "mds", psOutput: psOutput, uid: 501).isEmpty)
        #expect(MaintenanceActions.hostPIDs(name: "bird", psOutput: "", uid: 501).isEmpty)
    }

    // Fails if the row's monospace command drifts away from what we run — the
    // stale `launchctl kickstart` string is exactly how the dead button shipped.
    @Test("The displayed command names the signal we actually send")
    func commandStringMatchesReality() {
        let command = MaintenanceActions.restartCommand(name: "bird")
        #expect(command.contains("kill -TERM"))
        #expect(command.contains("bird"))
        #expect(!command.contains("launchctl"), "launchctl is refused under SIP; never show it as our command")
    }

    // Fails if a daemon with no running process silently "succeeds": there would
    // be nothing to signal and nothing to observe respawning.
    @Test("A daemon that is not running is reported, not signalled")
    func notRunningIsReported() async {
        let actions = MaintenanceActions()
        await #expect(throws: MaintenanceError.unknownDaemon("mds")) {
            _ = try await actions.restartDaemon(name: "mds")
        }
    }
}
