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
    ///
    /// P1 (2026-07-29 audit): check caches first instead of sync decrypt.
    /// Cold-cache items are skipped in this pass and prewarmed for the next
    /// one — mirrors ContentView.filterItemsImpl. The caller
    /// (recomputeDisplayedItems) triggers prewarm after the filter.
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
            let contentKey = item.id.uuidString as NSString
            let searchableText: String
            if item.type == .richText {
                if let cached = store.cachedRtfPlaintext(item) {
                    searchableText = cached
                } else {
                    return false
                }
            } else if let cached = store.contentCache.object(forKey: contentKey) as? String {
                searchableText = cached
            } else {
                return false
            }
            return FuzzySearchMatcher.matches(content: searchableText, searchText: searchTextDebounced)
        }
    }

    /// ID-LIFE-0019 (2026-07-30 audit) — REVERTED same session: the
    /// pure-path + orchestrator split caused a display regression
    /// (QuickBarView rows also showed empty content after the v3.0
    /// audit push — same `[self]` View struct capture issue as
    /// ContentView). Restored the pre-split monolithic form which
    /// calls `prewarmDecryptionCache` inline. The proposed auto-surface
    /// behavior needs a non-capture-based mechanism (Combine observer
    /// or Task-with-debounce) — re-attempt in a follow-up audit.
    private func recomputeDisplayedItems() {
        cachedDisplayedItems = Self.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: searchTextDebounced,
            maxItems: maxItems,
            store: store
        )
        // P0-2 P2: merge once per filter pass
        store.mergePendingDiagnostics()
        // P0-3: pre-warm caches in background for next filter pass.
        // ID-VIEW-0012 (2026-08-01 audit): feed the FULL item set, not the
        // filtered survivors — cold items fail the search filter (return
        // false in computeDisplayedItems) and would otherwise wait for the
        // next app-activation full-set prewarm before self-healing. prewarm
        // internally narrows to uncached items, so the extra input is cheap.
        // ID-PERF-0023 (2026-08-02 audit): 5 s throttled entry — see store.
        store.prewarmDecryptionCacheThrottled(items: store.items)
    }

    /// ID-A11Y-0008 (2026-07-31 audit): shared "copy + flash + dismiss" path
    /// used by row tap, list-level Enter (KeyCaptureView.onReturn), and the
    /// search field's Return (`.onSubmit`). Extracted so the three keyboard /
    /// pointer routes cannot drift apart.
    private func copyItemAndDismiss(_ item: ClipboardItem) {
        lastCopiedId = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if lastCopiedId == item.id { lastCopiedId = nil }
        }
        store.copyToClipboard(item)
        onDismiss()
    }

    var body: some View {
        // 2026-07-25: reading fontScale subscribes this view to @AppStorage
        // invalidation — an unread wrapper creates no dependency, so
        // font-size changes never re-rendered. See ClipboardItemRow.
        let _ = fontScale
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
                    // ID-A11Y-0008 (2026-07-31 audit): while the search field
                    // owns focus, KeyCaptureView deliberately lets Return/Esc
                    // propagate to the field (KeyCaptureView.swift:95-100),
                    // which made both keys dead for keyboard users. Route
                    // them explicitly: Return copies the keyboard-selected
                    // (else first) result; Esc closes the QuickBar.
                    .onSubmit {
                        let idx = keyboardSelectedIndex.flatMap { $0 >= 0 && $0 < displayedItems.count ? $0 : nil } ?? 0
                        guard !displayedItems.isEmpty else { return }
                        copyItemAndDismiss(displayedItems[idx])
                    }
                    .onExitCommand { onDismiss() }
                    // I-1 (2026-07-25 audit): writing @State synchronously
                    // inside `.onChange` can trigger SwiftUI's "Modifying state
                    // during view update" warning when the TextField binding
                    // changes during a view update. Defer the writes to the
                    // next runloop tick, matching `ContentView`'s pattern.
                    .onChange(of: searchText) { newValue in
                        DispatchQueue.main.async {
                            keyboardSelectedIndex = nil
                            searchDebounce?.cancel()
                            let item = DispatchWorkItem { searchTextDebounced = newValue }
                            searchDebounce = item
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
                        }
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

            // P0-2: diagnostics banner (key unavailable / data corrupted)
            DiagnosticsBanner(
                diagnostics: store.diagnostics,
                onDismiss: { store.dismissDiagnostics() }
            )

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
                                    store: store,
                                    isSelected: keyboardSelectedIndex == index,
                                    isCopied: lastCopiedId == item.id,
                                    searchText: searchText,
                                    // NEW-E (2026-07-27 review): thread the
                                    // debounced text into QuickBarRow so the
                                    // snippet doesn't flash a stale highlight
                                    // during the 250ms debounce window when
                                    // `searchText` updates keystroke-by-keystroke
                                    // but the filter only re-runs after the
                                    // debounce fires. The filter itself at :48
                                    // already reads `searchTextDebounced`, but
                                    // the row body at :397/:431 still used raw
                                    // `searchText` — so a row could be re-rendered
                                    // mid-window with a search term the filter
                                    // hadn't yet applied, producing a brief
                                    // "highlight on a row that's about to
                                    // disappear" flash.
                                    searchTextDebounced: searchTextDebounced,
                                    sz: sz,
                                    onTap: {
                                        copyItemAndDismiss(item)
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
                    .onTapGesture {
                        onDismiss()
                        (NSApp.delegate as? AppDelegate)?.showMainWindow()
                    }
                Color.clear.frame(height: 1)
                // 2026-07-25: settings entry in the Quick Bar menu — same
                // destination as the sidebar row and the ⌘, menu item.
                MacOSMenuItem(icon: "gear", label: L10n.buttonSettings, sz: sz)
                    .onTapGesture {
                        onDismiss()
                        (NSApp.delegate as? AppDelegate)?.showSettingsWindow()
                    }
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
                    // ID-LIFE-0013 (2026-07-30 audit): mirror onUp/onDown's
                    // `idx >= 0` guard. keyboardSelectedIndex is Int?; a -1
                    // would crash with array out-of-bounds. Today unreachable
                    // from keyboard handlers, but defensive.
                    if let idx = keyboardSelectedIndex, idx >= 0, idx < displayedItems.count {
                        copyItemAndDismiss(displayedItems[idx])
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
        // P0-2 F2/F19: QuickBar self-observes .cryptoKeyPrepared so the banner
        // refreshes on key restore / terminal failure.
        .onReceive(NotificationCenter.default.publisher(for: .cryptoKeyPrepared)) { note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            guard success else { return }
            recomputeDisplayedItems()
        }
        // ID-VIEW-0010 (2026-08-01 audit): cold-cache search misses were
        // silently dropped AND never recovered — nothing re-ran the filter
        // when prewarm finished. Mirrors ContentView's ID-VIEW-0008
        // mechanism (ContentView.swift:688-706): prewarm's batch-end path
        // sends store.objectWillChange when real decrypts ran, so observe
        // that publisher — debounced — and rebuild. Loop-freedom: the
        // rebuild's prewarm re-pass finds an empty uncached set → early
        // return, no send.
        // ID-VIEW-0012 (2026-08-01 audit): prewarm now also feeds the full
        // `store.items` set (not just the filtered survivors), so cold items
        // excluded by an active search are decrypted and surface via this
        // same rebuild path instead of waiting for the next app-activation
        // full-set prewarm. Loop-freedom still holds: once decrypted, the
        // re-pass finds no uncached items → no send.
        .onReceive(store.objectWillChange.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)) { _ in
            recomputeDisplayedItems()
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
        // ID-L10N-0003 (2026-07-30 audit): localized shortcut hint for VoiceOver.
        .accessibilityLabel(shortcut.isEmpty ? label : L10n.quickbarMenuShortcut(label, shortcut))
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
    // L-15 (2026-07-25 audit): inject the store instead of reaching for the
    // singleton, with a default fallback to `.shared` so existing call sites
    // and previews keep working. Tests can pass a mock/observed instance.
    let store: ClipboardStore
    let isSelected: Bool
    let isCopied: Bool
    let searchText: String
    // NEW-E (2026-07-27 review): debounced copy of searchText threaded from
    // the parent QuickBarView. Row body uses this for snippet rendering so
    // the highlight doesn't flash during the 250ms filter debounce window.
    // The filter at :48 already uses the parent's debounced state directly.
    let searchTextDebounced: String
    let sz: (CGFloat) -> CGFloat
    let onTap: () -> Void

    @State private var isHovered = false
    // P1 (2026-07-29 audit): async-populated cached plaintext to avoid
    // AES-GCM sync decrypt on the main thread during body evaluation.
    @State private var loadedContent: String?
    @State private var loadedRtfPlaintext: String?
    @State private var loadedOcrText: String?
    // ID-VIEW-0002 (2026-07-31 audit): bumped by the .cryptoKeyPrepared
    // observer below so the `.task` re-runs after the crypto key lands —
    // see ClipboardItemRow for the full key-race scenario.
    @State private var decryptRetryToken = 0

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
                    let trimmed = searchTextDebounced.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty,
                       store.ocrPreviewEnabled,
                       let ocrText = loadedOcrText {
                        Text(ClipboardItemRow.highlightedOcrContentNarrow(ocrText: ocrText, highlight: trimmed))
                            .font(.system(size: sz(12)))
                            .lineLimit(1)
                    } else {
                        Text(L10n.itemImage)
                            .font(.system(size: sz(12)))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else if item.type == .richText {
                    Text(loadedRtfPlaintext ?? L10n.itemRichText)
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
                    highlightedText((loadedContent ?? "").replacingOccurrences(of: "\n", with: " "), highlight: searchTextDebounced, fontSize: sz(12))
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
        .accessibilityLabel(clipboardItemAccessibilityLabel)
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
        .animation(.easeOut(duration: 0.3), value: isCopied)
        // ID-VIEW-0002 (2026-07-31 audit): `decryptRetryToken` in the task id
        // lets the .cryptoKeyPrepared observer below re-fire the decrypt
        // after a key-race double miss (same fix as ClipboardItemRow).
        .task(id: "\(item.id.uuidString)-\(decryptRetryToken)") {
            guard item.type != .richText else {
                if loadedRtfPlaintext == nil {
                    let rtf = await Task.detached(priority: .utility) {
                        store.getRTFPlaintext(item)
                    }.value
                    if Task.isCancelled { return }
                    loadedRtfPlaintext = rtf
                }
                return
            }
            guard item.type != .image else {
                if loadedOcrText == nil, item.ocrText != nil {
                    let ocr = await Task.detached(priority: .utility) {
                        store.getDecryptedOcrText(item)
                    }.value
                    if Task.isCancelled { return }
                    loadedOcrText = ocr
                }
                return
            }
            if loadedContent != nil { return }
            // ID-FIX-key-race (2026-07-30 audit): see ClipboardItemRow —
            // first decrypt can return empty if prepareKey hasn't finished
            // on a fresh launch. Retry once after 200ms.
            let first = await Task.detached(priority: .utility) {
                store.getDecryptedContent(item) ?? ""
            }.value
            if Task.isCancelled { return }
            if !first.isEmpty {
                loadedContent = first
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let second = await Task.detached(priority: .utility) {
                store.getDecryptedContent(item) ?? ""
            }.value
            if Task.isCancelled { return }
            // ID-VIEW-0002 (2026-07-31 audit): write only a non-empty result.
            // Storing "" made `loadedContent != nil` early-return forever and
            // left the QuickBar row blank with no recovery path; keeping nil
            // lets the .cryptoKeyPrepared retry below re-run this task.
            if !second.isEmpty {
                loadedContent = second
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cryptoKeyPrepared)) { note in
            // ID-VIEW-0002 (2026-07-31 audit): key landed after our decrypt
            // attempts missed — bump the token in the .task id so it re-runs.
            let success = (note.userInfo?["success"] as? Bool) ?? false
            guard success else { return }
            let needsRetry: Bool
            if item.type == .image {
                needsRetry = item.ocrText != nil && loadedOcrText == nil
            } else {
                needsRetry = item.type != .richText && loadedContent == nil
            }
            guard needsRetry else { return }
            decryptRetryToken += 1
        }
    }

    private var clipboardItemAccessibilityLabel: String {
        let typeLabel: String = {
            switch item.type {
            // ID-L10N-0001 (2026-07-30 audit): use existing localized type
            // names (already present for the sidebar type filter).
            case .text: return L10n.filterText
            case .image: return L10n.filterImage
            case .link: return L10n.filterLink
            case .richText: return L10n.filterRichText
            }
        }()
        let preview = loadedContent?.prefix(50) ?? ""
        // ID-L10N-0003 (2026-07-30 audit): localized "<Type> clipboard item: <preview>"
        // template. Falls back to the typeLabel key verbatim if the locale omits
        // the new "quickbar.clipboardItemPrefix" key (legacy / fallback bundle).
        return L10n.quickbarClipboardItemPrefix(typeLabel, String(preview))
    }

    private var formattedDate: String {
        // ID-SYNC-0005 (2026-08-01 audit): locked formatting — the shared
        // formatter instance is no longer exposed directly.
        cachedRelativeDateString(from: item.createdAt, relativeTo: Date(),
                                 languageCode: LanguageManager.shared.selectedLanguage)
    }
}
