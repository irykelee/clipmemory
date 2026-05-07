import Foundation
import CommonCrypto
import os.log

class CryptoService {
    static let shared = CryptoService()

    private let logger = Logger(subsystem: "com.clipmemory.app", category: "CryptoService")

    private var encryptionKey: Data?

    private init() {
        loadOrGenerateKey()
    }

    private var keyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("ClipMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(".key")
    }

    private func loadOrGenerateKey() {
        let url = keyFileURL

        // Load existing key
        if let data = try? Data(contentsOf: url), data.count == 32 {
            encryptionKey = data
            return
        }

        // Generate new key
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }

        guard result == errSecSuccess else {
            logger.error("Failed to generate random key")
            return
        }

        // Save to local file
        try? keyData.write(to: url)
        encryptionKey = keyData
    }

    /// Encrypts a string using AES-256-CBC
    /// Returns base64 encoded result: IV (16 bytes) + ciphertext
    func encrypt(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        guard let encrypted = encryptBytes(data) else { return nil }
        return encrypted.base64EncodedString()
    }

    /// Decrypts a base64 encoded string
    func decrypt(_ base64String: String) -> String? {
        guard let combined = Data(base64Encoded: base64String) else { return nil }
        guard let decrypted = decryptBytes(from: combined) else { return nil }
        return String(bytes: decrypted, encoding: .utf8)
    }

    /// Encrypts raw Data (for images)
    func encryptData(_ data: Data) -> Data? {
        return encryptBytes(data)
    }

    /// Decrypts Data (for images)
    func decryptData(_ combined: Data) -> Data? {
        guard let bytes = decryptBytes(from: combined) else { return nil }
        return Data(bytes)
    }

    private func encryptBytes(_ data: Data) -> Data? {
        guard let key = encryptionKey else { return nil }

        // Generate random IV
        var iv = Data(count: 16)
        let ivResult = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard ivResult == errSecSuccess else { return nil }

        // Encrypt
        guard let encrypted = aesEncrypt(data: data, key: key, iv: iv) else { return nil }

        // Combine IV + ciphertext
        var combined = iv
        combined.append(encrypted)
        return combined
    }

    private func decryptBytes(from combined: Data) -> [UInt8]? {
        guard combined.count > 16 else { return nil }
        guard let key = encryptionKey else { return nil }

        let iv = combined.prefix(16)
        let encryptedData = combined.dropFirst(16)

        guard let decrypted = aesDecrypt(data: Data(encryptedData), key: key, iv: Data(iv)) else { return nil }
        return Array(decrypted)
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
