import Foundation
import os.log

// P2-3 (OpenCode auto-review, 2026-09-23): the Keychain migration
// failure-classification helper lives in a sibling extension file
// because CryptoService.swift is at the SwiftLint file_length error
// threshold (1250 lines). This mirrors the pattern established by
// CryptoService+TestSeams.swift for test seams — extracted to honor
// the cap, not to add new functionality. Behavior is unchanged from
// the inline block in the previous commit; this is purely a relocation.
//
// Three-piece gate (CLAUDE.md 2026-08-08):
//  - 报错: error/notice logs include the OSStatus for diagnostics
//  - 重试: keep fallback on transient + unknown (err on caution); the
//    caller publishes the key to the shared cache from the file's bytes
//    so the in-session key is intact regardless of disk state
//  - 用户可见: .encryptionFailed NSAlert via EncryptionFailedAlertThrottler;
//    separate buckets (.transient / .permanent / .unknown) so transient
//    alerts don't suppress permanent alerts (and vice versa)

extension CryptoService {
    /// Classify a Keychain store failure during legacy `.encryption_key` →
    /// Keychain migration. Takes the optional typed error, the fallback
    /// URL, and an optional human-readable reason (for the unknown-error
    /// branch which has no OSStatus). The shared cache is not touched here
    /// — the caller still publishes the key from the file's bytes so the
    /// in-session encrypt/decrypt path remains intact.
    ///
    /// - `error: nil` → unknown error path (keep fallback; err on caution).
    /// - `.transient(s)` → keep fallback; next-launch retry will fix.
    /// - `.permanent(s)` (or synthetic `.permanent(errSecVerifyFailed)`
    ///   from the verification-mismatch branch) → delete fallback + alert;
    ///   user must act.
    ///
    /// Note: takes `logger` as a parameter because `CryptoService.logger`
    /// is `private` (single-file scope); the extension lives in a sibling
    /// file to honor the SwiftLint file_length cap.
    static func handleKeychainMigrationFailure(
        error: KeyStoreError?,
        keyURL: URL,
        logger: Logger,
        reason: String? = nil
    ) {
        let shouldDelete: Bool
        let source: String
        let recoverable: Bool
        let status: OSStatus?
        switch error {
        case .none:
            shouldDelete = false; source = "keychainMigration.unknown"
            recoverable = true; status = nil
            logger.error("Keychain migration failed with unknown error: \(reason ?? "?"); keeping fallback (err on caution, P2-3)")
        case .some(.transient(let s)):
            shouldDelete = false; source = "keychainMigration.transient"
            recoverable = true; status = s
            logger.notice("P2-3: transient Keychain error \(s); keeping fallback for retry")
        case .some(.permanent(let s)):
            shouldDelete = true; source = "keychainMigration.permanent"
            recoverable = false; status = s
            logger.notice("P2-3: permanent Keychain error \(s); deleting fallback + alert")
        }
        if shouldDelete { secureRemoveKeyFile(at: keyURL) }
        var info: [String: Any] = ["source": source, "recoverable": recoverable]
        if let status { info["status"] = Int(status) }
        NotificationCenter.default.post(name: .encryptionFailed, object: nil, userInfo: info)
    }
}