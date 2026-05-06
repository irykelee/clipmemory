import Foundation
import Security
import CommonCrypto

class CryptoService {
    static let shared = CryptoService()

    private let keyTag = "com.clippaste.clipboard.key"

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
        if result == errSecSuccess {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: keyTag,
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            SecItemDelete(query as CFDictionary)
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func getKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return result as? Data
        }
        return nil
    }

    func encrypt(_ string: String) -> String? {
        guard let key = getKey(),
              let data = string.data(using: .utf8) else { return nil }

        var iv = Data(count: 16)
        let ivResult = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard ivResult == errSecSuccess else { return nil }

        let encrypted = aesEncrypt(data: data, key: key, iv: iv)
        guard let encryptedData = encrypted else { return nil }

        var combined = iv
        combined.append(encryptedData)
        return combined.base64EncodedString()
    }

    func decrypt(_ base64String: String) -> String? {
        guard let key = getKey(),
              let combined = Data(base64Encoded: base64String),
              combined.count > 16 else { return nil }

        let iv = combined.prefix(16)
        let encryptedData = combined.dropFirst(16)

        guard let decrypted = aesDecrypt(data: Data(encryptedData), key: key, iv: Data(iv)) else { return nil }
        return String(data: decrypted, encoding: .utf8)
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
