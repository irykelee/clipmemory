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
