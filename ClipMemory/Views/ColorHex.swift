import SwiftUI
import os.log

private let colorHexLogger = Logger(subsystem: "com.clipmemory.app", category: "ColorHex")

/// Parses "#RRGGBB" (or "RRGGBB") hex strings into SwiftUI Colors.
/// Returns black on parse failure (rather than crashing) so chips stay visible
/// even if a tag definition somehow stored a malformed colorHex.
extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        // 1-line fix (2026-07-20 audit LOW): fall back to `.accentColor` instead
        // of `.black`. Black-on-Material chips are invisible against dark surfaces
        // and lose semantic contrast against Light. `.accentColor` keeps chips
        // visible across light/dark and matches user expectations for "decorative
        // tag fill".
        guard body.count == 6 else {
            self = .accentColor
            return
        }
        let scanner = Scanner(string: body)
        var hexNumber: UInt64 = 0
        guard scanner.scanHexInt64(&hexNumber), scanner.isAtEnd else {
            self = .accentColor
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
            // L-16 (2026-07-24 audit): the previous fallback was pure
            // black (#000000), which looks intentional to users and hides
            // the bug. Fall back to a distinguishable medium gray (#808080)
            // and log the conversion failure so a developer can spot the
            // bad input via Console.app / `log stream` filter on the
            // "ColorHex" subsystem+category.
            colorHexLogger.warning("toHex: NSColor conversion to deviceRGB failed; returning #808080 fallback")
            return "#808080"
        }
        let r = Int(round(components.redComponent * 255))
        let g = Int(round(components.greenComponent * 255))
        let b = Int(round(components.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
