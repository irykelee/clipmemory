import XCTest
@testable import ClipMemory

/// ID-CRASH-0064 (2026-10-23): guards for the test-isolation seam
/// consolidation (ID-CRASH-0029) and for the `nonisolated(unsafe)` roster
/// in `docs/SWIFT6_MIGRATION.md` §8.
///
/// The `UserDefaults` seam used to be five independent globals — three
/// `defaults` storages (`WindowManager` / `LanguageManager` /
/// `UpdateService`) plus two `injectedForTest` mirrors. It is now ONE
/// storage (`TestIsolation.defaults`) behind three forwarders.
///
/// The failure mode this file exists to catch is the one the consolidation
/// was supposed to prevent: a forwarder that quietly stops reading the
/// canonical storage (degenerating into "always `.standard`"). That would
/// send every test's writes back into the production `com.clipmemory.app`
/// domain while the suite still looked green.
///
/// Every assertion below is written so that it CAN fail:
/// * the identity assertions fail if any forwarder keeps its own storage;
/// * the read-path assertions fail if the seam ever answers `.standard`;
/// * the write-path assertions fail if a service bypasses the seam;
/// * the roster guard fails if the documented count drifts from reality.
final class IsolationSeamConsolidationTests: XCTestCase {

    // MARK: - Fixtures

    /// Repository root, computed from this file's own location
    /// (`Tests/ClipMemoryTests/IsolationSeamConsolidationTests.swift`).
    /// Same pattern as `ReleaseReadinessTests`.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }()

    /// Fixed suite names (not random) so the preferences plist is reused
    /// and cleaned in place. The scheme runs with `parallelizable = NO`,
    /// so there is no cross-process race on the suite name.
    private enum SuiteName {
        static let first = "IsolationSeamConsolidation-A"
        static let second = "IsolationSeamConsolidation-B"
    }

    /// The seam value in force before this test ran. The suite bootstrap
    /// (`AAASuiteBootstrapTests`) points it at the
    /// "LanguageManager-test-isolation" suite — NOT `.standard` — so the
    /// restore must put back the EXACT previous instance. Restoring
    /// `.standard` instead would silently re-point every later test at the
    /// production domain, which is exactly the pollution class this task
    /// is about.
    private var savedSeam: UserDefaults!

    override func setUp() {
        super.setUp()
        savedSeam = TestIsolation.defaults
        for name in [SuiteName.first, SuiteName.second] {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
    }

    override func tearDown() {
        TestIsolation.defaults = savedSeam
        savedSeam = nil
        super.tearDown()
    }

    // MARK: - One storage behind three forwarders

    /// The canonical storage is reachable — and reachable ONLY — through
    /// the three service forwarders. Writing through any entry point must
    /// be visible through all of them.
    ///
    /// Falsifiable: a forwarder that kept its own storage (or that
    /// hard-coded `.standard`) breaks the cross-checks below.
    func testAllServiceDefaultsForwardersShareTheCanonicalStorage() throws {
        let first = try makeSuite(SuiteName.first)
        let second = try makeSuite(SuiteName.second)
        XCTAssertFalse(first === UserDefaults.standard)
        XCTAssertFalse(first === second)

        // Write through the canonical entry point…
        TestIsolation.setDefaults(first)
        XCTAssertTrue(WindowManager.defaults === first)
        XCTAssertTrue(LanguageManager.defaults === first)
        XCTAssertTrue(UpdateService.defaults === first)

        // …then through each forwarder in turn: the storage is ONE, so
        // every write is visible through every reader.
        WindowManager.defaults = second
        XCTAssertTrue(TestIsolation.defaults === second)
        XCTAssertTrue(LanguageManager.defaults === second)
        XCTAssertTrue(UpdateService.defaults === second)

        LanguageManager.defaults = first
        XCTAssertTrue(TestIsolation.defaults === first)
        XCTAssertTrue(UpdateService.defaults === first)
        XCTAssertTrue(WindowManager.defaults === first)

        UpdateService.defaults = second
        XCTAssertTrue(TestIsolation.defaults === second)
        XCTAssertTrue(WindowManager.defaults === second)
        XCTAssertTrue(LanguageManager.defaults === second)
    }

    /// The per-service forwarders are the SAME storage — proven in the
    /// direction the tests actually use: assign through one service, read
    /// through the others.
    func testAssigningThroughOneForwarderIsVisibleThroughTheOthers() throws {
        let suite = try makeSuite(SuiteName.first)

        WindowManager.defaults = suite
        XCTAssertTrue(TestIsolation.defaults === suite)
        XCTAssertTrue(LanguageManager.defaults === suite)
        XCTAssertTrue(UpdateService.defaults === suite)

        UpdateService.defaults = suite
        XCTAssertTrue(TestIsolation.defaults === suite)
        XCTAssertTrue(LanguageManager.defaults === suite)
        XCTAssertTrue(WindowManager.defaults === suite)

        LanguageManager.defaults = suite
        XCTAssertTrue(TestIsolation.defaults === suite)
        XCTAssertTrue(UpdateService.defaults === suite)
        XCTAssertTrue(WindowManager.defaults === suite)
    }

    // MARK: - The services really READ the injected suite

    /// `LanguageManager.shared` must read the INJECTED suite, not
    /// `.standard`. The sentinel language exists only in the injected
    /// suite, so a seam that answered `.standard` would surface the
    /// production language instead and fail this assertion.
    @MainActor
    func testLanguageManagerReadsTheInjectedSuiteNotTheProductionDomain() throws {
        let suite = try makeSuite(SuiteName.first)
        let sentinel = "zz-seam-sentinel"
        suite.set(sentinel, forKey: UserDefaultsKey.appLanguage.rawValue)
        TestIsolation.setDefaults(suite)

        XCTAssertEqual(LanguageManager.shared.selectedLanguage, sentinel)
        XCTAssertNotEqual(
            LanguageManager.shared.selectedLanguage,
            UserDefaults.standard.string(forKey: UserDefaultsKey.appLanguage.rawValue)
        )
    }

    /// `UpdateService.feedPolicy` must read the INJECTED suite. The
    /// production domain carries a policy of its own, so a `.standard`
    /// answer would differ from the seeded value.
    func testUpdateServiceReadsTheInjectedSuiteNotTheProductionDomain() throws {
        let suite = try makeSuite(SuiteName.first)
        suite.set(UpdateFeedPolicy.primary.rawValue, forKey: UserDefaultsKey.updateFeedPolicy.rawValue)
        TestIsolation.setDefaults(suite)

        XCTAssertEqual(UpdateService.feedPolicy, .primary)
    }

    // MARK: - The services really WRITE through the seam

    /// Writing a language through `LanguageManager.shared` must land in
    /// the injected suite and leave the production domain byte-identical.
    @MainActor
    func testLanguageManagerWritesOnlyIntoTheInjectedSuite() throws {
        let suite = try makeSuite(SuiteName.first)
        TestIsolation.setDefaults(suite)

        let productionBefore = UserDefaults.standard.string(forKey: UserDefaultsKey.appLanguage.rawValue)
        let manager = LanguageManager.shared
        let original = manager.selectedLanguage
        defer { manager.selectedLanguage = original }

        manager.selectedLanguage = "ko"

        XCTAssertEqual(suite.string(forKey: UserDefaultsKey.appLanguage.rawValue), "ko")
        XCTAssertEqual(suite.stringArray(forKey: UserDefaultsKey.appleLanguages.rawValue)?.first, "ko")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: UserDefaultsKey.appLanguage.rawValue),
            productionBefore
        )
    }

    /// Writing the fallback-feed consent through `UpdateService` must
    /// land in the injected suite and leave the production domain alone.
    func testUpdateServiceWritesOnlyIntoTheInjectedSuite() throws {
        let suite = try makeSuite(SuiteName.first)
        TestIsolation.setDefaults(suite)

        let productionBefore = UserDefaults.standard.object(forKey: UserDefaultsKey.updateFallbackFeedConsent.rawValue) as? Bool
        UpdateService.fallbackFeedConsent = true

        XCTAssertEqual(suite.object(forKey: UserDefaultsKey.updateFallbackFeedConsent.rawValue) as? Bool, true)
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: UserDefaultsKey.updateFallbackFeedConsent.rawValue) as? Bool,
            productionBefore
        )
    }

    // MARK: - The probe stays single-source

    /// The "is this a test process?" probe has one home. A service that
    /// READS `XCTestConfigurationFilePath` on its own would re-introduce
    /// the second copy the consolidation removed — and the weaker one.
    ///
    /// The check uses the same "declaration vs mention" rule as the §8
    /// roster: a comment that merely names the variable does not count.
    func testOwnedServiceFilesDoNotReintroduceTheirOwnXcTestProbe() throws {
        for relativePath in [
            "ClipMemory/Services/UpdateService.swift",
            "ClipMemory/Services/LanguageManager.swift",
            "ClipMemory/Services/WindowManager.swift"
        ] {
            let url = Self.repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            let hits = Self.codeLines(containing: "XCTestConfigurationFilePath", in: source)
            XCTAssertTrue(
                hits.isEmpty,
                "\(relativePath) re-introduced a private XCTest probe at line(s) \(hits) — use TestIsolation.isRunningTests"
            )
        }
    }

    /// The canonical probe must still exist, otherwise the guard above
    /// would pass for the wrong reason.
    func testTheCanonicalProbeStillExists() throws {
        let url = Self.repoRoot.appendingPathComponent("ClipMemory/Utils/TestIsolation.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("XCTestConfigurationFilePath"))
        XCTAssertTrue(source.contains("isRunningTests"))
    }

    // MARK: - The roster in §8 matches reality

    /// `docs/SWIFT6_MIGRATION.md` §8 states how many
    /// `nonisolated(unsafe)` declarations the production code carries.
    /// A stale count tells the next reader the concurrency debt is
    /// smaller than it is — the exact drift this task was raised for.
    func testDocumentedRosterCountMatchesTheMeasuredDeclarationCount() throws {
        let docURL = Self.repoRoot.appendingPathComponent("docs/SWIFT6_MIGRATION.md")
        let doc = try String(contentsOf: docURL, encoding: .utf8)
        guard let documented = Self.documentedDeclarationCount(in: doc) else {
            XCTFail("docs/SWIFT6_MIGRATION.md is missing the '<!-- nonisolated-unsafe-declaration-count: N -->' marker")
            return
        }

        let measured = try Self.countDeclarations(
            inProductionSources: Self.repoRoot.appendingPathComponent("ClipMemory")
        )
        XCTAssertEqual(
            measured,
            documented,
            "docs/SWIFT6_MIGRATION.md §8 claims \(documented) declarations; the code carries \(measured)"
        )
    }

    /// The roster's LINE NUMBERS must still point at the declarations
    /// they claim to.
    ///
    /// ID-REVIEW-1024 review (2026-10-23): the count was enforced, the
    /// snapshot was not — and the snapshot went stale within a day of
    /// being taken (ID-CRASH-0066 moved the canonical seam's
    /// declaration from line 50 to line 84 while the roster still said
    /// 50). A roster row that points at a line which no longer holds
    /// the declaration sends the next reader to the wrong place, which
    /// is the same failure the count guard was raised for.
    ///
    /// The documented raw output must therefore list EXACTLY the measured
    /// declarations — same files, same line numbers. When a file moves,
    /// the roster is refreshed in the same commit.
    func testDocumentedRosterLineNumbersStillPointAtTheirDeclarations() throws {
        let docURL = Self.repoRoot.appendingPathComponent("docs/SWIFT6_MIGRATION.md")
        let doc = try String(contentsOf: docURL, encoding: .utf8)

        let documented = Self.documentedRosterEntries(in: doc)
        XCTAssertFalse(
            documented.isEmpty,
            "docs/SWIFT6_MIGRATION.md §8 no longer carries a readable raw-output block"
        )

        let measured = try Self.measuredDeclarations(
            inProductionSources: Self.repoRoot.appendingPathComponent("ClipMemory")
        )
        XCTAssertEqual(
            Set(documented.map { "\($0.path):\($0.line)" }),
            Set(measured.map { "\($0.path):\($0.line)" }),
            "docs/SWIFT6_MIGRATION.md §8's raw output no longer matches the code — "
            + "refresh the roster in the same commit that moved the declarations"
        )
    }

    // MARK: - Helpers

    /// A `UserDefaults` suite for the given name, guaranteed not to be
    /// `.standard` (a suite named after the app's own bundle id would be
    /// rejected by Foundation and silently degrade to `.standard`).
    private func makeSuite(_ name: String) throws -> UserDefaults {
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertFalse(suite === UserDefaults.standard)
        return suite
    }

    /// Counts `nonisolated(unsafe)` DECLARATIONS.
    ///
    /// A declaration is a line where the keyword appears with no `//`
    /// before it. A comment that merely MENTIONS the keyword does not
    /// count — the roster is a list of declarations, not of mentions.
    private static func countDeclarations(inProductionSources root: URL) throws -> Int {
        let fileManager = FileManager.default
        let enumerator = try XCTUnwrap(fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))

        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            count += codeLines(containing: "nonisolated(unsafe)", in: source).count
        }
        return count
    }

    /// 1-based line numbers where `needle` appears in CODE — i.e. with no
    /// `//` before it on that line. A comment that merely names the text
    /// does not count. Same rule as the §8 roster, so the two can never
    /// disagree about what a "declaration" is.
    private static func codeLines(containing needle: String, in source: String) -> [Int] {
        var hits: [Int] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: needle) else { continue }
            let prefix = line[line.startIndex..<range.lowerBound]
            guard !prefix.contains("//") else { continue }
            hits.append(index + 1)
        }
        return hits
    }

    /// Reads the machine-readable count marker out of §8.
    ///
    /// The marker may appear more than once (the prose describes it), so
    /// every occurrence is scanned and the first one that parses as a
    /// number wins.
    private static func documentedDeclarationCount(in doc: String) -> Int? {
        let marker = "<!-- nonisolated-unsafe-declaration-count:"
        var searchStart = doc.startIndex
        while let markerRange = doc.range(of: marker, range: searchStart..<doc.endIndex) {
            let tail = doc[markerRange.upperBound...]
            let digits = tail.drop(while: { $0 == " " || $0 == "\t" }).prefix { $0.isNumber }
            if let count = Int(digits) { return count }
            searchStart = markerRange.upperBound
        }
        return nil
    }

    /// The `(path, line)` pairs listed in §8's raw-output block.
    ///
    /// The block is the one right after the "Raw output on …" line; every
    /// entry has the shape `path:line:    code`.
    private static func documentedRosterEntries(in doc: String) -> [(path: String, line: Int)] {
        guard let anchor = doc.range(of: "Raw output on") else { return [] }
        guard let fenceStart = doc.range(of: "```", range: anchor.upperBound..<doc.endIndex) else { return [] }
        guard let fenceEnd = doc.range(of: "```", range: fenceStart.upperBound..<doc.endIndex) else { return [] }

        var entries: [(path: String, line: Int)] = []
        for rawLine in doc[fenceStart.upperBound..<fenceEnd.lowerBound].split(separator: "\n") {
            let parts = rawLine.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path = parts[0].trimmingCharacters(in: .whitespaces)
            guard path.hasSuffix(".swift") else { continue }
            guard let line = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            entries.append((path, line))
        }
        return entries
    }

    /// Every `nonisolated(unsafe)` declaration under `root`, with the
    /// path relative to `root` (the shape §8's raw output uses).
    private static func measuredDeclarations(
        inProductionSources root: URL
    ) throws -> [(path: String, line: Int)] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var entries: [(path: String, line: Int)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for line in codeLines(containing: "nonisolated(unsafe)", in: source) {
                entries.append((relative, line))
            }
        }
        return entries
    }
}
