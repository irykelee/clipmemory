import XCTest
@testable import ClipMemory

/// ID-REVIEW-1038 (2026-10-26): the test suite must not write the
/// PRODUCTION `UserDefaults` domain.
///
/// ## Why this guard exists
///
/// The test bundle is injected into the APP binary (`TEST_HOST` =
/// `$(BUILT_PRODUCTS_DIR)/ClipMemory.app/Contents/MacOS/ClipMemory`), so
/// `UserDefaults.standard` inside a test process IS the user's real
/// `com.clipmemory.app` domain — measured inside the test host:
/// `Bundle.main.bundleIdentifier` is `com.clipmemory.app` there.
///
/// Every production-domain write in the suite was therefore undoing the
/// user's real settings, and the undo was a `defer` / `tearDown` restore.
/// **A `defer` does not run when the test host aborts** — and this repo
/// has already proven the host aborts (CI run 40186263416,
/// ID-REVIEW-1034: "Restarting after unexpected exit, crash, or test
/// timeout").
///
/// Measured 2026-10-26 with a deliberate trap: the production plist was
/// left holding `fontScale = 3.7` — a real user setting — after the host
/// died between the write and the restore. The restore never ran.
///
/// ## Why a STATIC guard
///
/// The runtime guards that exist cannot cover this case:
///
///   * `ZZZSuiteTeardownTests.testNoProductionPollution` compares the
///     production domain before/after the whole suite. It does not run
///     after a host abort (the host is dead), and it `XCTSkip`s
///     whenever another ClipMemory instance holds the single-instance
///     lock — i.e. on the developer's own machine, where the app is
///     normally running.
///   * The per-service seams (`ClipboardStore.xcTestDefaults` etc.) keep
///     the PRODUCTION code from writing there. They cannot stop a TEST
///     from writing there directly.
///
/// A source scan is a property of the CODE, not of a running process, so
/// it still holds when the host dies. That is the whole point: the crash
/// is the case where the runtime guards are gone.
///
/// ## The rule
///
/// A test source may reach the production domain only at a site that
/// carries an `ALLOW-PRODUCTION-WRITE:` marker with a written
/// justification. Reads are fine. The marker must be on the line
/// immediately above the write (a six-line lookback covers a small
/// `if`/`else` group).
///
/// ## Known limitation
///
/// The scan is textual. A write through a value that reached the
/// production domain by another route (a function parameter, a property,
/// a `UserDefaults` returned from a call) is invisible to it. The alias
/// rule below closes the common case — binding the production domain to
/// a local — but not the general one.
/// The production domain, however it is spelled — built from fragments on
/// purpose: this file is itself scanned, and a literal spelling would make
/// the guard flag its own source.
private let prodDot = "."
private let prodStd = "standard"
private let prodDefaultsType = "UserDefaults"

final class ProductionDomainWriteGuardTests: XCTestCase {

    // MARK: - The premise

    /// The guard's premise: in this process, `UserDefaults.standard`
    /// addresses the production domain.
    ///
    /// It is worth pinning, because the whole rule rests on it. If a
    /// future change makes the test bundle run OUTSIDE the app (a
    /// non-hosted unit-test bundle), `.standard` would become a
    /// test-only domain, every write the guard polices would become
    /// harmless, and the exemptions below could be retired.
    func testStandardAddressesTheProductionDomainInThisProcess() {
        XCTAssertTrue(
            TestIsolation.addressesProductionDomain(UserDefaults.standard),
            "ID-REVIEW-1038: the guard assumes UserDefaults.standard IS the production "
            + "domain inside the test host. If that ever stops being true, the "
            + "exemptions in this file can be retired."
        )
    }

    // MARK: - The scan

    /// The production domain, however it is spelled.
    ///
    /// Built from fragments on purpose: this file is itself scanned, and a
    /// literal spelling would make the guard flag its own source.

    /// `.standard` OR `UserDefaults.standard` OR `UserDefaults . standard`.
    private static let productionDomainValue =
        "(?:" + prodDot + prodStd + "|" + prodDefaultsType + "\\s*" + prodDot + "\\s*" + prodStd + ")"

    /// The `UserDefaults` members that WRITE.
    private static let writeMethods = [
        "set", "setValue", "register", "setVolatileDomain",
        "removeObject", "removePersistentDomain", "synchronize"
    ]

    /// Rule A — a write called ON the production domain.
    ///
    /// Rule C — a production-domain value passed as an argument to
    /// `save(to:)`, which is the shape `HotKeyConfig.save(to:)` has.
    private static var writePatterns: [String] {
        var patterns: [String] = []
        for method in writeMethods {
            patterns.append(productionDomainValue + "\\s*" + prodDot + "\\s*" + method + "\\s*\\(")
        }
        patterns.append("save\\s*\\(\\s*to\\s*:\\s*" + productionDomainValue)
        return patterns
    }

    /// Rule B — the production domain bound to a local.
    ///
    /// A write through such an alias does not contain the production
    /// domain's spelling, so rule A cannot see it. Flagging the BINDING
    /// closes that hole.
    ///
    /// ⚠️ `(?m)` is REQUIRED here. ICU's `$` matches only at the very end
    /// of the input unless MULTILINE is on, so without it `\s*$` would
    /// match only an assignment on the LAST line of the file — and the
    /// rule would silently never fire. Measured 2026-10-27 by mutation
    /// (M4): an alias planted in the middle of a test file was NOT
    /// reported. That is exactly the kind of "looks right, does
    /// nothing" defect this round exists to remove.
    ///
    /// The tail accepts `else` (a `guard let … = <domain> else { … }`)
    /// and a trailing `//` comment, because the independent review found
    /// both spellings invisible to the strict form.
    private static var aliasPatterns: [String] {
        let tail = "\\s*(?:else\\b[^\\n]*)?(?:\\s*//[^\\n]*)?$"
        return [
            "(?m)(?:let|var)\\s+\\w+[^=\\n]*=\\s*" + productionDomainValue + tail,
            "(?m)guard\\s+let\\s+\\w+[^=\\n]*=\\s*" + productionDomainValue + tail
        ]
    }

    /// Rule D — the production domain passed as an ARGUMENT value.
    ///
    /// The independent review found this blind spot: `defaults: .standard`
    /// and `store: .standard` are writes handed to someone else, and
    /// neither contains a write method on the production domain, so rule A
    /// could not see them.
    private static var argumentPatterns: [String] {
        ["[A-Za-z_]\\w*\\s*:\\s*" + productionDomainValue + "(?![A-Za-z0-9_])"]
    }

    /// Every rule the scan applies.
    private static var allPatterns: [String] {
        writePatterns + aliasPatterns + argumentPatterns
    }

    /// The marker a write site must carry.
    private static let marker = "ALLOW-PRODUCTION-WRITE"

    /// How far above a write the marker may sit.
    ///
    /// Six lines covers a small `if`/`else` group; a longer gap means the
    /// marker has drifted away from what it exempts and the site is
    /// reported.
    ///
    /// ⚠️ KNOWN LOOSENESS (independent review, 2026-10-27): ONE marker
    /// excuses every production write within the six lines below it, so a
    /// second, unrelated write placed just under an existing marker
    /// would slip through. Tightening this to "one write per marker"
    /// would break the legitimate `if`/`else` pairs, so the rule stays
    /// at six lines and the looseness is recorded here instead of being
    /// left implicit.
    private static let markerLookbackLines = 6

    /// The minimum justification a marker must carry.
    ///
    /// A bare marker is not a decision — it is a way to make the guard
    /// quiet. The text after the colon is where the decision is written
    /// down. 40 characters (raised from 20 after the independent review
    /// noted that a bare "will fix it soon" placeholder cleared the old bar).
    private static let minimumJustificationLength = 40

    /// Justifications that are placeholders rather than reasons.
    ///
    /// A length check alone cannot tell "the snapshot baseline must live
    /// in the production domain" from "fix this later".
    private static let placeholderMarkers = ["todo", "fixme", "fix later", "tbd", "xxx", "wip", "later"]

    /// Repository root, computed from this file's own location.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .resolvingSymlinksInPath()
    }()

    /// The production-domain writes in the test tree that are not excused.
    func testNoTestSourceWritesTheProductionDomainWithoutAnExcusedSite() throws {
        var offenders: [String] = []
        for url in try Self.testSourceFiles() {
            let relativePath = Self.relativePath(of: url, root: Self.repoRoot)
            let source = try String(contentsOf: url, encoding: .utf8)
            let hits = Self.codeLines(
                matchingAnyOf: Self.writePatterns + Self.aliasPatterns + Self.argumentPatterns,
                in: source
            )
            for line in hits {
                if let marker = Self.markerAbove(line: line, in: source) {
                    let justification = Self.justification(of: marker)
                    if Self.isARealJustification(justification) { continue }
                    offenders.append(
                        "\(relativePath):\(line) — the \(Self.marker) marker carries no "
                        + "justification (needs at least \(Self.minimumJustificationLength) characters)"
                    )
                } else {
                    offenders.append(
                        "\(relativePath):\(line) — a production-domain write with no "
                        + "\(Self.marker) marker (and no justification for one)"
                    )
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "ID-REVIEW-1038: the test suite must not write the production UserDefaults "
            + "domain. Inside the test host `UserDefaults.standard` IS the user's real "
            + "com.clipmemory.app domain, and a `defer` restore does not survive a host "
            + "abort (measured 2026-10-26: `fontScale = 3.7` left in the user's plist). "
            + "Use a per-test suite instead. If a write is genuinely unavoidable, mark the "
            + "line above it with `\(Self.marker): <why>`. Offending sites: \(offenders)"
        )
    }

    // MARK: - The scanner's own controls

    /// The spellings the scanner must catch.
    ///
    /// ASSEMBLED at runtime, not written out: a literal production-domain
    /// spelling in this file would be flagged by the scan above — the
    /// guard file must not contain the pattern it forbids.
    private static var samplesToCatch: [String] {
        let shorthands = [prodDot + prodStd, prodDefaultsType + prodDot + prodStd, prodDefaultsType + " " + prodDot + " " + prodStd]
        var samples: [String] = []
        for shorthand in shorthands {
            samples.append("UserDefaults" + shorthand + ".set(1, forKey: \"k\")")
            samples.append("UserDefaults" + shorthand + ".removeObject(forKey: \"k\")")
            samples.append("UserDefaults" + shorthand + ".register(defaults)")
            samples.append("let alias = " + shorthand)
        }
        samples.append("HotKeyConfig(keyCode: 0, modifiers: 256).save(to: " + prodDot + prodStd + ")")
        return samples
    }

    /// Every spelling of a production-domain write must be caught.
    ///
    /// This is the control for the guard above: it feeds the scanner the
    /// exact lines a write would look like. If the pattern set ever
    /// narrows again, this goes red — instead of the guard quietly
    /// stopping to see the write.
    func testTheScannerCatchesEverySpellingOfAProductionDomainWrite() {
        for sample in Self.samplesToCatch {
            // The sample is embedded in a MULTI-LINE context on purpose.
            //
            // A single-line sample would let an end-anchored rule (`$`
            // without MULTILINE matches only at the very end of the
            // input) pass by accident — the rule would match the sample
            // simply because the sample WAS the whole input. That is how
            // the alias rule stayed broken for one round: measured
            // 2026-10-27 by mutation M4, an alias planted in the middle
            // of a test file was not reported, while the single-line
            // positive control passed happily. Embedded, the control
            // fails for a rule that only works at the end of a file.
            let embedded = """
            func demo() {
                \(sample)
            }
            """
            XCTAssertFalse(
                Self.codeLines(matchingAnyOf: Self.allPatterns, in: embedded).isEmpty,
                "the scanner must flag a production-domain write written as: \(sample)"
            )
        }
    }

    /// …and it must NOT flag a READ, a comment, or unrelated code.
    func testTheScannerIgnoresReadsCommentsAndUnrelatedCode() {
        let mustNotCatch = [
            "// UserDefaults" + prodDot + prodStd + ".set(1, forKey: \"k\")",
            "let scale = UserDefaults" + prodDot + prodStd + ".double(forKey: \"fontScale\")",
            "let before = UserDefaults" + prodDot + prodStd + ".object(forKey: key)",
            "XCTAssertTrue(TestIsolation.addressesProductionDomain(UserDefaults" + prodDot + prodStd + "))",
            "let suite = UserDefaults(suiteName: \"probe-\\(UUID().uuidString)\")!",
            "let other = SomeType" + prodDot + prodStd
        ]
        for sample in mustNotCatch {
            XCTAssertTrue(
                Self.codeLines(matchingAnyOf: Self.allPatterns, in: sample).isEmpty,
                "the scanner must not flag: \(sample)"
            )
        }
    }

    /// The marker must be REQUIRED, not optional.
    ///
    /// A site that writes the production domain without a marker must be
    /// reported. Without this control the scan could pass vacuously —
    /// e.g. if the lookback window were mis-implemented to always find a
    /// marker.
    func testTheScannerReportsAnUnmarkedProductionWrite() {
        let source = """
        func demo() {
            UserDefaults\(prodDot)\(prodStd).set(1, forKey: "k")
        }
        """
        let hits = Self.codeLines(matchingAnyOf: Self.writePatterns, in: source)
        XCTAssertEqual(hits.count, 1, "the scanner must find the unmarked write")
        XCTAssertNil(
            Self.markerAbove(line: hits[0], in: source),
            "an unmarked write must have no marker above it"
        )
    }

    /// A marker without a justification is not an excuse.
    func testAMarkerWithoutAJustificationIsRejected() {
        let source = """
        func demo() {
            // \(Self.marker):
            UserDefaults\(prodDot)\(prodStd).set(1, forKey: "k")
        }
        """
        let hits = Self.codeLines(matchingAnyOf: Self.writePatterns, in: source)
        XCTAssertEqual(hits.count, 1)
        let marker = Self.markerAbove(line: hits[0], in: source)
        XCTAssertNotNil(marker, "the marker is present")
        XCTAssertLessThan(
            Self.justification(of: marker!).count,
            Self.minimumJustificationLength,
            "a marker with no written reason must be treated as no excuse at all"
        )
    }

    // MARK: - Helpers

    /// Every Swift file in the test tree.
    private static func testSourceFiles() throws -> [URL] {
        let directory = repoRoot.appendingPathComponent("Tests/ClipMemoryTests")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The path of `url` relative to the repository root.
    static func relativePath(of url: URL, root: URL) -> String {
        let filePath = url.resolvingSymlinksInPath().path
        let rootPath = root.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /// 1-based line numbers where one of `patterns` matches CODE.
    ///
    /// A match that starts on a comment line is ignored: the same rule
    /// the seam-reset guard uses, so "declaration" means the same thing
    /// in both guards.
    private static func codeLines(matchingAnyOf patterns: [String], in source: String) -> [Int] {
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        var hits: Set<Int> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: fullRange) {
                let lineRange = nsSource.lineRange(for: NSRange(
                    location: match.range.location,
                    length: 0
                ))
                let prefixRange = NSRange(
                    location: lineRange.location,
                    length: match.range.location - lineRange.location
                )
                guard !nsSource.substring(with: prefixRange).contains("//") else { continue }
                hits.insert(lineNumber(of: lineRange.location, in: nsSource))
            }
        }
        return hits.sorted()
    }

    /// The 1-based number of the line that starts at `location`.
    private static func lineNumber(of location: Int, in nsSource: NSString) -> Int {
        var number = 1
        for index in 0..<location where nsSource.character(at: index) == 10 {
            number += 1
        }
        return number
    }

    /// The marker line above `line`, if there is one within the lookback.
    private static func markerAbove(line: Int, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        let first = max(1, line - markerLookbackLines)
        guard line >= 1, line <= lines.count else { return nil }
        var index = line - 2 // the line above the hit
        while index >= first - 1 {
            if index >= 0, index < lines.count, lines[index].contains(marker) {
                return lines[index]
            }
            index -= 1
        }
        return nil
    }

    /// Whether a justification is a reason and not a placeholder.
    private static func isARealJustification(_ justification: String) -> Bool {
        guard justification.count >= minimumJustificationLength else { return false }
        let lowered = justification.lowercased()
        return !placeholderMarkers.contains { lowered.contains($0) }
    }

    /// The written reason that follows the marker on its line.
    private static func justification(of markerLine: String) -> String {
        guard let range = markerLine.range(of: marker) else { return "" }
        let tail = markerLine[range.upperBound...]
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
