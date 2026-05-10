import Foundation
import CommonCrypto
import os.log

class CryptoService {
    static let shared = CryptoService()

    private let logger = Logger(subsystem: "com.clipmemory.app", category: "CryptoService")

    private var keyFileURL: URL {
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
            return
        }
        do {
            try keyData.write(to: keyFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
        } catch {
            logger.error("Failed to store encryption key: \(error.localizedDescription)")
        }
    }

    private func getKey() -> Data? {
        try? Data(contentsOf: keyFileURL)
    }

    /// Encrypts with AES-256-CBC + HMAC-SHA256 for authenticated encryption.
    /// Storage format: IV (16 bytes) + ciphertext + HMAC (32 bytes).
    /// HMAC is computed over IV || ciphertext to prevent bit-flipping attacks.
    func encrypt(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        return encryptBytes(Array(data)).map { $0.base64EncodedString() }
    }

    /// Encrypts raw Data (for images).
    func encryptData(_ data: Data) -> Data? {
        return encryptBytes(Array(data))
    }

    // MARK: - Encryption

    private func encryptBytes(_ bytes: [UInt8]) -> Data? {
        guard let key = getKey(), key.count == 32 else { return nil }

        var iv = Data(count: 16)
        guard iv.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else {
            return nil
        }

        guard let ciphertext = aesEncrypt(data: Data(bytes), key: key, iv: iv) else { return nil }

        // HMAC over IV || ciphertext
        var ivAndCiphertext = iv
        ivAndCiphertext.append(ciphertext)
        let hmac = computeHMAC(data: ivAndCiphertext, key: key)

        var combined = iv
        combined.append(ciphertext)
        combined.append(hmac)
        return combined
    }

    private func aesEncrypt(data: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var encryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        &encryptedBytes, bufferSize,
                        &numBytesEncrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return Data(encryptedBytes.prefix(numBytesEncrypted))
    }

    // MARK: - Decryption

    func decrypt(_ base64String: String) -> String? {
        guard let combined = Data(base64Encoded: base64String) else {
            logger.warning("Base64 decode failed for encrypted content")
            return nil
        }
        guard let bytes = decryptBytes(from: combined) else {
            logger.warning("Decryption failed — key unavailable, HMAC mismatch, or corrupted data")
            return nil
        }
        guard let result = String(bytes: bytes, encoding: .utf8) else {
            logger.warning("Decrypted data is not valid UTF-8")
            return nil
        }
        return result
    }

    func decryptData(_ combined: Data) -> Data? {
        guard let bytes = decryptBytes(from: combined) else {
            logger.warning("Image decryption failed — key unavailable, HMAC mismatch, or corrupted data")
            return nil
        }
        return Data(bytes)
    }

    private func decryptBytes(from combined: Data) -> [UInt8]? {
        guard let key = getKey(), key.count == 32 else { return nil }

        // New format: IV (16) + ciphertext + HMAC (32) — minimum 49 bytes
        if combined.count >= 49 {
            let hmacSize = 32
            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16).dropLast(hmacSize)
            let storedHMAC = combined.suffix(hmacSize)

            // Verify HMAC over IV || ciphertext
            let ivAndCiphertext = combined.dropLast(hmacSize)
            let computedHMAC = computeHMAC(data: Data(ivAndCiphertext), key: key)
            guard computedHMAC == storedHMAC else { return nil }

            return aesDecrypt(data: Data(ciphertext), key: key, iv: Data(iv))
        }

        // Legacy format (pre-1.2.0): IV (16) + ciphertext — no HMAC
        if combined.count > 16 {
            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16)
            return aesDecrypt(data: Data(ciphertext), key: key, iv: Data(iv))
        }

        return nil
    }

    // MARK: - HMAC

    private func computeHMAC(data: Data, key: Data) -> Data {
        let hash = hmacSHA256(data: data, key: key)
        return Data(hash)
    }

    private func hmacSHA256(data: Data, key: Data) -> [UInt8] {
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
        return result
    }

    private func aesDecrypt(data: Data, key: Data, iv: Data) -> [UInt8]? {
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
                        keyBytes.baseAddress, key.count,
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
