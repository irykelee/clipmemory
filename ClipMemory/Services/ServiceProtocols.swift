import Foundation

// MARK: - Encryption

protocol CryptoServiceProtocol {
    func encrypt(_ string: String) -> String?
    func decrypt(_ base64String: String) -> String?
    func encryptData(_ data: Data) -> Data?
    func decryptData(_ combined: Data) -> Data?
    func isOldFormat(_ base64String: String) -> Bool
    func migrateToV2(_ base64String: String) -> String?
}

// MARK: - Sensitive Detection

protocol SensitiveDetectorProtocol {
    func detectSensitive(_ content: String) -> Bool
}

// MARK: - Service Container

enum ServiceContainer {
    static var crypto: CryptoServiceProtocol = CryptoService.shared
}
