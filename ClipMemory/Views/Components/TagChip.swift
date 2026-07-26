import SwiftUI

/// Single tag chip: colored dot + name on a tinted background.
/// Used inside `TagChipStack` (row) and `TagPickerSheet` (list rows).
struct TagChip: View {
    let tag: Tag

    // CLIP-6 (2026-07-24 review): invalidation trigger only. The chip's
    // `tag` input doesn't change when the user switches font size, and
    // TagChipStack passes a plain `Tag` value — without an @AppStorage
    // dependency SwiftUI may skip recomputing body, leaving the chip at
    // the stale size. The actual scaling still goes through sz()'s
    // NaN/Inf/clamp guards; this value is never read directly.
    @AppStorage("fontScale") private var fontScale: Double = 1.0

    var body: some View {
        // 2026-07-25: reading fontScale subscribes this view to @AppStorage
        // invalidation — an unread wrapper creates no dependency, so
        // font-size changes never re-rendered. See ClipboardItemRow.
        let _ = fontScale
        HStack(spacing: 3) {
            Circle()
                .fill(Color(hex: tag.colorHex))
                .frame(width: 6, height: 6)
            Text(tag.name)
                .font(.system(size: sz(10)))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(hex: tag.colorHex).opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(hex: tag.colorHex).opacity(0.5), lineWidth: 0.5)
        )
        .cornerRadius(4)
        .accessibilityLabel("Tag: \(tag.name)")
    }
}
