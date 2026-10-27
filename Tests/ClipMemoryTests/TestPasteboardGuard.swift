import AppKit
@testable import ClipMemory

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
/// This guard snapshots the pasteboard before the test and restores it
/// afterwards, so the user's data survives the run.
///
/// ## ID-REVIEW-1042 (2026-10-27): what this guard does NOW
///
/// ID-REVIEW-1042 added a production seam (`AppPasteboard`) that binds the
/// app to a PRIVATE pasteboard in a test process. Two consequences:
///
/// * The guard now operates on **the board the app actually uses** — which
///   in a test process is that private board, not the user's clipboard. So
///   the guard no longer needs to name `NSPasteboard.general` at all, and
///   the user's clipboard is never emptied, not even for the duration of a
///   test.
/// * The guard's remaining job is **test isolation**: it clears the app's
///   pasteboard at `begin()` and puts back whatever was there at `end()`, so
///   one test's fixture cannot leak into the next.
///
/// The guard therefore KEEPS its snapshot/restore mechanics (they are still
/// what isolates tests from each other) but REDIRECTS them through the seam.
/// The old "protect the user's clipboard" job is now done upstream, at the
/// seam, where it no longer has a window.
///
/// This file is the sanctioned accessor for the app's pasteboard in the test
/// tree. `Review1041RegressionTests` enforces statically that NO test file
/// names `NSPasteboard.general`, and `Review1042RegressionTests` enforces
/// that the app tree names it only in `AppPasteboard.swift`.
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
    /// **original** snapshot, so `end()` restores what was actually there
    /// rather than an intermediate state.
    private static var isActive = false

    /// The one sanctioned accessor for the app's pasteboard.
    ///
    /// ID-REVIEW-1042: resolves through the production seam, so it is the
    /// SAME board the app writes to — the private one under XCTest, the
    /// system-wide general one in production.
    static var pasteboard: NSPasteboard {
        lock.lock()
        defer { lock.unlock() }
        return AppPasteboard.shared
    }

    /// Point the app's pasteboard at another board. `nil` restores the
    /// default resolution.
    ///
    /// Used by this guard's own regression test so that verifying the
    /// restore path does not itself disturb the shared test pasteboard.
    static func usePasteboardForTesting(_ board: NSPasteboard?) {
        AppPasteboard.setShared(board)
    }

    /// Snapshot the pasteboard and clear it. Call from `setUp()`.
    static func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard !isActive else { return }
        let board = AppPasteboard.shared
        savedItems = snapshot(of: board)
        isActive = true
        board.clearContents()
    }

    /// Restore what was there. Call from `tearDown()`.
    ///
    /// Unconditional restore: even if the test wrote something *new*, this
    /// puts the pre-test content back, so one test's fixture cannot leak
    /// into the next.
    ///
    /// A `tearDown()` that runs **without** a matching `begin()` is a no-op
    /// on purpose: a stray `end()` must never empty the board.
    static func end() {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        isActive = false
        let board = AppPasteboard.shared
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
    /// pasteboard, and drop any board override. Used by the guard's own
    /// regression test to avoid leaking state into the rest of the suite.
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        savedItems = []
        isActive = false
        AppPasteboard.setShared(nil)
    }
}
