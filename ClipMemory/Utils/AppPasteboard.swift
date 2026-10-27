import AppKit
import Foundation

/// The pasteboard the app reads from and writes to.
///
/// ## Why this seam exists
///
/// ID-REVIEW-1042 (2026-10-27): the test bundle is injected into the APP
/// binary (`TEST_HOST`), so `NSPasteboard.general` inside a test process IS
/// the user's real system clipboard.
///
/// ID-REVIEW-1041 measured the damage on the maintainer's machine: the
/// suite's fixture strings landed in the user's clipboard — where a
/// **separately running** ClipMemory app (which has its own monitor and
/// watches the system-wide pasteboard) captured them into the user's real
/// history — and the final `clearContents()` emptied the clipboard outright.
///
/// ID-REVIEW-1041 fixed the DAMAGE with a test-side guard (snapshot the
/// pasteboard, restore it afterwards). It could not fix the WINDOW: a
/// snapshot has to empty the user's clipboard to be taken, and the app had
/// no way to write anywhere else, so the suite's fixtures sat on the user's
/// clipboard for the duration of every affected test. That remainder was
/// recorded honestly as an unfixed gap in `docs/skips-ledger.md` §41.
///
/// This seam closes the window at the source: in a test process the app
/// binds to a PRIVATE, process-local pasteboard, so a production write can
/// never reach the user's clipboard at all.
///
/// ## Why a global seam rather than per-site injection
///
/// Per-site injection (a `pasteboard:` parameter on every call site) would
/// leave "the site somebody forgot" as a hole — the same shape of defect
/// ID-REVIEW-1038's M4 lesson. A global seam has no such list to forget:
/// every read and write resolves through one place, and the test process
/// activates it automatically.
///
/// ## Resolution
///
/// * **Production** → `NSPasteboard.general`: byte-identical to the
///   pre-ID-REVIEW-1042 behaviour, where every site named `.general`
///   directly.
/// * **Test process** → this seam's OWN private pasteboard, never `.general`.
///   Created ONCE and cached — `NSPasteboard.withUniqueName()` returns a
///   NEW object on every call (measured 2026-10-27), so a seam that
///   resolved it per access would hand the clipboard monitor a different
///   board on every poll tick.
/// * **A test that needs a specific board** overrides it with
///   `setShared(_:)`.
///
/// ## Known, unfixed hazard
///
/// The "production ⇒ `.general`" half of the contract depends on
/// `TestIsolation.isRunningTests` being FALSE in a production process. That
/// is the same assumption ID-REVIEW-1039's `AppStorageDefaults` seam already
/// relies on (if it were true in production, the app would read its
/// appearance settings from a test-only suite instead of the user's domain).
/// It cannot be asserted from inside a test process; `Review1042RegressionTests`
/// covers it statically instead (the seam must resolve to `.general` on its
/// default branch, and its private board must stay gated on the test probe).
enum AppPasteboard {

    /// The lock.
    ///
    /// The read points are NOT all on the main actor: `ClipboardMonitor`
    /// polls from its own timer queue (`com.clipmemory.clipboardmonitor`),
    /// and the cold-image copy completion in `ClipboardStore` runs off the
    /// main queue too. A bare `static var` would be a data race — the same
    /// shape that aborted the test host in CI run 40186263416 (see
    /// `AppStorageDefaults` for the same reasoning on the storage seam).
    ///
    /// The lock is NOT held while the caller uses the returned
    /// `NSPasteboard` — `NSPasteboard` is internally thread-safe.
    private static let lock = NSLock()

    /// The test override, if any.
    private nonisolated(unsafe) static var overrideBoard: NSPasteboard?

    /// This seam's own private board in a test process.
    ///
    /// `nil` in production (where `.general` is used instead), so the
    /// private pasteboard is never created outside XCTest — the pasteboard
    /// server entry would otherwise linger for the life of the app.
    private nonisolated static let xcTestPasteboard: NSPasteboard? = {
        guard TestIsolation.isRunningTests else { return nil }
        return NSPasteboard.withUniqueName()
    }()

    /// The pasteboard the app reads from and writes to.
    static var shared: NSPasteboard {
        lock.lock()
        defer { lock.unlock() }
        if let override = overrideBoard { return override }
        if let testBoard = xcTestPasteboard { return testBoard }
        return NSPasteboard.general
    }

    /// Points the app's pasteboard at `board`.
    ///
    /// Pass `nil` to go back to the default resolution. Tests call this in
    /// `setUp` and restore it in `tearDown`; production never calls it.
    static func setShared(_ board: NSPasteboard?) {
        lock.lock()
        defer { lock.unlock() }
        overrideBoard = board
    }

    /// True when the app is bound to the SYSTEM-WIDE general pasteboard —
    /// i.e. the user's real clipboard.
    ///
    /// False in a test process: the seam resolves to a private board there,
    /// so the suite can neither read nor write the user's clipboard.
    ///
    /// This exists so that the TEST TREE never has to name
    /// `NSPasteboard.general` itself. Naming it in a test file is what
    /// `Review1041RegressionTests` forbids (and what puts an accidental
    /// write to the user's clipboard one keystroke away); routing the
    /// question through the seam keeps that name in exactly one place in
    /// the whole repository.
    static var isSystemGeneral: Bool {
        shared === NSPasteboard.general
    }
}
