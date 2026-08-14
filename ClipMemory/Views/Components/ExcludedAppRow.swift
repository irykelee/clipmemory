import SwiftUI
import AppKit

/// One row in the settings "excluded apps" list: app icon + name + remove button.
///
/// ID-VIEW-0041 (2026-08-14): was a wrapping chip. With 14 curated exclusions
/// the chips wrapped to four rows and grew with every app the user added, so
/// the list moved into a fixed-height scroller and the chip became a row.
///
/// The bundle id is deliberately not rendered — a column of
/// `com.agilebits.onepassword7` is unreadable. It stays reachable as a
/// tooltip, which is also what disambiguates two apps sharing a display name.
struct ExcludedAppRow: View {
    let name: String
    let bundleId: String
    let onRemove: () -> Void

    // 2026-07-25: invalidation trigger only — see TagChip / ClipboardItemRow.
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @State private var resolvedIcon: NSImage?
    @State private var isHovered = false

    /// Kept in sync with ExcludedAppsList.visibleRowCount, which multiplies it
    /// to size the scroller.
    static func rowHeight() -> CGFloat { sz(24) }

    var body: some View {
        let _ = fontScale
        HStack(spacing: 8) {
            icon
            Text(name)
                .font(.system(size: sz(11)))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: onRemove, label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: sz(11)))
                    .foregroundColor(.secondary)
            })
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.appPickerAccessibilityRemove(name))
            // Only on hover, so a long list isn't a wall of ✕ glyphs.
            .opacity(isHovered ? 1 : 0.35)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight())
        .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Restores the detail the row no longer shows inline.
        .help(bundleId)
        .task(id: bundleId) {
            guard resolvedIcon == nil else { return }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            let image = await Task.detached(priority: .utility) {
                NSWorkspace.shared.icon(forFile: url.path)
            }.value
            // ID-LIFE-0015 (2026-07-30 audit): the detached task can return
            // after .task(id:) cancelled for a different bundleId.
            guard !Task.isCancelled else { return }
            await MainActor.run { resolvedIcon = image }
        }
    }

    /// Apps in this list are frequently NOT installed on this Mac — the seeded
    /// password managers are the common case — so the placeholder is a normal
    /// state here, not an error state.
    @ViewBuilder
    private var icon: some View {
        if let resolvedIcon {
            Image(nsImage: resolvedIcon)
                .resizable()
                .frame(width: sz(14), height: sz(14))
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: sz(12)))
                .foregroundColor(.secondary)
                .frame(width: sz(14), height: sz(14))
        }
    }
}
