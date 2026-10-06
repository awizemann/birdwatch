import Foundation
import Testing
@testable import Birdwatch

// The byte-scanning `BrctlDumpParser` is checked three ways:
// - against `ReferenceBrctlDumpParser` (the pre-rewrite regex code plus the
//   documented CHANGEs) on every fixture line and a fixed set of mutations;
// - whole-document, on mutated copies of the dump fixtures;
// - against stored golden serialisations of the complete parsed `BrctlDump`.

private nonisolated func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name)")
}

private nonisolated func fixture(_ name: String) throws -> String {
    try String(contentsOf: fixtureURL(name), encoding: .utf8)
}

/// Every real `brctl` capture in the fixtures.
private nonisolated let brctlFixtures = [
    "brctl-dump-excerpt.txt",
    "brctl-dump-ga-dir-fault-excerpt.txt",
    "brctl-dump-ga-zero-size-excerpt.txt",
    "brctl-status.txt",
    "brctl-monitor-live-upload.txt",
    "brctl-quota.txt",
]

/// The `brctl dump` captures among them, with their golden files.
private nonisolated let dumpFixtures = [
    ("brctl-dump-excerpt.txt", "brctl-dump-excerpt.parsed.txt"),
    ("brctl-dump-ga-dir-fault-excerpt.txt", "brctl-dump-ga-dir-fault-excerpt.parsed.txt"),
    ("brctl-dump-ga-zero-size-excerpt.txt", "brctl-dump-ga-zero-size-excerpt.parsed.txt"),
]

// MARK: - Mutations

/// Hand-written lines aimed at the scanner's edge cases (grammar corners the
/// fixtures do not contain).
private nonisolated let edgeLines = [
    "----a[1]----", "----[1]----", "-----[1]-----", "----a b[1]----", "----a[1]---", "----a[1]----x",
    "----a[x]----", "----a[]----", "----a[1][2]----", "--------", "-----a[12]----------",
    "+ app library: <c{1}m.a{3}e.s{5}x[51] NA {s:no-documents|l-root} ino:(null)>",
    "+app library:<a[1] x", "+ app library: <a[1]x[2] y", "+ app library: <[1] x", "+ app library: <a[1]",
    "+ app library: < a[1] x", "+ app  library: <a[1] x", "+ app library: <a[b][2] z", "+ app library: <a[1]\tz",
    "> upload{[1 old]}", "> upload{[12 old]}", "> upload{[1 old ]}", "> upload{[ 1 old]}", "> upload{[1 older]}",
    "> x{[a]} trailing ]} more", "> x{[]}", ">x{[attempts:2]}", "> {[attempts:2]}", "> X{[attempts:2]}",
    "> apply{[attempts:]}", "> apply{[attempts:5 next:] cleanup: ]}", "> apply{[next:]]}",
    "> apply{[last:1.2.3m ago]}", "> apply{[last:3m]}", "> apply{[last:3m agox]}", "> apply{[last:3x ago last:4m ago]}",
    "> apply{[xlast:3m ago last:4m ago]}", "> apply{[zone:x zone:4 attempts:y attempts:2]}",
    "> apply{[next:ready]}", "> apply{[next:5m]x cleanup:2h]}", "> dir-faults:1",
    "r:5 i:<A> up:needs-upload st{n:\"a.b\" dir}", "r:5 i:<A> up:needs-upload st{n:\"a.b\" dir-fault etag:1}",
    "r:5 i:<A> up:needs-upload st{n:\"dir\" doc}", "r:5 i:<A> up:needs-upload st{-dir x}", "r:5 i:<A> up:a {dir}",
    "i:<> i:<B> up:x", "i:<B up:x", "xup:no up:yes i:<C>", "up:- up:a- i:<D>", "up:idle i:<D>",
    "r:x i:<E> up:a al: al:7 sz:12 bytes", "r:1 i:<F> up:a sz:(12) sz:3 bytes", "r:1 i:<F> up:a sz:3 bytes(",
    "r:1 i:<F> up:a sz:x (12x) (13)", "r:1 i:<F> up:a sz:5 KB (12] (13)", "r:1 i:<F> up:a sz:0 bytes tsz:1 KB (99)",
    "r:1 i:<F> up:a n:\"unterminated device:4", "r:1 i:<F> up:a n:\"\" n:\"b.c\"", "r:1 i:<F> up:a n:\".hidden\"",
    "r:1 i:<F> up:a device: device:12 dir", "dir r:1 i:<G> up:a", "r:1 i:<G> up:a\tdir\t",
    "r:1 i:<H> up:needs-upload st{n:\"a device:7 dir up:idle sz:9 bytes (8) al:3.txt\" doc} ct{mt:5 sz:1 KB (1024) device:2}",
    "r:1 i:<I> up:needs-upload n:\"x\" n:\"y device:9\" device:3",
]

/// Deterministic rewrites of one line. Each targets a scanner decision:
/// truncation, keep-searching after a failed key, word boundaries,
/// terminators, tokens and trimming.
private nonisolated func mutations(of line: String) -> [String] {
    var out = [line]
    let count = line.count
    for cut in [1, count / 3, count / 2, (2 * count) / 3, count - 1] where cut > 0 && cut < count {
        out.append(String(line.prefix(cut)))
    }
    let rewrites: [(String, String)] = [
        ("up:idle ", "up:idler "), ("up:idle ", "up:idle}"), (" ago", ""), (" ago", "x ago"),
        (" old]", " older]"), (" dir ", " -dir "), (" dir ", "{dir "), (" dir ", " dirx "), (" doc ", " dir-faultx "),
        (" up:", " xup:"), (" up:", " éup:"), (" up:", " up:- up:"), (" device:", " édevice:"),
        (" device:", " device: device:"), (" al:", " al:x al:"), (" sz:", " sz:x( sz:"), (" i:<", " i:<> i:<"),
        ("next:", "next: next:"), ("cleanup:", "cleanup:] cleanup:"), ("last:", "last:x last:"),
        ("zone:", "zone:z zone:"), ("attempts:", "attempts:a attempts:"),
        (") n:\"", "] n:\""), (" n:\"", " n:\"q dir device:1 \" n:\""), ("----", "-----"), ("[", "x[["),
    ]
    for (from, to) in rewrites where line.contains(from) {
        out.append(line.replacing(from, with: to, maxReplacements: 1))
    }
    out.append(line.replacing(/\((\d+)\)/) { "(\($0.1)]" })
    return out
}

/// Whole-document variant `k` of a dump: line `i` takes mutation
/// `(i * 7 + k) % n`; even variants also pad lines with whitespace and odd
/// ones interleave noise lines (variant 1 before every `>` line), to
/// exercise trimming and anchor resets.
private nonisolated func documentVariant(_ text: String, _ k: Int) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var out: [String] = []
    for (i, line) in lines.enumerated() {
        let options = mutations(of: line)
        // Variants 0 and 1 keep every line intact (1 only adds noise lines).
        var chosen = k <= 1 ? line : options[(i * 7 + k) % options.count]
        if k % 2 == 0, k > 0 {
            switch i % 4 {
            case 0: chosen += " "
            case 1: chosen += "\t"
            case 2: chosen = "\u{00A0}" + chosen
            default: break
            }
        } else if k == 1, line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            // A non-item line between an item and its `>` line must detach it.
            out.append("noise sm{qta:1}")
        } else if k % 2 == 1, i % 3 == 0 {
            out.append(i % 2 == 0 ? "noise sm{qta:1}" : "\u{00A0}\u{00A0}")
        }
        out.append(chosen)
    }
    return out.joined(separator: "\n")
}

// MARK: - Tests

@Suite("BrctlDumpParser oracle")
struct BrctlDumpOracleTests {

    @Test func lineParsersMatchReferenceOnFixturesAndMutations() throws {
        var lines = edgeLines
        for name in brctlFixtures {
            let text = BrctlParser.stripANSI(try fixture(name))
            lines += text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var mismatches: [String] = []
        var checked = 0
        for line in Set(lines.flatMap(mutations(of:))).sorted() {
            checked += 1
            if BrctlDumpParser.parseItemLine(line) != ReferenceBrctlDumpParser.parseItemLine(line) {
                mismatches.append("item: \(line)")
            }
            if BrctlDumpParser.parseOperationLine(line) != ReferenceBrctlDumpParser.parseOperationLine(line) {
                mismatches.append("operation: \(line)")
            }
            let library = BrctlDumpParser.parseAppLibraryIdentifier(line)
            let referenceLibrary = ReferenceBrctlDumpParser.parseAppLibraryIdentifier(line)
            if library?.pattern != referenceLibrary?.pattern || library?.id != referenceLibrary?.id {
                mismatches.append("library: \(line)")
            }
            for word in line.split(whereSeparator: { $0 == " " || $0 == ":" }) {
                let word = String(word)
                if BrctlDumpParser.parseDuration(word) != ReferenceBrctlDumpParser.parseDuration(word) {
                    mismatches.append("duration: \(word)")
                }
            }
        }
        #expect(checked > 1_000)
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(5))")
    }

    @Test(arguments: dumpFixtures.map(\.0))
    func wholeDumpMatchesReferenceOnMutatedDocuments(_ name: String) throws {
        let text = try fixture(name)
        for k in 0..<12 {
            let variant = documentVariant(text, k)
            let parsed = BrctlDumpParser.parse(variant)
            let reference = ReferenceBrctlDumpParser.parse(variant)
            #expect(parsed == reference, "variant \(k) of \(name)")
        }
    }

    @Test func byteANSIStripMatchesRegexStrip() throws {
        let injections = ["\u{1B}[1 q", "\u{1B}[?25h", "\u{1B}[", "\u{1B}[12", "\u{1B}[0;1;30m", "\u{1B}x",
                          "\u{1B}[1;2 !p", "\u{1B}[:m", "\u{1B}[3\u{1B}[4m", "\u{1B}[ ", "\u{1B}[~"]
        var texts = try brctlFixtures.map(fixture)
        for (i, injection) in injections.enumerated() {
            texts.append("a\(injection)b \(injection)\n\(injection)")
            texts.append(texts[i % brctlFixtures.count].replacing("\u{1B}[0m", with: injection))
        }
        for text in texts {
            #expect(String(decoding: BrctlDumpParser.stripANSIBytes(text), as: UTF8.self) == BrctlParser.stripANSI(text))
        }
    }

    // MARK: Golden

    @Test(arguments: dumpFixtures)
    func wholeParsedDumpMatchesGolden(_ input: String, _ golden: String) throws {
        let parsed = goldenText(BrctlDumpParser.parse(try fixture(input)))
        #expect(parsed == (try fixture(golden)))
    }
}

/// Stable text form of a complete `BrctlDump`: dictionaries sorted, and the
/// one local-time date printed back in local time so the golden file does not
/// depend on the machine's time zone.
nonisolated func goldenText(_ parsed: BrctlDump) -> String {
    var copy = parsed
    var out = ""
    for (id, pattern) in copy.appLibraryPatterns.sorted(by: { $0.key < $1.key }) { out += "library \(id) \(pattern)\n" }
    for (slot, error) in copy.syncHealth.errors.sorted(by: { $0.key < $1.key }) { out += "health \(slot) \(error)\n" }
    if let date = copy.clientState.lastMetadataSyncDate {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        out += "lastMetadataSyncDate (local) \(formatter.string(from: date))\n"
    }
    copy.appLibraryPatterns = [:]
    copy.syncHealth.errors = [:]
    copy.clientState.lastMetadataSyncDate = nil
    dump(copy, to: &out)
    return out.replacingOccurrences(of: "Birdwatch.", with: "")
}
