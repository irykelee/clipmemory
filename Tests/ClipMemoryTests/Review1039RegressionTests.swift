import XCTest
import SwiftUI
@testable import ClipMemory

/// ID-REVIEW-1039 (2026-10-27): the view tree had no `UserDefaults` seam,
/// so the snapshot tests had to plant their baseline into the PRODUCTION
/// domain to make the render deterministic.
///
/// ## The defect
///
/// The test bundle is injected into the APP binary (`TEST_HOST`), so
/// `UserDefaults.standard` inside a test process IS the user's real
/// `com.clipmemory.app` domain (measured inside the test host:
/// `Bundle.main.bundleIdentifier == com.clipmemory.app`).
///
/// Every `@AppStorage` declaration in the view tree (17 sites across 14
/// view files) read that domain implicitly — `@AppStorage` without a
/// `store:` argument resolves to `UserDefaults.standard` — and `sz(_:)`
/// read it explicitly. So `SnapshotTestHelpers` had to:
///
/// * write `fontScale = 1.0` into the production domain,
/// * delete the user's real `settings.selectedTab` and `themeAppearance`,
/// * restore all three in `tearDown`.
///
/// A `tearDown` restore does not survive a host abort (ID-REVIEW-1038
/// measured `fontScale = 3.7` left in the user's plist after a trap), and
/// on this machine the user's real `settings.selectedTab` was one of the
/// keys the old code deleted around every snapshot test.
///
/// ## The fix
///
/// Every `@AppStorage` declaration now names `store: AppStorageDefaults.shared`
/// — the app's dedicated **appearance** seam — and `sz(_:)` reads the same
/// seam.
///
/// * Production: `AppStorageDefaults.shared` IS `UserDefaults.standard`
///   ⇒ byte-identical behaviour.
/// * Test process: the seam points at its OWN isolated suite ⇒ the snapshot
///   baseline is deterministic with **no write at all**.
///
/// ⚠️ The appearance seam is deliberately NOT the app's canonical service
/// seam (`TestIsolation.defaults`) and owns its own storage: swapping the
/// service seam invalidates `LanguageManager.shared`'s **instance-identity**
/// cache, so the next read of `shared` re-creates the manager and binds it
/// to whatever the service seam holds at that moment — and the next
/// `selectedLanguage` assignment then writes `appLanguage` +
/// `AppleLanguages` into THAT store. When it is the baseline suite, the ZZZ
/// canary goes red and blames four unrelated test classes (measured
/// 2026-10-27). See `AppStorageDefaults.swift` for the full account.
///
/// ## What this file guards
///
/// The seam is only worth anything if it stays in place. Two things can
/// silently undo it:
///
/// 1. A new `@AppStorage` declaration without a `store:` — it would read
///    the production domain again, and the next person would have to
///    "solve" the snapshot determinism by writing to production again.
/// 2. A declaration that names a store but not THE seam (e.g.
///    `store: UserDefaults.standard`) — same outcome, and a check that only
///    asks "is there a `store:`?" would call it fine. The independent
///    verification of 2026-10-27 mutated one declaration to
///    `store: UserDefaults.standard` and the first version of this guard
///    did NOT catch it — hence the `namesAppearanceSeam` rule below.
/// 3. `sz(_:)` drifting back to `UserDefaults.standard` — guarded by
///    `Audit20260720RegressionTests` (the clamp contract), not here.
/// A tiny scanner that blanks the parts of a Swift source that are prose
/// rather than code.
///
/// It is a separate type with one method per state because a correct
/// single-pass scanner needs a state machine, and a state machine in a
/// single function trips SwiftLint's complexity and body-length rules.
private struct SourceBlanker {
    enum State {
        case code, lineComment, blockComment, string
    }

    private var state: State = .code
    private var escaped = false

    /// The blanked source.
    static func blank(_ source: String) -> String {
        var blanker = SourceBlanker()
        var result = ""
        result.reserveCapacity(source.count)
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            let following: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            let skip = blanker.consume(characters[index], following, into: &result)
            index += 1 + skip
        }
        return result
    }

    /// Consumes one character; returns how many extra characters it ate.
    private mutating func consume(
        _ character: Character,
        _ following: Character?,
        into result: inout String
    ) -> Int {
        switch state {
        case .code: return consumeCode(character, following, into: &result)
        case .lineComment: consumeLineComment(character, into: &result)
        case .blockComment: return consumeBlockComment(character, following, into: &result)
        case .string: consumeString(character, into: &result)
        }
        return 0
    }

    private mutating func consumeCode(
        _ character: Character,
        _ following: Character?,
        into result: inout String
    ) -> Int {
        if character == "/", following == "/" {
            result.append("  ")
            state = .lineComment
            return 1
        }
        if character == "/", following == "*" {
            result.append("  ")
            state = .blockComment
            return 1
        }
        if character == "\"" { state = .string }
        result.append(character)
        return 0
    }

    private mutating func consumeLineComment(_ character: Character, into result: inout String) {
        if character == "\n" {
            state = .code
            result.append(character)
        } else {
            result.append(" ")
        }
    }

    private mutating func consumeBlockComment(
        _ character: Character,
        _ following: Character?,
        into result: inout String
    ) -> Int {
        if character == "*", following == "/" {
            result.append("  ")
            state = .code
            return 1
        }
        result.append(character == "\n" ? "\n" : " ")
        return 0
    }

    private mutating func consumeString(_ character: Character, into result: inout String) {
        if escaped {
            escaped = false
            result.append(" ")
        } else if character == "\\" {
            escaped = true
            result.append(" ")
        } else if character == "\"" {
            state = .code
            result.append(character)
        } else {
            result.append(character == "\n" ? "\n" : " ")
        }
    }
}

final class Review1039RegressionTests: XCTestCase {

    // MARK: - The static guard: every declaration names the seam

    /// The number of `@AppStorage` declarations the guard expects to find.
    ///
    /// A LOWER BOUND, deliberately: the point of the guard is "no
    /// declaration without the seam", not "there are exactly 17". But a
    /// floor is still needed — a scan that finds NOTHING passes
    /// vacuously, which is how the alias rule stayed broken for a whole
    /// round in ID-REVIEW-1038 (the control group was a single line, so an
    /// end-anchored rule matched it by accident).
    private static let minimumDeclarationCount = 17

    /// The symbol the appearance seam is addressed by.
    ///
    /// A declaration must name THIS store. `store: UserDefaults.standard`
    /// is a store, and it is exactly the defect — it resolves to the
    /// production domain inside the app-hosted test process.
    private static let seamSymbol = "AppStorageDefaults.shared"

    /// Repository root, computed from this file's own location.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }()

    /// The path of `url` relative to `root`, computed COMPONENT-WISE.
    ///
    /// Why not a string prefix replacement: `FileManager.enumerator(at:)`
    /// RESOLVES symlinks in the URLs it yields, while a root built with
    /// `appendingPathComponent` does NOT. In a checkout under a symlinked
    /// path (`/tmp` → `/private/tmp` on macOS) the two therefore disagree on
    /// the prefix, and the replacement either misses (leaving an absolute
    /// path) or mangles it (`/private` + `ClipMemory/...`). Measured
    /// 2026-10-27 — the same shape exists in
    /// `IsolationSeamConsolidationTests.measuredDeclarations`, where it made
    /// the §8 roster guard FAIL in a symlinked checkout.
    private static func relativePath(of url: URL, under root: URL) -> String {
        let fileComponents = normalizedComponents(url)
        let rootComponents = normalizedComponents(root)
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return url.path
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Path components with the path standardized and symlinks resolved.
    private static func normalizedComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }

    /// Every `@AppStorage` declaration in the APP target, with the span of
    /// its attribute.
    ///
    /// The span matters: a declaration may wrap its arguments over several
    /// lines, in which case the `store:` is NOT on the line that opens the
    /// attribute. A line-only check would report such a declaration as
    /// store-less — a false positive that teaches the next person to keep
    /// everything on one line instead of fixing the real thing.
    private struct Declaration {
        let file: String
        let line: Int
        /// The TEXT of the `store:` argument, or `nil` when the declaration
        /// has no `store:` at all.
        let storeArgument: String?

        /// Whether the declaration names the app's appearance seam.
        var namesAppearanceSeam: Bool {
            guard let storeArgument else { return false }
            return storeArgument.contains("AppStorageDefaults.shared")
        }
    }

    private static func declarations(in source: String, file: String) -> [Declaration] {
        let lines = blankingComments(source).components(separatedBy: "\n")
        var found: [Declaration] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            // Comment bodies are already blanked out by `blankingComments`, so
            // a comment line arrives here as blanks and never matches.
            // (An earlier version ALSO checked `trimmed.hasPrefix("//")` —
            // measured redundant: mutating that check to `false` left every
            // test green, because it guarded nothing.)
            guard line.contains("@AppStorage(") else {
                index += 1
                continue
            }

            // Collect the attribute span by balancing parentheses from the
            // opening `@AppStorage(`.
            var span = line
            var depth = line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            var cursor = index
            while depth > 0, cursor + 1 < lines.count {
                cursor += 1
                span += "\n" + lines[cursor]
                depth += lines[cursor].filter { $0 == "(" }.count
                depth -= lines[cursor].filter { $0 == ")" }.count
            }

            found.append(Declaration(
                file: file,
                line: index + 1,
                storeArgument: storeArgument(in: span)
            ))
            index = cursor + 1
        }
        return found
    }

    /// The text of the `store:` argument inside an attribute span.
    ///
    /// The argument is a plain expression in practice (a dotted path), so the
    /// text up to the next `,` or `)` is the whole argument.
    private static func storeArgument(in span: String) -> String? {
        guard let range = span.range(of: "store:") else { return nil }
        let rest = span[range.upperBound...]
        let end = rest.firstIndex(where: { $0 == "," || $0 == ")" }) ?? rest.endIndex
        let argument = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return argument.isEmpty ? nil : argument
    }

    /// The source with comment BODIES blanked out.
    ///
    /// Line structure is preserved, so line numbers stay accurate. Both `//`
    /// line comments and `/* */` block comments are handled: a
    /// `@AppStorage(` mentioned inside either is prose, not a declaration.
    /// A block comment that mentions one would otherwise be reported as an
    /// offending declaration and turn CI red for no reason.
    ///
    /// String literals are blanked as well — their text is prose too. (The
    /// interpolated code inside `\(…)` is blanked with the rest of the
    /// literal: a property declaration cannot live inside an
    /// interpolation, so nothing real is lost.)
    private static func blankingComments(_ source: String) -> String {
        SourceBlanker.blank(source)
    }

    /// Every `@AppStorage` declaration in the app target must name the
    /// appearance seam.
    func testEveryAppStorageDeclarationNamesTheAppearanceSeam() throws {
        let appRoot = Self.repoRoot.appendingPathComponent("ClipMemory")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var declarations: [Declaration] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = Self.relativePath(of: url, under: appRoot)
            declarations += Self.declarations(in: source, file: relative)
        }

        XCTAssertGreaterThanOrEqual(
            declarations.count, Self.minimumDeclarationCount,
            "ID-REVIEW-1039: the scan found \(declarations.count) @AppStorage declarations, "
            + "which is below the expected floor of \(Self.minimumDeclarationCount). "
            + "A scan that finds nothing passes vacuously — check that the scan still "
            + "matches the app target's shape before trusting a green result."
        )

        let offenders = declarations.filter { !$0.namesAppearanceSeam }
        XCTAssertTrue(
            offenders.isEmpty,
            "ID-REVIEW-1039: every @AppStorage declaration must name "
            + "`store: \(Self.seamSymbol)`. A declaration without one — or with a "
            + "different store — resolves to UserDefaults.standard, which, inside the "
            + "app-hosted test process, IS the user's real com.clipmemory.app domain. "
            + "Offending declarations: "
            + offenders.map { "\($0.file):\($0.line)" }.joined(separator: ", ")
        )
    }

    // MARK: - The scanner's own controls

    /// A declaration WITHOUT a store must be reported.
    ///
    /// Without this control the guard above could pass vacuously — e.g. if
    /// the `store:` search were mis-implemented to always answer "yes".
    func testTheScannerReportsADeclarationWithoutAStore() {
        let source = """
        struct Demo: View {
            @AppStorage("fontScale") private var fontScale: Double = 1.0
        }
        """
        let found = Self.declarations(in: source, file: "Demo.swift")
        XCTAssertEqual(found.count, 1, "the scanner must find the declaration")
        XCTAssertFalse(
            found[0].namesAppearanceSeam,
            "a declaration without a `store:` argument must be reported"
        )
    }

    /// The production domain spelled in FRAGMENTS.
    ///
    /// `ProductionDomainWriteGuardTests` scans the WHOLE test tree for
    /// production-domain spellings and cannot tell a string literal from
    /// code — so writing this spelling out in full would make THAT guard
    /// report this file (measured 2026-10-27: it flagged the control group
    /// below as "a production-domain write with no ALLOW-PRODUCTION-WRITE
    /// marker"). Building the spelling from fragments keeps the runtime
    /// sample identical while leaving no literal spelling in the source.
    ///
    /// Same convention as `ProductionDomainWriteGuardTests`'s own
    /// `prodDot` / `prodStd` fragments, for the same reason.
    private static let productionStoreSpelling = "UserDefaults" + "." + "standard"

    /// A declaration that names a store OTHER than the seam must be
    /// reported.
    ///
    /// This is the control group for the mutation the independent
    /// verification of 2026-10-27 ran: one declaration mutated to
    /// `store: UserDefaults.standard` slipped through the first version of
    /// this guard, which only asked "is there a `store:`?".
    func testTheScannerReportsADeclarationPointingAtADifferentStore() {
        let source = """
        struct Demo: View {
            @AppStorage("fontScale", store: \(Self.productionStoreSpelling)) private var fontScale: Double = 1.0
        }
        """
        let found = Self.declarations(in: source, file: "Demo.swift")
        XCTAssertEqual(found.count, 1, "the scanner must find the declaration")
        XCTAssertEqual(
            found[0].storeArgument,
            Self.productionStoreSpelling,
            "the control sample must really name the production domain as its store — "
            + "otherwise this control group would prove nothing"
        )
        XCTAssertFalse(
            found[0].namesAppearanceSeam,
            "a declaration that names a store OTHER than the appearance seam must be "
            + "reported — `UserDefaults.standard` IS the production domain inside the "
            + "app-hosted test process"
        )
    }

    /// A declaration WITH the seam must not be reported.
    ///
    /// This includes the multi-line spelling: the `store:` is on a
    /// different line than the one opening the attribute.
    func testTheScannerAcceptsADeclarationWithTheSeam() {
        let singleLine = """
        struct Demo: View {
            @AppStorage("fontScale", store: AppStorageDefaults.shared) private var fontScale: Double = 1.0
        }
        """
        let multiLine = """
        struct Demo: View {
            @AppStorage(
                "fontScale",
                store: AppStorageDefaults.shared
            ) private var fontScale: Double = 1.0
        }
        """
        for source in [singleLine, multiLine] {
            let found = Self.declarations(in: source, file: "Demo.swift")
            XCTAssertEqual(found.count, 1, "the scanner must find the declaration")
            XCTAssertTrue(
                found[0].namesAppearanceSeam,
                "a declaration that names the appearance seam must not be reported — "
                + "including the multi-line spelling, where `store:` is not on the "
                + "opening line"
            )
        }
    }

    /// A COMMENT that mentions `@AppStorage` is not a declaration.
    func testTheScannerIgnoresComments() {
        let source = """
        struct Demo: View {
            // @AppStorage("fontScale") is only the invalidation trigger
            /// Each View retains its own @AppStorage("fontScale")
            /*
             @AppStorage("fontScale") mentioned inside a block comment
            */
        }
        """
        XCTAssertTrue(
            Self.declarations(in: source, file: "Demo.swift").isEmpty,
            "a comment mentioning @AppStorage must not count as a declaration — "
            + "neither a line comment nor a block comment"
        )
    }

    /// The relative-path helper must survive a symlinked checkout root.
    ///
    /// `FileManager.enumerator` resolves symlinks in the URLs it yields
    /// while an `appendingPathComponent` root does not — so a checkout under
    /// a symlinked path made the old string-prefix replacement miss, and
    /// the §8 roster guard FAILED in such a checkout (measured 2026-10-27).
    func testTheRelativePathSurvivesASymlinkedCheckoutRoot() throws {
        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Review1039-symlink-\(UUID().uuidString)")
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Review1039-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target.path
        )
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        let nested = target.appendingPathComponent("Views/Deep.swift")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "struct A {}".write(to: nested, atomically: true, encoding: .utf8)

        let rootViaLink = link.appendingPathComponent("Views")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: rootViaLink,
            includingPropertiesForKeys: nil
        ))
        var checked = false
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = Self.relativePath(of: url, under: rootViaLink)
            XCTAssertEqual(
                relative, "Deep.swift",
                "the relative path must be computed component-wise — a symlinked root "
                + "made the old string-prefix replacement produce a mangled or "
                + "absolute path"
            )
            checked = true
        }
        XCTAssertTrue(checked, "the control group must actually contain a file to scan")
    }

    // MARK: - The behaviour: the snapshot baseline stays out of production

    /// The production domain must be byte-identical across a snapshot
    /// test's setup and teardown.
    ///
    /// This is the BEHAVIOURAL contract — the static guard proves where
    /// the declarations point, this proves that pointing them at the seam
    /// actually keeps the production domain untouched. The old code wrote
    /// `fontScale = 1.0` and deleted two keys there, so this test is the
    /// direct regression test for the defect.
    @MainActor
    func testTheSnapshotBaselineLeavesTheProductionDomainUntouched() {
        let keys = [
            UserDefaultsKey.fontScale.rawValue,
            "settings.selectedTab",
            "themeAppearance"
        ]

        func productionState() -> [String] {
            keys.map { key in
                guard let value = UserDefaults.standard.object(forKey: key) else {
                    return "\(key)=<absent>"
                }
                return "\(key)=\(value)"
            }
        }

        let before = productionState()
        snapshotTestSetUp()
        let during = productionState()
        snapshotTestTearDown()
        let after = productionState()

        XCTAssertEqual(
            before, during,
            "ID-REVIEW-1039: the snapshot baseline must not be planted in the production "
            + "domain — inside the app-hosted test process that domain IS the user's real "
            + "com.clipmemory.app settings"
        )
        XCTAssertEqual(
            before, after,
            "ID-REVIEW-1039: the production domain must be unchanged after a snapshot "
            + "test — and it must be unchanged even if the restore never runs, which is "
            + "why the baseline now lives in a per-test suite instead"
        )
    }

    // MARK: - The behaviour: a declaration that names the seam reads the seam

    /// A view whose `@AppStorage` names the seam must read the SEAM.
    ///
    /// The static guard proves every app declaration names the seam; this
    /// proves that naming it actually redirects the read. The two together
    /// are what make the snapshot baseline production-free.
    @MainActor
    func testADeclarationThatNamesTheSeamReadsTheSeam() {
        let suiteName = "Review1039-seam-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        suite.set("from-the-seam", forKey: Review1039RegressionTests.probeKey)

        AppStorageDefaults.setShared(suite)
        defer { AppStorageDefaults.setShared(nil) }

        let view = Review1039RegressionTests.ProbeView()
        XCTAssertEqual(
            view.readValue, "from-the-seam",
            "ID-REVIEW-1039: a declaration that names `store: AppStorageDefaults.shared` "
            + "must read the seam — otherwise the static guard proves nothing about "
            + "the runtime behaviour"
        )
    }

    /// The key the probe view reads.
    nonisolated(unsafe) static let probeKey = "Review1039.probe"

    /// A view whose `@AppStorage` names the app's seam.
    @MainActor
    struct ProbeView: View {
        @AppStorage(Review1039RegressionTests.probeKey, store: AppStorageDefaults.shared)
        private var value: String = ""

        /// The value the wrapper resolved.
        var readValue: String { value }

        var body: some View { Text(value) }
    }

}
