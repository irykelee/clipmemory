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

    /// Returns true if decryption was attempted but failed.
    /// Decrypts and caches the result so subsequent `getDecryptedContent` calls hit the cache.
    var decryptionFailed: Bool {
        guard isEncrypted else { return false }
        // Trigger decrypt + cache populate; NSCache stores nil-failed results implicitly
        // by not calling setObject (since nil cannot be stored), so repeated calls re-attempt.
        // This is acceptable since failed items are filtered out and won't be displayed.
        return ClipboardStore.shared.getDecryptedContent(self) == nil
    }

    /// Extracts plain text from RTF base64 content for preview purposes.
    var plainTextFromRTFFallback: String {
        guard type == .richText else { return "" }
        guard let data = Data(base64Encoded: content),
              let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return "Rich Text"
        }
        return attr.string
    }
}
