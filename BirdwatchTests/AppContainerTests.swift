import Foundation
import Testing
@testable import Birdwatch

/// Real container directory names captured from a live machine
/// (`ls ~/Library/Mobile Documents`), 219 entries.
private nonisolated func containerFixture() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/containers.txt")
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

@Suite("App container name derivation")
struct AppContainerNameTests {

    @Test("Real container ids map to human names", arguments: [
        ("4R6749AYRE~com~pixelmatorteam~pixelmator", "Pixelmator"),
        ("57T9237FN3~net~whatsapp~WhatsApp", "WhatsApp"),
        ("iCloud~md~obsidian", "Obsidian"),
        ("iCloud~net~shinyfrog~bear", "Bear"),
        ("iCloud~com~microsoft~Office~Word", "Word"),
        ("iCloud~com~todoist~ios", "Todoist"),
        ("iCloud~com~streaksapp~streak~coreData", "Streak"),
        ("com~apple~TextEdit", "TextEdit"),
        ("com~apple~Keynote", "Keynote"),
        ("W6L39UYL6Z~com~mindnode~MindNode", "MindNode"),
        ("iCloud~com~habit~habytracker~icloudcontainer", "Habytracker"),
        ("iCloud~com~apple~MobileSMS", "MobileSMS"),
        ("iCloud~dk~simonbs~Scriptable", "Scriptable"),
        ("iCloud~Elephas", "Elephas"),
        ("iCloud~com~renfei~SnippetsLab-setapp", "SnippetsLab"),
    ])
    func namesFromRealIDs(pair: (String, String)) {
        #expect(AppContainerSource.displayName(forDirectory: pair.0) == pair.1)
    }

    @Test("Every real fixture entry yields a presentable name or is skipped")
    func fixtureSweep() throws {
        let dirs = try containerFixture()
        #expect(dirs.count > 200)
        var named = 0
        for dir in dirs {
            guard let container = AppContainerSource.makeContainer(directoryName: dir) else { continue }
            named += 1
            #expect(!container.name.isEmpty)
            #expect(container.name.first?.isLetter == true || container.name.first?.isNumber == true)
            #expect(!container.name.contains("~"))
            #expect(container.id.hasPrefix("container-"))
            #expect(!container.id.contains("~"))
            #expect(!container.id.contains(" "))
        }
        // The overwhelming majority must resolve — a regression that starts
        // dropping containers should fail here.
        #expect(named > dirs.count - 10)
    }

    @Test("Container ids from the real fixture are unique")
    func idsUnique() throws {
        let ids = try containerFixture().compactMap { AppContainerSource.makeContainer(directoryName: $0)?.id }
        #expect(Set(ids).count == ids.count)
    }

    @Test("Apple containers are flagged, third-party are not")
    func appleFlag() {
        #expect(AppContainerSource.makeContainer(directoryName: "com~apple~Keynote")?.isApple == true)
        #expect(AppContainerSource.makeContainer(directoryName: "iCloud~com~apple~Playgrounds")?.isApple == true)
        #expect(AppContainerSource.makeContainer(directoryName: "iCloud~md~obsidian")?.isApple == false)
    }

    @Test("CloudDocs and plumbing containers are excluded")
    func exclusions() {
        for dir in ["com~apple~CloudDocs", "com~apple~TextInput", "debug", "com~apple~system~spotlight"] {
            #expect(AppContainerSource.makeContainer(directoryName: dir) == nil, "\(dir) should be excluded")
        }
    }

    @Test("Garbage names never crash and never produce junk rows", arguments: [
        "", "~", "~~~", ".", ".hidden", "~~a~~", "   ", "-", "___",
        "ABCDEFGHIJ", "com~", "~com~apple~", "app", "iCloud~",
    ])
    func garbage(dir: String) {
        if let container = AppContainerSource.makeContainer(directoryName: dir) {
            #expect(!container.name.isEmpty)
            #expect(!container.name.allSatisfy { $0 == "-" || $0 == " " })
            #expect(container.id != "container-")
        }
    }

    @Test("Team-id detection")
    func teamIDs() {
        #expect(AppContainerSource.isTeamID("4R6749AYRE"))
        #expect(AppContainerSource.isTeamID("F3LWYJ7GM7"))
        #expect(!AppContainerSource.isTeamID("ABCDEFGHIJ"))   // no digit
        #expect(!AppContainerSource.isTeamID("com"))
        #expect(!AppContainerSource.isTeamID("iCloud"))
    }
}

@Suite("App container transfer attribution")
struct AppContainerAttributionTests {
    let home = "/Users/tester"

    @Test("A path inside an app container attributes to that container")
    func containerPath() {
        let path = "\(home)/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/note.md"
        #expect(AppContainerSource.appID(forPath: path, homeDirectory: home) == "container-icloud-md-obsidian")
        #expect(UbiquityTransferSource.appID(forPath: path, homeDirectory: home) == "container-icloud-md-obsidian")
    }

    @Test("CloudDocs stays iCloud Drive")
    func cloudDocsPath() {
        let path = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Reports/q3.pdf"
        #expect(UbiquityTransferSource.appID(forPath: path, homeDirectory: home) == "icloud-drive")
    }

    @Test("Desktop & Documents still wins over the container mapping")
    func desktopDocuments() {
        #expect(UbiquityTransferSource.appID(forPath: "\(home)/Desktop/a.txt", homeDirectory: home) == "desktop-documents")
        #expect(UbiquityTransferSource.appID(forPath: "\(home)/Documents/a.txt", homeDirectory: home) == "desktop-documents")
    }

    @Test("Paths outside Mobile Documents have no container")
    func outside() {
        #expect(AppContainerSource.appID(forPath: "\(home)/Downloads/a.txt", homeDirectory: home) == nil)
        #expect(AppContainerSource.containerDirectory(forPath: "\(home)/Library/Mobile Documents/", homeDirectory: home) == nil)
        #expect(UbiquityTransferSource.appID(forPath: "/tmp/a.txt", homeDirectory: home) == "icloud-drive")
    }

    @Test("Excluded container paths fall back to iCloud Drive, not a junk id")
    func excludedFallback() {
        let path = "\(home)/Library/Mobile Documents/debug/x"
        #expect(AppContainerSource.appID(forPath: path, homeDirectory: home) == nil)
        #expect(UbiquityTransferSource.appID(forPath: path, homeDirectory: home) == "icloud-drive")
    }
}

@Suite("App container local footprint")
struct AppContainerSizeTests {

    /// Builds <root>/Documents/{a,b,c...}.bin with `bytes` each plus a nested dir.
    private func makeTree(fileCount: Int, bytes: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "bw-size-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = root.appending(path: "Documents/Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x41, count: bytes)
        for index in 0..<fileCount {
            let dir = index % 2 == 0 ? root.appending(path: "Documents") : nested
            try payload.write(to: dir.appending(path: "file-\(index).bin"))
        }
        return root
    }

    @Test("Sums allocated bytes of every file in the tree")
    func sumsTree() throws {
        let root = try makeTree(fileCount: 6, bytes: 10_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = AppContainerSource.allocatedSize(ofDirectory: root)
        let one = try root.appending(path: "Documents/file-0.bin")
            .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!
        // Exact: six identical files, allocation is deterministic per file.
        #expect(total == Int64(one) * 6)
        #expect(total >= 60_000)                 // at least the logical bytes
    }

    @Test("An empty tree is zero, and a missing directory is zero (not a crash)")
    func emptyAndMissing() throws {
        let root = try makeTree(fileCount: 0, bytes: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AppContainerSource.allocatedSize(ofDirectory: root) == 0)
        #expect(AppContainerSource.allocatedSize(
            ofDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) == 0)
    }

    @Test("The entry cap stops the walk and yields a partial figure")
    func capStopsWalk() throws {
        let root = try makeTree(fileCount: 12, bytes: 10_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let full = AppContainerSource.allocatedSize(ofDirectory: root)
        let capped = AppContainerSource.allocatedSize(ofDirectory: root, cap: 4)
        #expect(capped > 0)
        #expect(capped < full)
        #expect(AppContainerSource.allocatedSize(ofDirectory: root, cap: 0) == 0)
        #expect(AppContainerSource.sizeEntryCap == 50_000)
    }

    // Desktop & Documents are only iCloud data when that sync feature is ON.
    // Measuring them regardless read two folders the app had no business
    // touching — and earned a TCC prompt for it on every fresh dev build.
    // Discriminates: a regression to "always measure" fails the second case.
    @Test("localSizes reports iCloud Drive always, Desktop & Documents only when synced")
    func builtInKeys() async throws {
        let home = try makeTree(fileCount: 2, bytes: 4_000)
        defer { try? FileManager.default.removeItem(at: home) }
        let synced = await AppContainerSource.localSizes(
            containers: [], homeDirectory: home.path, includeDesktopDocuments: true)
        #expect(synced["icloud-drive"] != nil)
        #expect(synced["desktop-documents"] != nil)

        let unsynced = await AppContainerSource.localSizes(
            containers: [], homeDirectory: home.path, includeDesktopDocuments: false)
        #expect(unsynced["icloud-drive"] != nil)
        #expect(unsynced["desktop-documents"] == nil, "never touch Desktop/Documents when sync is off")
    }
}

@Suite("App container rows")
struct AppContainerRowTests {

    private func container(_ dir: String, items: Int = 3) -> AppContainerSource.Container {
        var c = AppContainerSource.makeContainer(directoryName: dir)!
        c.itemCount = items
        return c
    }

    @Test("Tile colors are stable and inside the palette")
    func tiles() {
        let a = AppContainerSource.tileColorHex(forName: "Obsidian")
        #expect(a == AppContainerSource.tileColorHex(forName: "Obsidian"))
        #expect(AppContainerSource.tilePalette.contains(a))
        // Different names should not all collapse to one bucket.
        let spread = Set(["Obsidian", "Bear", "Pixelmator", "WhatsApp", "Word", "Keynote"]
            .map(AppContainerSource.tileColorHex(forName:)))
        #expect(spread.count > 1)
    }

    @Test("Active containers sort ahead of idle ones, then by name")
    func sorting() {
        let containers = [container("iCloud~md~obsidian"), container("iCloud~net~shinyfrog~bear"), container("com~apple~Keynote")]
        let transfer = TransferItem(
            id: "t1", appID: "container-icloud-md-obsidian", name: "note.md",
            location: "~", sizeBytes: 10, direction: .upload, progress: 0
        )
        let rows = AppContainerSource.makeApps(containers: containers, transfers: [transfer])
        #expect(rows.first?.name == "Obsidian")
        #expect(rows.first?.pendingItems == 1)
        #expect(rows.dropFirst().map(\.name) == ["Bear", "Keynote"])
        #expect(rows.allSatisfy { $0.backend == .cloudDocs })
        #expect(rows.first?.status == .syncing(progress: 0))
    }

    @Test("Measured sizes reach the row, keyed by app id")
    func sizesApplied() {
        let rows = AppContainerSource.makeApps(
            containers: [container("iCloud~md~obsidian"), container("com~apple~Keynote")],
            transfers: [],
            localSizes: ["container-icloud-md-obsidian": 4_096]
        )
        let obsidian = rows.first { $0.name == "Obsidian" }
        let keynote = rows.first { $0.name == "Keynote" }
        #expect(obsidian?.localSizeBytes == 4_096)
        #expect(keynote?.localSizeBytes == 0)      // not measured yet — never invented
    }

    @Test("Rows never claim a local size they did not measure")
    func noFakeSize() {
        let rows = AppContainerSource.makeApps(containers: [container("iCloud~md~obsidian", items: 7)], transfers: [])
        #expect(rows[0].localSizeBytes == 0)
        #expect(rows[0].itemsIndexed == 7)
        #expect(rows[0].statusLine == "7 items in iCloud Drive")
    }

    @Test("buildApps keeps the built-ins and appends containers with unique ids")
    func joinedList() {
        let apps = SystemSyncSource.buildApps(
            status: nil, transfers: [], fileProviderDomains: ["Dropbox-Personal"],
            containers: [container("iCloud~md~obsidian"), container("com~apple~Keynote")]
        )
        let ids = apps.map(\.id)
        #expect(ids.contains("icloud-drive"))
        // No CloudKit observations were passed, so no CloudKit row exists.
        #expect(!ids.contains("photos"))
        #expect(ids.contains("fp-dropbox-personal"))
        #expect(ids.contains("container-icloud-md-obsidian"))
        #expect(Set(ids).count == ids.count)
        // Built-ins precede containers.
        #expect(ids.firstIndex(of: "icloud-drive")! < ids.firstIndex(of: "container-icloud-md-obsidian")!)
    }
}
