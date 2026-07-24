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
        // L-17 (2026-07-24 audit): the previous label read "Work, 5" with
        // no context. Now VoiceOver hears "Tag Work, 5 items" plus the
        // selection state as a separate accessibilityValue, so screen-reader
        // users get the same context that sighted users get from the dot +
        // checkmark visuals. L10n keys live in LocalizationService.swift.
        .accessibilityLabel(Text(L10n.sidebarTagAccessibilityLabel(tag.name, count)))
        .accessibilityValue(Text(isSelected ? L10n.sidebarTagAccessibilitySelected : L10n.sidebarTagAccessibilityUnselected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
