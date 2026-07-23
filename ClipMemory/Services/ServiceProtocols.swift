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
}

// MARK: - Sensitive Detection

protocol SensitiveDetectorProtocol {
    func detectSensitive(_ content: String) -> Bool
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
    static var crypto: CryptoServiceProtocol = CryptoService.shared {
        didSet {
            let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            // No-op same-instance assignment in tests is fine; any
            // production swap (oldValue is the production singleton) is
            // not.
            if !inTest {
                preconditionFailure(
                    "ServiceContainer.crypto reassigned outside XCTest — race risk. " +
                    "Use only in test setUp/tearDown."
                )
            }
        }
    }
}
