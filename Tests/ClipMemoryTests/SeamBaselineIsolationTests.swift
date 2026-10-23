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

    /// Scans every Swift file in the repository for an assignment of
    /// `.standard` to one of the seam forwarders (or to
    /// `TestIsolation.defaults` / `TestIsolation.setDefaults`).
    ///
    /// Only CODE is matched: a line whose match is preceded by `//` is a
    /// comment and is ignored. Same rule as the `nonisolated(unsafe)`
    /// roster guard in `IsolationSeamConsolidationTests`, so "declaration"
    /// means the same thing in both guards.
    func testNoSourceFileResetsTheSeamToTheProductionDomain() throws {
        var patterns: [String] = []
        for owner in Self.seamOwners {
            patterns.append("\(owner)\\.defaults\\s*=\\s*\\.standard")
            patterns.append("\(owner)\\.setDefaults\\(\\s*\\.standard")
        }

        var offenders: [String] = []
        for root in ["Tests/ClipMemoryTests", "ClipMemory"] {
            let directory = Self.repoRoot.appendingPathComponent(root)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath = url.path.replacingOccurrences(
                    of: Self.repoRoot.path + "/",
                    with: ""
                )
                if Self.allowedFiles.contains(relativePath) { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                let hits = Self.codeLines(matchingAnyOf: patterns, in: source)
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

    // MARK: - Helpers

    /// Repository root, computed from this file's own location
    /// (`Tests/ClipMemoryTests/SeamBaselineIsolationTests.swift`).
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }()

    /// 1-based line numbers where one of `patterns` matches CODE — i.e.
    /// with no `//` before the match on that line.
    private static func codeLines(matchingAnyOf patterns: [String], in source: String) -> [Int] {
        var hits: [Int] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let text = String(line)
            let nsText = text as NSString
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let fullRange = NSRange(location: 0, length: nsText.length)
                guard let match = regex.firstMatch(in: text, range: fullRange) else { continue }
                let prefix = nsText.substring(to: match.range.location)
                guard !prefix.contains("//") else { continue }
                hits.append(index + 1)
                break
            }
        }
        return hits
    }
}
