import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum SidebarTab: String, CaseIterable {
    case all, text, image, link, pinned, settings
    var icon: String {
        switch self { case .all: "tray.full"; case .text: "doc.text"; case .image: "photo"; case .link: "link"; case .pinned: "star"; case .settings: "gear" }
    }
    var label: String {
        switch self { case .all: L10n.filterAll; case .text: L10n.filterText; case .image: L10n.filterImage; case .link: L10n.filterLink; case .pinned: L10n.headerShowPinned; case .settings: L10n.buttonSettings }
    }
    var typeFilter: ClipboardItemType? {
        switch self { case .text: .text; case .image: .image; case .link: .link; default: nil }
    }
}

let appCornerRadius: CGFloat = 8

private let relativeDateFormatterCache = NSCache<NSString, RelativeDateTimeFormatter>()
private func cachedRelativeDateFormatter(for languageCode: String) -> RelativeDateTimeFormatter {
    let key = languageCode as NSString
    if let cached = relativeDateFormatterCache.object(forKey: key) { return cached }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    f.locale = Locale(identifier: languageCode)
    relativeDateFormatterCache.setObject(f, forKey: key)
    return f
}
private let absoluteDateFormatterCache = NSCache<NSString, DateFormatter>()
private func cachedAbsoluteDateFormatter(for languageCode: String) -> DateFormatter {
    let key = languageCode as NSString
    if let cached = absoluteDateFormatterCache.object(forKey: key) { return cached }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.locale = Locale(identifier: languageCode)
    absoluteDateFormatterCache.setObject(f, forKey: key)
    return f
}

private struct AppPickerItem {
    let name: String
    let bundleId: String
    let icon: NSImage?
    let isRunning: Bool
}

struct ContentView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared
    @State private var selectedTab: SidebarTab = .all
    @State private var searchText = "" { didSet { keyboardSelectedIndex = nil } }
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
    @State private var selectedItems: Set<UUID> = []
    @State private var collapsedGroups: Set<TimeGroup> = {
        guard let data = UserDefaults.standard.string(forKey: "collapsedGroups")?.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr.compactMap { TimeGroup(rawValue: $0) })
    }()
    @State private var isRecordingHotKey = false
    @State private var keyEventMonitor: Any?
    @State private var showingAppPicker = false
    @State private var appPickerSearch = ""
    @State private var appPickerSearchDebounced = ""
    @State private var searchDebounce: DispatchWorkItem?
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @AppStorage("themeAppearance") private var themeAppearance = "system"
    private func sz(_ base: CGFloat) -> CGFloat { base * fontScale }

    // MARK: - Cached Date Calculations
    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }
    private var startOfYesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
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
            if !searchTextDebounced.isEmpty && !(store.getDecryptedContent(item) ?? "").localizedCaseInsensitiveContains(searchTextDebounced) { return false }
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
        for item in store.items {
            switch item.type {
            case .text: counts[.text, default: 0] += 1
            case .image: counts[.image, default: 0] += 1
            case .link: counts[.link, default: 0] += 1
            default: break
            }
        }
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
        NavigationSplitView {
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
        .toolbar {
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
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: L10n.searchPlaceholder)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onAppear {
            applyAppearance()
            updateDisplayedItemsCache()
        }
        .onChange(of: searchText) { newValue in
            searchTextDebounce?.cancel()
            let work = DispatchWorkItem { searchTextDebounced = newValue }
            searchTextDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        .onChange(of: searchTextDebounced) { _ in updateDisplayedItemsCache() }
        .onChange(of: selectedTab) { _ in updateDisplayedItemsCache() }
        .onChange(of: dateFilter) { _ in updateDisplayedItemsCache() }
        .onChange(of: store.items) { _ in updateDisplayedItemsCache() }
        .onChange(of: collapsedGroups) { val in
            let arr = val.map { $0.rawValue }
            if let d = try? JSONEncoder().encode(arr), let s = String(data: d, encoding: .utf8) { UserDefaults.standard.set(s, forKey: "collapsedGroups") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { _ in selectedTab = .settings }
        .overlay(alignment: .top) { KeyCaptureView(onUp: {
            guard !displayedItems.isEmpty else { return }
            if let idx = keyboardSelectedIndex, idx > 0 { keyboardSelectedIndex = idx - 1 } else { keyboardSelectedIndex = displayedItems.count - 1 }
        }, onDown: {
            guard !displayedItems.isEmpty else { return }
            let last = displayedItems.count - 1; if let idx = keyboardSelectedIndex, idx < last { keyboardSelectedIndex = idx + 1 } else { keyboardSelectedIndex = 0 }
        }, onReturn: {
            if let idx = keyboardSelectedIndex, idx < displayedItems.count { let item = displayedItems[idx]; lastCopiedId = item.id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if lastCopiedId == item.id { lastCopiedId = nil } }; copyItem(item) }
        }, onEscape: {
            if selectedTab == .settings { selectedTab = .all } else if !searchText.isEmpty { searchText = "" } else { NSApp.keyWindow?.close() }
        }).frame(width: 0, height: 0) }
        .onDisappear { stopKeyEventMonitor() }
        .sheet(isPresented: $showingAppPicker) { appPickerSheet.onAppear {
            appPickerSearchDebounced = appPickerSearch
            Self.cachedApps = nil
        } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            LogoView()
                .padding(.horizontal, 8)
                .padding(.top, 8)
            List(selection: $selectedTab) {
                ForEach([SidebarTab.all, .text, .image, .link], id: \.self) { tab in
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
                            Text(hk.config.displayString).fontDesign(.monospaced)
                            Spacer()
                            Button(L10n.settingsHotkeyChange) { startRecording() }.buttonStyle(.link)
                        }
                    }
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
                Picker(L10n.settingsMaxItems, selection: $store.maxItems) { ForEach([50, 100, 200, 500], id: \.self) { Text(L10n.settingsMaxItemsCount($0)).tag($0) } }.id(languageManager.selectedLanguage)
            } header: { Text(L10n.settingsSectionHistory) }
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

    private struct AppPickerRow: View {
        let name: String
        let bundleId: String
        let icon: NSImage?
        let isExcluded: Bool
        let onToggle: () -> Void
        @AppStorage("fontScale") private var fontScale: Double = 1.0
        @State private var isHovered = false
        private func sz(_ base: CGFloat) -> CGFloat { base * fontScale }

        var body: some View {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    if let icon = icon {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onHover { hovering in isHovered = hovering }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) { Spacer(); Image(systemName: selectedTab == .pinned ? "star" : "tray").font(.system(size: sz(40))).foregroundColor(.secondary); Text(selectedTab == .pinned ? L10n.emptyNoPinned : L10n.emptyNoHistory).font(.system(size: sz(14))).foregroundColor(.secondary); if selectedTab == .pinned { Text(L10n.emptyPinnedHint).font(.system(size: sz(12))).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal) } else { Text(L10n.emptyHistoryHint).font(.system(size: sz(12))).foregroundColor(.secondary) }; Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyItem(_ item: ClipboardItem) { store.copyToClipboard(item) }
    private func toggleReveal(_ id: UUID) { if revealedItems.contains(id) { revealedItems.remove(id) } else { revealedItems.insert(id) } }
}

// MARK: - AppKit NSPressGestureRecognizer for stable image long-press
struct PressableImage: NSViewRepresentable {
    let onPressChanged: (Bool) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = LongPressView(onPressChanged: context.coordinator.onPressChanged)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LongPressView)?.onPressChanged = context.coordinator.onPressChanged
    }
    func makeCoordinator() -> Coordinator { Coordinator(onPressChanged: onPressChanged) }
    class Coordinator {
        var onPressChanged: (Bool) -> Void
        init(onPressChanged: @escaping (Bool) -> Void) { self.onPressChanged = onPressChanged }
    }
}

class LongPressView: NSView {
    var onPressChanged: (Bool) -> Void
    private var pressGesture: NSPressGestureRecognizer!

    init(onPressChanged: @escaping (Bool) -> Void) {
        self.onPressChanged = onPressChanged
        super.init(frame: .zero)
        pressGesture = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        pressGesture.minimumPressDuration = 0.4
        pressGesture.buttonMask = 0x1 // left mouse button
        addGestureRecognizer(pressGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handlePress(_ sender: NSPressGestureRecognizer) {
        let isPressed = sender.state == .began || sender.state == .changed
        DispatchQueue.main.async { self.onPressChanged(isPressed) }
    }

    deinit {
        if let gesture = pressGesture {
            removeGestureRecognizer(gesture)
        }
    }
}

struct ClipboardItemRow: View, Equatable {
    let item: ClipboardItem; let isRevealed: Bool; var isKeyboardSelected = false; var isCopied = false; var isSelected = false; var searchText = ""
    var onCopyWithFeedback: (() -> Void)?; let onPin: () -> Void; let onDelete: () -> Void; let onSelect: ((Bool) -> Void)?; let onToggleReveal: () -> Void
    @State private var isHovered = false; @State private var loadedImage: NSImage?; @State private var loadedContent: String?
    @State private var longPressing = false
    @State private var imageLongPressing = false
    @State private var showFullContent = false
    @State private var _cachedHighlighted: [String: AttributedString] = [:]

    static func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.isRevealed == rhs.isRevealed &&
        lhs.isCopied == rhs.isCopied &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isKeyboardSelected == rhs.isKeyboardSelected &&
        lhs.searchText == rhs.searchText &&
        lhs.item.isPinned == rhs.item.isPinned
    }
    @State private var _cachedMaskedHighlighted: [String: AttributedString] = [:]
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    private var iconSize: CGFloat { fontScale * 13 }

    private var rowBackground: Color {
        if isCopied { Color.green.opacity(0.12) } else if isSelected { Color.accentColor.opacity(0.10) } else if isHovered || isKeyboardSelected { Color.accentColor.opacity(0.06) } else if item.isSensitive { Color.orange.opacity(0.04) } else { Color.clear }
    }
    private var pinText: String { item.isPinned ? L10n.actionUnpin : L10n.actionPin }
    private var decryptedContent: String {
        loadedContent ?? ClipboardStore.shared.getDecryptedContent(item) ?? ""
    }
    private var formattedDate: String {
        cachedAbsoluteDateFormatter(for: LanguageManager.shared.selectedLanguage).string(from: item.createdAt)
    }

    private var cachedHighlighted: AttributedString {
        let cacheKey = "\(item.id.uuidString)-\(searchText)"
        if let cached = _cachedHighlighted[cacheKey] { return cached }
        let result = highlightedContent(decryptedContent, highlight: searchText)
        _cachedHighlighted[cacheKey] = result
        return result
    }
    private var cachedMaskedHighlighted: AttributedString {
        let cacheKey = "\(item.id.uuidString)-\(searchText)"
        if let cached = _cachedMaskedHighlighted[cacheKey] { return cached }
        let result = maskedHighlightedContent(decryptedContent, highlight: searchText)
        _cachedMaskedHighlighted[cacheKey] = result
        return result
    }

    private func highlightedContent(_ text: String, highlight: String) -> AttributedString {
        if highlight.isEmpty { return AttributedString(String(text.prefix(200))) }
        let lt = text.lowercased(), lh = highlight.lowercased()
        guard lt.range(of: lh) != nil else { return AttributedString(String(text.prefix(200))) }
        let fm = lt.range(of: lh)!
        let mso = lt.distance(from: lt.startIndex, to: fm.lowerBound)
        var prefix = ""
        let dsi: String.Index
        if mso > 30 { dsi = text.index(text.index(text.startIndex, offsetBy: mso), offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex; prefix = "..." } else { dsi = text.startIndex }
        let dei = text.index(dsi, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
        let ds = String(text[dsi..<dei])
        let prefixLen = prefix.count
        var a = AttributedString(prefix + ds)
        let lowerDS = ds.lowercased()
        // Compute highlight positions relative to ds, not lt
        let dsStartOffset = lt.distance(from: lt.startIndex, to: dsi)
        guard let fmInDS = lowerDS.range(of: lh) else { return a }
        var ss = fmInDS.lowerBound
        while let r = lowerDS.range(of: lh, range: ss..<lowerDS.endIndex) {
            let startOff = lowerDS.distance(from: lowerDS.startIndex, to: r.lowerBound)
            let endOff = startOff + lowerDS.distance(from: r.lowerBound, to: r.upperBound)
            if startOff < 200 {
                let si = a.index(a.startIndex, offsetByCharacters: prefixLen + startOff)
                let ei = a.index(a.startIndex, offsetByCharacters: min(prefixLen + endOff, prefixLen + 200))
                a[si..<ei].backgroundColor = .cyan.opacity(0.3)
                a[si..<ei].foregroundColor = .primary
            }
            ss = r.upperBound
        }
        return a
    }
    private func maskContent(_ c: String) -> String { c.count <= 4 ? String(repeating: "\u{2022}", count: c.count) : String(c.prefix(2)) + String(repeating: "\u{2022}", count: c.count - 4) + String(c.suffix(2)) }
    private func maskedHighlightedContent(_ content: String, highlight: String, ctx: Int = 15) -> AttributedString {
        if highlight.isEmpty { var a = AttributedString(maskContent(content)); a.foregroundColor = .orange; return a }
        let lc = content.lowercased(), lh = highlight.lowercased(); var vis: [Range<String.Index>] = []; var ss = lc.startIndex
        while let r = lc.range(of: lh, range: ss..<lc.endIndex) { let cs = lc.index(r.lowerBound, offsetBy: -ctx, limitedBy: lc.startIndex) ?? lc.startIndex; let ce = lc.index(r.upperBound, offsetBy: ctx, limitedBy: lc.endIndex) ?? lc.endIndex; vis.append(cs..<ce); ss = r.upperBound }
        guard !vis.isEmpty else { return AttributedString(maskContent(content)) }; vis.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []; for r in vis { if let last = merged.last, last.upperBound >= r.lowerBound { merged[merged.count-1] = last.lowerBound..<max(last.upperBound, r.upperBound) } else { merged.append(r) } }
        var res = AttributedString(); var ci = content.startIndex
        for r in merged { if ci < r.lowerBound { var b = AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: r.lowerBound))); b.foregroundColor = .orange; res += b }; var h = AttributedString(String(content[r])); h.backgroundColor = .blue.opacity(0.15); h.foregroundColor = .primary; res += h; ci = r.upperBound }
        if ci < content.endIndex { var t = AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: content.endIndex))); t.foregroundColor = .orange; res += t }
        return res
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: { onSelect?(!isSelected) }, label: { Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.system(size: iconSize)).foregroundColor(isSelected ? .accentColor : .secondary).frame(width: 22, height: 22) }).buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    if item.type == .image {
                        Group {
                            if let ns = loadedImage {
                                Image(nsImage: ns)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: imageLongPressing ? 300 : 80)
                                    .overlay(PressableImage { pressed in imageLongPressing = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                            } else {
                                Text(L10n.itemImage).font(.system(size: fontScale * 13)).foregroundColor(.secondary)
                            }
                        }
                        .task(id: item.content) { if let img = ImageStorage.shared.loadImageObject(filename: item.content) { loadedImage = img } }
                    } else if item.isSensitive && !isRevealed {
                        Text(longPressing ? cachedHighlighted : cachedMaskedHighlighted)
                            .font(.system(size: fontScale * 13)).lineLimit(3)
                            .overlay(PressableImage { pressed in longPressing = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                    } else {
                        Text(showFullContent ? AttributedString(decryptedContent) : cachedHighlighted)
                            .font(.system(size: fontScale * 12)).foregroundColor(Color(nsColor: .controlTextColor))
                            .lineLimit(showFullContent ? nil : 3)
                            .overlay(PressableImage { pressed in showFullContent = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .help(L10n.tooltipPin)
                HStack(spacing: 8) { Text(formattedDate).font(.system(size: fontScale * 11)).foregroundColor(.primary.opacity(0.55)); if item.isSensitive { Label(L10n.itemSensitive, systemImage: "exclamationmark.shield").font(.system(size: fontScale * 11)).foregroundColor(.orange) } }
            }
            .contentShape(Rectangle())
            .gesture(ExclusiveGesture(TapGesture(count: 2).onEnded { onPin() }, TapGesture().onEnded { onCopyWithFeedback?() }))
            HStack(spacing: 6) {
                Button(action: onPin) { Image(systemName: item.isPinned ? "star.fill" : "star").font(.system(size: iconSize)).foregroundColor(item.isPinned ? .orange : .secondary).frame(width: 24, height: 24) }.buttonStyle(.plain).help(item.isPinned ? L10n.tooltipUnpin : L10n.tooltipPin)
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: iconSize)).foregroundColor(.secondary).frame(width: 24, height: 24) }.buttonStyle(.plain).help(L10n.tooltipDelete)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(rowBackground).animation(.easeOut(duration: 0.3), value: isCopied).contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { Button(action: { onCopyWithFeedback?() }, label: { Label(L10n.actionCopy, systemImage: "doc.on.doc") }); if item.isSensitive { Button(action: onToggleReveal, label: { Label(isRevealed ? L10n.actionHideContent : L10n.actionShowContent, systemImage: isRevealed ? "eye.slash" : "eye") }) }; Button(action: onPin, label: { Label(pinText, systemImage: item.isPinned ? "star.slash" : "star") }); Divider(); Button(role: .destructive, action: onDelete, label: { Label(L10n.actionDelete, systemImage: "trash") }) }
        .task(id: item.id) {
            if loadedContent != nil { return }
            let result = await Task.detached(priority: .utility) {
                ClipboardStore.shared.getDecryptedContent(item) ?? ""
            }.value
            loadedContent = result
        }
    }
}

// MARK: - Brand Logo
private struct LogoView: View {
    @ObservedObject private var languageManager = LanguageManager.shared

    /// True when appName contains both Chinese and English (zh-Hans / zh-Hant)
    private var isBilingual: Bool {
        let name = L10n.appName
        return name.contains(" ClipMemory") && !name.hasPrefix("ClipMemory")
    }

    /// Chinese name extracted from appName (e.g. "剪忆" from "剪忆 ClipMemory")
    private var chineseName: String {
        let full = L10n.appName
        if let range = full.range(of: " ClipMemory") {
            return String(full[..<range.lowerBound])
        }
        return full
    }

    var body: some View {
        if isBilingual {
            // Chinese + English on one line: "剪忆 ClipMemory"
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(chineseName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("ClipMemory")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            // Single name (English, Japanese, Korean, etc.)
            Text(L10n.appName)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Flow Layout for wrapping tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return layoutSize(sizes: sizes, proposal: proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var point = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            if point.x + size.width > bounds.maxX && lineHeight > 0 {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: point, proposal: .unspecified)
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func layoutSize(sizes: [CGSize], proposal: ProposedViewSize) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for size in sizes {
            if lineWidth + size.width > maxWidth && lineWidth > 0 {
                width = max(width, lineWidth - spacing)
                height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        width = max(width, lineWidth - spacing)
        height += lineHeight
        return CGSize(width: width, height: height)
    }
}

// MARK: - Liquid Glass Date Filter Button
private struct DateFilterButton: View {
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
