import SwiftUI

// MARK: - Liquid Glass Date Filter Button
struct DateFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        // ID-L10N-0006 (2026-07-30 audit): localized selected-state suffix.
        // dateFilter.selected carries the locale-appropriate suffix
        // (", selected" / "（已选）" / "(선택됨)" / etc.) so VoiceOver reads
        // "Today, selected" / "今天（已选）" instead of bare "Today" when the
        // button is the active filter.
        .accessibilityLabel("\(title)\(isSelected ? L10n.dateFilterSelected : "")")
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        if isSelected {
            return .primary
        } else if isHovered {
            return .primary.opacity(0.8)
        } else {
            return .secondary
        }
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial.opacity(0.6))
        } else {
            Color.clear
        }
    }
}
