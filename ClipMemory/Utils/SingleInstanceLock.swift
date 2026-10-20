import Darwin
import Foundation
import os.log

/// ID-CRASH-0032 (2026-10-20) — the single-instance lock.
///
/// ## What it protects
///
/// The clipboard history and the recycle bin are stored as WHOLE-ARRAY
/// replacements: `ClipboardItems` and `ClipboardTrashedItems` are one JSON
/// blob each, and every write replaces the whole array. Two processes each
/// hold their own snapshot of that blob, so the second writer replaces the
/// first writer's blob with its own stale copy — entries the first deleted
/// come back, entries the first added disappear.
///
/// ## Why `flock` and not "is another process running?"
///
/// * The kernel releases an `flock` when the owning process exits, even on
///   SIGKILL, so a crashed instance can never leave a stale lock behind.
/// * The lock lives on a file, so every copy of the app shares it: an
///   `/Applications` install and a Debug build in DerivedData have the same
///   bundle id, the same UserDefaults domain and therefore the same data.
/// * It is atomic. Two processes starting in the same instant cannot both
///   win; a "list the running applications" check has a race window.
///
/// Measured on this machine: `flock` locks are held per *open file
/// description*, so two `open()` calls in the same process conflict with
/// each other — which is what makes the exclusion testable in-process.
///
/// ## Deliberately NOT taken by a test host
///
/// `xcodebuild test` launches the app binary itself. A test host is already
/// isolated onto its own UserDefaults suite (see `TestIsolation`), so it
/// never contends for the user's data — and it must not lock the user out
/// of their own app while the suite runs.
final class SingleInstanceLock {
    private static let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "SingleInstanceLock"
    )

    /// The shared instance used by the app.
    static let shared = SingleInstanceLock()

    /// Where the lock file lives. Every copy of the app resolves to the
    /// same path, because it depends only on the user's Application Support
    /// directory — not on where the bundle happens to live.
    static var defaultFileURL: URL {
        AppDirectories.applicationSupport
            .appendingPathComponent("ClipMemory", isDirectory: true)
            .appendingPathComponent(".instance.lock")
    }

    private let fileURL: URL
    private var descriptor: Int32 = -1

    init(fileURL: URL = SingleInstanceLock.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// True while this process holds the lock.
    var isHeld: Bool { descriptor >= 0 }

    /// Tries to become the only instance allowed to write the user's data.
    ///
    /// - Parameters:
    ///   - timeout: how long to keep retrying while another instance is
    ///     still shutting down. A quitting instance releases the lock when
    ///     its process exits, so a short wait covers "quit and relaunch".
    ///   - pollInterval: delay between attempts.
    /// - Returns: `true` when this process owns the lock.
    ///
    /// Failure mode: if the lock file cannot be created at all, this
    /// returns `true` (fail open) and logs. The guard is defence in depth,
    /// not the primary data path — refusing to start the app over a lock
    /// file would be a worse failure than running unguarded.
    func acquire(timeout: TimeInterval, pollInterval: TimeInterval = 0.05) -> Bool {
        if descriptor >= 0 { return true }
        // The app's Application Support folder does not exist yet on a
        // fresh install — and the guard runs before anything else creates
        // it. Without this, `open` would fail with ENOENT and the guard
        // would silently fall back to "no guard" on exactly the installs
        // that need it least but also the ones that need it most.
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fd = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Self.logger.error("""
            ID-CRASH-0032: cannot open the instance lock at \(self.fileURL.path) \
            (errno \(errno)); continuing without the single-instance guard
            """)
            return true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                descriptor = fd
                return true
            }
            let code = errno
            if code != EWOULDBLOCK && code != EINTR {
                Self.logger.error("""
                ID-CRASH-0032: flock failed with errno \(code); continuing \
                without the single-instance guard
                """)
                close(fd)
                return true
            }
            if Date() >= deadline {
                close(fd)
                return false
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// Releases the lock. The kernel would do this when the process exits
    /// anyway; releasing explicitly is what lets a test (or a controlled
    /// handover) re-acquire it.
    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
