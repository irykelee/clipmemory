import SwiftUI
import AppKit

struct AppPickerItem {
    let name: String
    let bundleId: String
    let icon: NSImage?
    let isRunning: Bool
}

struct AppPickerRow: View {
    let name: String
    let bundleId: String
    let icon: NSImage?
    let isExcluded: Bool
    let onToggle: () -> Void
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @State private var isHovered = false
    @State private var resolvedIcon: NSImage?

    var body: some View {
        // 2026-07-25: reading fontScale subscribes this view to @AppStorage
        // invalidation — an unread wrapper creates no dependency, so
        // font-size changes never re-rendered. See ClipboardItemRow.
        let _ = fontScale
        Button(action: onToggle) {
            HStack(spacing: 12) {
                if let icon = resolvedIcon ?? icon {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                } else {
                    Image(nsImage: NSImage(systemSymbolName: "app.badge.questionmark", accessibilityDescription: nil) ?? NSImage()).resizable().frame(width: 32, height: 32)
                }
                VStack(alignment: .leading) {
                    Text(name).font(.system(size: sz(13)))
                    Text(bundleId).font(.system(size: sz(10))).foregroundColor(.secondary)
                }
                Spacer()
                if isExcluded {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
            .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isExcluded ? "Remove exclusion for" : "Exclude") \(name)")
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onHover { hovering in isHovered = hovering }
        .task(id: bundleId) {
            guard resolvedIcon == nil, icon == nil else { return }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            let image = await Task.detached(priority: .utility) {
                NSWorkspace.shared.icon(forFile: url.path)
            }.value
            await MainActor.run { resolvedIcon = image }
        }
    }
}
