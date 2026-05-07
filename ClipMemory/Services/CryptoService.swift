import Foundation
import Security
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
            try keyData.write(to: keyFileURL, options: [.atomic, .completeFileProtection])
        } catch {
            logger.error("Failed to store encryption key: \(error.localizedDescription)")
        }
    }

    private func getKey() -> Data? {
        return try? Data(contentsOf: keyFileURL)
    }

    /// Encrypts with AES-256-CBC + HMAC-SHA256 for authenticated encryption.
    /// Storage format: IV (16 bytes) + ciphertext + HMAC (32 bytes).
    /// HMAC is computed over IV || ciphertext to prevent bit-flipping attacks.
    func encrypt(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        guard let combined = encryptBytes(Array(data)) else { return nil }
        return combined.base64EncodedString()
    }

    /// Encrypts raw Data (for images).
    func encryptData(_ data: Data) -> Data? {
        return encryptBytes(Array(data))
    }

    /// N7: Common encryption logic — AES-256-CBC + HMAC-SHA256 over raw bytes
    private func encryptBytes(_ bytes: [UInt8]) -> Data? {
        guard let key = getKey() else { return nil }

        var iv = Data(count: 16)
        let ivResult = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard ivResult == errSecSuccess else { return nil }

        guard let encrypted = aesEncrypt(data: Data(bytes), key: key, iv: iv) else { return nil }

        var ivAndCiphertext = iv
        ivAndCiphertext.append(encrypted)
        let hmac = computeHMAC(data: ivAndCiphertext, key: key)

        var combined = iv
        combined.append(encrypted)
        combined.append(hmac)
        return combined
    }

    /// Decrypts and verifies HMAC before decryption.
    /// Falls back to legacy format (no HMAC) for backwards compatibility with pre-1.2.0 data.
    func decrypt(_ base64String: String) -> String? {
        guard let combined = Data(base64Encoded: base64String) else { return nil }
        guard let bytes = decryptBytes(from: combined) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Decrypts Data (for images).
    func decryptData(_ combined: Data) -> Data? {
        guard let bytes = decryptBytes(from: combined) else { return nil }
        return Data(bytes)
    }

    /// N7: Common decryption logic — verifies HMAC then AES-256-CBC decrypt
    private func decryptBytes(from combined: Data) -> [UInt8]? {
        guard let key = getKey() else { return nil }

        // New format: IV (16) + ciphertext + HMAC (32) — minimum 49 bytes
        if combined.count >= 49 {
            let hmacSize = 32
            let ivAndCiphertextLength = combined.count - hmacSize
            let ivAndCiphertext = combined.prefix(ivAndCiphertextLength)
            let storedHMAC = combined.suffix(hmacSize)

            let computedHMAC = computeHMAC(data: Data(ivAndCiphertext), key: key)
            if computedHMAC == storedHMAC {
                let iv = combined.prefix(16)
                let encryptedData = combined.dropFirst(16).dropLast(hmacSize)
                if let decrypted = aesDecrypt(data: Data(encryptedData), key: key, iv: Data(iv)) {
                    return Array(decrypted)
                }
            }
            return nil
        }

        // Legacy format (pre-1.2.0): IV (16) + ciphertext — no HMAC
        if combined.count > 16 {
            let iv = combined.prefix(16)
            let encryptedData = combined.dropFirst(16)
            if let decrypted = aesDecrypt(data: Data(encryptedData), key: key, iv: Data(iv)) {
                return Array(decrypted)
            }
        }

        return nil
    }

    private func computeHMAC(data: Data, key: Data) -> Data {
        var hmac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        hmac.withUnsafeMutableBytes { hmacBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBytes.baseAddress, key.count,
                        dataBytes.baseAddress, data.count,
                        hmacBytes.baseAddress
                    )
                }
            }
        }
        return hmac
    }

    private func aesEncrypt(data: Data, key: Data, iv: Data) -> Data? {
        var encryptedBytes = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
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
                        &encryptedBytes, encryptedBytes.count,
                        &numBytesEncrypted
                    )
                }
            }
        }

        if status == kCCSuccess {
            return Data(encryptedBytes.prefix(numBytesEncrypted))
        }
        return nil
    }

    private func aesDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        var decryptedBytes = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
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
                        &decryptedBytes, decryptedBytes.count,
                        &numBytesDecrypted
                    )
                }
            }
        }

        if status == kCCSuccess {
            return Data(decryptedBytes.prefix(numBytesDecrypted))
        }
        return nil
    }
}
