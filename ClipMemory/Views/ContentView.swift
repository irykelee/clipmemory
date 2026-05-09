import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
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

struct ContentView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared
    @State private var selectedTab: SidebarTab = .all
    @State private var searchText = "" { didSet { keyboardSelectedIndex = nil } }
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: ClipboardItem?
    @State private var showingClearAlert = false
    @State private var revealedItems: Set<UUID> = []
    @State private var keyboardSelectedIndex: Int?
    @State private var lastCopiedId: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var collapsedGroups: Set<TimeGroup> = []
    @State private var isRecordingHotKey = false
    @State private var keyEventMonitor: Any?
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    private func sz(_ base: CGFloat) -> CGFloat { base * fontScale }

    var displayedItems: [ClipboardItem] {
        var base: [ClipboardItem]
        switch selectedTab { case .pinned: base = store.pinnedItems; default: base = store.items }
        if let f = selectedTab.typeFilter { base = base.filter { $0.type == f } }
        if searchText.isEmpty { return base }
        return base.filter { $0.decryptedContent.localizedCaseInsensitiveContains(searchText) }
    }

    private enum TimeGroup: CaseIterable { case today, yesterday, thisWeek, thisMonth, older
        var label: String {
            switch self { case .today: L10n.groupToday; case .yesterday: L10n.groupYesterday; case .thisWeek: L10n.groupThisWeek; case .thisMonth: L10n.groupThisMonth; case .older: L10n.groupOlder }
        }
    }
    private var groupedItems: [(TimeGroup, [ClipboardItem])] {
        let cal = Calendar.current, now = Date()
        var dict: [TimeGroup: [ClipboardItem]] = [:]
        for item in displayedItems {
            let g: TimeGroup
            if cal.isDateInToday(item.createdAt) { g = .today }
            else if cal.isDateInYesterday(item.createdAt) { g = .yesterday }
            else if let week = cal.date(byAdding: .day, value: -7, to: now), item.createdAt > week { g = .thisWeek }
            else if let month = cal.date(byAdding: .month, value: -1, to: now), item.createdAt > month { g = .thisMonth }
            else { g = .older }
            dict[g, default: []].append(item)
        }
        return TimeGroup.allCases.compactMap { guard let items = dict[$0], !items.isEmpty else { return nil }; return ($0, items) }
    }

    private var flattenedItems: [(item: ClipboardItem, globalIndex: Int)] {
        var result: [(item: ClipboardItem, globalIndex: Int)] = []
        var idx = 0
        for section in groupedItems {
            for item in section.1 {
                result.append((item, idx)); idx += 1
            }
        }
        return result
    }

    private var itemIndexMap: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: flattenedItems.map { ($0.item.id, $0.globalIndex) })
    }

    private var tabCounts: [SidebarTab: Int] {
        let items = store.items
        return [.all: items.count, .text: items.filter { $0.type == .text }.count, .image: items.filter { $0.type == .image }.count, .link: items.filter { $0.type == .link }.count]
    }

    private var batchAllPinned: Bool {
        let sel = selectedItems
        guard !sel.isEmpty else { return false }
        return displayedItems.filter { sel.contains($0.id) }.allSatisfy { $0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 170)
                Divider()
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: sz(12)))
                        TextField(L10n.searchPlaceholder, text: $searchText)
                            .textFieldStyle(.plain).font(.system(size: sz(13)))
                            .frame(minWidth: 260)
                        if !searchText.isEmpty { Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.system(size: sz(11))) }.buttonStyle(.plain) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.ultraThinMaterial).cornerRadius(appCornerRadius)
                    Button(action: { showingClearAlert = true }) { Image(systemName: "trash").font(.system(size: sz(14))).foregroundColor(.secondary) }.buttonStyle(.plain).help(L10n.tooltipClearHistory).disabled(store.items.isEmpty)
                    Spacer(minLength: 12)
                }.padding(.vertical, 6)
            }
            .frame(height: 42)
            .background(.clear)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text(L10n.appName).font(.system(size: sz(13), weight: .semibold)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.vertical, 10)
                    Divider()
                    sidebar
                }.frame(width: 170).background(.ultraThinMaterial)
                Divider()
                Group { if selectedTab == .settings { settingsDetail } else { mainContent } }.frame(minWidth: 420).background(.regularMaterial)
            }
        }
        .frame(minWidth: 640, minHeight: 440).ignoresSafeArea(edges: .top).background(.ultraThinMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { _ in selectedTab = .settings }
        .overlay(alignment: .top) { KeyCaptureView(onUp: {
            guard !displayedItems.isEmpty else { return }
            if let idx = keyboardSelectedIndex, idx > 0 { keyboardSelectedIndex = idx - 1 } else { keyboardSelectedIndex = displayedItems.count - 1 }
        }, onDown: {
            guard !displayedItems.isEmpty else { return }
            let last = displayedItems.count - 1; if let idx = keyboardSelectedIndex, idx < last { keyboardSelectedIndex = idx + 1 } else { keyboardSelectedIndex = 0 }
        }, onReturn: {
            if let idx = keyboardSelectedIndex, idx < displayedItems.count { let item = displayedItems[idx]; lastCopiedId = item.id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if lastCopiedId == item.id { lastCopiedId = nil } }; copyItem(item) }
        }, onEscape: { if selectedTab == .settings { selectedTab = .all } else if !searchText.isEmpty { searchText = "" } else { NSApp.keyWindow?.close() } }).frame(width: 0, height: 0) }
    }

    private var sidebar: some View {
        List(selection: $selectedTab) {
            Section { ForEach([SidebarTab.all, .text, .image, .link], id: \.self) { tab in Label { HStack { Text(tab.label).font(.system(size: sz(13))); Spacer(); Text("(\(tabCounts[tab] ?? 0))").font(.system(size: sz(11))).foregroundColor(.secondary) } } icon: { Image(systemName: tab.icon) }.tag(tab) } }
            Section { Label { Text(SidebarTab.pinned.label).font(.system(size: sz(13))) } icon: { Image(systemName: SidebarTab.pinned.icon) }.tag(SidebarTab.pinned) }
            Section { Label { Text(SidebarTab.settings.label).font(.system(size: sz(13))) } icon: { Image(systemName: SidebarTab.settings.icon) }.tag(SidebarTab.settings) }
        }.listStyle(.sidebar).onChange(of: selectedTab) { _ in keyboardSelectedIndex = nil }.environment(\.defaultMinListRowHeight, sz(28))
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if !selectedItems.isEmpty {
                HStack { Text(L10n.batchSelected(selectedItems.count)).font(.system(size: sz(12))).foregroundColor(.secondary); Spacer()
                    Button(action: { store.togglePinItems(displayedItems.filter { selectedItems.contains($0.id) }); selectedItems.removeAll() }) { Label(batchAllPinned ? L10n.actionUnpin : L10n.actionPin, systemImage: batchAllPinned ? "star.slash" : "star").font(.system(size: sz(12))) }.buttonStyle(.plain)
                    Button(action: { store.deleteItems(displayedItems.filter { selectedItems.contains($0.id) }); selectedItems.removeAll() }) { Label(L10n.actionDelete, systemImage: "trash").font(.system(size: sz(12))) }.buttonStyle(.plain).foregroundColor(.red)
                    Button(action: { selectedItems.removeAll() }) { Text(L10n.buttonCancel).font(.system(size: sz(12))) }.buttonStyle(.plain).foregroundColor(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(.ultraThinMaterial)
                Divider()
            }
            if displayedItems.isEmpty { emptyState } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedItems, id: \.0) { group, items in
                            Section {
                                if !collapsedGroups.contains(group) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                                        let gi = itemIndexMap[item.id] ?? 0
                                        ClipboardItemRow(item: item, isRevealed: revealedItems.contains(item.id),
                                            isKeyboardSelected: keyboardSelectedIndex == gi,
                                            isCopied: lastCopiedId == item.id, isSelected: selectedItems.contains(item.id),
                                            searchText: searchText,
                                            onCopyWithFeedback: { lastCopiedId = item.id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if lastCopiedId == item.id { lastCopiedId = nil } }; copyItem(item) },
                                            onPin: { store.togglePin(item) }, onDelete: { itemToDelete = item; showingDeleteAlert = true },
                                            onSelect: { if $0 { selectedItems.insert(item.id) } else { selectedItems.remove(item.id) } },
                                            onToggleReveal: { toggleReveal(item.id) })
                                }
                                }
                            } header: {
                                HStack {
                                    Text(group.label).font(.system(size: sz(11), weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase)
                                        .onTapGesture { toggleGroup(group) }
                                    Spacer()
                                    Image(systemName: collapsedGroups.contains(group) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: sz(10))).foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle()).onTapGesture { toggleGroup(group) }
                                .padding(.horizontal, 16).padding(.vertical, 4).background(.regularMaterial)
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
                Text(L10n.settingsTitle).font(.system(size: sz(20), weight: .semibold)).padding(.leading, 24).padding(.vertical, 16)
                Divider()
                Group {
                    settingsSection(L10n.settingsSectionHistory) { Picker(L10n.settingsMaxItems, selection: $store.maxItems) { ForEach([50,100,200,500], id: \.self) { Text(L10n.settingsMaxItemsCount($0)).font(.system(size: sz(13))).tag($0) } }.id(languageManager.selectedLanguage) }
                    settingsSection(L10n.settingsSectionSensitive) { Picker(L10n.settingsAutoClear, selection: $store.sensitiveClearHours) { ForEach(SensitiveClearOption.options) { Text($0.label).font(.system(size: sz(13))).tag($0.hours) } }.id(languageManager.selectedLanguage); Text(L10n.settingsSensitiveHint).font(.system(size: sz(11))).foregroundColor(.secondary) }
                    settingsSection(L10n.settingsSectionLanguage) { Picker(L10n.settingsSectionLanguage, selection: $languageManager.selectedLanguage) { ForEach(languageManager.availableLanguages, id: \.code) { Text($0.name).font(.system(size: sz(13))).tag($0.code) } } }
                    settingsSection(L10n.launchAtLogin) {
                        Toggle(isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { v in
                            do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                        })) { Text(L10n.launchAtLogin).font(.system(size: sz(13))) }
                    }
                    if let hk = (NSApp.delegate as? AppDelegate)?.hotKeyManager {
                        settingsSection(L10n.settingsSectionHotkey) {
                            HStack {
                                if isRecordingHotKey {
                                    Text(L10n.settingsHotkeyRecording).font(.system(size: sz(13))).foregroundColor(.orange)
                                    Spacer()
                                    Button(L10n.buttonCancel) { isRecordingHotKey = false }.buttonStyle(.plain).font(.system(size: sz(12))).foregroundColor(.secondary)
                                } else {
                                    Text(hk.config.displayString).font(.system(size: sz(13), design: .monospaced))
                                    Spacer()
                                    Button(L10n.settingsHotkeyChange) { startRecording() }.buttonStyle(.plain).font(.system(size: sz(12))).foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    settingsSection(L10n.settingsFontSize) { Picker("", selection: $fontScale) { Text(L10n.fontSizeSmall).font(.system(size: sz(13))).tag(0.85); Text(L10n.fontSizeMedium).font(.system(size: sz(13))).tag(1.0); Text(L10n.fontSizeLarge).font(.system(size: sz(13))).tag(1.15) } }
                    settingsSection(L10n.settingsSectionAbout) { Text(L10n.aboutVersion(AppVersion.current)).font(.system(size: sz(12))).foregroundColor(.secondary); Text(L10n.aboutFreeEdition).font(.system(size: sz(11))).foregroundColor(.secondary); Button(L10n.sendFeedback) { NSWorkspace.shared.open(URL(string: "https://github.com/irykelee/clipmemory/issues/new")!) }.font(.system(size: sz(12))).buttonStyle(.link).foregroundColor(.accentColor) }
                }.padding(.horizontal, 24).padding(.vertical, 16)
}
    }
}

    private func settingsSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: sz(11), weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase); content().padding(.bottom, 12) }
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
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    private var iconSize: CGFloat { fontScale * 13 }

    private var rowBackground: Color {
        if isCopied { Color.green.opacity(0.3) } else if isSelected { Color.accentColor.opacity(0.15) } else if isHovered || isKeyboardSelected { Color(.selectedContentBackgroundColor).opacity(0.3) } else { Color.clear }
    }
    private var pinText: String { item.isPinned ? L10n.actionUnpin : L10n.actionPin }
    private var decryptedContent: String { item.decryptedContent }
    private var formattedDate: String { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; f.locale = Locale(identifier: LanguageManager.shared.selectedLanguage); return f.localizedString(for: item.createdAt, relativeTo: Date()) }

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
        var ss = lowerDS.startIndex
        while let r = lowerDS.range(of: lh, range: ss..<lowerDS.endIndex) {
            let startOff = lowerDS.distance(from: lowerDS.startIndex, to: r.lowerBound)
            let endOff = startOff + lowerDS.distance(from: r.lowerBound, to: r.upperBound)
            if startOff < 200 {
                let si = a.index(a.startIndex, offsetByCharacters: prefixLen + startOff)
                let ei = a.index(a.startIndex, offsetByCharacters: min(prefixLen + endOff, prefixLen + 200))
                a[si..<ei].backgroundColor = .yellow.opacity(0.4)
                a[si..<ei].foregroundColor = .orange
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
        for r in merged { if ci < r.lowerBound { res += AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: r.lowerBound))) }; var h = AttributedString(String(content[r])); h.backgroundColor = .yellow.opacity(0.4); h.foregroundColor = .orange; res += h; ci = r.upperBound }
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
                        Text(longPressing ? highlightedContent(decryptedContent, highlight: searchText) : maskedHighlightedContent(decryptedContent, highlight: searchText))
                            .font(.system(size: fontScale * 13)).foregroundColor(.orange).lineLimit(3)
                            .overlay(PressableImage { pressed in longPressing = pressed })
                    } else {
                        Text(showFullContent ? AttributedString(decryptedContent) : highlightedContent(decryptedContent, highlight: searchText))
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
