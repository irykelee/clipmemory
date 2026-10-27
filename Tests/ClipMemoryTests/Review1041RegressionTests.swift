import XCTest
import AppKit

/// ID-REVIEW-1041 (2026-10-27): the test tree wrote to — and finally EMPTIED
/// — the user's REAL system clipboard.
///
/// Measured on the maintainer's machine, with a live ClipMemory app running
/// while the suite executed (poll every 150 ms):
///
///     +0.01s  'copy me'
///     +1.54s  'clipmemory own write'
///     +1.89s  'external paste'
///     +2.24s  'clipmemory own write'
///     +3.16s  ''                  ← the user's clipboard was EMPTIED
///
/// The controlled follow-up (production-domain snapshot every 100 s, no test
/// running in between) showed the **same** production-domain mutation
/// appearing exactly while a test ran and then stopping dead when it did not
/// ⇒ the suite's pasteboard writes are the cause, not the user.
///
/// These tests pin three things:
///
/// 1. **Behaviour** — `TestPasteboardGuard` restores what it snapshotted, and
///    a stray `end()` without a `begin()` does nothing at all.
/// 2. **Static** — `NSPasteboard.general` may be named in exactly ONE file
///    (the guard), and every file that touches the pasteboard must pair
///    `begin()` with `end()`.
/// 3. **Control group** — the scanner finds a planted call and ignores
///    comments and string literals.
///
/// The behavioural tests run against a PRIVATE named pasteboard, so verifying
/// the restore path does not itself disturb the user's clipboard.
final class Review1041RegressionTests: XCTestCase {

    /// The private pasteboard the behavioural tests use.
    ///
    /// `withUniqueName()` gives a uniquely-named pasteboard that the system
    /// releases when the process exits — so verifying the restore path never
    /// touches the user's real clipboard.
    private var scratch: NSPasteboard!

    override func setUp() {
        super.setUp()
        scratch = NSPasteboard.withUniqueName()
        TestPasteboardGuard.usePasteboardForTesting(scratch)
    }

    override func tearDown() {
        TestPasteboardGuard.resetForTesting()
        scratch.clearContents()
        scratch = nil
        super.tearDown()
    }

    // MARK: - Behaviour

    /// The guard must give the user their clipboard back.
    func testTheGuardRestoresWhatItSnapshotted() {
        scratch.clearContents()
        scratch.setString("user-content", forType: .string)

        TestPasteboardGuard.begin()
        XCTAssertNil(scratch.string(forType: .string),
                     "begin() must clear the pasteboard so the test starts from a known state")

        scratch.setString("test-fixture", forType: .string)
        XCTAssertEqual(scratch.string(forType: .string), "test-fixture",
                       "premise: the test's own write is on the pasteboard")

        TestPasteboardGuard.end()
        XCTAssertEqual(scratch.string(forType: .string), "user-content",
                       "end() must restore the content the user had")
    }

    /// A nested `begin()` must not replace the ORIGINAL snapshot — otherwise
    /// `end()` would restore an intermediate state (or the test's own
    /// fixture) instead of the user's data.
    func testTheGuardKeepsTheOriginalSnapshotWhenBeginIsCalledTwice() {
        scratch.clearContents()
        scratch.setString("user-content", forType: .string)

        TestPasteboardGuard.begin()
        scratch.setString("first-fixture", forType: .string)
        TestPasteboardGuard.begin()          // nested: must keep the first snapshot
        scratch.setString("second-fixture", forType: .string)
        TestPasteboardGuard.end()

        XCTAssertEqual(scratch.string(forType: .string), "user-content",
                       "a nested begin() must not overwrite the original snapshot")
    }

    /// A `tearDown()` that runs without a matching `begin()` must be a NO-OP.
    ///
    /// This is the safety property that matters most: a stray `end()` must
    /// never empty the user's clipboard.
    func testTheGuardEndWithoutBeginDoesNotTouchThePasteboard() {
        scratch.clearContents()
        scratch.setString("user-content", forType: .string)

        TestPasteboardGuard.end()

        XCTAssertEqual(scratch.string(forType: .string), "user-content",
                       "end() without a matching begin() must not touch the pasteboard")
    }

    // MARK: - Static guard: only the guard may name the general pasteboard

    /// How many times `NSPasteboard.general` occurs in `source`.
    ///
    /// The scan runs on a BLANKED copy (comments and string literals replaced
    /// by spaces) ⇒ a doc comment mentioning the API is not a use, and the
    /// control-group sample inside a string literal is not a use either.
    private static func generalPasteboardUses(in source: String) -> Int {
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        return TestSourceScanner.occurrenceCount(of: "NSPasteboard.general", in: blanked)
    }

    /// Files allowed to name `NSPasteboard.general`, and how many times.
    ///
    /// An exact COUNT, not a line number and not a prefix: line numbers drift
    /// with unrelated edits, and a prefix can be widened by accident. A new
    /// use ⇒ red; a removed use ⇒ the stale entry ⇒ red.
    private static let allowedGeneralPasteboardUses: [String: Int] = [
        "TestPasteboardGuard.swift": 3
    ]

    func testOnlyTheGuardFileMayNameTheGeneralPasteboard() throws {
        let files = try TestSourceScanner.testSourceFiles()
        var offenders: [String] = []
        for url in files {
            let relative = TestSourceScanner.relativePath(of: url)
            let source = try String(contentsOf: url, encoding: .utf8)
            let uses = Self.generalPasteboardUses(in: source)
            let allowed = Self.allowedGeneralPasteboardUses[relative] ?? 0
            if uses != allowed {
                offenders.append("\(relative): \(uses) use(s), allowed \(allowed)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "only TestPasteboardGuard.swift may name NSPasteboard.general; offenders: \(offenders)"
        )
    }

    /// The allowlist must not go stale: a use that was removed (or a count
    /// that drifted) has to be red, not silently accepted.
    func testTheGeneralPasteboardAllowlistIsNotStale() throws {
        let files = try TestSourceScanner.testSourceFiles()
        for (file, allowedCount) in Self.allowedGeneralPasteboardUses {
            let url = try XCTUnwrap(
                files.first { TestSourceScanner.relativePath(of: $0) == file },
                "allowlist names a file that does not exist: \(file)"
            )
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(
                Self.generalPasteboardUses(in: source),
                allowedCount,
                "allowlist entry for \(file) is stale — update the exact count"
            )
        }
    }

    // MARK: - Static guard: begin() and end() must be paired

    /// Tokens that mean "this file touches the clipboard".
    ///
    /// `TestPasteboardGuard.pasteboard` is the sanctioned accessor;
    /// `copyToClipboard(` / `writeOcrTextToPasteboard(` are the production
    /// entry points that write to the general pasteboard.
    private static let pasteboardUseTokens = [
        "TestPasteboardGuard.pasteboard",
        "copyToClipboard(",
        "writeOcrTextToPasteboard("
    ]

    func testEveryPasteboardUserMustPairBeginWithEnd() throws {
        let files = try TestSourceScanner.testSourceFiles()
        var offenders: [String] = []
        for url in files {
            let relative = TestSourceScanner.relativePath(of: url)
            let source = try String(contentsOf: url, encoding: .utf8)
            let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
            let touches = Self.pasteboardUseTokens.contains { token in
                TestSourceScanner.occurrenceCount(of: token, in: blanked) > 0
            }
            guard touches else { continue }
            let hasBegin = TestSourceScanner.occurrenceCount(
                of: "TestPasteboardGuard.begin(", in: blanked
            ) > 0
            let hasEnd = TestSourceScanner.occurrenceCount(
                of: "TestPasteboardGuard.end(", in: blanked
            ) > 0
            if !hasBegin || !hasEnd {
                offenders.append(
                    "\(relative): begin=\(hasBegin) end=\(hasEnd) — "
                    + "a file that touches the clipboard must pair begin() with end()"
                )
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "every pasteboard-touching test file must use TestPasteboardGuard; offenders: \(offenders)"
        )
    }

    // MARK: - Control group

    /// POSITIVE control: the scanner must find a planted use.
    ///
    /// The sample is embedded in a MULTI-LINE context — a single-line sample
    /// would let a rule that only fires at end-of-input pass by accident
    /// (the ID-REVIEW-1038 M4 lesson).
    func testTheScannerFindsAPlantedGeneralPasteboardUse() {
        let planted = """
        func demo() {
            let board = NSPasteboard.general
            board.clearContents()
        }
        """
        XCTAssertEqual(
            Self.generalPasteboardUses(in: planted), 1,
            "the scanner must find a planted use of the general pasteboard"
        )
    }

    /// NEGATIVE control: comments and string literals are not uses.
    func testTheScannerIgnoresCommentsAndStringLiterals() {
        let negative = """
        // A doc comment mentioning NSPasteboard.general is not a use.
        /* A block comment mentioning NSPasteboard.general is not a use. */
        func demo() {
            let literal = "NSPasteboard.general inside a string is not a use"
            let url = "https://example.com/NSPasteboard.general"
            print(literal, url)
        }
        """
        XCTAssertEqual(
            Self.generalPasteboardUses(in: negative), 0,
            "comments and string literals must not count as uses"
        )
    }
}
