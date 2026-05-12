import Foundation

enum ClipboardItemType: String, Codable {
    case text
    case image
    case link
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let content: String
    let type: ClipboardItemType
    let createdAt: Date
    var isPinned: Bool
    var isSensitive: Bool
    var expiresAt: Date?
    var isEncrypted: Bool = false
    /// SHA256 hash of plaintext content for fast search pre-filtering
    var contentHash: String?

    init(id: UUID = UUID(), content: String, type: ClipboardItemType, createdAt: Date = Date(), isPinned: Bool = false, isSensitive: Bool = false, expiresAt: Date? = nil, isEncrypted: Bool = false, contentHash: String? = nil) {
        self.id = id
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isSensitive = isSensitive
        self.expiresAt = expiresAt
        self.isEncrypted = isEncrypted
        self.contentHash = contentHash
    }

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }

    /// Returns decrypted content. If decryption fails, returns a placeholder (not ciphertext).
    /// DEPRECATED: Use `ClipboardStore.shared.getDecryptedContent(self)` instead,
    /// which uses contentCache to avoid repeated expensive AES decryption.
    var decryptedContent: String {
        guard !isEncrypted else {
            return CryptoService.shared.decrypt(content) ?? "(decryption failed)"
        }
        return content
    }

    /// Returns true if decryption was attempted but failed (content is encrypted but could not be decrypted).
    var decryptionFailed: Bool {
        guard isEncrypted else { return false }
        return CryptoService.shared.decrypt(content) == nil
    }
}
