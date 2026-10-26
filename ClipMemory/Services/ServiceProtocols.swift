import Foundation

// MARK: - Encryption

protocol CryptoServiceProtocol {
    func encrypt(_ string: String) -> String?
    func decrypt(_ base64String: String) -> String?
    func encryptData(_ data: Data) -> Data?
    func decryptData(_ combined: Data) -> Data?
    func isOldFormat(_ base64String: String) -> Bool
    func migrateToV2(_ base64String: String) -> String?
    func hmacHex(for string: String) -> String?
    /// Decrypts with explicit failure reason. Single chokepoint for search
    /// path so callers can distinguish transient key unavailability from
    /// permanent data corruption (P0-2 NR2/NR4).
    func decryptWithReason(_ base64String: String, itemID: UUID) -> DecryptResult
}

// MARK: - Service Container

enum ServiceContainer {
    /// Crypto service backing encrypt/decrypt across the store, image save,
    /// and backup package I/O.
    ///
    /// BUG-049 (2026-07-21): the previous `static var` allowed any code
    /// path to reassign the instance mid-run. A background thread that
    /// read `crypto` just before the swap would continue using a stale or
    /// partially-initialized instance while the main thread used the new
    /// one, causing inconsistent encrypt/decrypt across the same items
    /// array. The full fix is DI via init injection (deferred to a future
    /// refactor). For now, the setter is restricted to XCTest contexts:
    /// production code that accidentally swaps triggers
    /// `preconditionFailure` (Debug AND Release — aborts the process so a
    /// production swap can never silently take effect). Tests still work
    /// because their pattern is
    /// `setUp: save original, inject fake / tearDown: restore original`
    /// — both swaps happen under XCTestConfigurationFilePath.
    ///
    /// H-1 hardening (2026-07-23): previous version used
    /// `assertionFailure`, which is elided in `-O` builds. A Release
    /// production swap would silently bypass the guard. Bumping to
    /// `preconditionFailure` closes that hole without expanding scope
    /// (still no DI refactor).
    ///
    /// L-6 (2026-07-25 audit): `preconditionFailure` here is intentional
    /// fail-fast. A production crypto-swap is a catastrophic programming
    /// error; crashing immediately is safer than continuing with split-brain
    /// encryption keys. It is not converted to a recoverable error because
    /// there is no safe recovery path once two code paths hold different
    /// `CryptoService` instances.
    ///
    /// ⚠️ ID-REVIEW-1034 (2026-10-26) changed WHERE that guard lives: the
    /// `preconditionFailure` used to sit in the property's `didSet`. The
    /// property no longer has a setter at all — the only writer is
    /// `setCryptoForTesting(_:)`, which carries its own
    /// `precondition(inTest, …)`. A production swap is therefore a
    /// **compile error** now, which is strictly stronger than the runtime
    /// trap it replaces. The prose above describes the guard's INTENT
    /// (fail fast, never silently split-brain); the mechanism moved.
    ///
    /// ID-REVIEW-1034 (2026-10-26): the crypto seam is READ from background
    /// queues (the contentHash backfill, `ImageStorage`'s encrypt/decrypt)
    /// and SWAPPED by tests on the main thread. As a plain `static var` the
    /// read-modify-write of the existential box was not atomic: a background
    /// reader could retain the box after the writer had already released it
    /// ⇒ over-release ⇒ the Swift runtime aborts the process with
    /// "Object ... of class CryptoService deallocated with non-zero retain
    /// count 2".
    ///
    /// That abort is what made CI run 40186263416 red. The host died inside
    /// `DecryptionFailedLoopTests.testPreFailedItemReturnsNilImmediately`;
    /// xcodebuild relaunched it ("Restarting after unexpected exit, crash, or
    /// test timeout"); the relaunched process skipped the alphabetically-first
    /// `AAASuiteBootstrapTests` (so the shared-suite cleanup observer was
    /// never registered — see `XCTestIsolationSuiteBootstrap`); a stale
    /// `maxClipboardItems = 3` left in the shared suite by
    /// `IntegrationTests.testTrimToMaxItemsRemovesOldest` then broke
    /// `QuickBarViewTests` hundreds of lines later.
    ///
    /// Fix: the storage is lock-guarded, so the box is never read and
    /// written concurrently. The lock is NOT held while the caller uses the
    /// returned service — `CryptoService` is internally thread-safe.
    ///
    /// The setter is gone entirely (it was `private(set)` anyway, so only
    /// `setCryptoForTesting` could reach it): assigning
    /// `ServiceContainer.crypto` is now a COMPILE error (the property is
    /// get-only) instead of a runtime trap, which is strictly stronger than
    /// the previous `preconditionFailure` guard.
    ///
    /// ID-REVIEW-1035 (2026-10-26): that compile-time guarantee covers
    /// DIRECT ASSIGNMENT only. The remaining writer, `setCryptoForTesting`,
    /// is `internal` (not `fileprivate`), so a production call site would
    /// still compile and would only trip the runtime `precondition` below.
    private static let cryptoLock = NSLock()
    private static var cryptoStorage: CryptoServiceProtocol = CryptoService.shared

    static var crypto: CryptoServiceProtocol {
        cryptoLock.lock()
        defer { cryptoLock.unlock() }
        return cryptoStorage
    }

    static func setCryptoForTesting(_ service: CryptoServiceProtocol) {
        let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        precondition(inTest, "setCryptoForTesting called outside XCTest")
        cryptoLock.lock()
        defer { cryptoLock.unlock() }
        cryptoStorage = service
    }

    // MARK: - First Launch (P1-AUDIT-2026-09-22 P1-5)

    /// First-launch marker service. Replaces `FirstLaunchManager`'s direct
    /// `UserDefaults.standard.bool/set(forKey:)` access — the View (`WelcomeView`)
    /// and `AppDelegate` now read/write via this single service handle.
    ///
    /// The key (`"hasLaunchedBefore"`) is preserved so existing user state
    /// survives this refactor without migration. The key is intentionally
    /// registered in `ZZZSuiteTeardownTests.appLifecycleKeys` so the
    /// canary catches accidental new keys appearing on a cold run.
    ///
    /// Post-OpenCode-auto-review P2 fix (2026-09-22): the previous `static let`
    /// made the seam declared in `FirstLaunchService.init(store:)` unreachable
    /// from production callers (no setter, no DI path). Promoted to
    /// `static private(set) var` with the same XCTest-only `preconditionFailure`
    /// guard as `crypto` above; `setFirstLaunchForTesting(_:)` mirrors
    /// `setCryptoForTesting(_:)` for tests that need to swap the store.
    /// ID-REVIEW-1036 (2026-10-26): lock-protected, mirroring `crypto`
    /// above.
    ///
    /// The readers (`WelcomeView.FirstLaunchManager.isFirstLaunch` /
    /// `markLaunched`) are plain `static` helpers on a **view-layer** type —
    /// NOT actor-isolated, so they are callable from any thread — while the
    /// only writer (`setFirstLaunchForTesting`) runs on the test thread.
    /// That is the same read-modify-write of a class box that aborted the
    /// test host in CI run 40186263416 (see `crypto` above): the moment a
    /// background caller appears, an unsynchronized swap would over-release
    /// the box.
    ///
    /// The "only under XCTest" contract is unchanged and now *stronger*: the
    /// stored property's `didSet` precondition is replaced by a get-only
    /// computed accessor, so a direct assignment is a COMPILE error; the only
    /// writer left is `setFirstLaunchForTesting`, which keeps its own
    /// runtime precondition.
    private static let firstLaunchLock = NSLock()
    private static var firstLaunchStorage: FirstLaunchService = FirstLaunchService()

    static var firstLaunch: FirstLaunchService {
        firstLaunchLock.lock()
        defer { firstLaunchLock.unlock() }
        return firstLaunchStorage
    }

    static func setFirstLaunchForTesting(_ service: FirstLaunchService) {
        let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        precondition(inTest, "setFirstLaunchForTesting called outside XCTest")
        firstLaunchLock.lock()
        defer { firstLaunchLock.unlock() }
        firstLaunchStorage = service
    }
}
