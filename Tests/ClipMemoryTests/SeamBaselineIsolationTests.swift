import XCTest
@testable import ClipMemory

/// ID-CRASH-0066 (2026-10-23): guards for the BASELINE of the shared
/// `UserDefaults` seam (`TestIsolation.defaults`).
///
/// ## What went wrong
///
/// The seam used to start at `.standard` — the production
/// `com.clipmemory.app` domain — and three test classes reset it there in
/// their `tearDown`:
///
///   * `UpdateServiceTests`
///   * `WindowManagerTests`
///   * `SettingsWindowTests`
///
/// Those resets were harmless while each service owned its own static
/// storage. They became a LEAK when ID-CRASH-0029 unified the three
/// services onto ONE storage (`TestIsolation.defaults` behind three
/// forwarders): resetting one service's forwarder reset all three, so the
/// remainder of the test process ran with the production domain wired in.
/// `LanguageManager.applyLanguage()` writes `AppleLanguages` through the
/// seam, and `UpdateService` writes its feed-policy keys through it too.
///
/// ## What is guarded here
///
/// 1. The PRODUCTION branch is unchanged — the app still starts on
///    `.standard`. This is asserted directly, because "the test branch is
///    hermetic" is worthless if the production branch silently moved too.
/// 2. The TEST branch never addresses the production domain.
/// 3. The live seam does not address the production domain.
/// 4. No source file resets the seam to the production domain. This is the
///    order-independent guard: it catches the PATTERN, not just the three
///    known call sites, and it keeps catching new ones.
///
/// A runtime counterpart lives in `ZZZSuiteTeardownTests`
/// (`testSharedDefaultsSeamIsNotLeftOnTheProductionDomain`), which runs
/// last and therefore sees whatever the rest of the suite left behind.
///
/// ## The scanner is itself guarded (ID-REVIEW-1024 review, 2026-10-23)
///
/// Guard 4 is a SOURCE SCAN, and a source scan is only as good as the
/// spellings it knows. The first version of this guard matched the
/// literal `.standard` only — so a file that reset the seam with
/// `UserDefaults.standard` (the same object, written out) was NOT
/// flagged: the mutation stayed green while the production domain was
/// wired in. The scanner now knows every spelling of the production
/// domain, and `testTheScannerCatchesEverySpellingOfTheProductionDomain`
/// is its positive control: it feeds the scanner the spellings it must
/// catch, so "the scanner would have caught it" is an assertion and not a
/// claim.
final class SeamBaselineIsolationTests: XCTestCase {

    // MARK: - The production branch is unchanged

    /// The seam's production behaviour must stay exactly what it was:
    /// `.standard`. A test that only proves "the test branch is hermetic"
    /// would still pass if the production branch had been moved to an
    /// isolated suite — which would silently break the shipping app.
    func testProductionBranchStillUsesTheStandardDefaults() {
        let production = TestIsolation.defaultsFor(isTestProcess: false)
        XCTAssertTrue(
            production === UserDefaults.standard,
            "ID-CRASH-0066: the production branch of the seam must still be `.standard`"
        )
    }

    /// The test branch must not be `.standard` and must not address the
    /// production domain by any of the domain-level discriminators
    /// (`addressesProductionDomain` also compares the data blobs, so an
    /// isolated suite that happens to hold a production-named key is still
    /// rejected).
    func testTestProcessBranchNeverAddressesTheProductionDomain() throws {
        let suite = TestIsolation.defaultsFor(isTestProcess: true)
        XCTAssertFalse(
            suite === UserDefaults.standard,
            "ID-CRASH-0066: the test branch of the seam must not be `.standard`"
        )
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(suite),
            "ID-CRASH-0066: the test branch of the seam must not address the production domain"
        )
    }

    // MARK: - The live seam

    /// The BASELINE — the value the seam starts on — must not address the
    /// production domain.
    ///
    /// This is the DETERMINISTIC guard: `TestIsolation.defaults` is
    /// mutable and every test class that touches the seam reassigns it,
    /// so asserting on it says something about whose test ran last. The
    /// baseline is immutable, so this assertion cannot be satisfied by
    /// accident.
    func testTheBaselineNeverAddressesTheProductionDomain() {
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(TestIsolation.baselineDefaults),
            "ID-CRASH-0066: the seam's baseline points at the production domain — "
            + "every test that forgot to inject a suite would write the user's real settings"
        )
    }

    /// Whatever the suite did before this class ran, the live seam must
    /// not be pointing at the production domain.
    ///
    /// This one is ORDER-DEPENDENT by nature: the seam is mutable, so the
    /// value seen here is whatever the previously-run class left behind.
    /// It is kept because it catches the specific historical failure
    /// (a `tearDown` that reset the seam to `.standard`), but it is the
    /// baseline guard above — not this one — that pins the contract.
    func testTheLiveSeamDoesNotAddressTheProductionDomain() {
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(TestIsolation.defaults),
            "ID-CRASH-0066: the live seam is pointing at the production domain — "
            + "some test class reset it to `.standard` instead of restoring the value it saved"
        )
    }

    // MARK: - No source file may reset the seam to the production domain

    /// The owners of the shared storage. The needle is built at runtime
    /// from these names so that this file does not itself contain the
    /// pattern it forbids.
    private static let seamOwners = [
        "LanguageManager",
        "UpdateService",
        "WindowManager",
        "TestIsolation"
    ]

    /// Escape hatch, empty on purpose. A file may only be listed here
    /// with a written justification in the commit that adds it — the
    /// point of the guard is that "reset to the production domain" is
    /// never a casual thing to do.
    private static let allowedFiles: Set<String> = []

    /// The production domain, however it is spelled.
    ///
    /// * `.standard` — the usual shorthand.
    /// * `UserDefaults.standard` — the SAME object, written out.
    /// * `UserDefaults . standard` — the same, with spaces.
    ///
    /// A scanner that knows only the shorthand is a scanner that knows
    /// one spelling: the mutation that writes the long form keeps the
    /// production domain wired in and keeps the suite green.
    ///
    /// What it does NOT cover (and cannot, statically): a value that
    /// arrives through a local alias (`let std = UserDefaults.standard`)
    /// or through a `UserDefaults(suiteName:)` call. The latter cannot
    /// even address the app's own domain from inside the app / test-host
    /// process — measured: `UserDefaults(suiteName: <own bundle id>)`
    /// returns nil there (see `TestIsolation.addressesProductionDomain`).
    private static let productionDomainValue = "(?:\\.standard|UserDefaults\\s*\\.\\s*standard)"

    /// The patterns the scan looks for.
    ///
    /// `\s*` spans newlines in the ICU dialect, so an assignment whose
    /// value sits on the NEXT line is matched too.
    private static var seamPatterns: [String] {
        var patterns: [String] = []
        for owner in seamOwners {
            patterns.append("\(owner)\\.defaults\\s*=\\s*\(productionDomainValue)")
            patterns.append("\(owner)\\.setDefaults\\(\\s*\(productionDomainValue)")
        }
        return patterns
    }

    /// Scans every Swift file in the repository for an assignment of the
    /// production domain to one of the seam forwarders (or to
    /// `TestIsolation.defaults` / `TestIsolation.setDefaults`).
    ///
    /// Only CODE is matched: a line whose match is preceded by `//` is a
    /// comment and is ignored. Same rule as the `nonisolated(unsafe)`
    /// roster guard in `IsolationSeamConsolidationTests`, so "declaration"
    /// means the same thing in both guards.
    func testNoSourceFileResetsTheSeamToTheProductionDomain() throws {
        var offenders: [String] = []
        for root in ["Tests/ClipMemoryTests", "ClipMemory"] {
            let directory = Self.repoRoot.appendingPathComponent(root)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath = Self.relativePath(of: url, root: Self.repoRoot)
                if Self.allowedFiles.contains(relativePath) { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                let hits = Self.codeLines(matchingAnyOf: Self.seamPatterns, in: source)
                if !hits.isEmpty {
                    offenders.append("\(relativePath):\(hits.map(String.init).joined(separator: ","))")
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "ID-CRASH-0066: the shared seam must never be reset to the production domain — "
            + "restore the value you saved in `setUp` instead. Offending files: \(offenders)"
        )
    }

    // MARK: - The scanner's own positive control

    /// The spellings the scanner must catch.
    ///
    /// The samples are ASSEMBLED at runtime, not written out: a literal
    /// `"LanguageManager.defaults = .standard"` in this file would be
    /// flagged by the scan above — the guard file must not contain the
    /// pattern it forbids. Same convention as `seamOwners`.
    private static var samplesToCatch: [String] {
        let shorthands = [".standard", "UserDefaults.standard", "UserDefaults . standard"]
        var samples: [String] = []
        for owner in seamOwners {
            for shorthand in shorthands {
                samples.append("\(owner).defaults = \(shorthand)")
                samples.append("\(owner).setDefaults(\(shorthand))")
            }
        }
        // The value on the NEXT line.
        samples.append("\(seamOwners[0]).defaults =\n    \(shorthands[1])")
        return samples
    }

    /// Every spelling of the production domain must be caught.
    ///
    /// This is the control for the guard above: it feeds the scanner the
    /// exact lines a reset would look like. If the scanner's pattern set
    /// ever narrows again, this goes red — instead of the guard above
    /// quietly stopping to see the mutation.
    func testTheScannerCatchesEverySpellingOfTheProductionDomain() {
        for sample in Self.samplesToCatch {
            XCTAssertFalse(
                Self.codeLines(matchingAnyOf: Self.seamPatterns, in: sample).isEmpty,
                "the scanner must flag a seam reset written as: \(sample)"
            )
        }
    }

    /// …and it must NOT flag code that merely mentions the production
    /// domain, or that assigns an unrelated `defaults` property.
    func testTheScannerIgnoresCommentsAndUnrelatedCode() {
        let mustNotCatch = [
            "// LanguageManager.defaults = UserDefaults.standard",
            "// UpdateService.setDefaults(.standard)",
            "let defaults: UserDefaults = .standard",
            "private let defaults: UserDefaults = .standard",
            "someOtherService.defaults = .standard",
            "TestIsolation.setDefaults(isolatedSuite)"
        ]
        for sample in mustNotCatch {
            XCTAssertTrue(
                Self.codeLines(matchingAnyOf: Self.seamPatterns, in: sample).isEmpty,
                "the scanner must not flag: \(sample)"
            )
        }
    }

    /// The relative-path helper must survive a root that is a SYMLINK.
    ///
    /// This is the failure the guard's message would have shown: the
    /// repository root comes from `#filePath` (the compile-time path,
    /// e.g. `/tmp/whatever`) while the file enumerator hands out
    /// resolved paths (`/private/tmp/whatever`). Comparing the raw
    /// strings fails, and the failure message ends up carrying an
    /// absolute path instead of the file the reader has to open.
    func testRelativePathsSurviveASymlinkedRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeamRelativePath-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        // The root as `#filePath` would give it: the symlink itself.
        // The file as the enumerator would give it: the resolved path.
        let file = real.appendingPathComponent("sub/File.swift")
        XCTAssertEqual(
            Self.relativePath(of: file, root: link),
            "sub/File.swift",
            "the relative path must be computed across the symlink boundary"
        )
    }

    // MARK: - Helpers

    /// Repository root, computed from this file's own location
    /// (`Tests/ClipMemoryTests/SeamBaselineIsolationTests.swift`).
    ///
    /// The path is resolved through symlinks, because the file
    /// enumerator hands out resolved paths: on macOS a checkout under
    /// `/tmp` is really `/private/tmp`, and comparing the two raw
    /// strings would silently fail to produce a relative path — the
    /// failure message would then carry a mangled absolute path
    /// instead of the file the reader needs to open.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .resolvingSymlinksInPath()
    }()

    /// The path of `url` relative to the repository root.
    ///
    /// Both sides go through `resolvingSymlinksInPath()`, because the
    /// two sides can disagree: `#filePath` (the root) is the compile-time
    /// path — `/tmp/whatever` — while the file enumerator hands out
    /// resolved paths — `/private/tmp/whatever`. Comparing the raw
    /// strings would fail to produce a relative path, and the failure
    /// message would carry a mangled absolute path instead of the file
    /// the reader needs to open.
    ///
    /// Falls back to the absolute path when the file is outside the
    /// root, so a mismatch is visible rather than silently mangled.
    static func relativePath(of url: URL, root: URL) -> String {
        let filePath = url.resolvingSymlinksInPath().path
        let rootPath = root.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /// 1-based line numbers where one of `patterns` matches CODE — i.e.
    /// with no `//` before the match on the line the match starts on.
    ///
    /// The scan runs over the WHOLE source, not line by line, so an
    /// assignment whose value sits on the next line is matched too. A
    /// match that starts on a comment line is ignored.
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
}
