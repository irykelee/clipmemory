import XCTest
import AppKit
@testable import ClipMemory

/// ID-REVIEW-1042 (2026-10-27): the test tree wrote to the user's REAL
/// system clipboard, and a **separately running** ClipMemory app captured
/// the suite's fixture strings into the user's real history.
///
/// ID-REVIEW-1041 measured the damage and fixed it with a test-side guard
/// (snapshot the pasteboard, restore it afterwards). It could not fix the
/// WINDOW: the app had no way to write anywhere except
/// `NSPasteboard.general`, so the suite's fixtures sat on the user's
/// clipboard for the duration of every affected test. That remainder was
/// recorded honestly as an unfixed gap in `docs/skips-ledger.md` §41.
///
/// ID-REVIEW-1042 closes the window at the source with a production seam
/// (`ClipMemory/Utils/AppPasteboard.swift`): in a test process the app binds
/// to a PRIVATE pasteboard, so a production write cannot reach the user's
/// clipboard at all.
///
/// These tests pin:
///
/// 1. **Behaviour** — under XCTest the app is NOT bound to the system-wide
///    general pasteboard, and the seam resolves to a STABLE board.
/// 2. **Behaviour** — the app's two copy paths write to the seam.
/// 3. **Static** — the APP tree may name the system-wide general pasteboard
///    only in `AppPasteboard.swift`, and the seam must still resolve to it
///    on its default (production) branch.
/// 4. **Control group** — the scanner finds a planted use and ignores
///    comments and string literals.
///
/// ⚠️ The "production ⇒ the general pasteboard" half cannot be asserted
/// from inside a test process (the seam's private board is chosen by
/// `TestIsolation.isRunningTests`, which is true here by construction). It
/// is covered STATICALLY instead — see
/// `testTheSeamResolvesToTheGeneralPasteboardOnItsDefaultBranch` and
/// `testTheSeamsPrivateBoardIsGatedOnTheTestProbe`.
@MainActor
final class Review1042RegressionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // ID-REVIEW-1041's rule: a test file that touches the clipboard must
        // pair begin() with end(), so the app's pasteboard is isolated per
        // test and no fixture leaks into the next one.
        TestPasteboardGuard.begin()
    }

    override func tearDown() {
        TestPasteboardGuard.end()
        super.tearDown()
    }

    // MARK: - Behaviour: the seam must not hand the app the user's clipboard

    /// Under XCTest the app must be bound to a PRIVATE board.
    ///
    /// This is the whole point of the seam: it is what makes the
    /// "separately running ClipMemory app captures the suite's fixtures"
    /// harm impossible.
    func testTheAppIsNotBoundToTheSystemGeneralPasteboardUnderXCTest() {
        XCTAssertFalse(
            AppPasteboard.isSystemGeneral,
            "under XCTest the app must bind to a private pasteboard, never to the "
            + "user's system-wide clipboard"
        )
    }

    /// The seam must resolve to a STABLE board.
    ///
    /// `NSPasteboard.withUniqueName()` returns a NEW object on every call
    /// (measured 2026-10-27), so a seam that resolved it per access would
    /// hand the clipboard monitor a different board on every 0.5 s poll
    /// tick — the monitor would then never see a change it caused itself.
    func testTheSeamResolvesToAStableBoard() {
        let first = AppPasteboard.shared
        let second = AppPasteboard.shared
        XCTAssertTrue(
            first === second,
            "the seam must cache its board — withUniqueName() returns a NEW object "
            + "on every call, so a per-access resolution would hand the monitor a "
            + "different board on every tick"
        )
    }

    /// The copy path must write to the seam.
    ///
    /// The user-facing half of ID-REVIEW-1042: `ClipboardStore.copyToClipboard`
    /// is what the app's "copy" button runs, and it used to write straight
    /// to the user's clipboard.
    func testTheCopyPathWritesToTheSeam() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let board = AppPasteboard.shared
        board.clearContents()

        store.copyToClipboard(ClipboardItem(content: "seam-fixture", type: .text))

        XCTAssertEqual(
            board.string(forType: .string), "seam-fixture",
            "copyToClipboard must write to the seam's board"
        )
        XCTAssertFalse(
            AppPasteboard.isSystemGeneral,
            "the board the copy landed on must not be the user's clipboard"
        )
    }

    /// The OCR copy path must write to the seam too — it is a SECOND
    /// production write site, and the one the 1041 measurement showed
    /// actually reaching the user's clipboard.
    func testTheOcrCopyPathWritesToTheSeam() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let board = AppPasteboard.shared
        board.clearContents()

        ClipboardItemRow.writeOcrTextToPasteboard("ocr-seam-fixture", store: store)

        XCTAssertEqual(
            board.string(forType: .string), "ocr-seam-fixture",
            "writeOcrTextToPasteboard must write to the seam's board"
        )
        XCTAssertFalse(
            AppPasteboard.isSystemGeneral,
            "the board the OCR copy landed on must not be the user's clipboard"
        )
    }

    // MARK: - Static guard: only the seam may name the general pasteboard

    /// Tokens that reach the SYSTEM-WIDE general pasteboard — or the spelling
    /// that traps.
    ///
    /// ⚠️ `NSPasteboard()` is **NOT** a deprecated spelling of
    /// `NSPasteboard.general` (an earlier version of this note claimed that
    /// — it was measured false). `NSPasteboard` is a **class cluster**, and
    /// the no-argument form reaches `+[NSPasteboard allocWithZone:]`, which
    /// **raises**:
    ///
    ///     NSInvalidArgumentException: '+[NSPasteboard allocWithZone:]:
    ///     unrecognized selector sent to class 0x…'
    ///
    /// Measured 2026-10-27 (standalone probe, with the throwing frame in the
    /// stack: `AppKit +[NSPasteboard allocWithZone:]`) ⇒ the process
    /// terminates. It never returns the general pasteboard.
    ///
    /// ⇒ It is watched here for a STRONGER reason than the clipboard: a
    /// production path using it would **crash the app**, not merely reach
    /// the user's clipboard.
    private static let generalPasteboardTokens = [
        "NSPasteboard.general",
        "NSPasteboard()"
    ]

    /// How many times each APP file may name the general pasteboard.
    ///
    /// An exact COUNT, not a line number and not a prefix: line numbers drift
    /// with unrelated edits, and a prefix can be widened by accident. A new
    /// use ⇒ red; a removed use ⇒ the stale entry ⇒ red.
    private static let appTreeGeneralPasteboardBudget: [String: Int] = [
        "Utils/AppPasteboard.swift": 2
    ]

    /// Counts the general-pasteboard uses in one app file.
    private static func generalPasteboardUses(in source: String) -> Int {
        Self.generalPasteboardTokens.reduce(0) { total, token in
            total + TestSourceScanner.occurrenceCount(
                of: token, in: TestSourceScanner.blankingCommentsAndStrings(source)
            )
        }
    }

    func testOnlyTheSeamFileMayNameTheGeneralPasteboardInTheAppTree() throws {
        let files = try TestSourceScanner.appSourceFiles()
        var offenders: [String] = []
        for url in files {
            let relative = TestSourceScanner.appRelativePath(of: url)
            let source = try String(contentsOf: url, encoding: .utf8)
            let uses = Self.generalPasteboardUses(in: source)
            let allowed = Self.appTreeGeneralPasteboardBudget[relative] ?? 0
            if uses != allowed {
                offenders.append("\(relative): \(uses) use(s), allowed \(allowed)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "only AppPasteboard.swift may reach the system-wide general pasteboard "
            + "(or the class-cluster NSPasteboard() spelling, which traps); every "
            + "other app file must go through the seam; offenders: \(offenders)"
        )
    }

    /// The budget must not go stale: a use that was added (or a count that
    /// drifted) has to be red, not silently accepted.
    func testTheAppTreeGeneralPasteboardBudgetIsNotStale() throws {
        let files = try TestSourceScanner.appSourceFiles()
        for (file, allowedCount) in Self.appTreeGeneralPasteboardBudget {
            let url = try XCTUnwrap(
                files.first { TestSourceScanner.appRelativePath(of: $0) == file },
                "budget names a file that does not exist: \(file)"
            )
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(
                Self.generalPasteboardUses(in: source),
                allowedCount,
                "budget entry for \(file) is stale — update the exact count"
            )
        }
    }

    /// The app tree must really be scanned — a guard pointed at a moved or
    /// empty directory would pass vacuously.
    func testTheAppTreeIsFoundAndIsTheExpectedOne() throws {
        let files = try TestSourceScanner.appSourceFiles()
        let names = Set(files.map { TestSourceScanner.appRelativePath(of: $0) })
        for expected in ["Utils/AppPasteboard.swift",
                         "Services/ClipboardMonitor.swift",
                         "Services/ClipboardStore.swift",
                         "Views/Components/ClipboardItemRow.swift"] {
            XCTAssertTrue(
                names.contains(expected),
                "the app tree scan must cover \(expected) — found \(names.count) file(s)"
            )
        }
    }

    // MARK: - Static guard: the seam's production branch

    /// The seam must still resolve to the system-wide general pasteboard
    /// when there is no test override — that is what keeps production
    /// behaviour byte-identical to the pre-ID-REVIEW-1042 code.
    func testTheSeamResolvesToTheGeneralPasteboardOnItsDefaultBranch() throws {
        let files = try TestSourceScanner.appSourceFiles()
        let url = try XCTUnwrap(
            files.first { TestSourceScanner.appRelativePath(of: $0) == "Utils/AppPasteboard.swift" },
            "the seam file is missing from the app tree"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(of: "return NSPasteboard.general", in: blanked), 1,
            "the seam's default (production) branch must return the system-wide general pasteboard"
        )
    }

    /// The private board must stay gated on the test probe.
    ///
    /// `TestIsolation.isRunningTests` is the ONLY thing that decides whether
    /// the app gets a private board, and it is TRUE in a test process by
    /// construction — so the "the app would still use the user's clipboard in
    /// production" half cannot be asserted behaviourally from here. Pinning
    /// the reference statically is what keeps that half honest.
    ///
    /// A `!` inversion of the probe IS caught behaviourally (the seam would
    /// resolve to the general board under XCTest, turning
    /// `testTheAppIsNotBoundToTheSystemGeneralPasteboardUnderXCTest` red);
    /// what this check adds is coverage of the "the probe is not consulted
    /// at all" mutation.
    func testTheSeamsPrivateBoardIsGatedOnTheTestProbe() throws {
        let files = try TestSourceScanner.appSourceFiles()
        let url = try XCTUnwrap(
            files.first { TestSourceScanner.appRelativePath(of: $0) == "Utils/AppPasteboard.swift" },
            "the seam file is missing from the app tree"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(of: "TestIsolation.isRunningTests", in: blanked), 1,
            "the seam's private board must be gated on TestIsolation.isRunningTests — "
            + "exactly one reference, so the gate cannot be dropped"
        )
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(of: "NSPasteboard.withUniqueName()", in: blanked), 1,
            "the private board must be created exactly once (and cached — a per-access "
            + "creation would hand the monitor a different board on every tick)"
        )
    }

    /// The seam's "am I the user's clipboard?" probe must be an IDENTITY
    /// check against the real general pasteboard.
    ///
    /// If it were hard-coded to `false`, the behavioural guard above would
    /// pass for the WRONG reason — a vacuous green, which is the exact
    /// failure shape of defect ID-REVIEW-1038's M4 lesson. The test tree
    /// cannot name `NSPasteboard.general` itself (that is the rule
    /// `Review1041RegressionTests` enforces), so the probe's SHAPE is
    /// pinned statically instead.
    func testTheSeamsGeneralPasteboardProbeIsAnIdentityCheck() throws {
        let files = try TestSourceScanner.appSourceFiles()
        let url = try XCTUnwrap(
            files.first { TestSourceScanner.appRelativePath(of: $0) == "Utils/AppPasteboard.swift" },
            "the seam file is missing from the app tree"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(of: "shared === NSPasteboard.general", in: blanked), 1,
            "the seam's general-pasteboard probe must compare the resolved board by "
            + "identity with NSPasteboard.general — a hard-coded answer would make "
            + "the behavioural guard vacuous"
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

    /// NEGATIVE control for the class-cluster spelling.
    ///
    /// `NSPasteboard()` is not a way to reach the general pasteboard — it
    /// TRAPS (measured 2026-10-27: `NSInvalidArgumentException`, process
    /// terminates). The guard still watches for it, because a production
    /// path using it would crash the app.
    func testTheScannerAlsoCatchesTheClassClusterSpelling() {
        let planted = """
        func demo() {
            let board = NSPasteboard()
            board.clearContents()
        }
        """
        XCTAssertEqual(
            Self.generalPasteboardUses(in: planted), 1,
            "the class-cluster NSPasteboard() spelling must be caught too — it traps at runtime"
        )
    }
}
