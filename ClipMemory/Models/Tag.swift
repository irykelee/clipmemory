import Foundation

/// User-defined (or auto-suggested) label attached to ClipboardItems.
/// Tags are independent of ClipboardItemType — type is objective (what it is),
/// tag is subjective (what context it belongs to).
struct Tag: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var colorHex: String
    var isAutoSuggested: Bool
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         colorHex: String,
         isAutoSuggested: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isAutoSuggested = isAutoSuggested
        self.createdAt = createdAt
    }

    // MARK: - Codable compatibility
    // ID-STORE-0004 (2026-07-31 audit): synthesized Codable throws on ANY
    // missing field, and one bad tag fails the whole `[Tag]` decode —
    // `loadTags()` then quarantines the blob and every tag definition is
    // lost. Follow the ClipboardItem M-20 pattern (`decodeIfPresent` ??
    // default) so a single degraded tag decodes with defaults instead of
    // taking down all tags. A missing `id` gets a fresh UUID (degraded
    // identity, still better than losing every tag); a missing `createdAt`
    // uses `distantPast` so degraded tags sort last in recency ordering.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
        self.isAutoSuggested = try container.decodeIfPresent(Bool.self, forKey: .isAutoSuggested) ?? false
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }

    /// Curated palette for new-tag color picker. All 7-char "#RRGGBB" strings.
    /// Designed for distinct hues at small chip sizes (high enough chroma).
    static let presetColors: [String] = [
        "#FF6B6B", // coral red
        "#4ECDC4", // teal
        "#45B7D1", // sky blue
        "#FFA07A", // light salmon
        "#98D8C8", // mint
        "#F7DC6F", // mustard
        "#BB8FCE", // lavender
        "#85C1E2"  // pale blue
    ]
}
