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

    /// Returns decrypted content. For encrypted items, decrypts on each access.
    /// Note: struct value type prevents instance-level caching across multiple accesses.
    var decryptedContent: String {
        isEncrypted ? (CryptoService.shared.decrypt(content) ?? content) : content
    }

    var displayContent: String {
        switch type {
        case .text:
            return String(decryptedContent.prefix(200))
        case .link:
            return decryptedContent
        case .image:
            return L10n.itemImage
        }
    }
}
