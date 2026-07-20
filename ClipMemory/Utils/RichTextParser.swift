import Foundation
import AppKit

/// I-6 (2026-07-20 audit): pure parser extracted from `ClipboardStore.shared`
/// so that `ClipboardItem.plainTextFromRTFFallback` can be a true computed
/// property that does not transitively read from the shared store — the
/// previous shape (`ClipboardStore.shared.getRTFPlaintext(self)`) forced every
/// `ClipboardItem` reading off the SwiftUI render path to also pull from the
/// `@MainActor` ClipboardStore singleton, which created implicit threading and
/// lifecycle hazards for callers that don't otherwise need the store.
///
/// This is intentionally a static free function: pure input → output, no
/// cached state. Callers that hit the same `ClipboardItem` repeatedly (search
/// results, list previews) can layer their own cache on top — `ClipboardStore`
/// does so via `NSCache<NSString, NSString>` keyed by item id.
enum RichTextParser {

    /// Parse a base64-encoded RTF blob to its plaintext representation.
    /// Returns `fallback` if the input is empty, isn't valid base64, or fails
    /// to parse as RTF.
    ///
    /// - Parameters:
    ///   - base64RTF: The RTF payload as a base64 string. Pass the item's
    ///     stored `content` directly — the function handles non-base64 data
    ///     gracefully so callers don't have to pre-validate.
    ///   - fallback: Display string returned when parsing fails. Defaults to
    ///     the localized "Rich Text" placeholder so chips still render even
    ///     on malformed input.
    static func plaintext(from base64RTF: String, fallback: String = "Rich Text") -> String {
        guard !base64RTF.isEmpty,
              let data = Data(base64Encoded: base64RTF),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              )
        else { return fallback }
        return attr.string
    }

    /// Convenience for raw (non-base64) RTF `Data`. Useful in tests and in
    /// `ClipboardMonitor.processRichText` which currently works with the raw
    /// bytes from the pasteboard.
    static func plaintext(from rtfData: Data, fallback: String = "") -> String {
        guard !rtfData.isEmpty,
              let attr = try? NSAttributedString(
                data: rtfData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              )
        else { return fallback }
        return attr.string
    }
}
