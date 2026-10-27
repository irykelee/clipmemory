import XCTest
import AppKit
import Combine
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

    // MARK: - The resolution itself (the pure function the seam delegates to)

    /// The PRODUCTION branch must resolve to the system-wide general board.
    ///
    /// This is the property that could not be observed at all before the
    /// resolution was extracted into a pure function: a test process is
    /// always a test process, so the live `shared` never takes the
    /// production branch here.
    ///
    /// ⚠️ It used to be checked STATICALLY (the source must contain
    /// `return NSPasteboard.general` exactly once) — and that check could
    /// pass **vacuously**: an earlier `return` inside `shared` could shadow
    /// it while the substring count stayed at 1 (the independent verifier's
    /// mutation MX2b left all 13 guards green).
    func testTheProductionBranchResolvesToTheSystemGeneralPasteboard() {
        let resolved = AppPasteboard.resolve(override: nil, testBoard: nil)
        XCTAssertTrue(
            AppPasteboard.isSystemGeneralPasteboard(resolved),
            "with no override and no test board the seam must resolve to the "
            + "system-wide general pasteboard — that IS the production behaviour"
        )
    }

    /// With a test board present, the seam must resolve to THAT board.
    func testTheTestBoardWinsOverTheSystemGeneralPasteboard() {
        let privateBoard = NSPasteboard.withUniqueName()
        let resolved = AppPasteboard.resolve(override: nil, testBoard: privateBoard)
        XCTAssertTrue(resolved === privateBoard, "the test board must win over the general board")
        XCTAssertFalse(
            AppPasteboard.isSystemGeneralPasteboard(resolved),
            "the resolved board must not be the user's clipboard"
        )
    }

    /// An explicit override must beat the test board.
    func testTheOverrideWinsOverTheTestBoard() {
        let privateBoard = NSPasteboard.withUniqueName()
        let overrideBoard = NSPasteboard.withUniqueName()
        let resolved = AppPasteboard.resolve(override: overrideBoard, testBoard: privateBoard)
        XCTAssertTrue(resolved === overrideBoard, "an explicit override must win over the test board")
    }

    /// The live `shared` must go through that resolution: an override set
    /// through `setShared` must be what `shared` hands out.
    func testTheLiveSeamHonoursTheOverride() {
        let overrideBoard = NSPasteboard.withUniqueName()
        AppPasteboard.setShared(overrideBoard)
        defer { AppPasteboard.setShared(nil) }

        XCTAssertTrue(
            AppPasteboard.shared === overrideBoard,
            "`shared` must resolve through the seam's own resolution, not around it"
        )
        XCTAssertFalse(
            AppPasteboard.isSystemGeneral,
            "with an override in place the app must not be on the user's clipboard"
        )
    }

    // MARK: - Behaviour: the monitor polls the SEAM's board

    /// The clipboard monitor must poll the seam's board.
    ///
    /// The static rule forbids naming the general pasteboard anywhere in the
    /// app tree, but the monitor's READ path deserves its own behavioural
    /// proof: whatever the monitor polls IS the board the rest of the app
    /// writes to. (The independent verifier found that the by-NAME route to
    /// the general board used in `ClipboardMonitor` left every guard green
    /// before the static token list learned about it.)
    func testTheMonitorPollsTheSeamBoard() {
        let board = NSPasteboard.withUniqueName()
        AppPasteboard.setShared(board)
        defer { AppPasteboard.setShared(nil) }

        let delegate = MonitorStubDelegate()
        let monitor = ClipboardMonitor()
        monitor.delegate = delegate

        board.clearContents()
        board.setString("monitor seam probe 42", forType: .string)
        monitor.checkClipboard()
        // The capture is handed to the delegate on the main queue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(
            delegate.captured.map(\.content), ["monitor seam probe 42"],
            "the monitor must poll the seam's board — a monitor on the user's "
            + "clipboard would read the user's real clipboard during every test"
        )
    }

    /// A minimal `ClipboardMonitorDelegate` that only records what it is
    /// handed.
    private final class MonitorStubDelegate: ClipboardMonitorDelegate {
        var captured: [ClipboardItem] = []
        func sensitiveClearHoursForMonitor() -> Int { 0 }
        func captureRichTextSettingForMonitor() -> Bool { true }
        var captureRichTextPublisher: AnyPublisher<Bool, Never> {
            Empty().eraseToAnyPublisher()
        }
        func monitorDidCaptureItem(_ item: ClipboardItem) { captured.append(item) }
        func ocrEnabledForMonitor() -> Bool { false }
        func monitorDidRecognizeText(_ text: String, forImageItemId id: UUID, contentHash: String?) {}
    }

    // MARK: - Static guard: only the seam may name the general pasteboard

    /// Tokens that reach the SYSTEM-WIDE general pasteboard — or the spellings
    /// that must never appear in production code.
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
    ///
    /// ⚠️ `NSPasteboard(name:` is the **by-name route to the SAME board**:
    /// measured 2026-10-27, `NSPasteboard(name: NSPasteboard.Name("Apple
    /// CFPasteboard general"))` `===` `NSPasteboard.general` → **true**, and
    /// writing to it lands on the user's clipboard. The NAME is a string
    /// literal ⇒ blanking hides it ⇒ the token watches the CALL SHAPE, not
    /// the name. (The independent verifier's mutation MX7 used exactly this
    /// spelling in `ClipboardMonitor` and left every guard green before this
    /// token existed.)
    private static let generalPasteboardTokens = [
        "NSPasteboard.general",
        "NSPasteboard()",
        "NSPasteboard(name:"
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
            TestSourceScanner.occurrenceCount(of: "=== NSPasteboard.general", in: blanked), 1,
            "the seam's general-pasteboard probe must compare the resolved board by "
            + "identity with NSPasteboard.general — a hard-coded answer would make "
            + "the behavioural guard vacuous"
        )
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(of: "resolve(", in: blanked), 2,
            "the seam's live resolution must go through the pure `resolve(…)` "
            + "function — exactly one definition and exactly one call site, so "
            + "the production branch cannot be shadowed by an earlier return"
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

    /// POSITIVE control for the BY-NAME route.
    ///
    /// `NSPasteboard(name: NSPasteboard.Name("Apple CFPasteboard general"))`
    /// is the **same object** as `NSPasteboard.general` (measured 2026-10-27:
    /// `byName === general` → true, and writing to it lands on the user's
    /// clipboard). The NAME is a string literal ⇒ blanking hides it ⇒ the
    /// guard watches the CALL SHAPE instead.
    ///
    /// Without this control, dropping the `NSPasteboard(name:` token from
    /// the list would go unnoticed — the independent verifier's mutation
    /// MX7 did exactly that and every guard stayed green.
    func testTheScannerAlsoCatchesTheByNameRoute() {
        let planted = """
        func demo() {
            let board = NSPasteboard(name: NSPasteboard.Name("Apple CFPasteboard general"))
            board.clearContents()
        }
        """
        XCTAssertEqual(
            Self.generalPasteboardUses(in: planted), 1,
            "the by-name route to the general pasteboard must be caught — it is "
            + "the SAME OBJECT as NSPasteboard.general"
        )
    }
}
