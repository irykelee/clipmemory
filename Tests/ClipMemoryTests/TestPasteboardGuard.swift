import AppKit

/// ID-REVIEW-1041 (2026-10-27): the test tree wrote to — and finally
/// **emptied** — the user's REAL system clipboard (`NSPasteboard.general`).
///
/// Measured on the maintainer's machine, with a live ClipMemory app running
/// while the suite executed (poll every 150 ms during a targeted run):
///
///     +0.01s  'copy me'
///     +1.54s  'clipmemory own write'
///     +1.89s  'external paste'
///     +2.24s  'clipmemory own write'
///     +3.16s  ''                  ← the user's clipboard was EMPTIED
///
/// Two distinct harms:
/// 1. the suite's own fixture strings land in the user's clipboard — and a
///    **separately running** ClipMemory app captures them into the user's
///    real history (that app has its own monitor and watches the system-wide
///    pasteboard; the repo's existing XCTest guard only disables the monitor
///    *inside the test host*, see `SettingsWindowTests` / ID-MON-0002);
/// 2. the final `clearContents()` **destroys** whatever the user had copied.
///
/// This guard snapshots the real pasteboard before the test and restores it
/// afterwards, so the user's data survives the run.
///
/// ⚠️ **Scope, stated honestly** — this is a TEST-side guard, deliberately
/// **zero production change**. The suite still writes fixture content to the
/// general pasteboard *for the duration of the affected tests* (the monitor
/// reads `NSPasteboard.general` with no injection seam), so a separately
/// running app can still capture that content in that window. Removing that
/// residual needs a pasteboard seam in production code — recorded in
/// `docs/skips-ledger.md` §41 as a known, unfixed remainder.
///
/// This file is the **only** place in the test tree allowed to name
/// `NSPasteboard.general`. `Review1041RegressionTests` enforces that
/// statically, and also enforces that every file using the pasteboard pairs
/// `begin()` with `end()`.
enum TestPasteboardGuard {

    /// Guards the mutable state below.
    ///
    /// `NSLock` rather than an actor: two of the affected test classes are
    /// NOT `@MainActor`, and `NSPasteboard` is main-thread-only anyway (every
    /// caller here is on the main thread — XCTest runs non-async test cases
    /// there), so an actor would only add friction.
    private static let lock = NSLock()

    /// One pasteboard item: its types and their payloads.
    ///
    /// ⚠️ **The payload is copied, the `NSPasteboardItem` object is not.**
    /// Holding the item object and writing it back later fails with
    /// `NSInvalidArgumentException: Cannot write pasteboard item … It is
    /// already associated with another pasteboard` — `clearContents()`
    /// invalidates the items it handed out, and the system may re-associate
    /// them elsewhere. Measured 2026-10-27: the guard's own regression test
    /// caught exactly this in the first implementation.
    private typealias ItemSnapshot = (type: String, data: Data)

    /// The snapshot taken by `begin()`, restored by `end()`.
    private static var savedItems: [[ItemSnapshot]] = []

    /// Whether a snapshot is currently held. Nested `begin()` calls keep the
    /// **original** snapshot, so `end()` restores what the user actually had
    /// rather than an intermediate state.
    private static var isActive = false

    /// A pasteboard to operate on instead of the general one.
    ///
    /// Used by this guard's own regression test so that verifying the
    /// restore path does not itself disturb the user's clipboard.
    private static var overrideBoard: NSPasteboard?

    /// The one sanctioned accessor for the general pasteboard.
    ///
    /// Reads and writes are allowed here; the *cleanup* is what this guard
    /// exists for, so pair every use with `begin()` / `end()`.
    static var pasteboard: NSPasteboard {
        lock.lock()
        defer { lock.unlock() }
        return overrideBoard ?? NSPasteboard.general
    }

    /// Point the guard at another pasteboard. `nil` restores the general one.
    static func usePasteboardForTesting(_ board: NSPasteboard?) {
        lock.lock()
        defer { lock.unlock() }
        overrideBoard = board
    }

    /// Snapshot the user's pasteboard and clear it. Call from `setUp()`.
    static func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard !isActive else { return }
        let board = overrideBoard ?? NSPasteboard.general
        savedItems = snapshot(of: board)
        isActive = true
        board.clearContents()
    }

    /// Restore what the user had. Call from `tearDown()`.
    ///
    /// Unconditional restore: even if the user copied something *new* during
    /// the test window, this puts the pre-test content back. That is still
    /// strictly better than the previous behaviour (emptying the clipboard),
    /// and the window is a few seconds wide.
    ///
    /// A `tearDown()` that runs **without** a matching `begin()` is a no-op
    /// on purpose: a stray `end()` must never empty the user's clipboard.
    static func end() {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        isActive = false
        let board = overrideBoard ?? NSPasteboard.general
        board.clearContents()
        let objects = savedItems.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !objects.isEmpty {
            board.writeObjects(objects as [NSPasteboardWriting])
        }
        savedItems = []
    }

    /// Copy the board's contents out as plain data.
    ///
    /// Types whose payload cannot be read (promised file URLs and the like)
    /// are skipped — a test guard cannot meaningfully restore those.
    private static func snapshot(of board: NSPasteboard) -> [[ItemSnapshot]] {
        (board.pasteboardItems ?? []).map { item in
            var entry: [ItemSnapshot] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                entry.append((type.rawValue, data))
            }
            return entry
        }
    }

    /// Test-only: forget any pending snapshot without touching the
    /// pasteboard. Used by the guard's own regression test to avoid leaking
    /// state into the rest of the suite.
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        savedItems = []
        isActive = false
        overrideBoard = nil
    }
}
