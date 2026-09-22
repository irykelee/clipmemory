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
    static private(set) var crypto: CryptoServiceProtocol = CryptoService.shared {
        didSet {
            let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if !inTest {
                preconditionFailure(
                    "ServiceContainer.crypto reassigned outside XCTest — race risk."
                )
            }
        }
    }

    static func setCryptoForTesting(_ service: CryptoServiceProtocol) {
        let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        precondition(inTest, "setCryptoForTesting called outside XCTest")
        crypto = service
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
    static private(set) var firstLaunch: FirstLaunchService = FirstLaunchService() {
        didSet {
            let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if !inTest {
                preconditionFailure(
                    "ServiceContainer.firstLaunch reassigned outside XCTest — race risk."
                )
            }
        }
    }

    static func setFirstLaunchForTesting(_ service: FirstLaunchService) {
        let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        precondition(inTest, "setFirstLaunchForTesting called outside XCTest")
        firstLaunch = service
    }
}
