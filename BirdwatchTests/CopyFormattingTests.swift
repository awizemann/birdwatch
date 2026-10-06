import Foundation
import Testing
@testable import Birdwatch

/// Plurals, locale-aware numbers/times, and the copy that used to claim more
/// than the code does. Every test pins an explicit locale, so results never
/// depend on the machine running them.
@MainActor
@Suite("Copy — plurals, locale formatting and honest wording")
struct CopyFormattingTests {
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")
    private let de = Locale(identifier: "de_DE")
    private let fr = Locale(identifier: "fr_FR")
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: Plurals

    @Test("Count phrases agree with their number — never '1 apps' or '2 app'")
    func plurals() {
        #expect(Plural.count(0, "app", locale: us) == "0 apps")
        #expect(Plural.count(1, "app", locale: us) == "1 app")
        #expect(Plural.count(2, "app", locale: us) == "2 apps")
        #expect(Plural.count(2, "directory", plural: "directories", locale: us) == "2 directories")
        #expect(Plural.count(1, "directory", plural: "directories", locale: us) == "1 directory")
        #expect(Plural.word(1, "item") == "item")
        #expect(Plural.word(3, "item") == "items")
    }

    // Fails on the old helper, which printed a bare "1234".
    @Test("Counts are grouped the way the locale groups numbers")
    func pluralGrouping() {
        #expect(Plural.count(1_234, "item", locale: us) == "1,234 items")
        #expect(Plural.count(1_234, "item", locale: de) == "1.234 items")
    }

    @Test("Count-carrying lines built from the helper read correctly at 1 and many")
    func countLines() {
        #expect(PopoverSummary.issuesLine(count: 1) == "1 issue needs attention")
        #expect(PopoverSummary.issuesLine(count: 3) == "3 issues need attention")
        let one = AppContainerSource.Container(directoryName: "iCloud~x", id: "container-x", name: "X",
                                               isApple: false, itemCount: 1)
        #expect(AppContainerSource.topLevelLine(one) == "1 top-level item")
    }

    // MARK: Durations

    @Test("Compact durations keep English output and follow the locale's unit style")
    func durations() {
        #expect(Format.duration(45, locale: us) == "45s")
        #expect(Format.duration(12 * 60, locale: us) == "12m")
        #expect(Format.duration(4 * 3_600, locale: us) == "4h")
        #expect(Format.duration(75 * 86_400, locale: us) == "75d")
        #expect(Format.duration(-5, locale: us) == "0s", "a clock skew never prints a negative age")
        #expect(Format.duration(12 * 60, locale: fr) != "12m", "French writes minutes its own way")
        #expect(Age.compact(37, locale: us) == "37s")
        #expect(Age.compact(179, locale: us) == "2m", "truncates, unlike Format.duration")
        #expect(Age.compact(2 * 86_400 + 5, locale: us) == "2d")
    }

    // Fails on the first version, whose `Int64(value) * 86_400` trapped and
    // whose `Int(seconds)` trapped on NaN / infinity.
    @Test("Absurd and non-finite ages never trap")
    func durationEdges() {
        #expect(Format.duration(.nan, locale: us) == "—")
        #expect(Format.duration(.infinity, locale: us) == "—")
        #expect(Age.compact(.nan, locale: us) == "—")
        #expect(Age.compact(-.infinity, locale: us) == "—")
        #expect(!Format.duration(1e300, locale: us).isEmpty)
        #expect(!Age.compact(1e300, locale: us).isEmpty)
        #expect(!Format.compactUnit(Int.max, .days, locale: us).isEmpty)
        #expect(Format.compactUnit(-3, .hours, locale: us) == "0h")
    }

    // Fails when the label rounds while `cpuTint` compares the raw value:
    // 29.6 read "30%" yet stayed amber.
    @Test("CPU text and its tint agree at the thresholds")
    func cpuBoundary() {
        #expect(Format.cpu(29.6, locale: us) == "29% CPU")
        #expect(cpuTint(29.6) == Palette.warning)
        #expect(Format.cpu(30, locale: us) == "30% CPU")
        #expect(cpuTint(30) == Palette.error)
        #expect(Format.cpu(14.99, locale: us) == "14% CPU")
        #expect(cpuTint(14.99) == Palette.success)
        #expect(Format.cpu(.nan, locale: us) == "0% CPU")
    }

    // MARK: Percent, CPU, memory, times

    @Test("CPU, memory and budget percentages are locale-aware")
    func numbers() {
        #expect(Format.cpu(34, locale: us) == "34% CPU")
        #expect(Format.cpu(134, locale: us) == "134% CPU", "ps reports percent of one core; >100 is real")
        #expect(Format.memory(megabytes: 412, locale: us) == "412 MB")
        #expect(Format.memory(megabytes: 1_500, locale: us) == "1.46 GB")
        #expect(BrctlDumpMapper.percent(0.5, locale: us) == "0.5%")
        #expect(BrctlDumpMapper.percent(57, locale: us) == "57%")
        #expect(BrctlDumpMapper.percent(0.5, locale: de) == "0,5\u{00A0}%")
        #expect(BrctlDumpMapper.percent(57, locale: de) == Format.percent(0.57, locale: de),
                "one percentage formatter, one locale spelling")
    }

    // Fails on the old English-only SystemSyncSource.ageText ("12 min ago"
    // in every locale, and worded unlike every other age in the app).
    @Test("Last-known ages are localised and worded like every other relative age")
    func ages() {
        #expect(Format.age(720, locale: us) == "12m ago")
        #expect(Format.age(720, locale: de) == "vor 12 m")
        #expect(Format.age(720) == Format.relative.localizedString(fromTimeInterval: -720))
    }

    // Fails on the old fixed "HH:mm:ss" formatter, which ignored 12-hour locales.
    @Test("Log timestamps and hours follow the user's 12/24-hour convention")
    func times() {
        let date = Date(timeIntervalSince1970: 75_662)   // 21:01:02 UTC
        #expect(Format.clockTime(date, locale: us, timeZone: utc) == "9:01:02\u{202F}PM")
        #expect(Format.clockTime(date, locale: gb, timeZone: utc) == "21:01:02")
        #expect(Format.hourOfDay(14, locale: us) == "2:00\u{202F}PM")
        #expect(Format.hourOfDay(9, locale: gb) == "09:00")
    }

    // MARK: Honest wording

    // Fails on the old sheet, which reused "This can't be undone … only local
    // sync state is affected" for a SIGTERM + launchd respawn.
    @Test("The restart confirmation describes a signal and a respawn, not a reset")
    func restartCopy() {
        let bird = RestartCopy.consequence(daemon: "bird")
        #expect(bird.contains("SIGTERM"))
        #expect(bird.contains("starts it again"))
        #expect(!bird.contains("can't be undone"))
        #expect(!bird.contains("local sync state"))
        #expect(!bird.contains("CloudKit"))
        #expect(RestartCopy.consequence(daemon: "cloudd").contains("may stay stopped"))
    }

    // Fails on the old screen, which told every conflict it was "edited on two
    // devices at once" — Birdwatch knows neither the timing nor the device count.
    @Test("The conflict screen states only what is known, and names what keep-all does")
    func conflictCopy() {
        let two = ConflictCopy.subtitle(location: "Documents", versionCount: 2)
        #expect(two == "Documents · 2 versions kept by iCloud")
        #expect(!ConflictCopy.explanation(versionCount: 2).contains("at once"))
        #expect(!ConflictCopy.explanation(versionCount: 2).contains("two devices"))
        #expect(ConflictCopy.explanation(versionCount: 2).contains("keep both"))
        #expect(ConflictCopy.explanation(versionCount: 3).contains("keep all of them"))
        #expect(ConflictCopy.keepAllButton(versionCount: 2) == "Keep both versions")
        #expect(ConflictCopy.keepAllButton(versionCount: 3) == "Keep all versions")
        #expect(ConflictCopy.explanation(versionCount: 2).hasPrefix(
            "iCloud kept one version as the current file and saved the others for you to choose from."))
    }

    // Fails on the old fallback, which labelled an unknown saving computer "This Mac".
    @Test("A version whose saving device is unknown says so")
    func conflictDevice() {
        #expect(ConflictSource.deviceLabel(nil) == "Unknown device")
        #expect(ConflictSource.deviceLabel("") == "Unknown device")
        #expect(ConflictSource.deviceLabel("iPhone") == "iPhone")
        #expect(ConflictSource.changeNote(savedBy: nil) == "Saved on an unknown device")
        #expect(ConflictSource.changeNote(savedBy: "iPhone") == "Edited on iPhone")
        #expect(!ConflictSource.changeNote(savedBy: nil).contains("This Mac"))
    }

    // Fails on the old FDA-conditional line, which implied conflicts were
    // checked everywhere once access was granted. The walk covers only the
    // CloudDocs root (Desktop/Documents there are unfollowed symlinks; app
    // containers are outside it), so the scope is stated on every Mac.
    @Test("The Issues screen states where conflicts are checked, unconditionally")
    func conflictScope() {
        let scope = IssuesEmptyState.conflictScope
        #expect(scope.contains("iCloud Drive only"))
        #expect(scope.contains("Desktop & Documents"))
        #expect(scope.contains("apps' own iCloud folders"))
        #expect(!scope.contains("Full Disk Access"))
        // Present whether the answer is clean or qualified…
        #expect(IssuesEmptyState(isPaused: false, deliveredProducers: nil, conflictScanCap: nil).lines.contains(scope))
        #expect(IssuesEmptyState(isPaused: true, deliveredProducers: nil, conflictScanCap: nil).lines.contains(scope))
        // …but never a qualifier: it must not turn the Overview tile into "—".
        #expect(IssuesEmptyState.qualifiers(isPaused: false, deliveredProducers: nil, conflictScanCap: nil).isEmpty)
    }

    @Test("Backends describe what Birdwatch actually reads for progress")
    func progressDetail() {
        #expect(SyncBackend.cloudKit.progressDetail == "Activity only (no progress)")
        #expect(SyncBackend.fileProvider.progressDetail == "Not reported")
    }
}
