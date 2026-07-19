import Foundation
import AppKit
import CryptoKit
import CommonCrypto
import os.log

/// Why the app encryption key could not be prepared (H6).
enum CryptoKeyFailure {
    /// Key file exists but is unreadable or not 32 bytes. Regenerating
    /// makes all existing encrypted history undecryptable.
    case corruptExistingKey
    /// SecRandomCopyBytes failed; no key material can be created.
    case secureRandomUnavailable
    /// Key generated but could not be written to disk.
    case keyStorageFailed
}

/// User decision after a `CryptoKeyFailure`.
enum KeyFailureAction {
    /// (Re)generate the key. For a corrupt key this accepts data loss.
    case regenerate
    /// Quit the app. The default handler performs the termination.
    case quit
}

/// Encryption format versions:
/// - v2 (current): "v2" prefix + AES-GCM sealed box (nonce + ciphertext + tag)
/// - v1 (legacy): AES-CBC + HMAC-SHA256, no prefix, for backwards compatibility
/// - pre-1.2.0 (AES-CBC without HMAC) is REJECTED (C4): unauthenticated CBC is
///   a padding-oracle / tampering hole for anyone who can write UserDefaults.
class CryptoService: CryptoServiceProtocol {
    static let shared = CryptoService()

    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "CryptoService")

    /// Legacy key file location (pre-C1). Still consulted as a read-only
    /// fallback and migrated into the Keychain by `prepareKey`; new keys
    /// are never written here. Exposed for ImageStorage migration.
    static var keyFileURL: URL {
        let appSupport = AppDirectories.applicationSupport
        let dir = appSupport.appendingPathComponent("ClipMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".encryption_key")
    }

    /// When set (import/test instances), this key is used instead of the app key.
    private let customKey: SymmetricKey?

    /// True under XCTest. Tests never touch the real Keychain: prepareKey's
    /// migration is skipped (test-never-touch-prod-data) and key reads stay
    /// on the legacy file — the test runner is a different binary, so
    /// querying the production Keychain item could trigger an ACL prompt.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private init() {
        customKey = nil
        if Self.isRunningTests {
            Self.prepareLegacyFileKeyForTests()
        } else {
            Self.prepareKey()
        }
    }

    /// Instance operating on an explicit key rather than the app key.
    /// Used by BackupPackage to decrypt package data with the source machine's
    /// key and re-encrypt with the local one during import.
    init(customKeyData: Data) {
        customKey = SymmetricKey(data: customKeyData)
    }

    /// Raw key bytes of the app key (needed to embed into export packages).
    static func loadKeyData() -> Data? {
        if !isRunningTests, let data = KeychainKeyStore().load(), data.count == 32 { return data }
        return try? Data(contentsOf: keyFileURL)
    }

    /// XCTest only: many fixtures are built against the key file's bytes, so
    /// tests need a stable file key. Ensures one exists (atomic temp write,
    /// 0o600) without ever touching the Keychain. Failures are logged only —
    /// affected tests then fail loudly on their own.
    private static func prepareLegacyFileKeyForTests() {
        let keyURL = keyFileURL
        if let existing = try? Data(contentsOf: keyURL), existing.count == 32 { return }
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            logger.error("Tests: failed to generate random key bytes")
            return
        }
        let tempURL = keyURL.appendingPathExtension("tmp")
        do {
            try keyData.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            try FileManager.default.moveItem(at: tempURL, to: keyURL)
        } catch {
            logger.error("Tests: failed to store key file: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Called instead of crashing when the app key cannot be prepared (H6).
    /// The default shows a critical NSAlert on the main thread and quits the
    /// app unless the user chooses to regenerate. Tests replace this closure
    /// so no alert is shown and no termination happens.
    static var keyFailureHandler: (CryptoKeyFailure) -> KeyFailureAction = { failure in
        CryptoService.defaultKeyFailureHandler(failure)
    }

    /// Prepares the app key: Keychain first, then one-time migration of the
    /// pre-C1 key file, then fresh generation into the Keychain (C1).
    /// A corrupt key file is never silently overwritten (H6): the failure
    /// handler decides whether to regenerate — accepting that existing
    /// history becomes undecryptable — or quit.
    /// - Returns: the key when available; nil only when a custom failure
    ///   handler declined to regenerate (the default handler quits the app
    ///   in that case, so production never silently runs keyless).
    @discardableResult
    static func prepareKey(
        keyURL: URL = CryptoService.keyFileURL,
        keyStore: KeyStoring = KeychainKeyStore(),
        failureHandler: (CryptoKeyFailure) -> KeyFailureAction = CryptoService.keyFailureHandler
    ) -> SymmetricKey? {
        // 1. Keychain is the canonical store.
        if let data = keyStore.load(), data.count == 32 {
            return SymmetricKey(data: data)
        }
        // 2. Migrate a pre-C1 key file, then remove it.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: keyURL.path) {
            if let keyData = try? Data(contentsOf: keyURL), keyData.count == 32 {
                if keyStore.store(keyData) == errSecSuccess, keyStore.load() == keyData {
                    try? fileManager.removeItem(at: keyURL)
                } else {
                    // Keychain unusable (locked/denied): keep the file so the
                    // app still works; migration retries on the next launch.
                    // Restore owner-only perms as defense in depth meanwhile.
                    logger.error("Keychain migration failed; keeping key file until next launch")
                    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
                }
                return SymmetricKey(data: keyData)
            }
            // Corrupt or tampered key file — ask before destroying it.
            guard failureHandler(.corruptExistingKey) == .regenerate else { return nil }
            try? fileManager.removeItem(at: keyURL)
        }
        // 3. Fresh generation into the Keychain.
        return generateAndStoreKey(to: keyStore, failureHandler: failureHandler)
    }

    private static func generateAndStoreKey(
        to keyStore: KeyStoring,
        failureHandler: (CryptoKeyFailure) -> KeyFailureAction
    ) -> SymmetricKey? {
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            logger.error("Failed to generate random key bytes")
            // A CSPRNG failure cannot be fixed by regenerating; the default
            // handler quits the app after alerting. Never fatalError (H6).
            _ = failureHandler(.secureRandomUnavailable)
            return nil
        }
        let status = keyStore.store(keyData)
        guard status == errSecSuccess else {
            logger.error("Failed to store encryption key in Keychain: \(status)")
            // Offer regenerate (e.g. keychain was locked) or an informed
            // quit — never crash (H6).
            guard failureHandler(.keyStorageFailed) == .regenerate else { return nil }
            return generateAndStoreKey(to: keyStore, failureHandler: failureHandler)
        }
        return SymmetricKey(data: keyData)
    }

    private static func defaultKeyFailureHandler(_ failure: CryptoKeyFailure) -> KeyFailureAction {
        let action: KeyFailureAction
        if Thread.isMainThread {
            action = presentKeyFailureAlert(failure)
        } else {
            action = DispatchQueue.main.sync { presentKeyFailureAlert(failure) }
        }
        if action == .quit {
            // Graceful, informed exit instead of fatalError.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return action
    }

    /// Must run on the main thread — callers dispatch.
    private static func presentKeyFailureAlert(_ failure: CryptoKeyFailure) -> KeyFailureAction {
        NSApp.setActivationPolicy(.regular) // LSUIElement app: alert must be visible
        defer { NSApp.setActivationPolicy(.accessory) }
        let alert = NSAlert()
        alert.alertStyle = .critical
        switch failure {
        case .corruptExistingKey:
            alert.messageText = L10n.alertKeyCorruptTitle
            alert.informativeText = L10n.alertKeyCorruptMessage
            // Quit is the default button — a Return-key accident must never
            // destroy the user's history.
            alert.addButton(withTitle: L10n.quitApp)
            alert.addButton(withTitle: L10n.alertKeyButtonReset)
        case .secureRandomUnavailable:
            alert.messageText = L10n.alertKeyRandomTitle
            alert.informativeText = L10n.alertKeyRandomMessage
            alert.addButton(withTitle: L10n.quitApp)
        case .keyStorageFailed:
            alert.messageText = L10n.alertKeyStorageTitle
            alert.informativeText = L10n.alertKeyStorageMessage
            alert.addButton(withTitle: L10n.quitApp)
            alert.addButton(withTitle: L10n.alertKeyButtonRetry)
        }
        let response = alert.runModal()
        if failure == .secureRandomUnavailable { return .quit }
        return response == .alertSecondButtonReturn ? .regenerate : .quit
    }

    private func getKey() -> SymmetricKey? {
        if let customKey { return customKey }
        // C1: Keychain is canonical; the pre-C1 key file remains a read-only
        // fallback until prepareKey's migration removes it. Under XCTest,
        // read only the file — never prompt for the real Keychain item.
        if !Self.isRunningTests, let data = KeychainKeyStore().load(), data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard let keyData = try? Data(contentsOf: Self.keyFileURL), keyData.count == 32 else {
            return nil
        }
        return SymmetricKey(data: keyData)
    }

    // MARK: - Public API

    /// Encrypts string using AES-GCM (v2 format). Returns base64 encoded string with "v2" prefix.
    func encrypt(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        return encryptBytes(Array(data)).map { $0.base64EncodedString() }
    }

    /// Encrypts raw Data (for images) using AES-GCM (v2 format).
    func encryptData(_ data: Data) -> Data? {
        return encryptBytes(Array(data))
    }

    /// Decrypts base64 string. Automatically detects format (v2 or legacy).
    func decrypt(_ base64String: String) -> String? {
        guard let combined = Data(base64Encoded: base64String) else {
            return nil
        }
        guard let bytes = decryptBytes(from: combined) else {
            return nil
        }
        guard let result = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        return result
    }

    /// Decrypts raw Data (for images). Automatically detects format.
    func decryptData(_ combined: Data) -> Data? {
        guard let bytes = decryptBytes(from: combined) else {
            return nil
        }
        return Data(bytes)
    }

    /// Computes a deterministic HMAC-SHA256 hex digest of `string` using the
    /// app's symmetric key. Used for content deduplication; replaces the prior
    /// unsalted SHA256 which acted as an offline dictionary oracle for short
    /// secrets stored in UserDefaults alongside the ciphertext.
    func hmacHex(for string: String) -> String? {
        guard let key = getKey(), let data = string.data(using: .utf8) else {
            return nil
        }
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Encryption (v2: AES-GCM)

    private func encryptBytes(_ bytes: [UInt8]) -> Data? {
        guard let key = getKey() else { return nil }

        do {
            let sealedBox = try AES.GCM.seal(bytes, using: key)
            guard let combined = sealedBox.combined else { return nil }

            // Prepend "v2" format marker
            var result = Data("v2".utf8)
            result.append(combined)
            return result
        } catch {
            Self.logger.error("AES-GCM encryption failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Decryption (v2 and legacy)

    /// Returns nil if decryption fails for any reason.
    /// Tries v2 (AES-GCM) first, then legacy (AES-CBC+HMAC).
    private func decryptBytes(from combined: Data) -> [UInt8]? {
        // Detect format by "v2" prefix
        if combined.count >= 2 && combined.prefix(2) == Data("v2".utf8) {
            let sealedBoxData = combined.dropFirst(2)
            return decryptV2(data: Data(sealedBoxData))
        }
        // Legacy format (no prefix)
        return decryptLegacy(from: combined)
    }

    private func decryptV2(data: Data) -> [UInt8]? {
        guard let key = getKey() else { return nil }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            return Array(decrypted)
        } catch {
            return nil
        }
    }

    // MARK: - Legacy Decryption (AES-CBC+HMAC, pre-v2 format)

    /// Returns true if the given base64 string uses the legacy (pre-v2) format.
    /// C4: strict byte-prefix check only. v2 payloads are self-describing ("v2"
    /// marker); anything without the marker is treated as legacy. Decryption
    /// success is never used as a classifier — that gave a UserDefaults-writing
    /// attacker a v2/legacy oracle for free.
    func isOldFormat(_ base64String: String) -> Bool {
        guard let combined = Data(base64Encoded: base64String) else { return false }
        return !(combined.count >= 2 && combined.prefix(2) == Data("v2".utf8))
    }

    /// Migrates old-format encrypted string to new v2 format.
    /// Returns nil if not old format or migration fails.
    func migrateToV2(_ base64String: String) -> String? {
        guard let combined = Data(base64Encoded: base64String) else { return nil }
        // Already new format
        if combined.count >= 2 && combined.prefix(2) == Data("v2".utf8) { return nil }
        // Try decrypting as old format
        guard let bytes = decryptLegacy(from: combined) else { return nil }
        // Re-encrypt with new format
        return encryptBytes(bytes).map { $0.base64EncodedString() }
    }

    /// Legacy format: 16-byte IV + ciphertext + 32-byte HMAC (minimum 49 bytes).
    /// Returns nil if decryption fails.
    private func decryptLegacy(from combined: Data) -> [UInt8]? {
        guard let key = getKey() else { return nil }

        // New format (v2) with HMAC: minimum 16 (IV) + 1 + 32 (HMAC) = 49 bytes
        if combined.count >= 49 {
            let hmacSize = 32
            // Wrap slice with Data(...) so constantTimeCompare's 0-based loop
            // works. `combined.suffix(_:)` returns Slice<Data> with
            // startIndex = combined.count - hmacSize, not 0 — passing the raw
            // slice causes out-of-bounds subscript trap.
            let storedHMAC = Data(combined.suffix(hmacSize))

            // Verify HMAC over IV || ciphertext (constant-time to prevent
            // timing side-channel forgery of the auth tag)
            let ivAndCiphertext = combined.dropLast(hmacSize)
            let computedHMAC = computeHMAC(data: Data(ivAndCiphertext), key: key)
            guard Self.constantTimeCompare(computedHMAC, storedHMAC) else {
                return nil
            }

            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16).dropLast(hmacSize)
            let keyData = key.withUnsafeBytes { Data($0) }
            return aesDecryptCBC(data: Data(ciphertext), key: keyData, iv: Data(iv))
        }

        // C4: the pre-1.2.0 branch (16-byte IV + ciphertext, no HMAC) was removed.
        // Unauthenticated CBC let anyone who can write UserDefaults tamper with
        // ciphertext undetected and run a padding-oracle attack to recover
        // plaintext byte-by-byte. Such blobs are now rejected outright.
        return nil
    }

    // MARK: - Helpers

    /// Computes HMAC-SHA256 using raw Data key (for legacy format migration).
    /// Exposed for ImageStorage use.
    static func computeLegacyHMAC(data: Data, key: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress, key.count,
                    dataBytes.baseAddress, data.count,
                    &result
                )
            }
        }
        return Data(result)
    }

    private func computeHMAC(data: Data, key: SymmetricKey) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(authenticationCode)
    }

    /// Constant-time byte comparison. Defends HMAC tag verification against
    /// timing side channels — `Data ==` short-circuits on first mismatch and
    /// leaks information about the stored tag.
    static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    private func aesDecryptCBC(data: Data, key: Data, iv: Data) -> [UInt8]? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, 32,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        &decryptedBytes, bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return Array(decryptedBytes.prefix(numBytesDecrypted))
    }
}
