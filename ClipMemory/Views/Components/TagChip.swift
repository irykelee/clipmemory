import SwiftUI

/// Single tag chip: colored dot + name on a tinted background.
/// Used inside `TagChipStack` (row) and `TagPickerSheet` (list rows).
struct TagChip: View {
    let tag: Tag

    var body: some View {
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
    }
}
