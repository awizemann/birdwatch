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

        func read(_ name: String) throws -> String {
            try String(contentsOf: url.appending(path: name), encoding: .utf8)
        }

        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }
    }

    /// A REAL `NSFileVersion` carrying `contents`, created through
    /// `NSFileVersion.addOfItem` on the scratch file. macOS only lets iCloud
    /// flag a version as an unresolved *conflict*, so the tests hand these to
    /// `applyResolution` directly — the version objects, their store URLs,
    /// `replaceItem` and `removeOtherVersionsOfItem` are all the real thing.
    private func addVersion(to file: URL, contents: String, scratch: Scratch) throws -> NSFileVersion {
        // The donor MUST carry the target's extension: verified behavior —
        // `NSFileVersion.replaceItem` gives the replaced item the extension of
        // the version-store file, so an extension-less donor would rename
        // "Doc.txt" to "Doc" and the fixture would be lying about the shape of
        // a real conflict version (which always matches the original's type).
        let ext = file.pathExtension
        let donor = scratch.write("donor-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"), contents)
        defer { try? FileManager.default.removeItem(at: donor) }
        return try NSFileVersion.addOfItem(at: file, withContentsOf: donor)
    }

    /// The ids a screen would have shown for these versions (plus "current").
    private func ids(_ versions: NSFileVersion...) -> Set<String> {
        Set(versions.map(ConflictSource.versionID(for:))).union([ConflictSource.currentVersionID])
    }

    // MARK: - conflictedCopyURL numbering

    // Pins the numbering sequence actually implemented: the FIRST copy carries
    // no number, and the next slots are "copy 2", then "copy 3". Fails if the
    // numbering ever restarts at 1 (which would collide with the unnumbered
    // copy) or skips a slot.
    @Test("conflictedCopyURL: unnumbered first, then 2, then 3")
    func conflictedCopyNumbering() {
        let scratch = Scratch()
        let file = scratch.write("Report.pages")

        #expect(ConflictSource.conflictedCopyURL(for: file, attempt: 0).lastPathComponent
                == "Report (conflicted copy).pages")
        #expect(ConflictSource.conflictedCopyURL(for: file, attempt: 1).lastPathComponent
                == "Report (conflicted copy 2).pages")
        #expect(ConflictSource.conflictedCopyURL(for: file, attempt: 2).lastPathComponent
                == "Report (conflicted copy 3).pages")

        // The original is never proposed as its own copy destination.
        #expect(!(0..<3).contains {
            ConflictSource.conflictedCopyURL(for: file, attempt: $0).lastPathComponent == file.lastPathComponent
        })
    }

    // MARK: - claimConflictedCopy (atomic claim, no check-then-act)

    // Repeated claims walk the numbering without ever reusing a taken name,
    // and each copy carries its own source's bytes.
    @Test("claimConflictedCopy walks the numbering and never overwrites a taken name")
    func claimWalksNumbering() throws {
        let scratch = Scratch()
        let file = scratch.write("Report.pages", "current")
        let a = scratch.write("src-a", "from Mac A")
        let b = scratch.write("src-b", "from Mac B")
        let c = scratch.write("src-c", "from Mac C")

        let first = try ConflictSource.claimConflictedCopy(of: a, nextTo: file)
        let second = try ConflictSource.claimConflictedCopy(of: b, nextTo: file)
        let third = try ConflictSource.claimConflictedCopy(of: c, nextTo: file)

        #expect(first.lastPathComponent == "Report (conflicted copy).pages")
        #expect(second.lastPathComponent == "Report (conflicted copy 2).pages")
        #expect(third.lastPathComponent == "Report (conflicted copy 3).pages")
        #expect(try scratch.read(first.lastPathComponent) == "from Mac A")
        #expect(try scratch.read(second.lastPathComponent) == "from Mac B")
        #expect(try scratch.read(third.lastPathComponent) == "from Mac C")
        #expect(try scratch.read("Report.pages") == "current", "the original is never rewritten")
        // No temporary is left behind on the success path.
        #expect(try scratch.names().allSatisfy { !$0.hasPrefix(".bw-conflicted-copy-") })
    }

    // THE TOCTOU FALSIFIER. `FileManager.fileExists` FOLLOWS symlinks, so a
    // dangling symlink at the candidate name reports "free" — the old
    // check-then-act code therefore chose that name and its copyItem then
    // failed with EEXIST, silently losing the version it was preserving.
    // An atomic claim asks the kernel instead: renamex_np(RENAME_EXCL) sees
    // the link itself, reports EEXIST, and the loop moves to "copy 2".
    // This test FAILS on the pre-fix implementation.
    @Test("claimConflictedCopy skips a name held by a dangling symlink instead of losing the version")
    func claimSkipsDanglingSymlink() throws {
        let scratch = Scratch()
        let file = scratch.write("Report.pages", "current")
        let source = scratch.write("src", "from Mac A")

        // Occupy the first candidate with a symlink pointing at nothing.
        let taken = scratch.url.appending(path: "Report (conflicted copy).pages")
        try FileManager.default.createSymbolicLink(
            atPath: taken.path, withDestinationPath: scratch.url.appending(path: "gone.pages").path
        )
        #expect(!FileManager.default.fileExists(atPath: taken.path),
                "precondition: fileExists reports a dangling symlink as free — that is the bug")

        let claimed = try ConflictSource.claimConflictedCopy(of: source, nextTo: file)

        #expect(claimed.lastPathComponent == "Report (conflicted copy 2).pages",
                "the taken name must be skipped, not claimed")
        #expect(try scratch.read(claimed.lastPathComponent) == "from Mac A",
                "the version's bytes are preserved, not lost to an EEXIST")
        // The symlink itself is untouched — resolution never clobbers.
        let attrs = try FileManager.default.attributesOfItem(atPath: taken.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try scratch.names().allSatisfy { !$0.hasPrefix(".bw-conflicted-copy-") })
    }

    // A claim that cannot succeed must SURFACE the error (C7), not return a
    // half-done result, and must not leave its temporary behind.
    @Test("claimConflictedCopy throws when the source cannot be read and leaves no temporary")
    func claimThrowsOnUnreadableSource() throws {
        let scratch = Scratch()
        let file = scratch.write("Report.pages", "current")
        let missing = scratch.url.appending(path: "not-there")

        #expect(throws: (any Error).self) {
            try ConflictSource.claimConflictedCopy(of: missing, nextTo: file)
        }
        #expect(try scratch.names() == ["Report.pages"], "no temporary, no partial copy")
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
    @Test("resolve on a file with no conflicts reports notFound and leaves the bytes untouched",
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
            fileURL: file, keepVersionID: keepVersionID, shownVersionIDs: [], root: scratch.url
        )
        // Birdwatch did nothing, so the UI must not announce "Kept …": the
        // honest answer is "no longer reported".
        #expect(ok == .notFound)

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
            fileURL: file, keepVersionID: ConflictSource.currentVersionID, shownVersionIDs: [], root: scratch.url
        )
        #expect(ok == .failed)
        #expect(try Data(contentsOf: file) == before)
    }

    // MARK: - applyResolution over REAL NSFileVersions

    // The keep-version branch: `winner.replaceItem(at:)` is the real API on a
    // real version-store file, so the on-disk bytes must BECOME that version's
    // bytes and the other versions must be gone afterwards. Fails if
    // replaceItem is ever skipped, if the wrong version wins, or if
    // removeOtherVersionsOfItem stops running.
    @Test("keep-version replaces the on-disk bytes with that version and clears the others")
    func keepVersionReplacesOnDisk() throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let loser = try addVersion(to: file, contents: "from Mac A", scratch: scratch)
        let winner = try addVersion(to: file, contents: "from Mac B", scratch: scratch)
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.count == 2, "precondition: two real versions")

        let ok = ConflictSource.applyResolution(
            fileURL: file,
            keepVersionID: ConflictSource.versionID(for: winner),
            unresolved: [loser, winner], shownVersionIDs: ids(loser, winner),
            root: scratch.url
        )

        #expect(ok == .resolved)
        #expect(try scratch.read("Doc.txt") == "from Mac B",
                "the chosen version's bytes really replaced the file")
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.isEmpty == true,
                "the losing versions were removed")
        #expect(try scratch.names() == ["Doc.txt"], "keep-version never manufactures a copy")
    }

    // An id that matches no version must be refused BEFORE anything is
    // mutated — the caller's cached detail may be stale. Fails if the default
    // branch ever falls through to removeOtherVersionsOfItem.
    @Test("keep-version with an unknown id changes nothing and reports failure")
    func keepVersionUnknownIDIsRefused() throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let version = try addVersion(to: file, contents: "from Mac A", scratch: scratch)

        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: "version-notmine",
            unresolved: [version], shownVersionIDs: ids(version), root: scratch.url
        )

        #expect(ok == .failed)
        #expect(try scratch.read("Doc.txt") == "current bytes")
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.count == 1,
                "a refused resolution must not remove versions")
    }

    // The keep-both branch end to end: every version's bytes land beside the
    // original under its own numbered name, and the original is untouched.
    // §8 — nothing is lost.
    @Test("keep-both duplicates every version beside the original and keeps the current bytes")
    func keepBothPreservesEveryVersion() throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let a = try addVersion(to: file, contents: "from Mac A", scratch: scratch)
        let b = try addVersion(to: file, contents: "from Mac B", scratch: scratch)

        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: ConflictSource.keepBothVersionID,
            unresolved: [a, b], shownVersionIDs: ids(a, b), root: scratch.url
        )

        #expect(ok == .resolved)
        #expect(try scratch.read("Doc.txt") == "current bytes", "keep-both never rewrites the original")
        #expect(try scratch.names() == ["Doc (conflicted copy 2).txt", "Doc (conflicted copy).txt", "Doc.txt"])
        // Both versions survived, under distinct names, with their own bytes.
        let preserved = Set([try scratch.read("Doc (conflicted copy).txt"),
                             try scratch.read("Doc (conflicted copy 2).txt")])
        #expect(preserved == ["from Mac A", "from Mac B"])
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.isEmpty == true,
                "the version store is cleared only after the bytes are safe on disk")
    }

    // keep-both when a candidate name is occupied by a dangling symlink: the
    // pre-fix check-then-act picked that name, copyItem failed with EEXIST,
    // and that version was logged-and-skipped — silently lost. FAILS on the
    // old behavior (only one copy would exist, and it would be "copy 2").
    @Test("keep-both preserves every version even when a copy name is held by a dangling symlink")
    func keepBothSurvivesAnOccupiedName() throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let a = try addVersion(to: file, contents: "from Mac A", scratch: scratch)
        let b = try addVersion(to: file, contents: "from Mac B", scratch: scratch)
        let taken = scratch.url.appending(path: "Doc (conflicted copy).txt")
        try FileManager.default.createSymbolicLink(
            atPath: taken.path, withDestinationPath: scratch.url.appending(path: "gone.txt").path
        )

        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: ConflictSource.keepBothVersionID,
            unresolved: [a, b], shownVersionIDs: ids(a, b), root: scratch.url
        )

        #expect(ok == .resolved)
        let preserved = Set([try scratch.read("Doc (conflicted copy 2).txt"),
                             try scratch.read("Doc (conflicted copy 3).txt")])
        #expect(preserved == ["from Mac A", "from Mac B"],
                "both versions preserved: the occupied name is skipped, not lost")
        #expect(try scratch.names().allSatisfy { !$0.hasPrefix(".bw-conflicted-copy-") })
    }

    // keep-both when one copy FAILS: the pre-fix loop logged the failure, kept
    // going, and then removeOtherVersionsOfItem deleted the version it never
    // copied — and reported success. FAILS on the old behavior (ok == true,
    // the version store empty). The failure is injected for the SECOND
    // version so the test also pins that an earlier, successful copy stays.
    @Test("keep-both stops on a failed copy: nothing is removed or resolved, and it reports failure")
    func keepBothCopyFailureLosesNothing() throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let a = try addVersion(to: file, contents: "from Mac A", scratch: scratch)
        let b = try addVersion(to: file, contents: "from Mac B", scratch: scratch)
        struct InjectedCopyFailure: Error {}

        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: ConflictSource.keepBothVersionID,
            unresolved: [a, b], shownVersionIDs: ids(a, b), root: scratch.url,
            claimCopy: { source, nextTo in
                guard source != b.url else { throw InjectedCopyFailure() }
                return try ConflictSource.claimConflictedCopy(of: source, nextTo: nextTo)
            }
        )

        #expect(ok == .failed, "a resolution that could not preserve every version must say so")
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.count == 2,
                "the uncopied version (and every other) is still in the version store")
        #expect(try scratch.read("Doc.txt") == "current bytes")
        #expect(try scratch.names() == ["Doc (conflicted copy).txt", "Doc.txt"],
                "the copy that did succeed stays — it is the user's bytes")
        #expect(try scratch.read("Doc (conflicted copy).txt") == "from Mac A")
    }

    // A conflict version that lands between the unresolved read and the
    // removal was never shown, chosen or copied; removeOtherVersionsOfItem
    // would delete it. Only iCloud can mint a real conflict version, so the
    // last-moment re-read is injected: it reports one id we did not handle.
    @Test("A conflict version arriving mid-resolution aborts before anything is removed",
          arguments: [ConflictSource.currentVersionID, ConflictSource.keepBothVersionID])
    func newVersionDuringResolutionAborts(keepVersionID: String) throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let a = try addVersion(to: file, contents: "from Mac A", scratch: scratch)

        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: keepVersionID,
            unresolved: [a], shownVersionIDs: ids(a), root: scratch.url,
            unresolvedIDsNow: { _ in [ConflictSource.versionID(for: a), "version-arrived-late"] }
        )

        #expect(ok == .changed, "the screen must reload, not offer a blind retry")
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.count == 1, "nothing was removed")
        #expect(try scratch.read("Doc.txt") == "current bytes")
    }

    // The re-review's data-loss case: the screen showed {current, A}; B
    // arrived later; the user clicked "Keep current". The click-time read is
    // {A, B}, and removeOtherVersionsOfItem would delete B, which the user
    // never saw. The old code compared nothing against what was shown and
    // resolved (B gone). Keep-version follows the same rule; keep-both,
    // which removes nothing it has not copied, still copies everything.
    @Test("Keep-current / keep-version refuse when a version the user was not shown is unresolved",
          arguments: [ConflictSource.currentVersionID, "winner"])
    func unseenVersionAtClickTimeIsRefused(choice: String) throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let a = try addVersion(to: file, contents: "from Mac A (shown)", scratch: scratch)
        let b = try addVersion(to: file, contents: "from Mac B (never shown)", scratch: scratch)
        let keep = choice == "winner" ? ConflictSource.versionID(for: a) : choice

        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: keep,
            unresolved: [a, b],
            shownVersionIDs: [ConflictSource.currentVersionID, ConflictSource.versionID(for: a)],
            root: scratch.url
        )

        #expect(ok == .changed)
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.count == 2, "B — and A — are still there")
        #expect(try scratch.read("Doc.txt") == "current bytes", "nothing was replaced either")
    }

    // An unreadable re-read is not "nothing new": it aborts too.
    @Test("An unreadable last-moment re-read aborts the removal")
    func unreadableRecheckAborts() throws {
        let scratch = Scratch()
        let file = scratch.write("Doc.txt", "current bytes")
        let a = try addVersion(to: file, contents: "from Mac A", scratch: scratch)
        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: ConflictSource.currentVersionID,
            unresolved: [a], shownVersionIDs: ids(a), root: scratch.url, unresolvedIDsNow: { _ in nil }
        )
        #expect(ok == .failed)
        #expect(NSFileVersion.otherVersionsOfItem(at: file)?.count == 1)
    }

    // A scan that could not look must say so (nil), never claim "no
    // conflicts" ([]) — the store would take [] as the producer's first
    // successful delivery. An empty but readable root really is [].
    @Test("findConflicts: nil for an unreachable root, [] for a readable empty one")
    func findConflictsFailureIsNotEmpty() async {
        let scratch = Scratch()
        #expect(await ConflictSource.findConflicts(root: scratch.url.appending(path: "missing")) == nil)
        let empty = await ConflictSource.findConflicts(root: scratch.url)
        #expect(empty?.isEmpty == true)
    }

    // The containment guard also protects the direct mutating entry point.
    @Test("applyResolution refuses a path outside the allowed root")
    func applyResolutionRefusesOutsideRoot() throws {
        let scratch = Scratch()
        let outside = Scratch()
        let file = outside.write("Doc.txt", "do not touch")
        let version = try addVersion(to: file, contents: "from Mac A", scratch: outside)

        let ok = ConflictSource.applyResolution(
            fileURL: file, keepVersionID: ConflictSource.versionID(for: version),
            unresolved: [version], shownVersionIDs: ids(version), root: scratch.url
        )

        #expect(ok == .failed)
        #expect(try outside.read("Doc.txt") == "do not touch")
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
