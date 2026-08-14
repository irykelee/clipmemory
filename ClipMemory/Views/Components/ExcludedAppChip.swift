import SwiftUI
import AppKit

/// One chip in the settings "excluded apps" list: app icon + name + remove button.
///
/// Extracted from HistoryCaptureSettingsView so the icon can own the async
/// lookup state (a `@State` per chip), matching AppPickerRow's pattern.
///
/// The bundle id is deliberately not rendered. A dozen chips reading
/// `com.agilebits.onepassword7` are unreadable and eat the settings pane; the
/// id stays reachable as a tooltip, which is also what disambiguates two apps
/// that share a display name.
struct ExcludedAppChip: View {
    let name: String
    let bundleId: String
    let onRemove: () -> Void

    // 2026-07-25: invalidation trigger only — see TagChip / ClipboardItemRow.
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @State private var resolvedIcon: NSImage?

    /// Chips wrap in a FlowLayout, so a long name must not push a chip past
    /// the pane width. Middle truncation keeps both ends of a raw bundle id
    /// legible for apps we have no curated name for.
    private static let maxNameWidth: CGFloat = 140

    var body: some View {
        let _ = fontScale
        HStack(spacing: 4) {
            icon
            Text(name)
                .font(.system(size: sz(11)))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.maxNameWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button(action: onRemove, label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: sz(10)))
                    .foregroundColor(.secondary)
            })
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.appPickerAccessibilityRemove(name))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        // Restores the detail the chip no longer shows inline.
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
