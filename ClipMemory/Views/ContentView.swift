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

private var relativeDateFormatters: [String: RelativeDateTimeFormatter] = [:]
private func cachedRelativeDateFormatter(for languageCode: String) -> RelativeDateTimeFormatter {
    if let cached = relativeDateFormatters[languageCode] { return cached }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    f.locale = Locale(identifier: languageCode)
    relativeDateFormatters[languageCode] = f
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
        AnyShapeStyle(Material.regularMaterial)
    }
    private var sidebarBackground: AnyShapeStyle {
        AnyShapeStyle(Material.ultraThinMaterial)
    }

    // MARK: - Optimized Item Filtering
    var displayedItems: [ClipboardItem] {
        var counts: [SidebarTab: Int] = [.text: 0, .image: 0, .link: 0]
        let result = store.items.filter { item in
            switch item.type {
            case .text: counts[.text]! += 1
            case .image: counts[.image]! += 1
            case .link: counts[.link]! += 1
            default: break
            }
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
                if dateFilter == .today { return false }
            } else {
                if dateFilter == .yesterday || dateFilter == .older { return false }
            }
            // search filter
            if !searchText.isEmpty && !item.decryptedContent.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
        return result
    }

    private var tabCounts: [SidebarTab: Int] {
        var counts: [SidebarTab: Int] = [.all: store.items.count, .text: 0, .image: 0, .link: 0]
        for item in store.items {
            switch item.type {
            case .text: counts[.text]! += 1
            case .image: counts[.image]! += 1
            case .link: counts[.link]! += 1
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
    private var groupedItems: [(TimeGroup, [ClipboardItem])] {
        var dict: [TimeGroup: [ClipboardItem]] = [:]
        for item in displayedItems {
            let g: TimeGroup
            if item.createdAt >= startOfToday { g = .today }
            else if item.createdAt >= startOfYesterday { g = .yesterday }
            else { g = .older }
            dict[g, default: []].append(item)
        }
        return TimeGroup.allCases.compactMap { guard let items = dict[$0], !items.isEmpty else { return nil }; return ($0, items) }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: sz(12)))
            TextField(L10n.searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain).font(.system(size: sz(13)))
            if !searchText.isEmpty { Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.system(size: sz(11))) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(8)
    }

    private var dateFilterBar: some View {
        HStack(spacing: 6) {
            ForEach(DateFilter.allCases, id: \.self) { filter in
                Button(action: { dateFilter = filter }) {
                    Text(filter.label)
                        .font(.system(size: sz(11)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(dateFilter == filter ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(dateFilter == filter ? .accentColor : .secondary)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 36, minHeight: 26)
                .contentShape(Rectangle())
            }
            Spacer()
        }
    }

    private var combinedToolbar: some View {
        HStack(spacing: 12) {
            searchBar
            dateFilterBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

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
        var result: [(group: TimeGroup, items: [(item: ClipboardItem, globalIndex: Int)])] = []
        var globalIdx = 0
        for (g, items) in groupedItems {
            var groupItems: [(item: ClipboardItem, globalIndex: Int)] = []
            for item in items {
                groupItems.append((item, globalIdx))
                globalIdx += 1
            }
            result.append((g, groupItems))
        }
        return result
    }

    private var batchAllPinned: Bool {
        let sel = selectedItems
        guard !sel.isEmpty else { return false }
        return displayedItems.filter { sel.contains($0.id) }.allSatisfy { $0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 200)
                Divider()
                HStack(spacing: 12) {
                    Text(L10n.appName).font(.system(size: sz(13), weight: .semibold)).foregroundColor(.secondary)
                    Spacer()
                    Button(action: { showingClearAlert = true }) { Image(systemName: "trash").font(.system(size: sz(14))).foregroundColor(.secondary) }.buttonStyle(.plain).help(L10n.tooltipClearHistory).disabled(store.items.isEmpty)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            .frame(height: 42)
            .background(.clear)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    sidebar
                }.frame(width: 200).background(sidebarBackground)
                Divider()
                Group { if selectedTab == .settings { settingsDetail } else { mainContent } }.frame(minWidth: 420).background(bodyBackground)
            }
        }
        .frame(minWidth: 640, minHeight: 440).ignoresSafeArea(edges: .top).background(bodyBackground)
        .onAppear { applyAppearance() }
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
        .sheet(isPresented: $showingAppPicker) { appPickerSheet.onAppear { appPickerSearchDebounced = appPickerSearch } }
    }

    private var sidebar: some View {
        List(selection: $selectedTab) {
            Section { ForEach([SidebarTab.all, .text, .image, .link], id: \.self) { tab in Label { HStack { Text(tab.label).font(.system(size: sz(13))); Spacer(); Text("(\(tabCounts[tab] ?? 0))").font(.system(size: sz(11))).foregroundColor(.secondary) } } icon: { Image(systemName: tab.icon) }.tag(tab) } }
            Section { Label { Text(SidebarTab.pinned.label).font(.system(size: sz(13))) } icon: { Image(systemName: SidebarTab.pinned.icon) }.tag(SidebarTab.pinned) }
            Section { Label { Text(SidebarTab.settings.label).font(.system(size: sz(13))) } icon: { Image(systemName: SidebarTab.settings.icon) }.tag(SidebarTab.settings) }
        }.listStyle(.sidebar).onChange(of: selectedTab) { _ in keyboardSelectedIndex = nil }.environment(\.defaultMinListRowHeight, sz(32))
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if !selectedItems.isEmpty {
                HStack { Text(L10n.batchSelected(selectedItems.count)).font(.system(size: sz(12))).foregroundColor(.secondary); Spacer()
                    Button(action: { store.togglePinItems(displayedItems.filter { selectedItems.contains($0.id) }); selectedItems.removeAll() }) { Label(batchAllPinned ? L10n.actionUnpin : L10n.actionPin, systemImage: batchAllPinned ? "star.slash" : "star").font(.system(size: sz(12))) }.buttonStyle(.plain)
                    Button(action: { store.deleteItems(displayedItems.filter { selectedItems.contains($0.id) }); selectedItems.removeAll() }) { Label(L10n.actionDelete, systemImage: "trash").font(.system(size: sz(12))) }.buttonStyle(.plain).foregroundColor(.red)
                    Button(action: { selectedItems.removeAll() }) { Text(L10n.buttonCancel).font(.system(size: sz(12))) }.buttonStyle(.plain).foregroundColor(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(sidebarBackground)
                Divider()
            }
            if selectedTab != .settings {
                combinedToolbar
                Divider()
            }
            if displayedItems.isEmpty { emptyState } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedItemsWithIndex, id: \.group) { section in
                            VStack(spacing: 0) {
                                HStack {
                                    Text(section.group.label).font(.system(size: sz(11), weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase)
                                        .onTapGesture { toggleGroup(section.group) }
                                    Spacer()
                                    Image(systemName: (!collapsedGroups.contains(section.group) || !searchText.isEmpty) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: sz(10))).foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle()).onTapGesture { toggleGroup(section.group) }
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .padding(.horizontal, 12).padding(.vertical, 4).background(bodyBackground)
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
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 2)
}
    }
}

        .alert(L10n.alertDeleteTitle, isPresented: $showingDeleteAlert) { Button(L10n.buttonCancel, role: .cancel) {}; Button(L10n.buttonDelete, role: .destructive) { if let item = itemToDelete { store.deleteItem(item) } } } message: { Text(L10n.alertDeleteMessage) }
        .alert(L10n.alertClearTitle, isPresented: $showingClearAlert) { Button(L10n.buttonCancel, role: .cancel) {}; Button(L10n.buttonClear, role: .destructive) { store.clearAllItems() } } message: { let c = store.items.filter { !$0.isPinned }.count; Text(c > 0 ? L10n.alertClearMessage(c) : L10n.alertClearNone) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.settingsTitle).font(.system(size: sz(20), weight: .semibold)).padding(.horizontal, 24).padding(.vertical, 16)
                Divider()
                if let hk = (NSApp.delegate as? AppDelegate)?.hotKeyManager {
                    settingsSection(L10n.settingsSectionHotkey) {
                        HStack {
                            if isRecordingHotKey {
                                Text(L10n.settingsHotkeyRecording).font(.system(size: sz(13))).foregroundColor(.orange)
                                Spacer()
                                Button(L10n.buttonCancel) { isRecordingHotKey = false }.buttonStyle(.link).font(.system(size: sz(13)))
                            } else {
                                Text(hk.config.displayString).font(.system(size: sz(13), design: .monospaced))
                                Spacer()
                                Button(L10n.settingsHotkeyChange) { startRecording() }.buttonStyle(.link).font(.system(size: sz(13)))
                            }
                        }
                    }
                    .padding(.top, 20)
                }
                settingsSection(L10n.settingsSectionTheme) {
                    Picker(L10n.themeAppearance, selection: Binding(get: { themeAppearance }, set: { themeAppearance = $0; applyAppearance() })) {
                        Text(L10n.themeAppearanceSystem).tag("system"); Text(L10n.themeAppearanceLight).tag("light"); Text(L10n.themeAppearanceDark).tag("dark")
                    }
                }
                settingsSection(L10n.settingsSectionLanguage) { Picker(L10n.settingsSectionLanguage, selection: $languageManager.selectedLanguage) { ForEach(languageManager.availableLanguages, id: \.code) { Text($0.name).font(.system(size: sz(13))).tag($0.code) } } }
                settingsSection(L10n.settingsFontSize) { Picker(L10n.string("settings.font.picker"), selection: $fontScale) { Text(L10n.fontSizeSmall).font(.system(size: sz(13))).tag(1.0); Text(L10n.fontSizeMedium).font(.system(size: sz(13))).tag(1.2); Text(L10n.fontSizeLarge).font(.system(size: sz(13))).tag(1.4) } }
                settingsSection(L10n.settingsSectionSensitive) { Picker(L10n.settingsAutoClear, selection: $store.sensitiveClearHours) { ForEach(SensitiveClearOption.options) { Text($0.label).font(.system(size: sz(13))).tag($0.hours) } }.id(languageManager.selectedLanguage); Text(L10n.settingsSensitiveHint).font(.system(size: sz(12))).foregroundColor(.secondary) }
                settingsSection(L10n.settingsSectionHistory) { Picker(L10n.settingsMaxItems, selection: $store.maxItems) { ForEach([50,100,200,500], id: \.self) { Text(L10n.settingsMaxItemsCount($0)).font(.system(size: sz(13))).tag($0) } }.id(languageManager.selectedLanguage) }
                settingsSection(L10n.settingsSectionExcludedApps) {
                    excludedAppsTags
                    Button(action: { showingAppPicker = true }) {
                        Label(L10n.settingsAddExcludedApp, systemImage: "plus.circle")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: sz(13)))
                }
                settingsSection(L10n.launchAtLogin) {
                    Toggle(isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { v in
                        do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSSound.beep() }
                    })) { Text(L10n.launchAtLogin).font(.system(size: sz(13))) }
                }
                settingsSection(L10n.settingsSectionAbout) { Text(L10n.aboutVersion(AppVersion.current)).font(.system(size: sz(12))).foregroundColor(.secondary); Text(L10n.aboutFreeEdition).font(.system(size: sz(12))).foregroundColor(.secondary); Button(L10n.sendFeedback) { NSWorkspace.shared.open(URL(string: "https://github.com/irykelee/clipmemory/issues/new")!) }.font(.system(size: sz(13))).buttonStyle(.link) }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
    }

    private func settingsSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: sz(13), weight: .semibold)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) { content() }
                .padding(.top, 6)
                .padding(.leading, 20)
        }
        .padding(.bottom, 20)
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
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: sz(10)))
                                .foregroundColor(.secondary)
                        }
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
            Divider()
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
            Divider()
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
                        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 32, height: 32)
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
        let v = NSView(frame: .zero)
        let p = NSPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        p.minimumPressDuration = 0.4; p.buttonMask = 1 << 0; v.addGestureRecognizer(p)
        return v
    }
    func updateNSView(_: NSView, context: Context) { context.coordinator.onPressChanged = onPressChanged }
    func makeCoordinator() -> Coordinator { Coordinator(onPressChanged: onPressChanged) }
    class Coordinator: NSObject {
        var onPressChanged: (Bool) -> Void
        init(onPressChanged: @escaping (Bool) -> Void) { self.onPressChanged = onPressChanged }
        @objc func pressed(_ sender: NSPressGestureRecognizer) {
            DispatchQueue.main.async { self.onPressChanged(sender.state == .began || sender.state == .changed) }
        }
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem; let isRevealed: Bool; var isKeyboardSelected = false; var isCopied = false; var isSelected = false; var searchText = ""
    var onCopyWithFeedback: (() -> Void)?; let onPin: () -> Void; let onDelete: () -> Void; let onSelect: ((Bool) -> Void)?; let onToggleReveal: () -> Void
    @State private var isHovered = false; @State private var loadedImage: NSImage?
    @State private var longPressing = false
    @State private var imageLongPressing = false
    @State private var showFullContent = false
    @State private var _cachedDecryptedContent: String?
    @State private var _cachedHighlighted: [String: AttributedString] = [:]
    @State private var _cachedMaskedHighlighted: [String: AttributedString] = [:]
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    private var iconSize: CGFloat { fontScale * 13 }

    private var rowBackground: Color {
        if isCopied { Color.green.opacity(0.3) } else if isSelected { Color.accentColor.opacity(0.15) } else if isHovered || isKeyboardSelected { Color(.selectedContentBackgroundColor).opacity(0.3) } else { Color.clear }
    }
    private var pinText: String { item.isPinned ? L10n.actionUnpin : L10n.actionPin }
    private var decryptedContent: String {
        if _cachedDecryptedContent == nil {
            _cachedDecryptedContent = item.decryptedContent
        }
        return _cachedDecryptedContent!
    }
    private var formattedDate: String { cachedRelativeDateFormatter(for: LanguageManager.shared.selectedLanguage).localizedString(for: item.createdAt, relativeTo: Date()) }

    private var cachedHighlighted: AttributedString {
        if let cached = _cachedHighlighted[searchText] { return cached }
        let result = highlightedContent(decryptedContent, highlight: searchText)
        _cachedHighlighted[searchText] = result
        return result
    }
    private var cachedMaskedHighlighted: AttributedString {
        if let cached = _cachedMaskedHighlighted[searchText] { return cached }
        let result = maskedHighlightedContent(decryptedContent, highlight: searchText)
        _cachedMaskedHighlighted[searchText] = result
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
        if highlight.isEmpty { return AttributedString(maskContent(content)) }
        let lc = content.lowercased(), lh = highlight.lowercased(); var vis: [Range<String.Index>] = []; var ss = lc.startIndex
        while let r = lc.range(of: lh, range: ss..<lc.endIndex) { let cs = lc.index(r.lowerBound, offsetBy: -ctx, limitedBy: lc.startIndex) ?? lc.startIndex; let ce = lc.index(r.upperBound, offsetBy: ctx, limitedBy: lc.endIndex) ?? lc.endIndex; vis.append(cs..<ce); ss = r.upperBound }
        guard !vis.isEmpty else { return AttributedString(maskContent(content)) }; vis.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []; for r in vis { if let last = merged.last, last.upperBound >= r.lowerBound { merged[merged.count-1] = last.lowerBound..<max(last.upperBound, r.upperBound) } else { merged.append(r) } }
        var res = AttributedString(); var ci = content.startIndex
        for r in merged { if ci < r.lowerBound { res += AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: r.lowerBound))) }; var h = AttributedString(String(content[r])); h.backgroundColor = .cyan.opacity(0.3); h.foregroundColor = .primary; res += h; ci = r.upperBound }
        if ci < content.endIndex { res += AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: content.endIndex))) }
        return res
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: { onSelect?(!isSelected) }) { Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.system(size: iconSize)).foregroundColor(isSelected ? .accentColor : .secondary).frame(width: 22, height: 22) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    if item.type == .image {
                        Group {
                            if let ns = loadedImage {
                                Image(nsImage: ns)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: imageLongPressing ? 300 : 80)
                                    .overlay(PressableImage { pressed in imageLongPressing = pressed })
                            } else {
                                Text(L10n.itemImage).font(.system(size: fontScale * 13)).foregroundColor(.secondary)
                            }
                        }
                        .task(id: item.content) { if let img = ImageStorage.shared.loadImageObject(filename: item.content) { loadedImage = img } }
                    } else if item.isSensitive && !isRevealed {
                        Text(longPressing ? cachedHighlighted : cachedMaskedHighlighted)
                            .font(.system(size: fontScale * 13)).foregroundColor(.orange).lineLimit(3)
                            .overlay(PressableImage { pressed in longPressing = pressed })
                    } else {
                        Text(showFullContent ? AttributedString(decryptedContent) : cachedHighlighted)
                            .font(.system(size: fontScale * 12)).foregroundColor(Color(nsColor: .controlTextColor))
                            .lineLimit(showFullContent ? nil : 3)
                            .overlay(PressableImage { pressed in showFullContent = pressed })
                    }
                    Spacer()
                }
                .contentShape(Rectangle()).onTapGesture(count: 2) { onPin() }.onTapGesture { onCopyWithFeedback?() }
                HStack(spacing: 8) { if item.isSensitive { Button(action: onToggleReveal) { Text(isRevealed ? L10n.actionHide : L10n.actionView).font(.system(size: fontScale * 11)).foregroundColor(.secondary) }.buttonStyle(.plain) }; Text(formattedDate).font(.system(size: fontScale * 11)).foregroundColor(.secondary); if item.isSensitive { Label(L10n.itemSensitive, systemImage: "exclamationmark.shield").font(.system(size: fontScale * 11)).foregroundColor(.orange) } }
            }
            HStack(spacing: 6) {
                Button(action: onPin) { Image(systemName: item.isPinned ? "star.fill" : "star").font(.system(size: iconSize)).foregroundColor(item.isPinned ? .orange : .secondary).frame(width: 24, height: 24) }.buttonStyle(.plain).help(item.isPinned ? L10n.tooltipUnpin : L10n.tooltipPin)
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: iconSize)).foregroundColor(.secondary).frame(width: 24, height: 24) }.buttonStyle(.plain).help(L10n.tooltipDelete)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(rowBackground).animation(.easeOut(duration: 0.3), value: isCopied).contentShape(Rectangle()).onTapGesture(count: 2) { onPin() }.onHover { isHovered = $0 }
        .contextMenu { Button(action: { onCopyWithFeedback?() }) { Label(L10n.actionCopy, systemImage: "doc.on.doc") }; if item.isSensitive { Button(action: onToggleReveal) { Label(isRevealed ? L10n.actionHideContent : L10n.actionShowContent, systemImage: isRevealed ? "eye.slash" : "eye") } }; Button(action: onPin) { Label(pinText, systemImage: item.isPinned ? "star.slash" : "star") }; Divider(); Button(role: .destructive, action: onDelete) { Label(L10n.actionDelete, systemImage: "trash") } }
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
