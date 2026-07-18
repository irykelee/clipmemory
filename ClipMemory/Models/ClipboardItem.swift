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
    /// Timestamp when the item was moved to the recycle bin. nil for active
    /// items. Used for trash sorting and auto-purge.
    var deletedAt: Date?
    /// OCR-recognized text of an image item, encrypted at rest (v2 ciphertext).
    /// nil when OCR has not run or found no text. Never set for non-image items.
    var ocrText: String?

    init(id: UUID = UUID(), content: String, type: ClipboardItemType, createdAt: Date = Date(), isPinned: Bool = false, isSensitive: Bool = false, expiresAt: Date? = nil, isEncrypted: Bool = false, contentHash: String? = nil, decryptionFailed: Bool = false, tagIds: Set<UUID> = [], deletedAt: Date? = nil, ocrText: String? = nil) {
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
        self.deletedAt = deletedAt
        self.ocrText = ocrText
    }

    // MARK: - Codable compatibility
    // Synthesized Codable ignores property defaults, so old persisted data
    // missing newer fields would throw keyNotFound and wipe the history.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.content = try container.decode(String.self, forKey: .content)
        self.type = try container.decode(ClipboardItemType.self, forKey: .type)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.isPinned = try container.decode(Bool.self, forKey: .isPinned)
        self.isSensitive = try container.decode(Bool.self, forKey: .isSensitive)
        self.expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.isEncrypted = try container.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        self.contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        self.decryptionFailed = try container.decodeIfPresent(Bool.self, forKey: .decryptionFailed) ?? false
        self.tagIds = try container.decodeIfPresent(Set<UUID>.self, forKey: .tagIds) ?? []
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
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
    /// Uses ClipboardStore's RTF cache to avoid repeated parsing.
    var plainTextFromRTFFallback: String {
        ClipboardStore.shared.getRTFPlaintext(self)
    }
}
