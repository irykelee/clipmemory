import XCTest
@testable import ClipMemory

/// Release-readiness regression tests for the v2.2.4 audit (Task 5).
///
/// These tests are deliberately file-system-level: they read the actual
/// `project.yml`, `project.pbxproj`, `Scripts/package.sh`, and
/// `ClipMemory/Views/QuickBarView.swift` source files rather than the
/// compiled `Bundle.infoDictionary`. The intent is to fail-fast before
/// `xcodebuild Release build` if any of the audit-confirmed drifts
/// (F-1, F-3, S-3) reappear in a future release cycle.
///
/// Tests run from the test bundle path which is built into the source
/// tree at `Tests/ClipMemoryTests/`. We walk up three directories to
/// reach the project root that contains `project.yml`.
final class ReleaseReadinessTests: XCTestCase {

    /// Repository root, computed once per test run from the location of
    /// the test source file (`Tests/ClipMemoryTests/ReleaseReadinessTests.swift`).
    private static let repoRoot: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }()

    // MARK: - F-1: project.yml version fields must match expected tag

    /// Reads `project.yml` and asserts both `MARKETING_VERSION` and
    /// `CURRENT_PROJECT_VERSION` equal `expectedVersion`. Used to guard
    /// the post-v2.2.4 release cycle and future bumps.
    /// Reads `project.yml` and asserts both `MARKETING_VERSION` and
    /// `CURRENT_PROJECT_VERSION` are present and equal. Used to guard
    /// the post-v2.2.4 release cycle and future bumps.
    private func readProjectYMLVersions(file: StaticString = #filePath,
                                        line: UInt = #line) throws -> (marketing: String, project: String) {
        let url = ReleaseReadinessTests.repoRoot.appendingPathComponent("project.yml")
        let contents = try String(contentsOf: url, encoding: .utf8)

        let marketingRegex = try NSRegularExpression(
            pattern: #"^[ \t]*MARKETING_VERSION:[ \t]*\"([0-9][^\"]*)\""#,
            options: [.anchorsMatchLines]
        )
        let projectRegex = try NSRegularExpression(
            pattern: #"^[ \t]*CURRENT_PROJECT_VERSION:[ \t]*\"([0-9][^\"]*)\""#,
            options: [.anchorsMatchLines]
        )

        let marketingRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let marketingMatch = marketingRegex.firstMatch(in: contents, range: marketingRange),
              let marketingCaptureRange = Range(marketingMatch.range(at: 1), in: contents) else {
            XCTFail("MARKETING_VERSION not found in project.yml", file: file, line: line)
            return ("", "")
        }
        let marketingVersion = String(contents[marketingCaptureRange])

        guard let projectMatch = projectRegex.firstMatch(in: contents, range: marketingRange),
              let projectCaptureRange = Range(projectMatch.range(at: 1), in: contents) else {
            XCTFail("CURRENT_PROJECT_VERSION not found in project.yml", file: file, line: line)
            return ("", "")
        }
        let projectVersion = String(contents[projectCaptureRange])
        XCTAssertEqual(marketingVersion, projectVersion,
                       "project.yml MARKETING_VERSION and CURRENT_PROJECT_VERSION must match",
                       file: file, line: line)
        return (marketingVersion, projectVersion)
    }

    func testF1_projectYml_marksCurrentVersion() throws {
        let versions = try readProjectYMLVersions()
        XCTAssertFalse(versions.marketing.isEmpty, "MARKETING_VERSION must not be empty")
    }

    // MARK: - F-1: project.pbxproj version fields must match expected tag

    /// The generated `project.pbxproj` is required to expose the same
    /// version in both Debug and Release build configurations. XcodeGen
    /// emits exactly four literal assignments of `MARKETING_VERSION` and
    /// `CURRENT_PROJECT_VERSION` (two per config). Any drift means the
    /// `xcodebuild Release` artifact will ship with a stale `CFBundle…`
    /// stamp and the v2.2.3 lesson repeats.
    func testF1_projectPbxproj_allFourSectionsMatchProjectYml() throws {
        let versions = try readProjectYMLVersions()
        let expectedVersion = versions.marketing
        let url = ReleaseReadinessTests.repoRoot
            .appendingPathComponent("ClipMemory.xcodeproj/project.pbxproj")
        let contents = try String(contentsOf: url, encoding: .utf8)

        // Match both forms in the same regex so we count occurrences
        // regardless of which identifier precedes the version literal.
        let pattern = #"(?:MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*([0-9][^;\n]*)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        let matches = regex.matches(in: contents, range: range)

        XCTAssertEqual(matches.count, 4,
                       "Expected exactly 4 version literals in project.pbxproj (Release+Debug × 2 keys), found \(matches.count). Run `xcodegen generate` after editing project.yml.",
                       file: #filePath, line: #line)

        for match in matches {
            guard let captureRange = Range(match.range(at: 1), in: contents) else {
                XCTFail("Regex capture missing for a match", file: #filePath, line: #line)
                continue
            }
            let value = String(contents[captureRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(value, expectedVersion,
                           "A pbxproj version literal is not \(expectedVersion)",
                           file: #filePath, line: #line)
        }
    }

    // MARK: - F-3: Scripts/package.sh must not default to a stale version

    /// The historical footgun: `VERSION=${1:-2.0.0}` silently packaged a
    /// stale-stamped tarball when invoked without an explicit argument.
    /// The fix is to read `MARKETING_VERSION` from `project.yml` while
    /// keeping the positional argument as an override. This test guards
    /// against regression by parsing the script's first 30 lines.
    func testF3_packageScript_doesNotPinStaleDefault() throws {
        let url = ReleaseReadinessTests.repoRoot
            .appendingPathComponent("Scripts/package.sh")
        let contents = try String(contentsOf: url, encoding: .utf8)

        // The script must NOT contain a hard-coded `2.0.0` default —
        // that's the v2.0.0 / pre-audit footgun.
        XCTAssertFalse(contents.contains("${1:-2.0.0}"),
                       "Scripts/package.sh still pins the 2.0.0 default — it must read MARKETING_VERSION from project.yml.",
                       file: #filePath, line: #line)

        // The script must reference `MARKETING_VERSION` (case-insensitive
        // match) so it picks up whatever the build configuration says.
        XCTAssertTrue(contents.localizedCaseInsensitiveContains("MARKETING_VERSION"),
                      "Scripts/package.sh does not reference MARKETING_VERSION.",
                      file: #filePath, line: #line)
    }

    // MARK: - S-3: QuickBarView "open full window" item must not advertise ⌘⌃V

    /// After commit `b656a92`, `Cmd+Ctrl+V` opens the full main window,
    /// not the Quick Bar. The Quick Bar is reached via the menu-bar icon.
    /// The misleading shortcut label was reintroduced on the "open full
    /// window" `MacOSMenuItem` in `QuickBarView.swift` line 137 during
    /// the Liquid Glass UI rewrite. The fix is to drop the `shortcut:`
    /// argument on that one item so no shortcut label renders for it.
    func testS3_quickBarOpenFullItem_doesNotAdvertiseCmdCtrlV() throws {
        let url = ReleaseReadinessTests.repoRoot
            .appendingPathComponent("ClipMemory/Views/QuickBarView.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)

        // Locate the line that constructs the "open full window" menu item.
        // We assert that the line does NOT carry a `shortcut:` argument
        // tied to ⌘⌃V.
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        var foundOpenFullLine = false
        for lineSub in lines {
            let line = String(lineSub)
            if line.contains("quickbarOpenFull") {
                foundOpenFullLine = true
                XCTAssertFalse(line.contains("⌘⌃V"),
                               "QuickBarView 'open full window' menu item still advertises ⌘⌃V: \(line)",
                               file: #filePath, line: #line)
                // Also assert the call site no longer passes any
                // `shortcut:` literal so the rendering guard
                // (`if !shortcut.isEmpty`) skips the label entirely.
                XCTAssertFalse(line.contains("shortcut:"),
                               "QuickBarView 'open full window' menu item still passes shortcut: label: \(line)",
                               file: #filePath, line: #line)
            }
        }
        XCTAssertTrue(foundOpenFullLine,
                      "Could not find the quickbarOpenFull menu item line in QuickBarView.swift",
                      file: #filePath, line: #line)
    }
}
