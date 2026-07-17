import SwiftUI

/// A single row in the sidebar's "标签" Section. Shows a selection
/// indicator (checkmark/circle), a colored dot matching the tag's colorHex,
/// the tag name, and a usage count badge.
///
/// Visual rule: selected row uses `.accentColor` for the checkmark and
/// the name's full color; unselected rows use secondary tints to keep the
/// sidebar visually quiet.
struct SidebarTagRow: View {
    let tag: Tag
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: sz(12)))
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .frame(width: 8, height: 8)
                Text(tag.name)
                    .font(.system(size: sz(12)))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: sz(10)))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(L10n.sidebarDeleteTag, systemImage: "trash")
            }
        }
        .accessibilityLabel(Text("\(tag.name), \(count)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
