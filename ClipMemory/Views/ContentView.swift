import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

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

struct ContentView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared
    @State private var selectedTab: SidebarTab = .all
    @State private var searchText = "" { didSet { keyboardSelectedIndex = nil } }
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
    private enum ClearMode {
        case today, yesterday, older, all
    }
    @State private var revealedItems: Set<UUID> = []
    @State private var keyboardSelectedIndex: Int?
    @State private var lastCopiedId: UUID?
    @State private var scrollAnchor: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var collapsedGroups: Set<TimeGroup> = {
        guard let data = UserDefaults.standard.string(forKey: "collapsedGroups")?.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr.compactMap { TimeGroup(rawValue: $0) })
    }()
    /// Anchor used for "today"/"yesterday" grouping.  Updated by a timer so
    /// items move to the correct section if the app stays open across midnight.
    @State private var currentDate = Date()
    @State private var isRecordingHotKey = false
    @State private var hotkeyRefresh = false
    @State private var keyEventMonitor: Any?
    @State private var showingAppPicker = false
    @State private var showingTips = false
    @State private var pendingMaxItemsReduction: (old: Int, new: Int)?
    @State private var appPickerSearch = ""
    @State private var appPickerSearchDebounced = ""
    @State private var searchDebounce: DispatchWorkItem?
    @State private var installedApps: [AppPickerItem] = []
    @State private var isLoadingApps = false
    @State private var tagPickerItem: ClipboardItem?
    @State private var selectedTagIds: Set<UUID> = []
    @State private var showNewTagSheet: Bool = false
    @State private var tagPendingDelete: Tag?
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @AppStorage("themeAppearance") private var themeAppearance = "system"

    // MARK: - Cached Date Calculations
    private var startOfToday: Date {
        Calendar.current.startOfDay(for: currentDate)
    }
    private var startOfYesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    }

    // MARK: - Keyboard Handlers
    /// Global indices (into `cachedDisplayedItems`) of items whose group is
    /// not collapsed. Used as the navigation sequence for ↑/↓/Return so the
    /// highlight doesn't skip through hidden rows.
    /// When search is active the UI force-expands all groups, so keyboard nav
    /// must treat every item as visible to stay in sync with what the user sees.
    private var visibleGlobalIndices: [Int] {
        let effectiveCollapsed: Set<TimeGroup> = searchText.isEmpty ? collapsedGroups : []
        let visibleIds = Set(SidebarTagFilter.visibleItems(
            items: cachedDisplayedItems,
            collapsedGroups: effectiveCollapsed,
            today: startOfToday,
            yesterday: startOfYesterday
        ).map(\.id))
        return cachedDisplayedItems.indices.filter {
            visibleIds.contains(cachedDisplayedItems[$0].id)
        }
    }

    private func handleKeyUp() {
        let visibleIdx = visibleGlobalIndices
        guard !visibleIdx.isEmpty else { return }
        if let current = keyboardSelectedIndex,
           let pos = visibleIdx.firstIndex(of: current),
           pos > 0 {
            keyboardSelectedIndex = visibleIdx[pos - 1]
        } else {
            // No selection, or selection hidden — wrap to last visible.
            keyboardSelectedIndex = visibleIdx.last!
        }
        if let idx = keyboardSelectedIndex { scrollAnchor = cachedDisplayedItems[idx].id }
    }

    private func handleKeyDown() {
        let visibleIdx = visibleGlobalIndices
        guard !visibleIdx.isEmpty else { return }
        if let current = keyboardSelectedIndex,
           let pos = visibleIdx.firstIndex(of: current),
           pos < visibleIdx.count - 1 {
            keyboardSelectedIndex = visibleIdx[pos + 1]
        } else {
            // No selection, selection hidden, or at end — wrap to first visible.
            keyboardSelectedIndex = visibleIdx.first!
        }
        if let idx = keyboardSelectedIndex { scrollAnchor = cachedDisplayedItems[idx].id }
    }

    private func handleKeyReturn() {
        let visibleIdx = visibleGlobalIndices
        guard let idx = keyboardSelectedIndex, visibleIdx.contains(idx) else { return }
        let item = cachedDisplayedItems[idx]
        lastCopiedId = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if self.lastCopiedId == item.id { self.lastCopiedId = nil }
        }
        copyItem(item)
    }

    private func handleKeyEscape() {
        if selectedTab == .settings {
            selectedTab = .all
        } else if !searchText.isEmpty {
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
        guard let data = try? JSONEncoder().encode(arr) else { return }
        guard let str = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(str, forKey: "collapsedGroups")
    }

    @ViewBuilder private var appPickerSheetContent: some View {
        appPickerSheet.onAppear {
            appPickerSearchDebounced = appPickerSearch
            loadInstalledAppsIfNeeded()
        }
    }

    @ViewBuilder private var tipsSheet: some View {
        TipsView(onClose: { showingTips = false })
    }

    private func debounceSearch(_ text: String) {
        searchTextDebounce?.cancel()
        let work = DispatchWorkItem { [self] in
            self.searchTextDebounced = text
        }
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
            if !searchTextDebounced.isEmpty {
                let searchableText = item.type == .richText
                    ? item.plainTextFromRTFFallback
                    : (store.getDecryptedContent(item) ?? "")
                let ocrText = item.type == .image ? (store.getDecryptedOcrText(item) ?? "") : ""
                if !searchableText.localizedCaseInsensitiveContains(searchTextDebounced),
                   !ocrText.localizedCaseInsensitiveContains(searchTextDebounced) { return false }
            }
            return true
        }
    }

    private func updateDisplayedItemsCache() {
        let start = Date()
        cachedDisplayedItems = filterItems(store.items)
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

    enum DateFilter: String, CaseIterable {
        case all, today, yesterday, older
        var label: String {
            switch self { case .all: return L10n.dateFilterAll; case .today: return L10n.groupToday; case .yesterday: return L10n.groupYesterday; case .older: return L10n.groupOlder }
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
        withKeyAndSheets(splitViewWithLifecycle)
            .onChange(of: store.items.count) { _ in
                // Prune selectedItems to contain only IDs still present in items.
                // Defensive guard against any delete path that forgets to clean
                // selectedItems — e.g. per-row delete (was a stale-UUID bug pre-fix),
                // bulk delete's removeAll, restore-from-trash, auto-expiry, etc.
                // Without this the bulk-select toolbar (L624-628) stays visible
                // with stale UUIDs after the underlying item disappears.
                // .onChange(of: store.items.count) uses `Int` for Equatable
                // (required by .onChange signature); count changes on add/remove,
                // which is exactly the prune window we care about.
                let liveIDs = Set(store.items.map(\.id))
                selectedItems = selectedItems.intersection(liveIDs)
                // I-9: refresh cached tab/tag counts so badge() and tag rows
                // reflect the new item set without recomputing on every body.
                refreshUsageCountCache()
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
            .onDisappear { stopKeyEventMonitor() }
            .sheet(isPresented: $showingAppPicker) { self.appPickerSheetContent }
            .sheet(isPresented: $showingTips) { self.tipsSheet }
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

    /// Defer cache rebuilds out of the current view-update cycle. Writing
    /// @State synchronously inside onChange/onReceive triggers SwiftUI's
    /// "Modifying state during view update" runtime warning.
    private func refreshDisplayedItemsCacheSoon(source: String) {
        UIObservability.logRefreshTrigger(source: source)
        DispatchQueue.main.async { updateDisplayedItemsCache() }
    }

    private func attachLifecycle<V: View>(_ v: V) -> some View {
        v
            .onAppear {
                (NSApp.delegate as? AppDelegate)?.disableFindMenuShortcut()
                applyAppearance()
                updateDisplayedItemsCache()
            }
            .onChange(of: searchText) { newValue in
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
            .onChange(of: store.items) { _ in refreshDisplayedItemsCacheSoon(source: "store.items") }
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
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { _ in selectedTab = .settings }
            .onReceive(NotificationCenter.default.publisher(for: .cmdFFindAction)) { _ in self.focusSearchField() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                DispatchQueue.main.async {
                    let calendar = Calendar.current
                    let nowStart = calendar.startOfDay(for: Date())
                    let cachedStart = calendar.startOfDay(for: currentDate)
                    if nowStart != cachedStart {
                        // currentDate is @State — capture BEFORE reassigning so
                        // the rollover log shows the actual transition.
                        let previous = currentDate
                        currentDate = Date()
                        UIObservability.logCurrentDateRollover(from: previous, to: currentDate)
                        updateDisplayedItemsCache()
                    }
                }
            }
    }

    private var splitViewWithLifecycle: some View {
        attachLifecycle(NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            if selectedTab == .settings {
                settingsDetail
            } else {
                mainContent
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .toolbar { self.toolbarContent }
        .toolbarBackground(.visible, for: .windowToolbar))
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
                    .frame(width: 180)
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
        ToolbarItemGroup(placement: .principal) {
            if selectedTab != .settings {
                HStack(spacing: 4) {
                    ForEach(DateFilter.allCases, id: \.self) { filter in
                        DateFilterButton(title: filter.label, isSelected: dateFilter == filter) {
                            dateFilter = filter
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            LogoView()
                .padding(.horizontal, 8)
                .padding(.top, 8)
            List(selection: $selectedTab) {
                ForEach([SidebarTab.all, .text, .image, .link, .richText], id: \.self) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .badge(tabCounts[tab] ?? 0)
                        .tag(tab)
                        .contextMenu {
                            if let type = tab.typeFilter {
                                Button(role: .destructive, action: { pendingTypeClear = type }, label: {
                                    Label(L10n.clearTypeAction(typeLabel(type)), systemImage: "trash")
                                })
                            }
                        }
                }
                Section {
                    Label(SidebarTab.pinned.label, systemImage: SidebarTab.pinned.icon)
                        .tag(SidebarTab.pinned)
                    Label(SidebarTab.trash.label, systemImage: SidebarTab.trash.icon)
                        .badge(store.trashedItems.count)
                        .tag(SidebarTab.trash)
                    Label(SidebarTab.settings.label, systemImage: SidebarTab.settings.icon)
                        .tag(SidebarTab.settings)
                }
                Section(L10n.sidebarSectionTags) {
                    if store.tags.isEmpty {
                        Text(L10n.sidebarTagsEmpty)
                            .font(.system(size: sz(11)))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sortedTags, id: \.id) { tag in
                            SidebarTagRow(
                                tag: tag,
                                count: tagCounts[tag.id] ?? 0,
                                isSelected: selectedTagIds.contains(tag.id),
                                onTap: { toggleTag(tag.id) },
                                onDelete: { tagPendingDelete = tag }
                            )
                        }
                    }
                    Button(action: { showNewTagSheet = true }, label: {
                        Label(L10n.sidebarNewTag, systemImage: "plus.circle")
                            .font(.system(size: sz(12)))
                    })
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            .listStyle(.sidebar)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: selectedTab) { _ in DispatchQueue.main.async { keyboardSelectedIndex = nil } }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if selectedTab == .trash {
                trashView
            } else if displayedItems.isEmpty { emptyState } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(groupedItemsWithIndex, id: \.group) { section in
                            Section {
                                if !searchText.isEmpty || !collapsedGroups.contains(section.group) {
                                    ForEach(section.items, id: \.item.id) { itemWithIndex in
                                        self.buildItemRow(itemWithIndex: itemWithIndex)
                                            .listRowInsets(EdgeInsets())
                                            .listRowSeparator(.hidden)
                                            .id(itemWithIndex.item.id)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(section.group.label).font(.system(size: sz(12), weight: .semibold)).foregroundColor(.secondary)
                                    Spacer()
                                    Button(action: { pendingClearMode = clearModeForGroup(section.group) }, label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: sz(11)))
                                            .foregroundColor(.secondary)
                                    })
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.buttonClear)
                                    Image(systemName: (!collapsedGroups.contains(section.group) || !searchText.isEmpty) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: sz(10))).foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle()).onTapGesture { toggleGroup(section.group) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .layoutPriority(1)
                    .task(id: scrollAnchor) {
                        if let anchor = scrollAnchor {
                            proxy.scrollTo(anchor, anchor: .center)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if !selectedItems.isEmpty {
                        HStack { Text(L10n.batchSelected(selectedItems.count)).font(.system(size: sz(12))).foregroundColor(.secondary); Spacer()
                            Button(action: { store.togglePinItems(displayedItems.filter { selectedItems.contains($0.id) }); selectedItems.removeAll() }, label: { Label(batchAllPinned ? L10n.actionUnpin : L10n.actionPin, systemImage: batchAllPinned ? "star.slash" : "star").font(.system(size: sz(12))) }).buttonStyle(.plain)
                            Button(action: { store.deleteItems(displayedItems.filter { selectedItems.contains($0.id) }); selectedItems.removeAll() }, label: { Label(L10n.actionDelete, systemImage: "trash").font(.system(size: sz(12))) }).buttonStyle(.plain).foregroundColor(.red)
                            Button(action: { selectedItems.removeAll() }, label: { Text(L10n.buttonCancel).font(.system(size: sz(12))) }).buttonStyle(.plain).foregroundColor(.secondary)
                        }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: selectedItems.isEmpty)
            }
        }
        .alert(L10n.alertDeleteTitle, isPresented: $showingDeleteAlert) { Button(L10n.buttonCancel, role: .cancel) {}; Button(L10n.buttonDelete, role: .destructive) { if let item = itemToDelete { store.deleteItem(item) } } } message: { Text(L10n.alertDeleteMessage) }
        .alert(L10n.alertClearTitle, isPresented: Binding(
            get: { pendingTypeClear != nil },
            set: { if !$0 { pendingTypeClear = nil } }
        )) {
            Button(L10n.buttonCancel, role: .cancel) { pendingTypeClear = nil }
            Button(L10n.buttonClear, role: .destructive) {
                if let type = pendingTypeClear {
                    store.clearItems(type: type, range: .all)
                }
                pendingTypeClear = nil
            }
        } message: {
            if let type = pendingTypeClear {
                Text(L10n.clearTypeConfirm(typeLabel(type), store.items.filter { $0.type == type && !$0.isPinned }.count))
            }
        }
        .alert(L10n.alertClearTitle, isPresented: Binding(
            get: { pendingClearMode != nil },
            set: { if !$0 { pendingClearMode = nil } }
        )) {
            Button(L10n.buttonCancel, role: .cancel) { pendingClearMode = nil }
            Button(L10n.buttonClear, role: .destructive) { confirmClear() }
        } message: {
            Text(clearAlertText)
        }
        .alert(L10n.trashEmptyConfirmTitle, isPresented: $showingEmptyTrashAlert) {
            Button(L10n.buttonCancel, role: .cancel) { showingEmptyTrashAlert = false }
            Button(L10n.buttonClear, role: .destructive) {
                store.emptyTrash()
                showingEmptyTrashAlert = false
            }
        } message: {
            Text(L10n.trashEmptyConfirmMessage(store.trashedItems.count))
        }
        .alert(L10n.alertTrimTitle, isPresented: Binding(
            get: { pendingMaxItemsReduction != nil },
            set: { if !$0 { pendingMaxItemsReduction = nil } }
        )) {
            Button(L10n.alertTrimCancel, role: .cancel) {
                guard let pair = pendingMaxItemsReduction else { return }
                store.maxItems = pair.old
                pendingMaxItemsReduction = nil
                selectedTab = .settings
            }
            Button(L10n.alertTrimConfirm) {
                guard let pair = pendingMaxItemsReduction else { return }
                pendingMaxItemsReduction = nil
                store.maxItems = pair.new
                store.trimToMaxItems()
                store.flushPendingSaves()
            }
        } message: {
            if let pair = pendingMaxItemsReduction {
                Text(L10n.alertTrimMessage(store.items.count, pair.new))
            }
        }
    }

    private var clearAlertText: String {
        guard let mode = pendingClearMode else { return "" }
        let count: Int
        switch mode {
        case .today: count = store.todayCount
        case .yesterday: count = store.yesterdayCount
        case .older: count = store.olderCount
        case .all: count = store.items.filter { !$0.isPinned }.count
        }
        return count > 0 ? L10n.alertClearMessage(count) : L10n.alertClearNone
    }

    /// Maps a time group to the ClearMode used by the toolbar menu so the new
    /// per-group header trash button reuses the exact same confirmation flow.
    private func clearModeForGroup(_ group: TimeGroup) -> ClearMode {
        switch group {
        case .today: return .today
        case .yesterday: return .yesterday
        case .older: return .older
        }
    }

    /// Localized display name for a content type (matches sidebar filter labels).
    func typeLabel(_ type: ClipboardItemType) -> String {
        switch type {
        case .text: return L10n.filterText
        case .image: return L10n.filterImage
        case .link: return L10n.filterLink
        case .richText: return L10n.filterRichText
        }
    }

    private func confirmClear() {
        guard let mode = pendingClearMode else { return }
        switch mode {
        case .today: store.clearToday()
        case .yesterday: store.clearYesterday()
        case .older: store.clearOlder()
        case .all: store.clearAllItems()
        }
        pendingClearMode = nil
    }

    private var trashView: some View {
        VStack(spacing: 0) {
            if store.trashedItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: sz(36)))
                        .foregroundColor(.secondary)
                    Text(L10n.trashEmpty)
                        .font(.system(size: sz(14)))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(store.trashedItems) { item in
                        TrashItemRow(
                            item: item,
                            onRestore: { store.restoreFromTrash(item) },
                            onDeletePermanently: { store.deletePermanently(item) }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func startRecording() {
        isRecordingHotKey = true
        stopKeyEventMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard isRecordingHotKey else { return event }
            // Esc cancels recording and is returned to the responder chain so the
            // user can dismiss the sheet / settings panel as expected.
            if event.keyCode == 53 {
                isRecordingHotKey = false
                stopKeyEventMonitor()
                return event
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return nil }
            let keyCode = UInt32(event.keyCode)
            var modifiers: UInt32 = 0
            if mods.contains(.command) { modifiers |= UInt32(cmdKey) }
            if mods.contains(.control) { modifiers |= UInt32(controlKey) }
            if mods.contains(.option) { modifiers |= UInt32(optionKey) }
            if mods.contains(.shift) { modifiers |= UInt32(shiftKey) }
            isRecordingHotKey = false
            stopKeyEventMonitor()
            // H-1: hotKeyManager is optional — skip the rebind if the
            // AppDelegate hasn't initialized it yet (race on first launch).
            (NSApp.delegate as? AppDelegate)?.hotKeyManager?.updateHotKey(keyCode: keyCode, modifiers: modifiers)
            return nil
        }
    }

    private func stopKeyEventMonitor() {
        if let m = keyEventMonitor { NSEvent.removeMonitor(m); keyEventMonitor = nil }
    }

    private func toggleGroup(_ g: TimeGroup) {
        if collapsedGroups.contains(g) { collapsedGroups.remove(g) } else { collapsedGroups.insert(g) }
    }

    private var settingsDetail: some View {
        Form {
            if let hk = (NSApp.delegate as? AppDelegate)?.hotKeyManager {
                Section {
                    HStack {
                        if isRecordingHotKey {
                            Text(L10n.settingsHotkeyRecording).foregroundColor(.orange)
                            Spacer()
                            Button(L10n.buttonCancel) { isRecordingHotKey = false }.buttonStyle(.link)
                        } else {
                            Text(hk.config.displayString).fontDesign(.monospaced).id(hotkeyRefresh)
                            Spacer()
                            Button(L10n.settingsHotkeyChange) { startRecording() }.buttonStyle(.link)
                        }
                    }
                    Button(L10n.settingsHotkeyReset) {
                        hk.updateHotKey(keyCode: HotKeyConfig.defaultConfig.keyCode, modifiers: HotKeyConfig.defaultConfig.modifiers)
                        hotkeyRefresh.toggle()
                    }.buttonStyle(.link)
                } header: { Text(L10n.settingsSectionHotkey) }
            }
            Section {
                Picker(L10n.themeAppearance, selection: Binding(get: { themeAppearance }, set: { themeAppearance = $0; applyAppearance() })) {
                    Text(L10n.themeAppearanceSystem).tag("system"); Text(L10n.themeAppearanceLight).tag("light"); Text(L10n.themeAppearanceDark).tag("dark")
                }
            } header: { Text(L10n.settingsSectionTheme) }
            Section {
                Picker(L10n.settingsSectionLanguage, selection: $languageManager.selectedLanguage) { ForEach(languageManager.availableLanguages, id: \.code) { Text($0.name).tag($0.code) } }
            } header: { Text(L10n.settingsSectionLanguage) }
            Section {
                Picker(L10n.string("settings.font.picker"), selection: $fontScale) { Text(L10n.fontSizeSmall).tag(1.0); Text(L10n.fontSizeMedium).tag(1.2); Text(L10n.fontSizeLarge).tag(1.4) }
            } header: { Text(L10n.settingsFontSize) }
            Section {
                Picker(L10n.settingsAutoClear, selection: $store.sensitiveClearHours) { ForEach(SensitiveClearOption.options) { Text($0.label).tag($0.hours) } }.id(languageManager.selectedLanguage)
            } header: { Text(L10n.settingsSectionSensitive) } footer: { Text(L10n.settingsSensitiveHint).foregroundColor(.secondary) }
            Section {
                Picker(L10n.settingsMaxItems, selection: Binding(get: { store.maxItems }, set: { newValue in
                    if newValue < store.maxItems, store.items.count > newValue {
                        pendingMaxItemsReduction = (old: store.maxItems, new: newValue)
                    } else {
                        store.maxItems = newValue
                    }
                })) { ForEach([50, 100, 200, 500], id: \.self) { Text(L10n.settingsMaxItemsCount($0)).tag($0) } }.id(languageManager.selectedLanguage)
            } header: { Text(L10n.settingsSectionHistory) }
            Section {
                Picker(L10n.trashRetentionDays, selection: $store.trashRetentionDays) { ForEach([3, 7, 14, 30], id: \.self) { Text("\($0)").tag($0) } }
            }
            Section {
                Toggle(L10n.settingsCaptureRichText, isOn: $store.captureRichText)
            } footer: { Text(L10n.settingsCaptureRichTextHint).foregroundColor(.secondary) }
            Section {
                Toggle(L10n.settingsOcrEnabled, isOn: Binding(
                    get: { store.ocrEnabled },
                    set: { store.ocrEnabled = $0 }
                ))
            } footer: { Text(L10n.settingsOcrHint).foregroundColor(.secondary) }
            Section {
                excludedAppsTags
                Button(action: { showingAppPicker = true }, label: { Label(L10n.settingsAddExcludedApp, systemImage: "plus.circle") }).buttonStyle(.link)
            } header: { Text(L10n.settingsSectionExcludedApps) }
            Section {
                Toggle(L10n.launchAtLogin, isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { v in
                    do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { showLaunchAtLoginError() }
                }))
            }
            Section {
                Toggle(L10n.settingsBackupAuto, isOn: Binding(
                    get: { backupService.isEnabled },
                    set: { backupService.isEnabled = $0 }
                ))
                Picker(L10n.settingsBackupKeep, selection: Binding(
                    get: { backupService.keepCount },
                    set: { backupService.keepCount = $0 }
                )) { ForEach([3, 7, 14, 30], id: \.self) { Text("\($0)").tag($0) } }
                Button(L10n.settingsBackupNow) {
                    backupService.backupNow()
                    backupRefresh.toggle()
                }.buttonStyle(.link)
                Button(L10n.settingsBackupOpen) {
                    NSWorkspace.shared.open(backupService.backupsDirectoryURL)
                }.buttonStyle(.link)
                Button(L10n.settingsBackupExport) { exportBackup() }.buttonStyle(.link)
                Button(L10n.settingsBackupImport) { importBackup() }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionBackup) } footer: {
                if let last = backupService.lastBackupDate {
                    Text(L10n.settingsBackupLast(last.formatted(date: .abbreviated, time: .shortened))).foregroundColor(.secondary)
                        .id(backupRefresh)
                }
            }
            Section {
                Toggle(L10n.settingsUpdateAuto, isOn: Binding(
                    get: { UpdateService.shared.automaticallyChecksForUpdates },
                    set: { UpdateService.shared.automaticallyChecksForUpdates = $0 }
                ))
                Button(L10n.settingsUpdateCheckNow) { UpdateService.shared.checkNow() }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionUpdate) } footer: {
                if let lastCheck = UpdateService.shared.lastUpdateCheckDate {
                    Text(L10n.settingsUpdateLastCheck(lastCheck.formatted(date: .abbreviated, time: .shortened))).foregroundColor(.secondary)
                }
            }
            Section {
                Text(L10n.aboutVersion(AppVersion.current)).foregroundColor(.secondary)
                Text(L10n.aboutFreeEdition).foregroundColor(.secondary)
                Button(L10n.sendFeedback) { NSWorkspace.shared.open(URL(string: "https://github.com/irykelee/clipmemory/issues/new")!) }.buttonStyle(.link)
                Button(L10n.viewWelcomeGuide) { (NSApp.delegate as? AppDelegate)?.showWelcomeView() }.buttonStyle(.link)
                Button(L10n.tipsTitle) { showingTips = true }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionAbout) }
        }
        .formStyle(.grouped)
    }

    private func showLaunchAtLoginError() {
        let alert = NSAlert()
        alert.messageText = L10n.error
        alert.informativeText = L10n.settingsLaunchAtLoginErrorBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.buttonConfirm)
        alert.runModal()
    }

    // MARK: - Backup / Export / Import

    private let backupService = BackupService.shared
    @State private var backupRefresh = false

    private func showBackupInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: L10n.buttonConfirm)
        alert.runModal()
    }

    /// Prompts for the backup passphrase (min 6 chars). Returns nil on cancel/too short.
    private func promptBackupPassphrase() -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.settingsBackupPassphrase
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.buttonConfirm)
        alert.addButton(withTitle: L10n.buttonCancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.count >= 6 ? value : nil
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "clipmemory")].compactMap { $0 }
        panel.nameFieldStringValue = "ClipMemory-backup.clipmemory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let passphrase = promptBackupPassphrase() else { return }
        guard let keyData = CryptoService.loadKeyData() else {
            showBackupInfo(L10n.settingsBackupError)
            return
        }
        // Flush the 500ms debounce so the package includes the very latest items.
        ClipboardStore.shared.flushPendingSaves()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BackupPackage.exportPackage(
                    to: url,
                    passphrase: passphrase,
                    imagesDirectory: ImageStorage.shared.imagesDirectoryURL,
                    keyData: keyData
                )
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupExportDone) }
            } catch {
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupError) }
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "clipmemory")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let passphrase = promptBackupPassphrase() else { return }
        // Flush + safety snapshot of current data before mutating.
        ClipboardStore.shared.flushPendingSaves()
        // Heavy work (unzip, re-keying, image copies) off the main thread;
        // BackupPackage hops to main for the @Published merges itself.
        DispatchQueue.global(qos: .userInitiated).async {
            backupService.backupNow()
            do {
                let result = try BackupPackage.importPackage(
                    from: url,
                    passphrase: passphrase,
                    store: ClipboardStore.shared,
                    localCrypto: ServiceContainer.crypto,
                    imagesDirectory: ImageStorage.shared.imagesDirectoryURL
                )
                DispatchQueue.main.async {
                    showBackupInfo(L10n.settingsBackupImportResult(result.itemsImported, result.itemsSkipped, result.imagesImported))
                }
            } catch BackupPackageError.wrongPassword {
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupPassphraseWrong) }
            } catch {
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupError) }
            }
        }
    }

    private var excludedAppsTags: some View {
        let rawIds = store.excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let excludedIds = rawIds.filter { seen.insert($0).inserted }
        if excludedIds.isEmpty {
            return AnyView(EmptyView())
        }
        let apps: [(name: String, bundleId: String)] = excludedIds.compactMap { bundleId in
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                return (app.localizedName ?? bundleId, bundleId)
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return (url.deletingPathExtension().lastPathComponent, bundleId)
            }
            return nil
        }
        return AnyView(
            FlowLayout(spacing: 6) {
                ForEach(apps, id: \.bundleId) { app in
                    HStack(spacing: 4) {
                        Text(app.name).font(.system(size: sz(11)))
                        Button(action: {
                            let newIds = excludedIds.filter { $0 != app.bundleId }
                            store.excludedBundleIdsString = newIds.joined(separator: ",")
                        }, label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: sz(10)))
                                .foregroundColor(.secondary)
                        })
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
            }
        )
    }

    private var appPickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.settingsAddExcludedApp).font(.system(size: sz(14), weight: .semibold))
                Spacer()
                Button(L10n.buttonDone) { showingAppPicker = false }
                    .buttonStyle(.plain)
                    .font(.system(size: sz(12)))
                    .foregroundColor(.accentColor)
            }
            .padding()
            Color.clear.frame(height: 1)
            TextField(L10n.settingsAppPickerSearch, text: $appPickerSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onChange(of: appPickerSearch) { newValue in
                    DispatchQueue.main.async {
                        searchDebounce?.cancel()
                        let item = DispatchWorkItem { appPickerSearchDebounced = newValue }
                        searchDebounce = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
                    }
                }
            Color.clear.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let excludedIds = Set(store.excludedBundleIdsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    let allApps = installedApps.sorted { $0.name < $1.name }

                    let search = appPickerSearchDebounced.lowercased()
                    let filtered = allApps.filter {
                        search.isEmpty || $0.name.lowercased().contains(search)
                    }

                    if isLoadingApps {
                        HStack {
                            Spacer()
                            ProgressView().scaleEffect(0.8)
                            Spacer()
                        }
                        .padding()
                    } else if filtered.isEmpty {
                        Text(L10n.settingsAppPickerNoResults).font(.system(size: sz(12))).foregroundColor(.secondary).padding()
                    } else {
                        ForEach(filtered.indices, id: \.self) { idx in
                            let app = filtered[idx]
                            AppPickerRow(
                                name: app.name,
                                bundleId: app.bundleId,
                                icon: app.icon,
                                isExcluded: excludedIds.contains(app.bundleId),
                                onToggle: {
                                    var ids = Array(excludedIds)
                                    if excludedIds.contains(app.bundleId) {
                                        ids.removeAll { $0 == app.bundleId }
                                    } else {
                                        ids.append(app.bundleId)
                                    }
                                    store.excludedBundleIdsString = ids.joined(separator: ",")
                                }
                            )
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 450)
    }

    private static var cachedApps: [AppPickerItem]?

    /// Kick off a background fetch of installed applications. Icons are loaded
    /// lazily by AppPickerRow via NSImage, so only the directory scan and bundle
    /// ID lookup run on the background queue. Results are cached statically.
    private func loadInstalledAppsIfNeeded() {
        guard installedApps.isEmpty, !isLoadingApps else { return }
        if let cached = Self.cachedApps {
            installedApps = cached
            return
        }
        isLoadingApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [AppPickerItem] = []
            let fileManager = FileManager.default
            let appDirs = ["/Applications", NSHomeDirectory() + "/Applications"]

            for appDir in appDirs {
                guard let apps = try? fileManager.contentsOfDirectory(atPath: appDir) else { continue }
                for app in apps where app.hasSuffix(".app") {
                    let appPath = (appDir as NSString).appendingPathComponent(app)
                    let name = (app as NSString).deletingPathExtension
                    if let bundleId = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier {
                        results.append(AppPickerItem(name: name, bundleId: bundleId, icon: nil, isRunning: false))
                    }
                }
            }
            DispatchQueue.main.async {
                Self.cachedApps = results
                self.installedApps = results
                self.isLoadingApps = false
            }
        }
    }

    private var emptyState: some View {
        let name = store.items.isEmpty ? "no_items_overall" : "filter_no_match"
        UIObservability.logEmptyStateRender(name: name, itemCount: store.items.count)
        return VStack(spacing: 12) { Spacer(); Image(systemName: selectedTab == .pinned ? "star" : "tray").font(.system(size: sz(40))).foregroundColor(.secondary); Text(selectedTab == .pinned ? L10n.emptyNoPinned : L10n.emptyNoHistory).font(.system(size: sz(14))).foregroundColor(.secondary); if selectedTab == .pinned { Text(L10n.emptyPinnedHint).font(.system(size: sz(12))).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal) } else { Text(L10n.emptyHistoryHint).font(.system(size: sz(12))).foregroundColor(.secondary) }; Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyItem(_ item: ClipboardItem) { store.copyToClipboard(item) }
    private func toggleReveal(_ id: UUID) { if revealedItems.contains(id) { revealedItems.remove(id) } else { revealedItems.insert(id) } }

    /// Builds a single ClipboardItemRow. Extracted from the ForEach body to
    /// keep Swift's type-checker happy — the row init has 12 named parameters
    /// and SwiftUI's @ViewBuilder blows the solver budget when inlined inside
    /// a deeply nested Section/ForEach.
    @ViewBuilder
    private func buildItemRow(itemWithIndex: (item: ClipboardItem, globalIndex: Int)) -> some View {
        let item: ClipboardItem = itemWithIndex.item
        let itemId: UUID = item.id
        let revealed: Bool = revealedItems.contains(itemId)
        let kbSelected: Bool = keyboardSelectedIndex == itemWithIndex.globalIndex
        let copied: Bool = lastCopiedId == itemId
        let selected: Bool = selectedItems.contains(itemId)
        let copyAction: () -> Void = {
            self.lastCopiedId = itemId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self.lastCopiedId == itemId { self.lastCopiedId = nil }
            }
            self.copyItem(item)
        }
        let pinAction: () -> Void = { self.store.togglePin(item) }
        let deleteAction: () -> Void = {
            self.itemToDelete = item
            self.showingDeleteAlert = true
        }
        let selectAction: (Bool) -> Void = { isOn in
            if isOn { self.selectedItems.insert(itemId) } else { self.selectedItems.remove(itemId) }
        }
        let revealAction: () -> Void = { self.toggleReveal(itemId) }
        let editTagsAction: () -> Void = { self.tagPickerItem = item }
        ClipboardItemRow(item: item,
            isRevealed: revealed,
            isKeyboardSelected: kbSelected,
            isCopied: copied,
            isSelected: selected,
            searchText: searchText,
            onCopyWithFeedback: copyAction,
            onPin: pinAction,
            onDelete: deleteAction,
            onSelect: selectAction,
            onToggleReveal: revealAction,
            onEditTags: editTagsAction)
    }
}
