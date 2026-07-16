import Foundation

enum ClipboardItemType: String, Codable {
    case text
    case image
    case link
    case richText
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
    /// Set by ClipboardStore.getDecryptedContent on first decrypt failure.
    /// Replaces the prior computed-property pattern that re-decrypted on every access.
    var decryptionFailed: Bool = false
    /// Tag IDs attached to this item. Empty means untagged. Stored as a Set
    /// for O(1) membership checks when filtering by tag in the sidebar.
    /// Tags themselves live in ClipboardStore.tags; this field only stores IDs.
    var tagIds: Set<UUID> = []

    init(id: UUID = UUID(), content: String, type: ClipboardItemType, createdAt: Date = Date(), isPinned: Bool = false, isSensitive: Bool = false, expiresAt: Date? = nil, isEncrypted: Bool = false, contentHash: String? = nil, decryptionFailed: Bool = false, tagIds: Set<UUID> = []) {
        self.id = id
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isSensitive = isSensitive
        self.expiresAt = expiresAt
        self.isEncrypted = isEncrypted
        self.contentHash = contentHash
        self.decryptionFailed = decryptionFailed
        self.tagIds = tagIds
    }

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }

    /// O(1) read of the memoized decryption outcome. Set by ClipboardStore
    /// on first decrypt attempt; not re-computed.
    var isDecryptionFailed: Bool {
        decryptionFailed
    }

    /// Extracts plain text from RTF content for preview and search purposes.
    /// Handles both encrypted (v2:) and plaintext base64 RTF.
    var plainTextFromRTFFallback: String {
        guard type == .richText else { return "" }
        // Decrypt if needed to get raw base64 RTF
        let base64RTF = isEncrypted
            ? (ClipboardStore.shared.getDecryptedContent(self) ?? content)
            : content
        guard let data = Data(base64Encoded: base64RTF),
              let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return "Rich Text"
        }
        return attr.string
    }
}
