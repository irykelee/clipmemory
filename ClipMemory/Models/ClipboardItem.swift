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

    var displayContent: String {
        switch type {
        case .text:
            return String(content.prefix(200))
        case .link:
            return content
        case .image:
            return "[图片]"
        }
    }
}
