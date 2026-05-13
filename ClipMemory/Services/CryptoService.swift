import Foundation
import CryptoKit
import CommonCrypto
import os.log

/// Encryption format versions:
/// - v2 (current): "v2" prefix + AES-GCM sealed box (nonce + ciphertext + tag)
/// - v1 (legacy): AES-CBC + HMAC-SHA256, no prefix, for backwards compatibility
class CryptoService {
    static let shared = CryptoService()

    private let logger = Logger(subsystem: "com.clipmemory.app", category: "CryptoService")

    /// Exposed for ImageStorage migration
    static var keyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClipMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".encryption_key")
    }

    private init() {
        if getKey() == nil {
            generateKey()
        }
    }

    private func generateKey() {
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            logger.error("Failed to generate random key bytes")
            fatalError("Cannot continue without cryptographically secure key")
        }
        do {
            try keyData.write(to: Self.keyFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.keyFileURL.path)
        } catch {
            logger.error("Failed to store encryption key: \(error.localizedDescription)")
            fatalError("Cannot continue without encryption key: \(error.localizedDescription)")
        }
    }

    private func getKey() -> SymmetricKey? {
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
            logger.error("AES-GCM encryption failed: \(error.localizedDescription)")
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

    /// Returns true if the given base64 string uses the old (pre-v2) format.
    /// Uses try-decrypt approach: if v2 decrypt succeeds → false, if legacy succeeds → true.
    /// More robust than byte-prefix inspection and avoids polluting encrypted data.
    func isOldFormat(_ base64String: String) -> Bool {
        guard let combined = Data(base64Encoded: base64String) else { return false }
        if combined.count >= 2 && combined.prefix(2) == Data("v2".utf8) {
            // Has v2 marker — try decrypting as v2 to confirm it's valid v2
            if decryptV2(data: Data(combined.dropFirst(2))) != nil { return false }
            // v2 marker present but can't decrypt — treat as old format
        }
        // No v2 marker or v2 decrypt failed — try legacy
        return decryptLegacy(from: combined) != nil
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
            let storedHMAC = combined.suffix(hmacSize)

            // Verify HMAC over IV || ciphertext
            let ivAndCiphertext = combined.dropLast(hmacSize)
            let computedHMAC = computeHMAC(data: Data(ivAndCiphertext), key: key)
            guard computedHMAC == storedHMAC else {
                return nil
            }

            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16).dropLast(hmacSize)
            let keyData = key.withUnsafeBytes { Data($0) }
            return aesDecryptCBC(data: Data(ciphertext), key: keyData, iv: Data(iv))
        }

        // Old format without HMAC: 16-byte IV + ciphertext (pre-1.2.0)
        if combined.count > 16 {
            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16)
            let keyData = key.withUnsafeBytes { Data($0) }
            return aesDecryptCBC(data: Data(ciphertext), key: keyData, iv: Data(iv))
        }

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
