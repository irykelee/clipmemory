import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import os.log

// swiftlint:disable file_length
// Justification: ContentView is the single SwiftUI root for sidebar + content +
// settings Form. Splitting ContentView was deferred per 2026-07-20 audit
// (ContentView split is the remaining deferred item). File was already at the
// 1250-line ceiling before Task 7; adding the UpdateSource Section pushes it
// over. Track the 1250 ceiling explicitly so any further growth is visible.

enum SidebarTab: String, CaseIterable {
    case all, text, image, link, richText, pinned, trash, settings
    var icon: String {
        switch self { case .all: "tray.full"; case .text: "doc.text"; case .image: "photo"; case .link: "link"; case .richText: "doc.richtext"; case .pinned: "star"; case .trash: "trash"; case .settings: "gear" }
    }
    var label: String {
        switch self { case .all: L10n.filterAll; case .text: L10n.filterText; case .image: L10n.filterImage; case .link: L10n.filterLink; case .richText: L10n.filterRichText; case .pinned: L10n.headerShowPinned; case .trash: L10n.trashTitle; case .settings: L10n.buttonSettings }
    }
    var typeFilter: ClipboardItemType? {
        switch self { case .text: .text; case .image: .image; case .link: .link; case .richText: .richText; default: nil }
    }
}

/// Localized display name for a clipboard content type.
func typeLabel(_ type: ClipboardItemType) -> String {
    switch type {
    case .text: return L10n.filterText
    case .image: return L10n.filterImage
    case .link: return L10n.filterLink
    case .richText: return L10n.filterRichText
    }
}

let appCornerRadius: CGFloat = 8

/// Time-based grouping used by ContentView's list sections. Defined at
/// module scope (not nested in ContentView) so SidebarTagFilter helpers
/// can reference it without going through ContentView.Type.
enum TimeGroup: String, CaseIterable {
    case today, yesterday, older
    var label: String {
        switch self {
        case .today: L10n.groupToday
        case .yesterday: L10n.groupYesterday
        case .older: L10n.groupOlder
        }
    }
}

/// H-13 (2026-07-24 audit): replaced `(old: Int, new: Int)?` tuple with this
/// explicit Equatable struct. @State storage of tuples was undocumented and
/// could silently break SwiftUI diffing (no Equatable conformance). Members
/// are `let` so the value is immutable after construction.
struct PendingMaxItemsReduction: Equatable {
    let old: Int
    let new: Int
}

struct ContentView: View {
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "ContentView")
    // ID-PERF-0001 (2026-07-30 audit): hoist JSONEncoder. saveCollapsedGroups
    // is called from the SwiftUI main-actor context, so this static is safe.
    private static let collapsedGroupsEncoder = JSONEncoder()
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared
    @State private var selectedTab: SidebarTab = .all
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var searchTextDebounced = ""
    @State private var searchTextDebounce: DispatchWorkItem?
    // Cache for displayedItems to avoid recomputing on every access
    @State private var cachedDisplayedItems: [ClipboardItem] = []
    @State private var cachedGroupedItems: [(TimeGroup, [ClipboardItem])] = []
    @State private var cachedGroupedItemsWithIndex: [(group: TimeGroup, items: [(item: ClipboardItem, globalIndex: Int)])] = []
    // I-9 (2026-07-20 audit): cached tab/tag usage counts. Body was O(n) twice
    // per render; cached as @State and refreshed via .onChange(items.count).
    @State private var cachedTabCounts: [SidebarTab: Int] = [.all: 0]
    @State private var cachedTagCounts: [UUID: Int] = [:]
    @State private var cachedTabCountsVersion: Int = 0
    @State private var dateFilter: DateFilter = .all
    /// Captures the previous DateFilter so onChange can log the transition
    /// (1-param onChange API on macOS 13 does not deliver the old value).
    @State private var previousDateFilter: DateFilter = .all
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: ClipboardItem?
    @State private var showingEmptyTrashAlert = false
    @State private var pendingClearMode: ClearMode?
    @State private var pendingTypeClear: ClipboardItemType?
    @State private var showingConditionalClear = false
    @State private var revealedItems: Set<UUID> = []
    @State private var keyboardSelectedIndex: Int?
    // H-10 (2026-07-24 audit): visibleGlobalIndices used to be a computed
    // property walked on every ↑/↓/Return (3 calls per keystroke, each O(n)).
    // Cache it as @State and recompute only when collapsedGroups /
    // searchTextDebounced / cachedDisplayedItems change (via the onChange
    // handlers below + updateDisplayedItemsCache). handleKeyUp/Down/Return now
    // just read the cached value.
    @State private var cachedVisibleGlobalIndices: [Int] = []
    @State private var lastCopiedId: UUID?
    @State private var scrollAnchor: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var collapsedGroups: Set<TimeGroup> = {
        guard let data = UserDefaults.standard.string(forKey: "collapsedGroups")?.data(using: .utf8) else {
            return []
        }
        // ID-06 (2026-07-30 audit): a future TimeGroup rename would make every
        // user's stored collapsed state silently invalid and reset to "all
        // expanded". Log the decode failure so the regression is visible.
        do {
            let arr = try JSONDecoder().decode([String].self, from: data)
            return Set(arr.compactMap { TimeGroup(rawValue: $0) })
        } catch {
            Self.logger.error("Failed to decode persisted collapsed groups (reset to all expanded): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }()
    /// Anchor used for "today"/"yesterday" grouping.  Updated by a timer so
    /// items move to the correct section if the app stays open across midnight.
    @State private var currentDate = Date()
    @State private var tagPickerItem: ClipboardItem?
    @State private var selectedTagIds: Set<UUID> = []
    @State private var showNewTagSheet: Bool = false
    @State private var tagPendingDelete: Tag?
    @AppStorage("themeAppearance") private var themeAppearance = "system"
    // 2026-07-25: font-scale invalidation trigger. MUST be read in body —
    // an unread @AppStorage creates no SwiftUI dependency, so font-size
    // changes never re-rendered views that size via sz().
    @AppStorage("fontScale") private var fontScale: Double = 1.0

    // MARK: - Cached Date Calculations
    private var startOfToday: Date {
        Calendar.current.startOfDay(for: currentDate)
    }
    private var startOfYesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    }

    // MARK: - Keyboard Handlers
    /// Pure helper extracted from the old computed property so the logic is
    /// unit-testable without a SwiftUI view body. Returns global indices into
    /// `items` whose time-group is not collapsed. Active search forces all
    /// groups expanded (matches original body behavior).
    static func computeVisibleGlobalIndices(
        items: [ClipboardItem],
        collapsedGroups: Set<TimeGroup>,
        searchText: String,
        today: Date,
        yesterday: Date
    ) -> [Int] {
        let effectiveCollapsed: Set<TimeGroup> = searchText.isEmpty ? collapsedGroups : []
        let visibleIds = Set(SidebarTagFilter.visibleItems(
            items: items,
            collapsedGroups: effectiveCollapsed,
            today: today,
            yesterday: yesterday
        ).map(\.id))
        return items.indices.filter {
            visibleIds.contains(items[$0].id)
        }
    }

    /// H-10: rebuild cachedVisibleGlobalIndices from current state. Called
    /// when cachedDisplayedItems / collapsedGroups / searchTextDebounced
    /// change (see onChange handlers below + updateDisplayedItemsCache).
    /// Key handlers read `cachedVisibleGlobalIndices` directly.
    private func recomputeVisibleGlobalIndices() {
        cachedVisibleGlobalIndices = Self.computeVisibleGlobalIndices(
            items: cachedDisplayedItems,
            collapsedGroups: collapsedGroups,
            searchText: searchTextDebounced,
            today: startOfToday,
            yesterday: startOfYesterday
        )
    }

    private func handleKeyUp() {
        let visibleIdx = cachedVisibleGlobalIndices
        guard !visibleIdx.isEmpty else { return }
        if let current = keyboardSelectedIndex,
           let pos = visibleIdx.firstIndex(of: current),
           pos > 0 {
            keyboardSelectedIndex = visibleIdx[pos - 1]
        } else {
            // No selection, or selection hidden — wrap to last visible.
            // Guarded by `!visibleIdx.isEmpty` above, but use optional fallback for
            // safety against future refactors that drop the guard.
            keyboardSelectedIndex = visibleIdx.last ?? keyboardSelectedIndex
        }
        if let idx = keyboardSelectedIndex { scrollAnchor = cachedDisplayedItems[idx].id }
    }

    private func handleKeyDown() {
        let visibleIdx = cachedVisibleGlobalIndices
        guard !visibleIdx.isEmpty else { return }
        if let current = keyboardSelectedIndex,
           let pos = visibleIdx.firstIndex(of: current),
           pos < visibleIdx.count - 1 {
            keyboardSelectedIndex = visibleIdx[pos + 1]
        } else {
            // No selection, selection hidden, or at end — wrap to first visible.
            // Guarded by `!visibleIdx.isEmpty` above, but use optional fallback for
            // safety against future refactors that drop the guard.
            keyboardSelectedIndex = visibleIdx.first ?? keyboardSelectedIndex
        }
        if let idx = keyboardSelectedIndex { scrollAnchor = cachedDisplayedItems[idx].id }
    }

    private func handleKeyReturn() {
        let visibleIdx = cachedVisibleGlobalIndices
        guard let idx = keyboardSelectedIndex, visibleIdx.contains(idx) else { return }
        copyItemWithFlash(cachedDisplayedItems[idx])
    }

    /// Copy an item to the clipboard and flash the "copied" state briefly.
    /// ID-VIEW-0011 (2026-08-01 audit): shared by KeyCaptureView.onReturn
    /// (handleKeyReturn above) and the search field's `.onSubmit` so the
    /// two Return routes cannot drift apart (same rationale as QuickBar's
    /// ID-A11Y-0008 copyItemAndDismiss).
    private func copyItemWithFlash(_ item: ClipboardItem) {
        lastCopiedId = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if self.lastCopiedId == item.id { self.lastCopiedId = nil }
        }
        store.copyToClipboard(item)
    }

    private func handleKeyEscape() {
        // selectedTab can no longer be .settings (sidebar binding intercepts
        // it), so Escape only handles search-clear and window close.
        if !searchText.isEmpty {
            searchText = ""
        } else {
            NSApp.keyWindow?.close()
        }
    }

    private func focusSearchField() {
        isSearchFocused = true
    }

    private func saveCollapsedGroups(_ groups: Set<TimeGroup>) {
        let arr = groups.map { $0.rawValue }
        // ID-05 (2026-07-30 audit): JSONEncoder on [String] doesn't realistically
        // fail, but if a future refactor adds non-encodable elements the user's
        // collapsed-group preference would silently reset on next launch. Log it.
        do {
            let data = try Self.collapsedGroupsEncoder.encode(arr)
            guard let str = String(data: data, encoding: .utf8) else {
                Self.logger.error("Failed to convert collapsed-groups JSON to UTF-8 (preference lost)")
                return
            }
            UserDefaults.standard.set(str, forKey: "collapsedGroups")
        } catch {
            Self.logger.error("Failed to persist collapsed groups (preference lost on next launch): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func debounceSearch(_ text: String) {
        searchTextDebounce?.cancel()
        // H-11 (2026-07-24 audit): match QuickBarView's implicit-self
        // `DispatchWorkItem { var = value }` form — the prior `{ [self] in
        // self.x = y }` was functionally identical but read as if self
        // capture was doing something unusual, inviting future readers to
        // second-guess the [self] capture semantics.
        let work = DispatchWorkItem { searchTextDebounced = text }
        searchTextDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Theme
    private func applyAppearance() {
        switch themeAppearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Optimized Item Filtering
    private func filterItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        filterItemsImpl(items)
    }

    private func filterItemsImpl(_ items: [ClipboardItem]) -> [ClipboardItem] {
        // Sidebar dimensions (type/pinned + tag section) are pure — delegate
        // to SidebarTagFilter so we can unit-test them. Date + search stay
        // here because they need view-scoped state (startOfToday, debounced
        // search text).
        let sidebarFiltered = SidebarTagFilter.apply(
            items: items,
            typeFilter: selectedTab == .pinned ? nil : selectedTab.typeFilter,
            pinnedOnly: selectedTab == .pinned,
            selectedTagIds: selectedTagIds
        )
        return sidebarFiltered.filter { item in
            // date filter
            if item.createdAt < startOfYesterday {
                if dateFilter == .today || dateFilter == .yesterday { return false }
            } else if item.createdAt < startOfToday {
                if dateFilter == .today || dateFilter == .older { return false }
            } else {
                if dateFilter == .yesterday || dateFilter == .older { return false }
            }
            // search filter
            // CLIP-1 main (2026-07-24 audit): richText search goes through
            // the store's rtfPlaintextCache — never parse the raw (encrypted
            // base64) content directly here; that path returned the parser's
            // default "Rich Text" string for every encrypted RTF item and
            // bypassed rtfPlaintextCache (M-24 contract). Search matches the
            // actual RTF plaintext AND respects the cache (no per-keystroke
            // NSAttributedString parse).
            if !searchTextDebounced.isEmpty {
                // P0-3: check caches first instead of sync decrypt.
                // Cold-cache items are batched for background prewarm and
                // skipped in this pass; they reappear once caches are warm.
                let contentKey = item.id.uuidString as NSString
                let searchableText: String
                // ID-PERF-0021 (2026-08-01 audit): richText used to call
                // store.getRTFPlaintext here — a synchronous AES-GCM decrypt
                // + RTF parse (20-100 ms/item) on a cold cache, violating
                // the P0-3 contract above. Read the cache only, mirroring
                // QuickBarView.computeDisplayedItems; cold items are skipped
                // this pass and resurface after background prewarm via the
                // ID-VIEW-0008 debounced objectWillChange rebuild.
                if item.type == .richText {
                    guard let cached = store.cachedRtfPlaintext(item) else { return false }
                    searchableText = cached
                } else if let cached = store.contentCache.object(forKey: contentKey) as? String {
                    searchableText = cached
                } else if item.decryptionFailed {
                    return false
                } else {
                    return false
                }

                var ocrMatch = false
                if item.type == .image {
                    let ocrKey = (item.id.uuidString + ".ocr") as NSString
                    if let cachedOCR = store.contentCache.object(forKey: ocrKey) as? String {
                        ocrMatch = FuzzySearchMatcher.matches(content: cachedOCR, searchText: searchTextDebounced)
                    } else if item.ocrText != nil, !item.decryptionFailed {
                        return false
                    }
                }

                if !FuzzySearchMatcher.matches(content: searchableText, searchText: searchTextDebounced), !ocrMatch {
                    return false
                }
            }
            return true
        }
    }

    /// Checks if the calendar day rolled over since `currentDate` was last set,
    /// and if so, advances `currentDate` + refreshes the displayed-items cache.
    /// Called from `.onReceive(NSCalendarDayChangedNotification)` (cross-midnight)
    /// and `.onAppear` (initial render even if no rollover yet).
    private func handleDayRolloverIfNeeded() {
        let calendar = Calendar.current
        let nowStart = calendar.startOfDay(for: Date())
        let cachedStart = calendar.startOfDay(for: currentDate)
        guard nowStart != cachedStart else { return }
        handleDayRollover()
    }

    /// Applies the day rollover: bump `currentDate`, log, refresh cache.
    /// Always called on main thread (notification + onAppear both deliver on main).
    private func handleDayRollover() {
        // currentDate is @State — capture BEFORE reassigning so the rollover log
        // shows the actual transition.
        let previous = currentDate
        currentDate = Date()
        UIObservability.logCurrentDateRollover(from: previous, to: currentDate)
        updateDisplayedItemsCache()
    }

    /// ID-LIFE-0019 (2026-07-30 audit) — REVERTED same session: the
    /// pure-path + orchestrator split caused a display regression
    /// (text rows rendered empty after Phase A push). Root cause is
    /// the `[self]` value capture of a SwiftUI View struct in the
    /// orchestrator's completion handler — the captured copy's
    /// `@State` mutations through `updateDisplayedItemsCache()` didn't
    /// propagate to the live view correctly (struct value semantics +
    /// @State external storage interaction is subtle). Restored the
    /// pre-split monolithic form. ID-LIFE-0019's proposed behavior
    /// (cold items auto-surface via completion) needs a different
    /// mechanism (Combine observer on `store.contentCache.count`, or
    /// Task + debounce on the AppDelegate side) — re-attempt in a
    /// follow-up audit batch with a non-capture-based approach.
    private func updateDisplayedItemsCache() {
        let start = Date()
        cachedDisplayedItems = filterItems(store.items)
        // P0-2 P2: merge once per filter pass (not per-item inside .filter closure).
        store.mergePendingDiagnostics()
        // P0-3: pre-warm caches in background so the next filter pass reads from
        // contentCache/rtfPlaintextCache (fast path) instead of doing sync AES-GCM
        // decrypt on the main thread.
        // ID-VIEW-0012 (2026-08-01 audit): feed the FULL item set, not the
        // filtered survivors — during an active search, cold items fail the
        // filter (return false below) and would otherwise wait for the next
        // app-activation full-set prewarm before self-healing. prewarm
        // internally narrows to uncached items, so the extra input is cheap.
        // ID-PERF-0023 (2026-08-02 audit): 5 s throttled entry — see store.
        store.prewarmDecryptionCacheThrottled(items: store.items)
        // H-10 (2026-07-24 audit): items changed → visible indices change too.
        recomputeVisibleGlobalIndices()
        // Update grouped items cache
        var dict: [TimeGroup: [ClipboardItem]] = [:]
        for item in cachedDisplayedItems {
            let g: TimeGroup
            if item.createdAt >= startOfToday { g = .today } else if item.createdAt >= startOfYesterday { g = .yesterday } else { g = .older }
            dict[g, default: []].append(item)
        }
        cachedGroupedItems = TimeGroup.allCases.compactMap { guard let items = dict[$0], !items.isEmpty else { return nil }; return ($0, items) }
        // Update groupedItemsWithIndex cache
        var result: [(group: TimeGroup, items: [(item: ClipboardItem, globalIndex: Int)])] = []
        var globalIdx = 0
        for (g, items) in cachedGroupedItems {
            var groupItems: [(item: ClipboardItem, globalIndex: Int)] = []
            for item in items {
                groupItems.append((item, globalIdx))
                globalIdx += 1
            }
            result.append((g, groupItems))
        }
        cachedGroupedItemsWithIndex = result
        UIObservability.logCacheRebuild(
            groups: cachedGroupedItems.count,
            items: cachedGroupedItems.reduce(0) { $0 + $1.1.count },
            durationMs: Date().timeIntervalSince(start) * 1000
        )
    }

    var displayedItems: [ClipboardItem] { cachedDisplayedItems }

    private var tabCounts: [SidebarTab: Int] {
        // I-9: serve from cache; invalidation lives in .onChange(of: store.items.count).
        // Initial seed happens lazily on first access (returned cache falls back to
        // computed value if cachedTabCountsVersion never bumped).
        if cachedTabCountsVersion == 0 { return Self.computeTabCounts(items: store.items) }
        return cachedTabCounts
    }

    /// Per-tag usage count over ALL items (independent of current sidebar
    /// selection). Users see "this tag is attached to N items" without
    /// filtering the count itself by what they've already selected.
    private var tagCounts: [UUID: Int] {
        // I-9: identical invalidation contract — see tabCounts above.
        if cachedTabCountsVersion == 0 { return Self.computeTagCounts(items: store.items) }
        return cachedTagCounts
    }

    /// O(n) recompute helper. Called only when cachedTabCountsVersion resets
    /// (initial render) or when invalidated by `.onChange(of: store.items.count)`.
    private static func computeTabCounts(items: [ClipboardItem]) -> [SidebarTab: Int] {
        var counts: [SidebarTab: Int] = [.all: items.count]
        for item in items { switch item.type {
        case .text: counts[.text, default: 0] += 1
        case .image: counts[.image, default: 0] += 1
        case .link: counts[.link, default: 0] += 1
        case .richText: counts[.richText, default: 0] += 1
        } }
        return counts
    }

    private static func computeTagCounts(items: [ClipboardItem]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in items {
            for tagId in item.tagIds {
                counts[tagId, default: 0] += 1
            }
        }
        return counts
    }

    /// Cache refresh exposed to the `.onChange(of: store.items.count)` watcher.
    /// Avoids recomputing on every body re-render.
    fileprivate func refreshUsageCountCache() {
        cachedTabCounts = Self.computeTabCounts(items: store.items)
        cachedTagCounts = Self.computeTagCounts(items: store.items)
        cachedTabCountsVersion += 1
    }

    /// Tags sorted newest-first, matching the TagPickerSheet ordering.
    private var sortedTags: [Tag] {
        store.tags.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Toggle a tag in/out of the sidebar selection. Empty selection means
    /// "no tag filter applied"; multiple selected means "OR within section".
    private func toggleTag(_ id: UUID) {
        if selectedTagIds.contains(id) {
            selectedTagIds.remove(id)
        } else {
            selectedTagIds.insert(id)
        }
    }

    private var groupedItemsWithIndex: [(group: TimeGroup, items: [(item: ClipboardItem, globalIndex: Int)])] {
        cachedGroupedItemsWithIndex
    }

    private var batchAllPinned: Bool {
        let sel = selectedItems
        guard !sel.isEmpty else { return false }
        return displayedItems.filter { sel.contains($0.id) }.allSatisfy { $0.isPinned }
    }

    var body: some View {
        let _ = fontScale  // 2026-07-25: subscribe to font-scale changes (see declaration)
        return withKeyAndSheets(splitViewWithLifecycle)
            .onChange(of: store.items) { _ in
                // H-9: prune selectedItems to live IDs (defensive against any
                // delete path that forgets to clean it). Also refresh caches.
                // Deferred via Task to avoid "Modifying state during view update".
                let liveIDs = Set(store.items.map(\.id))
                let pruned = selectedItems.intersection(liveIDs)
                Task { @MainActor in
                    selectedItems = pruned
                    refreshUsageCountCache()
                    refreshDisplayedItemsCacheSoon(source: "store.items")
                }
            }
            // B-2 (2026-07-27): the `searchText` change that cleared
            // `keyboardSelectedIndex` was previously registered HERE in
            // `withKeyAndSheets`, separately from the debounce + log handler
            // in `attachLifecycle`. SwiftUI dispatches both observers, but
            // splitting the same signal across two callbacks is fragile —
            // the BUG-004 handler is now consolidated with the debounce
            // observer in `attachLifecycle` (see below). The `collapsedGroups`
            // and `searchTextDebounced` observers stay here because they
            // are about the visible-index sequence, not the search field.
            // H-10 (2026-07-24 audit): collapsed-groups toggles invalidate the
            // visible-index sequence. ID-VIEW-0007 (2026-07-31 audit): this
            // recomputes SYNCHRONOUSLY — the old comment claimed a deferred
            // "next main hop" that was never implemented. Sync is safe here:
            // both triggers (user group-toggle click, debounce work item)
            // fire outside SwiftUI's view-update cycle, so writing
            // cachedVisibleGlobalIndices can't hit "Modifying state during
            // view update".
            .onChange(of: collapsedGroups) { _ in
                recomputeVisibleGlobalIndices()
            }
            // H-10 (2026-07-24 audit): searchTextDebounced is the "search has
            // settled" signal (raw searchText changes on every keystroke; the
            // debounced copy only fires 250ms after the last edit). Recompute
            // on the settled copy so we don't pay O(n) per keystroke.
            // ID-VIEW-0007 (2026-07-31 audit): synchronous recompute, same
            // rationale as collapsedGroups above.
            .onChange(of: searchTextDebounced) { _ in
                recomputeVisibleGlobalIndices()
            }
    }

    private func withKeyAndSheets<V: View>(_ v: V) -> some View {
        v
            .overlay(alignment: .top) { KeyCaptureView(
                searchText: searchText,
                onUp: { self.handleKeyUp() },
                onDown: { self.handleKeyDown() },
                onReturn: { self.handleKeyReturn() },
                onEscape: { self.handleKeyEscape() },
                onCommandF: { self.focusSearchField() }
            ).frame(width: 0, height: 0) }
            .sheet(isPresented: $showingConditionalClear) { ConditionalClearSheet(store: store) }
            .sheet(item: $tagPickerItem) { item in
                TagPickerSheet(item: item, store: store)
            }
            .sheet(isPresented: $showNewTagSheet) {
                NewTagSheet(store: store) { newId in
                    selectedTagIds.insert(newId)
                }
            }
            .alert(L10n.sidebarDeleteTagConfirmTitle,
                   isPresented: Binding(get: { tagPendingDelete != nil },
                                        set: { if !$0 { tagPendingDelete = nil } })) {
                Button(L10n.buttonCancel, role: .cancel) { tagPendingDelete = nil }
                Button(L10n.tagDeleteOnlyTag, role: .destructive) {
                    if let tag = tagPendingDelete {
                        store.deleteTag(id: tag.id)
                        selectedTagIds.remove(tag.id)
                    }
                    tagPendingDelete = nil
                }
                Button(L10n.tagDeleteWithContent, role: .destructive) {
                    if let tag = tagPendingDelete {
                        store.deleteTag(id: tag.id, includeItems: true)
                        selectedTagIds.remove(tag.id)
                    }
                    tagPendingDelete = nil
                }
            } message: {
                if let tag = tagPendingDelete {
                    let count = store.items.filter { $0.tagIds.contains(tag.id) }.count
                    Text(L10n.sidebarDeleteTagConfirmMessage(tag.name, count))
                }
            }
    }

    /// CLIP-3: trim-alert cancel path, extracted so the regression tests can
    /// drive it without a SwiftUI view tree. Restores the pre-picker limit;
    /// the history stays untouched.
    static func applyTrimCancellation(pair: PendingMaxItemsReduction, store: ClipboardStore) {
        store.maxItems = pair.old
    }

    /// CLIP-3: trim-alert confirm path. Applies the reduced limit, evicts
    /// the overflow (pinned items survive — see `trimToMaxItems`), and
    /// persists synchronously so a quit right after confirming can't lose
    /// the trimmed state.
    static func applyTrimConfirmation(pair: PendingMaxItemsReduction, store: ClipboardStore) {
        store.maxItems = pair.new
        store.trimToMaxItems()
        store.flushPendingSaves()
    }

    /// Defer cache rebuilds out of the current view-update cycle. Writing
    /// @State synchronously inside onChange/onReceive triggers SwiftUI's
    /// "Modifying state during view update" runtime warning.
    private func refreshDisplayedItemsCacheSoon(source: String) {
        UIObservability.logRefreshTrigger(source: source)
        DispatchQueue.main.async { updateDisplayedItemsCache() }
    }

    private func attachLifecycle<V: View>(_ v: V) -> some View {
        v
            // L-13 (2026-07-25 audit): attachLifecycle previously registered
            // two separate `.onAppear` modifiers. SwiftUI applies both, but
            // they express related lifecycle work and are clearer as a single
            // appear block. Consolidated here: menu shortcut, appearance,
            // displayed-items cache, and the midnight rollover check.
            .onAppear {
                (NSApp.delegate as? AppDelegate)?.disableFindMenuShortcut()
                applyAppearance()
                updateDisplayedItemsCache()
                handleDayRolloverIfNeeded()
            }
            .onChange(of: searchText) { newValue in
                // B-2 (2026-07-27): previously the `keyboardSelectedIndex`
                // clear was registered in `withKeyAndSheets`, separately from
                // the debounce + log here. Splitting the same signal across
                // two observers was fragile — if a future refactor calls
                // `searchText = ""` programmatically, the debounce async
                // hop would land after the visible-index recompute, leaving
                // the user on a stale selection for one frame. Now both
                // side-effects run synchronously in the same callback:
                // (1) clear the keyboard selection (BUG-004 — Binding
                // bypasses @State didSet, so we observe via the view layer);
                // (2) log the change for observability;
                // (3) schedule the debounce hop (deferred to avoid "modifying
                // state during view update" runtime warnings).
                keyboardSelectedIndex = nil
                UIObservability.logSearchChange(length: newValue.count)
                DispatchQueue.main.async { self.debounceSearch(newValue) }
            }
            .onChange(of: searchTextDebounced) { _ in refreshDisplayedItemsCacheSoon(source: "searchDebounced") }
            .onChange(of: selectedTab) { _ in refreshDisplayedItemsCacheSoon(source: "selectedTab") }
            .onChange(of: dateFilter) { newValue in
                UIObservability.logDateFilterChange(from: previousDateFilter, to: newValue)
                previousDateFilter = newValue
                refreshDisplayedItemsCacheSoon(source: "dateFilter")
            }
            .onChange(of: selectedTagIds) { newValue in
                UIObservability.logTagSelectionChange(count: newValue.count)
                refreshDisplayedItemsCacheSoon(source: "selectedTagIds")
            }
            .onChange(of: store.tags) { _ in
                DispatchQueue.main.async {
                    UIObservability.logRefreshTrigger(source: "store.tags")
                    // Strip orphan UUIDs (tag deleted from store while selected)
                    // before re-rendering so we don't show a stale empty filter.
                    let valid = Set(store.tags.keys)
                    if !selectedTagIds.isSubset(of: valid) {
                        selectedTagIds.formIntersection(valid)
                    }
                    updateDisplayedItemsCache()
                }
            }
            .onChange(of: collapsedGroups) { val in
                self.saveCollapsedGroups(val)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cmdFFindAction)) { _ in self.focusSearchField() }
            // P0-2 F2/F19: view self-observes .cryptoKeyPrepared so the banner
            // hides on key restore (keyUnavailable→success) and reappears on
            // terminal failure. guard success==true: failure doesn't need refresh.
            .onReceive(NotificationCenter.default.publisher(for: .cryptoKeyPrepared)) { note in
                let success = (note.userInfo?["success"] as? Bool) ?? false
                guard success else { return }
                refreshDisplayedItemsCacheSoon(source: "cryptoKeyPrepared")
            }
            // ID-VIEW-0008 (2026-08-01 audit, cross-ref ID-LIFE-0019): cold
            // items (filter path can't decrypt them yet, e.g. right after
            // launch) only surfaced on the NEXT user edit — prewarm decrypted
            // them in the background but nothing re-ran the filter when it
            // finished. The reverted ID-LIFE-0019 attempt captured the View
            // struct in a completion handler and caused a display regression;
            // this retry is the mandated non-capture mechanism: prewarm's
            // batch-end path already sends store.objectWillChange (only when
            // real decrypts ran), so observe that publisher — debounced —
            // and rebuild the displayed cache.
            // Loop-freedom reasoning: the rebuild's prewarm re-pass finds an
            // empty uncached set → early return, no send; an items-change
            // burst coalesces into one debounced fire, which the existing
            // .onChange(of: store.items) rebuild path also answers (one extra
            // cache-hit rebuild at most). mergePendingDiagnostics SETs zero
            // state once and then compares equal, so it can't sustain a loop.
            .onReceive(store.objectWillChange.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)) { _ in
                // ID-PERF-0022 (2026-08-01 audit): route through the async
                // hop like the other rebuild triggers above — the onReceive
                // closure runs inside the view-update cycle, and a
                // synchronous full O(n) cache rebuild writing @State here
                // risks SwiftUI's "Modifying state during view update".
                refreshDisplayedItemsCacheSoon(source: "objectWillChange.debounce")
            }
            // M8 fix: use NSCalendarDayChanged notification (fires at midnight) instead of
            // Timer.publish(every: 60). Reduces wakeups from 1440/day to 1/day, and removes
            // the synchronous-write-of-@State-in-onReceive pattern that triggered SwiftUI warnings.
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name(rawValue: "NSCalendarDayChangedNotification")
            )) { _ in
                handleDayRollover()
            }
    }

    private var splitViewWithLifecycle: some View {
        attachLifecycle(NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            // 2026-07-25: selectedTab can no longer be .settings (the sidebar
            // binding intercepts it and opens the settings window instead),
            // so the detail pane is always the item list.
            itemList
        }
        .frame(minWidth: 640, minHeight: 440)
        .toolbar { self.toolbarContent }
        // 2026-07-25: `.visible` forced an opaque toolbar background. On
        // macOS 15 that rendered as a unified material blended with the
        // sidebar; on macOS 26 (Tahoe) the title bar + toolbar stack renders
        // as an opaque white band with a separator. This modifier only
        // controls the toolbar layer — the actual culprit is the title bar
        // layer underneath, which WindowManager fixes via
        // `titlebarAppearsTransparent` + `.fullSizeContentView`. `.hidden`
        // here keeps the toolbar layer itself from painting a background
        // so the two layers stay transparent together.
        .toolbarBackground(.hidden, for: .windowToolbar))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "search") {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: sz(11)))
                TextField(L10n.searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: sz(12)))
                    .focused($isSearchFocused)
                    // ID-VIEW-0011 (2026-08-01 audit): with the search field
                    // focused, KeyCaptureView propagates Return to the field
                    // (KeyCaptureView.swift:95-100), but no `.onSubmit` was
                    // attached — Return was a dead key here. Copy the
                    // keyboard-selected item when one is visible, else the
                    // first filtered result. Mirrors QuickBarView's
                    // `.onSubmit` (ID-A11Y-0008); the main window stays open
                    // (it's not a popover).
                    .onSubmit {
                        let idx = keyboardSelectedIndex.flatMap {
                            cachedVisibleGlobalIndices.contains($0) ? $0 : nil
                        } ?? cachedVisibleGlobalIndices.first
                        guard let idx, idx < cachedDisplayedItems.count else { return }
                        copyItemWithFlash(cachedDisplayedItems[idx])
                    }
                    .frame(width: 180)
                // 2026-07-27 (user-requested): one-tap clear of the search
                // field instead of backspacing character by character.
                // Hidden when the field is empty so the toolbar stays
                // visually quiet when no search is active. Mirrors the
                // QuickBar × at QuickBarView.swift:110-115 so both search
                // surfaces have a consistent interaction model.
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        isSearchFocused = true
                    }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: sz(11)))
                    })
                    .buttonStyle(.plain)
                    // ID-L10N-0002 (2026-07-30 audit): localized VoiceOver label.
                    .accessibilityLabel(L10n.searchClear)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .cornerRadius(6)
        }
        ToolbarItem(id: "clear") {
            if selectedTab == .trash {
                Button(role: .destructive, action: { showingEmptyTrashAlert = true }, label: {
                    Label(L10n.trashEmptyConfirmTitle, systemImage: "trash")
                })
                .disabled(store.trashedItems.isEmpty)
            } else {
                Menu {
                    Button(action: { showingConditionalClear = true }, label: { Label(L10n.clearConditionalAction, systemImage: "line.3.horizontal.decrease.circle") })
                    Divider()
                    Button(action: { pendingClearMode = .today }, label: { Label(L10n.clearToday, systemImage: "sunrise") })
                    Button(action: { pendingClearMode = .yesterday }, label: { Label(L10n.clearYesterday, systemImage: "sun.haze") })
                    Button(action: { pendingClearMode = .older }, label: { Label(L10n.clearOlder, systemImage: "clock.arrow.circlepath") })
                    Divider()
                    Button(role: .destructive, action: { pendingClearMode = .all }, label: { Label(L10n.headerClearHistory, systemImage: "trash") })
                    Divider()
                    Button(action: { store.unpinToday() }, label: { Label(L10n.unpinToday, systemImage: "star.slash") })
                    Button(action: { store.unpinYesterday() }, label: { Label(L10n.unpinYesterday, systemImage: "star.slash") })
                    Button(action: { store.unpinOlder() }, label: { Label(L10n.unpinOlder, systemImage: "star.slash") })
                    Button(action: { store.unpinAll() }, label: { Label(L10n.unpinAll, systemImage: "star.slash") })
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(store.items.isEmpty)
            }
        }
        // ID-VIEW-0014 (2026-08-03 audit, user-driven): date filter was
        // previously a ToolbarItemGroup(placement: .principal) at the
        // top of this toolbar. `.principal` items are NOT routed through
        // NSToolbar's native » overflow menu when the window narrows —
        // they get silently clipped, hiding both the search hint and
        // the active filter selection from the user. Date filters and
        // tag filters are semantically the same class (list filters, not
        // window-level commands), so move the date filter chip strip
        // down next to the existing `activeTagFilterStrip` (itemList's
        // VStack). The toolbar now only carries window-level commands
        // (search + clear) and stays legible at 640pt.
    }

    private var sidebar: some View {
        SidebarView(
            store: store,
            // 2026-07-25: intercept the settings row so it never becomes a
            // real tab selection. Routing it through selectedTab swapped the
            // detail pane to a placeholder and back within one runloop tick,
            // producing a visible flash in the main content area. Now the
            // click opens the independent settings window directly and the
            // current tab stays put.
            selectedTab: Binding(
                get: { selectedTab },
                set: { newValue in
                    if newValue == .settings {
                        (NSApp.delegate as? AppDelegate)?.showSettingsWindow()
                    } else {
                        selectedTab = newValue
                    }
                }
            ),
            selectedTagIds: selectedTagIds,
            tabCounts: tabCounts,
            tagCounts: tagCounts,
            sortedTags: sortedTags,
            onToggleTag: { toggleTag($0) },
            onNewTag: { showNewTagSheet = true },
            onDeleteTag: { tagPendingDelete = $0 },
            onClearType: { pendingTypeClear = $0 },
            onTabChanged: {
                DispatchQueue.main.async {
                    keyboardSelectedIndex = nil
                }
            }
        )
    }

    /// NEW-7 Phase 4: passes the list-related @State through to ItemListView.
    /// ContentView keeps ownership so filterItems / search debouncing / day
    /// rollover stay in one place — the ViewModel collapse is Phase 5+ scope.
    private var itemList: some View {
        VStack(spacing: 0) {
            // ID-VIEW-0014 (2026-08-03 audit): date filter chip strip
            // moved here from the window toolbar's `.principal` placement
            // (ContentView.swift:830-839, now removed). `.principal`
            // toolbar items are silently clipped on narrow windows instead
            // of being routed into NSToolbar's » overflow menu — moving
            // down here keeps them always visible and side-by-side with
            // the semantically-equivalent tag filter strip below.
            // Padding mirrors `activeTagFilterStrip` so the two strips
            // share the same horizontal margin.
            HStack(spacing: 4) {
                ForEach(DateFilter.allCases, id: \.self) { filter in
                    DateFilterButton(title: filter.label, isSelected: dateFilter == filter) {
                        dateFilter = filter
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // 2026-07-27 (user-requested): surface the active tag filter at
            // the top of the list so users don't read a short list as
            // "missing content". When `selectedTagIds` is empty the chip
            // strip renders nothing (no extra vertical space). When set,
            // the strip shows one chip per selected tag with an inline ×,
            // plus a "clear all" affordance and a count badge.
            activeTagFilterStrip
            DiagnosticsBanner(
                diagnostics: store.diagnostics,
                onDismiss: { store.dismissDiagnostics() }
            )
            ItemListView(
                store: store,
                selectedTab: selectedTab,
                displayedItems: displayedItems,
                groupedItemsWithIndex: groupedItemsWithIndex,
                batchAllPinned: batchAllPinned,
                searchText: $searchText,
                searchTextDebounced: $searchTextDebounced,
                collapsedGroups: $collapsedGroups,
                selectedItems: $selectedItems,
                keyboardSelectedIndex: $keyboardSelectedIndex,
                lastCopiedId: $lastCopiedId,
                scrollAnchor: $scrollAnchor,
                revealedItems: $revealedItems,
                pendingClearMode: $pendingClearMode,
                pendingTypeClear: $pendingTypeClear,
                showingConditionalClear: $showingConditionalClear,
                showingDeleteAlert: $showingDeleteAlert,
                itemToDelete: $itemToDelete,
                showingEmptyTrashAlert: $showingEmptyTrashAlert,
                tagPickerItem: $tagPickerItem
            )
        }
    }

    /// Active tag filter chip strip + count badge. Renders nothing when
    /// `selectedTagIds` is empty. See itemList for context.
    @ViewBuilder
    private var activeTagFilterStrip: some View {
        if !selectedTagIds.isEmpty {
            let activeTags = sortedTags.filter { selectedTagIds.contains($0.id) }
            HStack(spacing: 8) {
                Text(L10n.tagFilterActiveTitle)
                    .font(.system(size: sz(11), weight: .medium))
                    .foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(activeTags, id: \.id) { tag in
                            activeTagChip(tag: tag)
                        }
                    }
                }
                Button(action: { selectedTagIds.removeAll() }) {
                    Text(L10n.tagFilterClearAll)
                        .font(.system(size: sz(11), weight: .medium))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help(L10n.tagFilterClearAll)
                .accessibilityLabel(L10n.tagFilterClearAll)
                Spacer(minLength: 8)
                Text(L10n.tagFilterCount(displayedItems.count, store.items.count))
                    .font(.system(size: sz(11)))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    /// Single tag chip in the active-filter strip. Color dot + name + × to
    /// remove this tag from the filter.
    private func activeTagChip(tag: Tag) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: tag.colorHex))
                .frame(width: 8, height: 8)
            Text(tag.name)
                .font(.system(size: sz(11)))
                .lineLimit(1)
            Button(action: { selectedTagIds.remove(tag.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: sz(10)))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tagFilterRemoveTag)
            .accessibilityLabel(Text(L10n.tagFilterRemoveTag) + Text(", ") + Text(tag.name))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: tag.colorHex).opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: tag.colorHex).opacity(0.5), lineWidth: 0.5)
        )
    }
}
