import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum SidebarTab: String, CaseIterable {
    case all, text, image, link, richText, pinned, settings
    var icon: String {
        switch self { case .all: "tray.full"; case .text: "doc.text"; case .image: "photo"; case .link: "link"; case .richText: "doc.richtext"; case .pinned: "star"; case .settings: "gear" }
    }
    var label: String {
        switch self { case .all: L10n.filterAll; case .text: L10n.filterText; case .image: L10n.filterImage; case .link: L10n.filterLink; case .richText: L10n.filterRichText; case .pinned: L10n.headerShowPinned; case .settings: L10n.buttonSettings }
    }
    var typeFilter: ClipboardItemType? {
        switch self { case .text: .text; case .image: .image; case .link: .link; case .richText: .richText; default: nil }
    }
}

let appCornerRadius: CGFloat = 8

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
    @State private var dateFilter: DateFilter = .all
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: ClipboardItem?
    @State private var pendingClearMode: ClearMode?
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
    @State private var isRecordingHotKey = false
    @State private var hotkeyRefresh = false
    @State private var keyEventMonitor: Any?
    @State private var showingAppPicker = false
    @State private var showingTips = false
    @State private var pendingMaxItemsReduction: (old: Int, new: Int)?
    @State private var appPickerSearch = ""
    @State private var appPickerSearchDebounced = ""
    @State private var searchDebounce: DispatchWorkItem?
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @AppStorage("themeAppearance") private var themeAppearance = "system"

    // MARK: - Cached Date Calculations
    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }
    private var startOfYesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    }

    // MARK: - Keyboard Handlers
    private func handleKeyUp() {
        guard !displayedItems.isEmpty else { return }
        if let idx = keyboardSelectedIndex, idx > 0 {
            keyboardSelectedIndex = idx - 1
        } else {
            keyboardSelectedIndex = displayedItems.count - 1
        }
        if let idx = keyboardSelectedIndex { scrollAnchor = displayedItems[idx].id }
    }

    private func handleKeyDown() {
        guard !displayedItems.isEmpty else { return }
        let last = displayedItems.count - 1
        if let idx = keyboardSelectedIndex, idx < last {
            keyboardSelectedIndex = idx + 1
        } else {
            keyboardSelectedIndex = 0
        }
        if let idx = keyboardSelectedIndex { scrollAnchor = displayedItems[idx].id }
    }

    private func handleKeyReturn() {
        guard let idx = keyboardSelectedIndex, idx < displayedItems.count else { return }
        let item = displayedItems[idx]
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
            Self.cachedApps = nil
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
    private var bodyBackground: AnyShapeStyle {
        AnyShapeStyle(Material.thick)
    }
    private var sidebarBackground: AnyShapeStyle {
        AnyShapeStyle(Material.thin)
    }

    // MARK: - Optimized Item Filtering
    private func filterItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { item in
            // tab filter
            switch selectedTab {
            case .pinned: if !item.isPinned { return false }
            case .all: break
            default: if item.type != selectedTab.typeFilter { return false }
            }
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
                if !searchableText.localizedCaseInsensitiveContains(searchTextDebounced) { return false }
            }
            return true
        }
    }

    private func updateDisplayedItemsCache() {
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
    }

    var displayedItems: [ClipboardItem] { cachedDisplayedItems }

    private var tabCounts: [SidebarTab: Int] {
        var counts: [SidebarTab: Int] = [.all: store.items.count]
        for item in store.items { switch item.type {
        case .text: counts[.text, default: 0] += 1
        case .image: counts[.image, default: 0] += 1
        case .link: counts[.link, default: 0] += 1
        case .richText: counts[.richText, default: 0] += 1
        } }
        return counts
    }

    private enum TimeGroup: String, CaseIterable { case today, yesterday, older
        var label: String {
            switch self { case .today: L10n.groupToday; case .yesterday: L10n.groupYesterday; case .older: L10n.groupOlder }
        }
    }

    enum DateFilter: String, CaseIterable {
        case all, today, yesterday, older
        var label: String {
            switch self { case .all: return L10n.dateFilterAll; case .today: return L10n.groupToday; case .yesterday: return L10n.groupYesterday; case .older: return L10n.groupOlder }
        }
    }
    private var groupedItems: [(TimeGroup, [ClipboardItem])] { cachedGroupedItems }

    // 扁平化的显示项目
    private var flattenedDisplayedItems: [(item: ClipboardItem, globalIndex: Int)] {
        var result: [(item: ClipboardItem, globalIndex: Int)] = []
        var idx = 0
        for section in groupedItems {
            for item in section.1 {
                result.append((item, idx)); idx += 1
            }
        }
        return result
    }

    // 带全局索引的分组项目
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
    }

    private func attachLifecycle<V: View>(_ v: V) -> some View {
        v
            .onAppear {
                (NSApp.delegate as? AppDelegate)?.disableFindMenuShortcut()
                applyAppearance()
                updateDisplayedItemsCache()
            }
            .onChange(of: searchText) { newValue in
                self.debounceSearch(newValue)
            }
            .onChange(of: searchTextDebounced) { _ in updateDisplayedItemsCache() }
            .onChange(of: selectedTab) { _ in updateDisplayedItemsCache() }
            .onChange(of: dateFilter) { _ in updateDisplayedItemsCache() }
            .onChange(of: store.items) { _ in updateDisplayedItemsCache() }
            .onChange(of: collapsedGroups) { val in
                self.saveCollapsedGroups(val)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { _ in selectedTab = .settings }
            .onReceive(NotificationCenter.default.publisher(for: .cmdFFindAction)) { _ in self.focusSearchField() }
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
            Menu {
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
        // swiftlint:enable identifier_name
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
                }
                Section {
                    Label(SidebarTab.pinned.label, systemImage: SidebarTab.pinned.icon)
                        .tag(SidebarTab.pinned)
                    Label(SidebarTab.settings.label, systemImage: SidebarTab.settings.icon)
                        .tag(SidebarTab.settings)
                }
            }
            .listStyle(.sidebar)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: selectedTab) { _ in keyboardSelectedIndex = nil }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if displayedItems.isEmpty { emptyState } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(groupedItemsWithIndex, id: \.group) { section in
                            Section {
                                if !searchText.isEmpty || !collapsedGroups.contains(section.group) {
                                    ForEach(section.items, id: \.item.id) { itemWithIndex in
                                        ClipboardItemRow(item: itemWithIndex.item, isRevealed: revealedItems.contains(itemWithIndex.item.id),
                                            isKeyboardSelected: keyboardSelectedIndex == itemWithIndex.globalIndex,
                                            isCopied: lastCopiedId == itemWithIndex.item.id, isSelected: selectedItems.contains(itemWithIndex.item.id),
                                            searchText: searchText,
                                            onCopyWithFeedback: { lastCopiedId = itemWithIndex.item.id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if lastCopiedId == itemWithIndex.item.id { lastCopiedId = nil } }; copyItem(itemWithIndex.item) },
                                            onPin: { store.togglePin(itemWithIndex.item) }, onDelete: { itemToDelete = itemWithIndex.item; showingDeleteAlert = true },
                                            onSelect: { if $0 { selectedItems.insert(itemWithIndex.item.id) } else { selectedItems.remove(itemWithIndex.item.id) } },
                                            onToggleReveal: { toggleReveal(itemWithIndex.item.id) })
                                            .listRowInsets(EdgeInsets())
                                            .listRowSeparator(.hidden)
                                            .id(itemWithIndex.item.id)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(section.group.label).font(.system(size: sz(12), weight: .semibold)).foregroundColor(.secondary)
                                    Spacer()
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
            get: { pendingClearMode != nil },
            set: { if !$0 { pendingClearMode = nil } }
        )) {
            Button(L10n.buttonCancel, role: .cancel) { pendingClearMode = nil }
            Button(L10n.buttonClear, role: .destructive) { confirmClear() }
        } message: {
            Text(clearAlertText)
        }
        .alert(L10n.alertTrimTitle, isPresented: Binding(
            get: { pendingMaxItemsReduction != nil },
            set: { if !$0 { pendingMaxItemsReduction = nil } }
        )) {
            Button(L10n.alertTrimCancel, role: .cancel) {
                guard let pair = pendingMaxItemsReduction else { return }
                store.maxItems = pair.old
                pendingClearMode = nil
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

    private func startRecording() {
        isRecordingHotKey = true
        stopKeyEventMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard isRecordingHotKey else { return event }
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
            (NSApp.delegate as? AppDelegate)?.hotKeyManager.updateHotKey(keyCode: keyCode, modifiers: modifiers)
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
                Toggle(L10n.settingsCaptureRichText, isOn: $store.captureRichText)
            } footer: { Text(L10n.settingsCaptureRichTextHint).foregroundColor(.secondary) }
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

    private var excludedAppsTags: some View {
        let excludedIds = Array(Set(store.excludedBundleIdsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }))
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
                    searchDebounce?.cancel()
                    let item = DispatchWorkItem { appPickerSearchDebounced = newValue }
                    searchDebounce = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
                }
            Color.clear.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let excludedIds = Set(store.excludedBundleIdsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    let allApps = Self.fetchInstalledAppsFromDisk().sorted { $0.name < $1.name }

                    let search = appPickerSearchDebounced.lowercased()
                    let filtered = allApps.filter {
                        search.isEmpty || $0.name.lowercased().contains(search)
                    }

                    if filtered.isEmpty {
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
    private static func fetchInstalledAppsFromDisk() -> [AppPickerItem] {
        if let cached = cachedApps { return cached }
        var results: [AppPickerItem] = []
        let fileManager = FileManager.default
        let appDirs = ["/Applications", NSHomeDirectory() + "/Applications"]

        for appDir in appDirs {
            guard let apps = try? fileManager.contentsOfDirectory(atPath: appDir) else { continue }
            for app in apps where app.hasSuffix(".app") {
                let appPath = (appDir as NSString).appendingPathComponent(app)
                let name = (app as NSString).deletingPathExtension
                if let bundleId = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier {
                    let icon = NSWorkspace.shared.icon(forFile: appPath)
                    results.append(AppPickerItem(name: name, bundleId: bundleId, icon: icon, isRunning: false))
                }
            }
        }
        cachedApps = results
        return results
    }

    private var emptyState: some View {
        VStack(spacing: 12) { Spacer(); Image(systemName: selectedTab == .pinned ? "star" : "tray").font(.system(size: sz(40))).foregroundColor(.secondary); Text(selectedTab == .pinned ? L10n.emptyNoPinned : L10n.emptyNoHistory).font(.system(size: sz(14))).foregroundColor(.secondary); if selectedTab == .pinned { Text(L10n.emptyPinnedHint).font(.system(size: sz(12))).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal) } else { Text(L10n.emptyHistoryHint).font(.system(size: sz(12))).foregroundColor(.secondary) }; Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyItem(_ item: ClipboardItem) { store.copyToClipboard(item) }
    private func toggleReveal(_ id: UUID) { if revealedItems.contains(id) { revealedItems.remove(id) } else { revealedItems.insert(id) } }
}
