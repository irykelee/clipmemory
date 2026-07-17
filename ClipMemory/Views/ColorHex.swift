import SwiftUI

/// Parses "#RRGGBB" (or "RRGGBB") hex strings into SwiftUI Colors.
/// Returns black on parse failure (rather than crashing) so chips stay visible
/// even if a tag definition somehow stored a malformed colorHex.
extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else {
            self = .black
            return
        }
        let scanner = Scanner(string: body)
        var hexNumber: UInt64 = 0
        guard scanner.scanHexInt64(&hexNumber), scanner.isAtEnd else {
            self = .black
            return
        }
        let r = Double((hexNumber & 0xFF0000) >> 16) / 255.0
        let g = Double((hexNumber & 0x00FF00) >> 8) / 255.0
        let b = Double(hexNumber & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    /// Convert to "#RRGGBB" for storage in Tag.colorHex. Alpha is ignored —
    /// tags are rendered as small opaque chips.
    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let r = Int(round(components.redComponent * 255))
        let g = Int(round(components.greenComponent * 255))
        let b = Int(round(components.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
