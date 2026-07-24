import SwiftUI
import AppKit

struct QuickBarView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared

    @State private var searchText = ""
    @State private var searchTextDebounced = ""
    @State private var searchDebounce: DispatchWorkItem?
    @State private var keyboardSelectedIndex: Int?
    @State private var lastCopiedId: UUID?
    @State private var showFullWindow = false
    @State private var scrollAnchor: UUID?
    // CLIP-4 (2026-07-24 audit): displayedItems used to be an uncached
    // computed property consumed 4+ times per body evaluation (section
    // label, empty-state, ForEach, dividers, keyboard handlers), each an
    // O(n) filter with per-item RTF-plaintext/decrypt lookups. Cache it as
    // @State and recompute only when store.items / searchTextDebounced
    // change — mirrors the visibleGlobalIndices pattern in ContentView
    // (H-10). The getter below stays side-effect-free (BUG-039).
    @State private var cachedDisplayedItems: [ClipboardItem] = []
    @FocusState private var isSearchFocused: Bool
    @AppStorage("fontScale") private var fontScale: Double = 1.0

    let onDismiss: () -> Void

    private let maxItems = 8

    private var quickBarBackground: AnyShapeStyle {
        AnyShapeStyle(Color.clear)
    }

    private var menuSectionBackground: AnyShapeStyle {
        AnyShapeStyle(Color.clear)
    }

    var displayedItems: [ClipboardItem] {
        cachedDisplayedItems
    }

    /// CLIP-4: pure filter extracted from the old computed property so the
    /// logic is unit-testable without a SwiftUI view body. Side-effect-free:
    /// reads go through the store's caches (M-24 contract), no cache writes
    /// (BUG-039 — the previous filter wrote to `cacheRTFPlaintext` inside
    /// the getter, which SwiftUI evaluates during view-body updates).
    static func computeDisplayedItems(
        items: [ClipboardItem],
        searchTextDebounced: String,
        maxItems: Int,
        store: ClipboardStore
    ) -> [ClipboardItem] {
        if searchTextDebounced.isEmpty {
            return Array(items.prefix(maxItems))
        }
        return items.filter { item in
            guard !item.isDecryptionFailed else { return false }
            // CLIP-1 main (2026-07-24 audit): use store.getRTFPlaintext
            // instead of item.plainTextFromRTFFallback so search hits
            // actual RTF plaintext (not the parser's hardcoded "Rich Text"
            // placeholder for encrypted items) AND goes through the cache
            // (M-24 contract).
            let searchableText = item.type == .richText
                ? store.getRTFPlaintext(item)
                : (store.getDecryptedContent(item) ?? "")
            return searchableText.localizedCaseInsensitiveContains(searchTextDebounced)
        }
    }

    /// Rebuild cachedDisplayedItems from current inputs. Called on appear
    /// and when store.items / searchTextDebounced change (see modifiers in
    /// body). Key handlers read `displayedItems` (the cache) directly.
    private func recomputeDisplayedItems() {
        cachedDisplayedItems = Self.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: searchTextDebounced,
            maxItems: maxItems,
            store: store
        )
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
                    .onChange(of: searchText) { newValue in
                        keyboardSelectedIndex = nil
                        searchDebounce?.cancel()
                        let item = DispatchWorkItem { searchTextDebounced = newValue }
                        searchDebounce = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
                    }
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
                ScrollViewReader { proxy in
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
                                .id(item.id)
                                if index < displayedItems.count - 1 {
                                    // 40 = row horizontal padding(12) + icon width(16) + icon-text spacing(8) + 4 for visual alignment
                                    Color.primary.opacity(0.06).frame(height: 1).padding(.leading, 40)
                                }
                            }
                        }
                    }
                    .onChange(of: scrollAnchor) { newAnchor in
                        if let anchor = newAnchor {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(anchor, anchor: .center)
                            }
                        }
                    }
                }
            }

            Color.clear.frame(height: 6)

            // macOS 26 menu style bottom section
            VStack(spacing: 0) {
                MacOSMenuItem(icon: "rectangle.expand.vertical", label: L10n.quickbarOpenFull, sz: sz)
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
                searchText: searchText,
                onUp: {
                    guard !displayedItems.isEmpty else { return }
                    // Add upper-bound guard (idx < displayedItems.count) so a stale
                    // keyboardSelectedIndex pointing past the end — e.g. after the user
                    // deletes the currently-selected item — falls through to the safe
                    // else branch instead of computing an out-of-bounds subscript.
                    if let idx = keyboardSelectedIndex, idx > 0, idx < displayedItems.count {
                        keyboardSelectedIndex = idx - 1
                    } else {
                        keyboardSelectedIndex = displayedItems.count - 1
                    }
                    if let idx = keyboardSelectedIndex { scrollAnchor = displayedItems[idx].id }
                },
                onDown: {
                    guard !displayedItems.isEmpty else { return }
                    let last = displayedItems.count - 1
                    // Add idx >= 0 guard so a stale negative idx (e.g. -5) cannot bypass
                    // the < last check and trigger a negative-index Array subscript trap.
                    if let idx = keyboardSelectedIndex, idx < last, idx >= 0 {
                        keyboardSelectedIndex = idx + 1
                    } else {
                        keyboardSelectedIndex = 0
                    }
                    if let idx = keyboardSelectedIndex { scrollAnchor = displayedItems[idx].id }
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
                onEscape: { onDismiss() },
                onCommandF: { isSearchFocused = true }
            )
            .frame(width: 0, height: 0)
        )
        // F-9 (2026-07-23 audit): ⌘F inside the QuickBar popover could be
        // a no-op because the popover is in its own NSWindow and the
        // KeyCaptureView NSEvent local monitor doesn't always fire there
        // consistently. AppDelegate's `handleFindAction` posts a
        // `.cmdFFindAction` notification via the menu path, but QuickBar
        // had no listener for it. Mirrors ContentView's
        // `.onReceive(NotificationCenter.default.publisher(for: .cmdFFindAction))`
        // (ContentView.swift:524) so the menu path focuses the search
        // field regardless of which route fires.
        .onReceive(NotificationCenter.default.publisher(for: .cmdFFindAction)) { _ in
            isSearchFocused = true
        }
        .onChange(of: showFullWindow) { newValue in
            if newValue {
                // M-14 (2026-07-24 audit): the previous code called
                // `onDismiss()` then queued `showMainWindow()` on the next
                // runloop tick. The popover closing + main window showing
                // happened in two separate AppKit frames, leaving a brief
                // gap where no window was frontmost (visible flicker on
                // some macOS 14/15 builds). Invoke both synchronously in
                // the same tick — onDismiss closes the popover, then
                // showMainWindow activates the main window immediately.
                onDismiss()
                (NSApp.delegate as? AppDelegate)?.showMainWindow()
            }
        }
        // CLIP-4 (2026-07-24 audit): keep cachedDisplayedItems in sync with
        // its two inputs. onAppear covers popover-open (the view is created
        // fresh each time). The onChange writes are deferred one runloop
        // tick — writing @State synchronously inside onChange during a view
        // update triggers SwiftUI's "Modifying state during view update"
        // warning (same pattern as ContentView.refreshDisplayedItemsCacheSoon).
        .onAppear { recomputeDisplayedItems() }
        .onChange(of: store.items) { _ in
            DispatchQueue.main.async { recomputeDisplayedItems() }
        }
        .onChange(of: searchTextDebounced) { _ in
            DispatchQueue.main.async { recomputeDisplayedItems() }
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
        case .richText: return "doc.richtext"
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
                } else if item.type == .richText {
                    // CLIP-1 main + CLIP-2 (2026-07-24 audit): use the cached,
                    // decrypted plaintext path. The prior `plainTextFromRTFFallback`
                    // returned the parser's hardcoded English "Rich Text" string
                    // for every encrypted RTF item — both wrong text AND a
                    // localization bug (L10n.itemRichText was ignored).
                    Text(ClipboardStore.shared.getRTFPlaintext(item))
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
