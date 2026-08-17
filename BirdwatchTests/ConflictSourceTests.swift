import Foundation
import Testing
@testable import Birdwatch

/// Audit P1 #5: `ConflictSource.resolve` is the only code path that can lose
/// user data, and it had zero coverage. These tests run entirely inside a
/// per-test temporary directory — the real CloudDocs container is never
/// touched, read, or enumerated.
@Suite("ConflictSource resolution")
struct ConflictResolutionTests {

    /// Fresh scratch directory per test, removed on deinit.
    final class Scratch {
        let url: URL
        init() {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "bw-conflict-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ name: String, _ contents: String = "original bytes") -> URL {
            let file = url.appending(path: name)
            try? Data(contents.utf8).write(to: file)
            return file
        }
    }

    // MARK: - conflictedCopyURL numbering

    // Pins the numbering sequence actually implemented: the FIRST copy carries
    // no number, and the next free slot is "copy 2", then "copy 3". Fails if
    // the numbering ever restarts at 1 (which would collide with the unnumbered
    // copy) or skips a free slot.
    @Test("conflictedCopyURL: unnumbered first, then 2, then 3 — never reusing a taken name")
    func conflictedCopyNumbering() {
        let scratch = Scratch()
        let file = scratch.write("Report.pages")

        let first = ConflictSource.conflictedCopyURL(for: file)
        #expect(first.lastPathComponent == "Report (conflicted copy).pages")

        scratch.write("Report (conflicted copy).pages")
        let second = ConflictSource.conflictedCopyURL(for: file)
        #expect(second.lastPathComponent == "Report (conflicted copy 2).pages")

        scratch.write("Report (conflicted copy 2).pages")
        let third = ConflictSource.conflictedCopyURL(for: file)
        #expect(third.lastPathComponent == "Report (conflicted copy 3).pages")

        // The original is never proposed as its own copy destination.
        #expect(![first, second, third].contains { $0.lastPathComponent == file.lastPathComponent })
    }

    // Fails if the extension handling ever appends a bare "." to an
    // extension-less file, or moves the suffix into the wrong position.
    @Test("conflictedCopyURL on an extension-less file appends the suffix with no trailing dot")
    func conflictedCopyWithoutExtension() {
        let scratch = Scratch()
        let file = scratch.write("Makefile")
        let copy = ConflictSource.conflictedCopyURL(for: file)
        #expect(copy.lastPathComponent == "Makefile (conflicted copy)")
        #expect(!copy.lastPathComponent.hasSuffix("."))
        #expect(copy.deletingLastPathComponent().path == file.deletingLastPathComponent().path,
                "the copy lands beside the original")
    }

    // A dotted name that is NOT an extension in the intended sense still round
    // trips: base keeps everything before the LAST dot.
    @Test("conflictedCopyURL keeps only the final path extension")
    func conflictedCopyMultiDot() {
        let scratch = Scratch()
        let file = scratch.write("archive.tar.gz")
        #expect(ConflictSource.conflictedCopyURL(for: file).lastPathComponent
                == "archive.tar (conflicted copy).gz")
    }

    // MARK: - resolve

    // The no-unresolved-versions path: a plain non-ubiquitous file has no
    // NSFileVersion conflicts, so resolve reports success WITHOUT touching a
    // single byte. Fails if resolve ever starts mutating (replaceItem /
    // removeOtherVersions / copy) before confirming there is a conflict to
    // resolve — the exact regression that could destroy user data.
    @Test("resolve on a file with no conflicts succeeds and leaves the bytes untouched",
          arguments: [ConflictSource.currentVersionID,
                      ConflictSource.keepBothVersionID,
                      "version-deadbeef"])
    func resolveNoConflictsIsAByteLevelNoop(keepVersionID: String) async throws {
        let scratch = Scratch()
        let file = scratch.write("Notes.txt", "line one\nline two\n")
        let before = try Data(contentsOf: file)

        // `root:` is a pure test seam; production callers use the real
        // CloudDocs container. Here it makes the scratch dir the allowed root.
        let ok = await ConflictSource.resolve(
            fileURL: file, keepVersionID: keepVersionID, root: scratch.url
        )
        #expect(ok, "nothing to resolve is success, not failure")

        let after = try Data(contentsOf: file)
        #expect(before == after, "resolve must not rewrite a file it had no conflict for")
        #expect(FileManager.default.fileExists(atPath: file.path))
        // And no stray "(conflicted copy)" was manufactured.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path)
        #expect(siblings == ["Notes.txt"])
    }

    // Defense in depth (Batch A): a tampered/stale cached path outside the
    // CloudDocs root must be refused outright. Fails if the containment guard
    // is removed or inverted.
    @Test("resolve refuses a path outside the allowed root and changes nothing")
    func resolveRefusesOutsideRoot() async throws {
        let scratch = Scratch()
        let outside = Scratch()
        let file = outside.write("Elsewhere.txt", "do not touch")
        let before = try Data(contentsOf: file)

        let ok = await ConflictSource.resolve(
            fileURL: file, keepVersionID: ConflictSource.currentVersionID, root: scratch.url
        )
        #expect(!ok)
        #expect(try Data(contentsOf: file) == before)
    }

    // MARK: - Containment + stable ids

    @Test("isUnderCloudDocsRoot accepts descendants and rejects siblings and escapes")
    func containment() {
        let root = URL(fileURLWithPath: "/tmp/bw-root")
        #expect(ConflictSource.isUnderCloudDocsRoot(root.appending(path: "a/b.txt"), root: root))
        #expect(!ConflictSource.isUnderCloudDocsRoot(root, root: root), "the root itself is not a file in it")
        // Prefix-only sibling: "/tmp/bw-rootx" must not pass a naive hasPrefix.
        #expect(!ConflictSource.isUnderCloudDocsRoot(URL(fileURLWithPath: "/tmp/bw-rootx/a.txt"), root: root))
        #expect(!ConflictSource.isUnderCloudDocsRoot(root.appending(path: "../escape.txt"), root: root))
    }
}
