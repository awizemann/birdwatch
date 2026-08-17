import Foundation
import Testing
@testable import Birdwatch

/// A temp directory shaped like `~/Library/Mobile Documents`, torn down with
/// the suite instance.
private final class Scratch {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "bw-resolver-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func directory(_ relative: String) -> URL {
        let target = url.appending(path: relative)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) -> URL {
        let target = url.appending(path: relative)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: bytes).write(to: target)
        return target
    }
}

private func item(
    id: String,
    name: String,
    container: String? = nil,
    isDirectory: Bool = false,
    size: Int64? = nil
) -> BrctlPendingItem {
    var item = BrctlPendingItem(itemID: id, uploadState: "needs-sync-up")
    item.redactedName = name
    item.isDirectory = isDirectory
    item.byteSize = size
    item.containerPattern = container
    return item
}

@Suite("RedactedPathResolver")
struct RedactedPathResolverTests {

    // MARK: - Pattern matching

    @Test func bracePatternMatchesOnlyTheExactLength() {
        // bird's redaction of "Documents": first char, 7 hidden, last char.
        #expect(RedactedPathResolver.matches(pattern: "D{7}s", name: "Documents"))
        #expect(!RedactedPathResolver.matches(pattern: "D{7}s", name: "Document"))
        #expect(!RedactedPathResolver.matches(pattern: "D{7}s", name: "Documentss"))
        #expect(!RedactedPathResolver.matches(pattern: "D{7}s", name: "Downloadss"))
    }

    @Test func extensionOutsideBracesIsLiteral() {
        #expect(RedactedPathResolver.matches(pattern: "r{5}g.pdf", name: "reading.pdf"))
        #expect(!RedactedPathResolver.matches(pattern: "r{5}g.pdf", name: "reading.png"))
        // Same length, wrong first character.
        #expect(!RedactedPathResolver.matches(pattern: "r{5}g.pdf", name: "beading.pdf"))
    }

    @Test func multipleBraceGroupsMatchContainerIdentifiers() {
        // The app-library header for iCloud~com~microsoft~Office~Excel.
        #expect(RedactedPathResolver.matchesContainer(
            pattern: "i{4}d.c{1}m.m{7}t.O{4}e.E{3}l",
            directoryName: "iCloud~com~microsoft~Office~Excel"
        ))
        #expect(!RedactedPathResolver.matchesContainer(
            pattern: "i{4}d.c{1}m.m{7}t.O{4}e.E{3}l",
            directoryName: "iCloud~com~microsoft~Office~Word"
        ))
    }

    @Test func unredactedPatternComparesLiterally() {
        #expect(RedactedPathResolver.matches(pattern: "Notes", name: "Notes"))
        #expect(!RedactedPathResolver.matches(pattern: "Notes", name: "Note"))
    }

    // MARK: - Resolution against a real temp tree

    @Test func uniqueMatchResolvesToAnExactPath() {
        let scratch = Scratch()
        scratch.directory("iCloud~com~acme~Notes/Documents")
        scratch.file("iCloud~com~acme~Notes/Documents/report.pdf", bytes: 1234)
        let candidates = RedactedPathResolver.candidates(root: scratch.url)

        let resolved = RedactedPathResolver.resolve(
            items: [item(id: "A", name: "r{4}t.pdf", container: "i{4}d.c{1}m.a{2}e.N{3}s", size: 1234)],
            candidates: candidates
        )
        let match = resolved["A"]
        #expect(match?.confidence == .exact)
        #expect(match?.absolutePath?.hasSuffix("iCloud~com~acme~Notes/Documents/report.pdf") == true)
    }

    @Test func directoryItemResolvesInsideItsContainer() {
        let scratch = Scratch()
        scratch.directory("iCloud~com~acme~Notes/Documents")
        scratch.directory("iCloud~com~other~App/Documents")
        let candidates = RedactedPathResolver.candidates(root: scratch.url)

        // Same "D{7}s" in two containers — the header is what disambiguates.
        let resolved = RedactedPathResolver.resolve(
            items: [item(id: "D", name: "D{7}s", container: "i{4}d.c{1}m.a{2}e.N{3}s", isDirectory: true)],
            candidates: candidates
        )
        #expect(resolved["D"]?.confidence == .exact)
        #expect(resolved["D"]?.absolutePath?.hasSuffix("iCloud~com~acme~Notes/Documents") == true)
    }

    @Test func twoFilesOfTheSamePatternAndSizeAreReportedAmbiguous() {
        let scratch = Scratch()
        scratch.file("iCloud~com~acme~Notes/Documents/report.pdf", bytes: 1234)
        scratch.file("iCloud~com~acme~Notes/Documents/rebost.pdf", bytes: 1234)
        let candidates = RedactedPathResolver.candidates(root: scratch.url)

        let resolved = RedactedPathResolver.resolve(
            items: [item(id: "A", name: "r{4}t.pdf", container: "i{4}d.c{1}m.a{2}e.N{3}s", size: 1234)],
            candidates: candidates
        )
        // "rebost.pdf" ends in 't' and is the same length, so both fit.
        #expect(resolved["A"]?.confidence == .ambiguous(count: 2))
        // Both live in the same folder, so the folder is still an honest answer.
        #expect(resolved["A"]?.absolutePath?.hasSuffix("Documents") == true)
    }

    @Test func sizeDisambiguatesTwoFilesOfTheSameShape() {
        let scratch = Scratch()
        scratch.file("iCloud~com~acme~Notes/Documents/report.pdf", bytes: 1234)
        scratch.file("iCloud~com~acme~Notes/Documents/rebost.pdf", bytes: 999)
        let candidates = RedactedPathResolver.candidates(root: scratch.url)

        let resolved = RedactedPathResolver.resolve(
            items: [item(id: "A", name: "r{4}t.pdf", container: "i{4}d.c{1}m.a{2}e.N{3}s", size: 999)],
            candidates: candidates
        )
        #expect(resolved["A"]?.confidence == .exact)
        #expect(resolved["A"]?.absolutePath?.hasSuffix("rebost.pdf") == true)
    }

    @Test func noMatchYieldsNoEntryAtAll() {
        let scratch = Scratch()
        scratch.file("iCloud~com~acme~Notes/Documents/report.pdf", bytes: 1234)
        let candidates = RedactedPathResolver.candidates(root: scratch.url)

        let resolved = RedactedPathResolver.resolve(
            items: [
                // Right container, no file of that shape.
                item(id: "A", name: "z{9}z.key", container: "i{4}d.c{1}m.a{2}e.N{3}s"),
                // Container that does not exist on this disk.
                item(id: "B", name: "r{4}t.pdf", container: "i{4}d.c{1}m.g{4}e.D{4}e", size: 1234),
            ],
            candidates: candidates
        )
        #expect(resolved["A"] == nil)
        #expect(resolved["B"] == nil)
    }

    @Test func rightShapeButWrongSizeIsNotAMatch() {
        let scratch = Scratch()
        scratch.file("iCloud~com~acme~Notes/Documents/report.pdf", bytes: 1234)
        let candidates = RedactedPathResolver.candidates(root: scratch.url)

        let resolved = RedactedPathResolver.resolve(
            items: [item(id: "A", name: "r{4}t.pdf", container: "i{4}d.c{1}m.a{2}e.N{3}s", size: 55)],
            candidates: candidates
        )
        #expect(resolved["A"] == nil)
    }

    @Test func emptyCandidatesResolveNothingRatherThanGuessing() {
        let resolved = RedactedPathResolver.resolve(
            items: [item(id: "A", name: "r{4}t.pdf", container: "i{4}d.c{1}m.a{2}e.N{3}s")],
            candidates: []
        )
        #expect(resolved.isEmpty)
    }

    // MARK: - Enumeration

    @Test func candidateWalkSkipsHiddenFilesAndTagsTheContainer() {
        let scratch = Scratch()
        scratch.file("iCloud~com~acme~Notes/Documents/report.pdf", bytes: 12)
        scratch.file("iCloud~com~acme~Notes/.hidden.pdf", bytes: 12)
        let candidates = RedactedPathResolver.candidates(root: scratch.url)

        #expect(!candidates.contains { $0.name == ".hidden.pdf" })
        let report = candidates.first { $0.name == "report.pdf" }
        #expect(report?.containerDirectoryName == "iCloud~com~acme~Notes")
        #expect(report?.sizeBytes == 12)
        #expect(report?.isDirectory == false)
    }

    @Test func entryCapBoundsTheWalk() {
        let scratch = Scratch()
        for index in 0..<20 { scratch.file("iCloud~com~acme~Notes/f\(index).bin", bytes: 1) }
        #expect(RedactedPathResolver.candidates(root: scratch.url, cap: 5).count <= 5)
    }

    @Test func abbreviationHidesTheAccountShortName() {
        let home = NSHomeDirectory()
        #expect(RedactedPathResolver.abbreviate(home + "/Library/Mobile Documents") == "~/Library/Mobile Documents")
        #expect(RedactedPathResolver.abbreviate("/private/tmp/x") == "/private/tmp/x")
    }
}
