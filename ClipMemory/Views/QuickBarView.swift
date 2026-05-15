import SwiftUI
import AppKit

private var relativeDateFormatters: [String: RelativeDateTimeFormatter] = [:]
private func cachedRelativeDateFormatter(for languageCode: String) -> RelativeDateTimeFormatter {
    if let cached = relativeDateFormatters[languageCode] { return cached }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    f.locale = Locale(identifier: languageCode)
    relativeDateFormatters[languageCode] = f
    return f
}

struct QuickBarView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared

    @State private var searchText = ""
    @State private var keyboardSelectedIndex: Int?
    @State private var lastCopiedId: UUID?
    @State private var showFullWindow = false
    @FocusState private var isSearchFocused: Bool
    @AppStorage("fontScale") private var fontScale: Double = 1.0

    let onDismiss: () -> Void

    private let maxItems = 8

    private func sz(_ base: CGFloat) -> CGFloat { base * fontScale }

    private var quickBarBackground: AnyShapeStyle {
        AnyShapeStyle(Color.clear)
    }

    private var menuSectionBackground: AnyShapeStyle {
        AnyShapeStyle(Color.clear)
    }

    var displayedItems: [ClipboardItem] {
        let base = searchText.isEmpty
            ? Array(store.items.prefix(maxItems))
            : store.items.filter { item in
                guard !item.decryptionFailed else { return false }
                return (ClipboardStore.shared.getDecryptedContent(item) ?? "").localizedCaseInsensitiveContains(searchText)
            }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: sz(12)))
                TextField(L10n.searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: sz(13)))
                    .focused($isSearchFocused)
                    .onChange(of: searchText) { _ in keyboardSelectedIndex = nil }
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: sz(11)))
                    })
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSearchFocused ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(appCornerRadius)

            Color.clear.frame(height: 6)

            // Section label
            Text(L10n.quickbarRecent(displayedItems.count))
                .font(.system(size: sz(10)))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)

            if displayedItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 40)
                    if searchText.isEmpty {
                        Text(L10n.emptyNoHistory)
                            .font(.system(size: sz(12)))
                            .foregroundColor(.secondary)
                        Text(L10n.emptyHistoryHint)
                            .font(.system(size: sz(11)))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    } else {
                        Text(L10n.quickbarNoResults)
                            .font(.system(size: sz(12)))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 40)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                            QuickBarRow(
                                item: item,
                                isSelected: keyboardSelectedIndex == index,
                                isCopied: lastCopiedId == item.id,
                                searchText: searchText,
                                sz: sz,
                                onTap: {
                                    lastCopiedId = item.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                        if lastCopiedId == item.id { lastCopiedId = nil }
                                    }
                                    store.copyToClipboard(item)
                                    onDismiss()
                                }
                            )
                            if index < displayedItems.count - 1 {
                                // 40 = row horizontal padding(12) + icon width(16) + icon-text spacing(8) + 4 for visual alignment
                                Color.primary.opacity(0.06).frame(height: 1).padding(.leading, 40)
                            }
                        }
                    }
                }
            }

            Color.clear.frame(height: 6)

            // macOS 26 menu style bottom section
            VStack(spacing: 0) {
                MacOSMenuItem(icon: "rectangle.expand.vertical", label: L10n.quickbarOpenFull, shortcut: "⌘⌃V", sz: sz)
                    .onTapGesture { showFullWindow = true }
                Color.clear.frame(height: 1)
                MacOSMenuItem(icon: "xmark.circle", label: L10n.quitApp, color: .secondary, shortcut: "⌘Q", sz: sz)
                    .onTapGesture { NSApp.terminate(nil) }
            }
            .padding(.vertical, 6)
            .background(menuSectionBackground)
        }
        .background(quickBarBackground)
        .frame(width: 340)
        .frame(maxHeight: 480)
        .background(
            KeyCaptureView(
                onUp: {
                    guard !displayedItems.isEmpty else { return }
                    if let idx = keyboardSelectedIndex, idx > 0 {
                        keyboardSelectedIndex = idx - 1
                    } else {
                        keyboardSelectedIndex = displayedItems.count - 1
                    }
                },
                onDown: {
                    guard !displayedItems.isEmpty else { return }
                    let last = displayedItems.count - 1
                    if let idx = keyboardSelectedIndex, idx < last {
                        keyboardSelectedIndex = idx + 1
                    } else {
                        keyboardSelectedIndex = 0
                    }
                },
                onReturn: {
                    if let idx = keyboardSelectedIndex, idx < displayedItems.count {
                        let item = displayedItems[idx]
                        lastCopiedId = item.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if lastCopiedId == item.id { lastCopiedId = nil }
                        }
                        store.copyToClipboard(item)
                        onDismiss()
                    }
                },
                onEscape: { onDismiss() }
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: showFullWindow) { newValue in
            if newValue {
                onDismiss()
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.showMainWindow()
                }
            }
        }
    }
}

// MARK: - macOS 26 style menu item
struct MacOSMenuItem: View {
    let icon: String
    let label: String
    var color: Color = .accentColor
    var shortcut: String = ""
    var sz: (CGFloat) -> CGFloat = { $0 }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: sz(14), weight: .regular))
                .foregroundColor(color)
                .frame(width: 20, height: 22)
            Text(label)
                .font(.system(size: sz(14)))
                .foregroundColor(Color(nsColor: .controlTextColor))
            Spacer()
            if !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: sz(11), design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hoverBackground.cornerRadius(appCornerRadius))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var hoverBackground: some View {
        if isHovered {
            Color.accentColor.opacity(0.15)
        } else {
            Color.clear
        }
    }
}

private func highlightedText(_ text: String, highlight: String, fontSize: CGFloat) -> Text {
    var displayText: String
    if !highlight.isEmpty, let range = text.range(of: highlight, options: .caseInsensitive) {
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let start = max(0, matchStart - 20)
        let end = min(text.count, matchStart + 80)
        var excerpt = String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
        if start > 0 { excerpt = "…" + excerpt }
        if end < text.count { excerpt += "…" }
        displayText = excerpt
    } else {
        displayText = String(text.prefix(80))
        if text.count > 80 { displayText += "…" }
    }

    var attr = AttributedString(displayText)
    attr.foregroundColor = Color(nsColor: .controlTextColor)
    attr.font = .system(size: fontSize)
    if !highlight.isEmpty, let attrRange = attr.range(of: highlight, options: .caseInsensitive) {
        attr[attrRange].backgroundColor = Color.yellow.opacity(0.7)
        attr[attrRange].foregroundColor = .black
    }
    return Text(attr)
}

struct QuickBarRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isCopied: Bool
    let searchText: String
    let sz: (CGFloat) -> CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    private var iconName: String {
        switch item.type {
        case .text: return "doc.text"
        case .image: return "photo"
        case .link: return "link"
        }
    }

    private var rowBackground: Color {
        if isCopied { return Color.green.opacity(0.3) }
        if isSelected || isHovered { return Color.accentColor.opacity(0.15) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: sz(12)))
                .foregroundColor(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                if item.type == .image {
                    Text(L10n.itemImage)
                        .font(.system(size: sz(12)))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if item.isSensitive {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: sz(9)))
                            .foregroundColor(.orange)
                        Text("[\(L10n.itemSensitive)]")
                            .font(.system(size: sz(12)))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                } else {
                    highlightedText((ClipboardStore.shared.getDecryptedContent(item) ?? "").replacingOccurrences(of: "\n", with: " "), highlight: searchText, fontSize: sz(12))
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(formattedDate)
                .font(.system(size: sz(10)))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
        .animation(.easeOut(duration: 0.3), value: isCopied)
    }

    private var formattedDate: String {
        cachedRelativeDateFormatter(for: LanguageManager.shared.selectedLanguage)
            .localizedString(for: item.createdAt, relativeTo: Date())
    }
}
