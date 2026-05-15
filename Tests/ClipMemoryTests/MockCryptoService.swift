import Foundation
@testable import ClipMemory

class MockCryptoService: CryptoServiceProtocol {
    var shouldFail = false
    var capturedContent: String?
    var capturedData: Data?

    func encrypt(_ string: String) -> String? {
        guard !shouldFail else { return nil }
        capturedContent = string
        return string.data(using: .utf8)?.base64EncodedString()
    }

    func decrypt(_ base64String: String) -> String? {
        guard !shouldFail else { return nil }
        capturedContent = base64String
        return String(data: Data(base64Encoded: base64String) ?? Data(), encoding: .utf8)
    }

    func encryptData(_ data: Data) -> Data? {
        guard !shouldFail else { return nil }
        capturedData = data
        return data.base64EncodedData()
    }

    func decryptData(_ combined: Data) -> Data? {
        guard !shouldFail else { return nil }
        capturedData = combined
        return Data(base64Encoded: combined)
    }

    func isOldFormat(_ base64String: String) -> Bool {
        false
    }

    func migrateToV2(_ base64String: String) -> String? {
        nil
    }
}
