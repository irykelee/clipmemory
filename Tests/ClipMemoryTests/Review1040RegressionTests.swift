import XCTest
@testable import ClipMemory

/// ID-REVIEW-1040 (2026-10-27): the test suite left a `UserDefaults` plist
/// file on the developer's machine for **every** suite it created.
///
/// ## The defect (measured)
///
/// `removePersistentDomain(forName:)` clears a suite's values but leaves
/// `~/Library/Preferences/<suite>.plist` on disk — a ~42-byte empty shell
/// that still occupies a whole 4 KB block. Measured on the developer's
/// machine:
///
/// | item | measured |
/// |---|---|
/// | leftover `*.plist` files in `~/Library/Preferences` | **199 536** |
/// | their disk footprint (4 KB blocks) | **819 MB** (the bytes are only 21.8 MB) |
/// | added by ONE full test run | **339** |
/// | content of a sampled leftover | `{}` — an empty shell, no data |
///
/// Every suite-creating site leaked, whether or not it called
/// `removePersistentDomain` — because the **file** was never touched.
///
/// ## The fix
///
/// `TestSuiteCleanup` destroys a suite's **file** (not only its values),
/// every suite creation goes through it — so every suite this process
/// creates is **registered** — and a process-end sweep destroys whatever a
/// crashed or forgetful test left behind.
///
/// ## What this file guards
///
/// 1. The **behaviour**: destroying a suite must take its file with it, and
///    the file must not come back.
/// 2. The **static shape**: no test source may create a `test-…` suite
///    behind the helper's back — a suite created outside the helper is
///    invisible to the process-end sweep, and its plist file leaks.
final class Review1040RegressionTests: XCTestCase {

    // MARK: - The behaviour: destroying a suite takes its FILE with it

    /// Destroying a suite must remove its plist file, not only its values.
    ///
    /// This is the direct regression test for the defect: the old
    /// `removeTestDefaults` called `removePersistentDomain` only, and the
    /// file survived every single time.
    func testDestroyingASuiteRemovesItsPreferencesFile() {
        let suiteName = "Review1040-\(UUID().uuidString)"
        let defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        defaults.set("value", forKey: "k")
        defaults.synchronize()

        XCTAssertTrue(
            Self.waitForPreferencesFile(suiteName),
            "the suite must have a file on disk before it is destroyed — otherwise "
            + "this test would pass vacuously"
        )

        TestSuiteCleanup.destroy(suiteName: suiteName)

        XCTAssertFalse(
            TestSuiteCleanup.hasPreferencesFile(for: suiteName),
            "ID-REVIEW-1040: destroying a suite must remove its plist FILE, not only "
            + "its values — removing the domain alone leaves an empty shell behind "
            + "(measured: 199 536 of them, 819 MB on the developer's machine)"
        )
    }

    /// The destroyed file must not come back.
    ///
    /// `cfprefsd` writes a domain back to disk when the domain carries a
    /// **pending write** — and `removePersistentDomain` is exactly such a
    /// write (measured: 5/40 empty shells came back). `TestSuiteCleanup
    /// .destroy` uses `removeSuite` + an explicit file delete instead, which
    /// measured 0/40. This test pins that observable consequence, so a
    /// future "simplification" that swaps the order turns red.
    func testADestroyedSuiteFileDoesNotComeBack() {
        let suiteName = "Review1040-\(UUID().uuidString)"
        let defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        defaults.set("value", forKey: "k")
        defaults.synchronize()
        XCTAssertTrue(Self.waitForPreferencesFile(suiteName))

        TestSuiteCleanup.destroy(suiteName: suiteName)
        XCTAssertFalse(TestSuiteCleanup.hasPreferencesFile(for: suiteName))

        // Give cfprefsd a moment to (not) rewrite the file.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(
            TestSuiteCleanup.hasPreferencesFile(for: suiteName),
            "ID-REVIEW-1040: the destroyed file must stay destroyed — a suite that "
            + "still carries a pending write is written back by cfprefsd "
            + "(measured: 5/40 with `removePersistentDomain`, 0/40 with `removeSuite`)"
        )
    }

    /// `makeTestDefaults` — the factory ~30 test files use — must destroy
    /// the file as well.
    func testTheSharedFactoryDestroysTheFileToo() {
        let defaults = makeTestDefaults()
        defaults.set("value", forKey: "k")
        defaults.synchronize()
        let suiteName = Self.suiteName(of: defaults)
        XCTAssertNotNil(
            suiteName,
            "the factory must register the suite, otherwise nobody can find its name"
        )
        XCTAssertTrue(Self.waitForPreferencesFile(suiteName!))

        removeTestDefaults(defaults)

        XCTAssertFalse(
            TestSuiteCleanup.hasPreferencesFile(for: suiteName!),
            "ID-REVIEW-1040: `removeTestDefaults` must take the plist file with it"
        )
    }

    // MARK: - The behaviour: the process-end sweep

    /// A suite this process created must be findable by the sweep.
    ///
    /// The sweep is the safety net for the two ways a suite escapes a
    /// precise cleanup: a test that never destroys it, and a host that dies
    /// before its `tearDown` runs (this repo has been bitten by that twice
    /// — CI run 40186263416).
    func testTheProcessEndSweepFindsAndDestroysRegisteredSuites() {
        let suiteName = "Review1040-\(UUID().uuidString)"
        let defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        defaults.set("value", forKey: "k")
        defaults.synchronize()
        XCTAssertTrue(Self.waitForPreferencesFile(suiteName))

        XCTAssertTrue(
            TestSuiteCleanup.registeredSuiteNames.contains(suiteName),
            "a suite created through the helper must be registered for the sweep"
        )

        TestSuiteCleanup.destroyAllRegistered()

        XCTAssertFalse(
            TestSuiteCleanup.hasPreferencesFile(for: suiteName),
            "the sweep must destroy the FILE of every registered suite"
        )
        XCTAssertFalse(
            TestSuiteCleanup.registeredSuiteNames.contains(suiteName),
            "a destroyed suite must not stay registered"
        )
    }

    /// The sweep must also catch a suite whose file came BACK after its
    /// own destroy.
    ///
    /// A suite destroyed mid-run can still have its file written back
    /// afterwards (measured: ~1 in 8 with `removePersistentDomain`). The
    /// final pass deletes the file of every suite the process ever created,
    /// so a late write-back cannot survive the run.
    func testTheFinalPassDeletesAFileThatCameBack() {
        let suiteName = "Review1040-\(UUID().uuidString)"
        let defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        defaults.set("value", forKey: "k")
        defaults.synchronize()
        XCTAssertTrue(Self.waitForPreferencesFile(suiteName))

        TestSuiteCleanup.destroy(suiteName: suiteName)
        XCTAssertFalse(TestSuiteCleanup.hasPreferencesFile(for: suiteName))

        // Simulate the late write-back cfprefsd can do.
        let resurrected = try? Data("{}".utf8).write(to: TestSuiteCleanup.preferencesFileURL(for: suiteName))
        XCTAssertNotNil(resurrected, "the fixture must be able to re-create the file")

        TestSuiteCleanup.deleteAllCreatedFiles()

        XCTAssertFalse(
            TestSuiteCleanup.hasPreferencesFile(for: suiteName),
            "the final pass must delete the file of every suite the process created"
        )
    }

    /// The sweep that ACTUALLY runs must destroy what a test case left.
    ///
    /// `testBundleWillFinish` is never called in this repo's app-hosted test
    /// host (measured 2026-10-27: the bundle-level observer's body never
    /// ran through a full 1294-test run), so the cleanup that keeps the
    /// preferences directory from growing is the **per-test-case** one. This
    /// test pins what it does.
    func testThePerCaseSweepDestroysWhatTheCaseLeftBehind() {
        let suiteName = "Review1040-\(UUID().uuidString)"
        let defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        defaults.set("value", forKey: "k")
        defaults.synchronize()
        XCTAssertTrue(Self.waitForPreferencesFile(suiteName))

        // Exactly what the observer does when the test case ends.
        TestSuiteCleanup.endTestCase()

        XCTAssertFalse(
            TestSuiteCleanup.hasPreferencesFile(for: suiteName),
            "ID-REVIEW-1040: the per-test-case sweep must destroy the file of every "
            + "suite the process holds — a suite created and never destroyed is "
            + "what leaked 199 536 files"
        )
    }

    // MARK: - The observer WIRING (not just the functions it calls)

    /// The suite a previous test case leaves behind, for the wiring test.
    ///
    /// XCTest runs the methods of a class in alphabetical order, so the
    /// `testA…` method runs before the `testB…` method — the same ordering
    /// the repo's own `AAASuiteBootstrapTests` relies on ("Runs first in the
    /// suite (alphabetically before every other test class)").
    private static var observerProbeSuiteName: String?

    /// Leaves a suite behind for the NEXT test case.
    ///
    /// The suite is created and written but **not** destroyed — only the
    /// per-case observer can clean it up. `testB…` proves it did.
    func testATheObserverProbeSuiteIsLeftBehind() {
        let suiteName = "Review1040-observer-\(UUID().uuidString)"
        let defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        defaults.set("value", forKey: "k")
        defaults.synchronize()
        XCTAssertTrue(Self.waitForPreferencesFile(suiteName))
        Self.observerProbeSuiteName = suiteName
    }

    /// …and the next test case proves the OBSERVER cleaned it up.
    ///
    /// This is the test that pins the **wiring**, not just the function:
    /// deleting `addTestObserver(TestCaseScopeObserver())` leaves every
    /// other test green (the independent verifier found that hole), because
    /// `testThePerCaseSweepDestroysWhatTheCaseLeftBehind` calls
    /// `endTestCase()` **directly** and never goes through the observer.
    func testBTheObserverDestroyedTheSuiteThePreviousCaseLeft() throws {
        let suiteName = try XCTUnwrap(
            Self.observerProbeSuiteName,
            "the previous test case must have left a suite behind — "
            + "otherwise this test proves nothing"
        )
        XCTAssertFalse(
            TestSuiteCleanup.hasPreferencesFile(for: suiteName),
            "ID-REVIEW-1040: the per-case OBSERVER must destroy what the case "
            + "left behind — the observer's registration is the mechanism, and "
            + "calling `endTestCase()` directly does not prove it is wired"
        )
    }

    /// `destroy` must refuse the production domain.
    ///
    /// The test host IS the app (ID-REVIEW-1039), so
    /// `UserDefaults.standard` inside a test process addresses the user's
    /// real `com.clipmemory.app` preferences. `removeSuite` on that bundle
    /// id would delete them.
    func testDestroyRefusesTheProductionDomain() {
        XCTAssertFalse(
            TestSuiteCleanup.mayDestroy(suiteName: TestSuiteCleanup.productionDomainName),
            "the production domain must never be destroyable"
        )
        XCTAssertFalse(
            TestSuiteCleanup.mayDestroy(suiteName: Bundle.main.bundleIdentifier ?? ""),
            "the host's own bundle id must never be destroyable"
        )
        XCTAssertTrue(
            TestSuiteCleanup.mayDestroy(suiteName: "test-\(UUID().uuidString)"),
            "an ordinary test suite must be destroyable"
        )
    }

    // MARK: - The static guard: no suite is created behind the helper's back

    /// No test source may create a suite on its own.
    ///
    /// A suite created outside the helper is a suite nobody can destroy by
    /// name — so its file leaks, and the process-end sweep cannot see it
    /// either (it only knows the registered ones).
    ///
    /// The allowlist is a **count per file**, not a list of lines: a
    /// line-based allowlist breaks when an unrelated edit shifts a line, and
    /// a prefix-based one can be widened by accident. A count cannot.
    /// Adding one more bare suite creation to a listed file turns this red;
    /// converting one of them to the helper turns it red too (the count no
    /// longer matches — see `testTheAllowlistIsNotStale`).
    func testNoTestSourceCreatesASuiteWithoutTheHelper() throws {
        var offenders: [String] = []
        var stale: [String] = []
        var scanned = 0
        var helperSites = 0
        for url in try Self.testSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = TestSourceScanner.relativePath(of: url)
            let sites = Self.suiteCreationSites(in: source)
            scanned += sites.count
            helperSites += Self.helperCreationCount(in: source)
            let allowed = Self.allowedSuiteCreations[relative] ?? 0
            if sites.count > allowed {
                offenders.append(
                    "\(relative): \(sites.count) bare suite creations, \(allowed) allowed"
                    + " (lines \(sites.map { String($0.line) }.joined(separator: ", ")))"
                )
            } else if sites.count < allowed {
                stale.append("\(relative): \(sites.count) bare suite creations, \(allowed) allowed")
            }
        }

        XCTAssertGreaterThan(
            helperSites, 40,
            "ID-REVIEW-1040: only \(helperSites) sites create a suite through the "
            + "helper — the sweep can only cover the suites the helper knows about"
        )
        XCTAssertGreaterThan(
            scanned, 10,
            "ID-REVIEW-1040: the scan found only \(scanned) bare suite creations — "
            + "a scan that finds nothing passes vacuously"
        )
        XCTAssertTrue(
            offenders.isEmpty,
            "ID-REVIEW-1040: a suite must be created through "
            + "`TestSuiteCleanup.makeSuite(named:)` — a suite created directly is "
            + "invisible to the process-end sweep and its plist file leaks. "
            + "Offending files: \(offenders.joined(separator: "; "))"
        )
        XCTAssertTrue(
            stale.isEmpty,
            "ID-REVIEW-1040: the allowlist no longer matches the code — a listed "
            + "site was converted to the helper, so the allowlist entry must be "
            + "removed. Stale: \(stale.joined(separator: "; "))"
        )
    }

    /// The allowlist must not rot.
    ///
    /// An allowlist entry that no longer matches any site would silently
    /// stop protecting anything — and, worse, would let a NEW violation
    /// through if the site came back with different text.
    func testTheAllowlistIsNotStale() throws {
        var stale: [String] = []
        for (file, allowedCount) in Self.allowedSuiteCreations {
            let url = try Self.testSourceFiles().first { TestSourceScanner.relativePath(of: $0) == file }
            guard let url else {
                stale.append("\(file): the file no longer exists")
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let found = Self.suiteCreationSites(in: source).count
            if found != allowedCount {
                stale.append("\(file): expected \(allowedCount) bare creations, found \(found)")
            }
        }
        XCTAssertTrue(
            stale.isEmpty,
            "ID-REVIEW-1040: the allowlist no longer matches the code. "
            + "Stale: \(stale.joined(separator: "; "))"
        )
    }

    // MARK: - Static guard: only the shared-suite files may clear a domain

    /// Files allowed to call `removePersistentDomain`, and how many times.
    ///
    /// `removePersistentDomain` is the ONLY API that clears a suite's values
    /// in cfprefsd's memory — and it is exactly what queues the **pending
    /// write** that makes an empty shell land on disk (measured 5/40). So it
    /// is allowed only where it is genuinely needed:
    ///
    /// * `IsolationSeamConsolidationTests` (1) and `XCTestIsolationSuiteBootstrap` (1)
    ///   — the FIXED-NAME shared suites; the ZZZ guard reads them back with
    ///   `persistentDomain(forName:)`, so `removeSuite` would leave the old
    ///   values visible and the guard would misfire.
    /// * `TestHostIsolationTests` (1) — restores the shared
    ///   `ClipboardStore-XCTest-isolation` suite for the same reason.
    /// * `TestSuiteCleanup` (1) — `makeSuite` clears a name this process
    ///   already used, because `destroy` deliberately does not.
    ///
    /// ⚠️ A clear on a **fresh-UUID** suite is a no-op (such a suite cannot
    /// have a domain yet) and still queues a pending write ⇒ five such
    /// leftovers were removed 2026-10-27 (see ID-REVIEW-1040 follow-up).
    private static let allowedDomainClears: [String: Int] = [
        "IsolationSeamConsolidationTests.swift": 1,
        "TestHostIsolationTests.swift": 1,
        "TestSuiteCleanup.swift": 1,
        "XCTestIsolationSuiteBootstrap.swift": 1
    ]

    /// How many times `removePersistentDomain` is called in `source`.
    ///
    /// Counted on the BLANKED copy ⇒ a doc comment or a string literal
    /// mentioning the API is not a call.
    private static func domainClearSites(in source: String) -> Int {
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        return TestSourceScanner.occurrenceCount(of: "removePersistentDomain", in: blanked)
    }

    /// Every Swift file in the test tree **including** the helper.
    ///
    /// The helper itself clears a domain (`makeSuite` re-using a name), so
    /// this rule needs to see it — unlike the bare-creation rule, which
    /// excludes the one file allowed to create a suite.
    private static func filesIncludingHelper() throws -> [URL] {
        try TestSourceScanner.testSourceFiles(excluding: ["Review1040RegressionTests.swift"])
    }

    func testOnlyTheSharedSuiteFilesMayClearADomain() throws {
        var offenders: [String] = []
        for url in try Self.filesIncludingHelper() {
            let relative = TestSourceScanner.relativePath(of: url)
            let source = try String(contentsOf: url, encoding: .utf8)
            let found = Self.domainClearSites(in: source)
            let allowed = Self.allowedDomainClears[relative] ?? 0
            if found != allowed {
                offenders.append("\(relative): \(found) domain clear(s), allowed \(allowed)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "ID-REVIEW-1040: `removePersistentDomain` queues the pending write that "
            + "makes an empty shell land on disk; it is allowed only in the "
            + "shared-suite files. Offending files: \(offenders.joined(separator: "; "))"
        )
    }

    func testTheDomainClearAllowlistIsNotStale() throws {
        var stale: [String] = []
        for (file, allowedCount) in Self.allowedDomainClears {
            let url = try Self.filesIncludingHelper().first { TestSourceScanner.relativePath(of: $0) == file }
            guard let url else {
                stale.append("\(file): the file no longer exists")
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let found = Self.domainClearSites(in: source)
            if found != allowedCount {
                stale.append("\(file): expected \(allowedCount) domain clear(s), found \(found)")
            }
        }
        XCTAssertTrue(
            stale.isEmpty,
            "ID-REVIEW-1040: the domain-clear allowlist no longer matches the code. "
            + "Stale: \(stale.joined(separator: "; "))"
        )
    }

    /// The scanner must have teeth: a planted suite creation must be found.
    ///
    /// The sample is embedded in a MULTI-LINE context on purpose. A
    /// single-line sample would let a rule that only works at the end of a
    /// file pass by accident — the sample would match simply because it WAS
    /// the whole input. That is how the alias rule in
    /// `ProductionDomainWriteGuardTests` stayed broken for one round
    /// (measured 2026-10-27 by mutation M4).
    func testTheScannerFindsAPlantedSuiteCreation() {
        let planted = """
        func demo() {
            let suite = \(Self.userDefaultsCall)
            _ = suite
        }
        """
        XCTAssertFalse(
            Self.suiteCreationSites(in: planted).isEmpty,
            "the scanner must find a planted suite creation"
        )
    }

    /// …and it must NOT flag a comment or an unrelated call.
    func testTheScannerIgnoresCommentsAndUnrelatedCalls() {
        let mustNotCatch = [
            "// \(Self.userDefaultsCall)",
            "/// a doc comment mentioning \(Self.userDefaultsCall)",
            "let scale = UserDefaults.standard.double(forKey: \"fontScale\")",
            "let suite = FailingUserDefaults(suiteName: \"x\")!"
        ]
        for sample in mustNotCatch {
            XCTAssertTrue(
                Self.suiteCreationSites(in: sample).isEmpty,
                "the scanner must not flag: \(sample)"
            )
        }
    }

    // MARK: - Helpers

    /// The call the scanner looks for.
    ///
    /// Built from fragments because this file is itself scanned — a literal
    /// spelling would make the scan flag its own source.
    private static let userDefaultsCall = "UserDefaults" + "(suiteName: \"x\")"

    /// Sites that legitimately create a suite without the helper, and how
    /// many bare creations each of them may keep.
    ///
    /// Every one of them is a FIXED-NAME suite the shared isolation
    /// infrastructure owns, or a probe that must address the production
    /// domain on purpose. A per-test suite (UUID in its name) has no
    /// business being here.
    ///
    /// * `IsolationSeamConsolidationTests` (2) — clears and reads the two
    ///   fixed-name suites it consolidates.
    /// * `ProductionDataWriteGuardTests` (1) — probes the PRODUCTION domain
    ///   (`bundleId`). `removeSuite` on it would delete the user's real
    ///   preferences, so it must never go through the helper.
    /// * `ProductionDomainWriteGuardTests` — **0**: its decoy SOURCE STRING
    ///   (the production guard's own control group) lives inside a string
    ///   literal, and the scanner blanks string literals ⇒ not a call.
    /// * `Review1034RegressionTests` (4) — the fixed-name shared
    ///   ClipboardStore suite.
    /// * `Review1035RegressionTests` (3) — the fixed-name shared HotKey and
    ///   ClipboardStore suites.
    /// * `Review1037RegressionTests` (3) — the fixed-name shared suites the
    ///   guard's own test seeds.
    /// * `XCTestIsolationSuiteBootstrap` (2) — clears and reads the five
    ///   fixed-name shared suites.
    private static let allowedSuiteCreations: [String: Int] = [
        "IsolationSeamConsolidationTests.swift": 2,
        "ProductionDataWriteGuardTests.swift": 1,
        "Review1034RegressionTests.swift": 4,
        "Review1035RegressionTests.swift": 3,
        "Review1037RegressionTests.swift": 3,
        "XCTestIsolationSuiteBootstrap.swift": 2
    ]

    /// How many suites `source` creates through the helper.
    private static func helperCreationCount(in source: String) -> Int {
        source.components(separatedBy: "TestSuiteCleanup.makeSuite(named:").count - 1
    }

    /// Every Swift file in the test tree except this one and the helper.
    ///
    /// This file is excluded because it necessarily contains the patterns it
    /// looks for (the allowlist above spells them out); the helper is
    /// excluded because it is the one place that may call the API.
    private static func testSourceFiles() throws -> [URL] {
        try TestSourceScanner.testSourceFiles(excluding: [
            "Review1040RegressionTests.swift",
            "TestSuiteCleanup.swift"
        ])
    }

    /// Every suite-creation site in `source`, one entry per OCCURRENCE.
    ///
    /// Two sites on one line are TWO entries — counting distinct lines would
    /// let a second creation hide behind the first (the independent verifier
    /// found exactly that hole).
    ///
    /// The scan runs on a **blanked** copy of the source: comments (both
    /// `//` and `/* */`) and string literals are replaced by spaces, so
    ///
    /// * a doc comment mentioning `UserDefaults(suiteName:)` is not a call,
    /// * a `//` inside a string (e.g. `http://…`) does not hide a real call
    ///   that follows it on the same line,
    /// * a decoy source string (the production guard's own control group)
    ///   is not a call.
    ///
    /// Blanking preserves line structure, so a hit still knows its line.
    private static func suiteCreationSites(in source: String) -> [(line: Int, content: String)] {
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        let nsBlanked = blanked as NSString
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsBlanked.length)
        // `\b` before `UserDefaults` so a SUBCLASS call
        // (`FailingUserDefaults(suiteName:)`) is not mistaken for one.
        let pattern = "\\bUserDefaults\\s*(\\.\\s*init\\s*)?\\(\\s*suiteName\\s*:"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var sites: [(line: Int, content: String)] = []
        for match in regex.matches(in: blanked, range: fullRange) {
            let lineRange = nsBlanked.lineRange(for: NSRange(
                location: match.range.location,
                length: 0
            ))
            var number = 1
            for index in 0..<lineRange.location where nsBlanked.character(at: index) == 10 {
                number += 1
            }
            let contentRange = nsSource.lineRange(for: NSRange(
                location: match.range.location,
                length: 0
            ))
            let content = nsSource
                .substring(with: contentRange)
                .trimmingCharacters(in: .whitespaces)
            sites.append((line: number, content: content))
        }
        return sites
    }

    /// Replaces comments and string literals with spaces, keeping the line
    /// structure intact.
    ///
    /// A hand-rolled scanner is needed because the obvious shortcut — "skip
    /// a match whose line prefix contains `//`" — is wrong in both
    /// directions: a `//` inside a string literal (`http://…`) hides a real
    /// call on the same line, and a `/* … */` block comment is not filtered
    /// at all.
    /// The path of `url` relative to the test directory.
    ///
    /// Computed by path COMPONENT, not by string prefix: `FileManager
    /// .enumerator` resolves symlinks while `appendingPathComponent` does
    /// not, so a prefix replacement silently degrades in a symlinked
    /// checkout (measured 2026-10-27, ID-REVIEW-1039).
    /// The name of the suite `defaults` was created under, if it is known.
    private static func suiteName(of defaults: UserDefaults) -> String? {
        TestSuiteCleanup.registeredName(for: defaults)
    }

    /// Waits (briefly) for the suite's file to appear on disk.
    ///
    /// `cfprefsd` writes the file asynchronously, so a fixed sleep would
    /// be either flaky or slow; this polls instead.
    private static func waitForPreferencesFile(
        _ suiteName: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if TestSuiteCleanup.hasPreferencesFile(for: suiteName) { return true }
            usleep(20_000)
        }
        return TestSuiteCleanup.hasPreferencesFile(for: suiteName)
    }
}
