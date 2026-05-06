import SwiftUI

struct ContentView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared
    @State private var searchText = ""
    @State private var selectedItem: ClipboardItem?
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: ClipboardItem?
    @State private var showingClearAlert = false
    @State private var revealedItems: Set<UUID> = []
    @State var pinnedOnly: Bool = false
    @State var settingsOnly: Bool = false

    var displayedItems: [ClipboardItem] {
        let baseItems = pinnedOnly ? store.pinnedItems : store.items
        if searchText.isEmpty {
            return baseItems
        }
        return baseItems.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if settingsOnly {
                SettingsView(isSettingsOnly: $settingsOnly)
            } else {
                headerView
                Divider()
                if displayedItems.isEmpty {
                    emptyStateView
                } else {
                    listView
                }
            }
        }
        .frame(minWidth: 380, minHeight: 400)
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("ClipMemory")
                    .font(.headline)

                Spacer()

                Button(action: { showingClearAlert = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("清空")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空历史（保留固定片段）")
                .disabled(store.items.isEmpty)

                Button(action: { pinnedOnly.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: pinnedOnly ? "star.fill" : "star")
                        Text(pinnedOnly ? "全部" : "固定")
                    }
                    .font(.caption)
                    .foregroundColor(pinnedOnly ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(pinnedOnly ? "显示全部剪贴板历史" : "仅显示已固定的片段（不会被自动清理）")

                Button(action: { settingsOnly = true }) {
                    Image(systemName: "gear")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("设置")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(.textBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(.windowBackgroundColor).opacity(0.5))
        .alert("清空历史", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                clearHistory()
            }
        } message: {
            let count = store.items.filter { !$0.isPinned }.count
            if count > 0 {
                Text("确定清空 \(count) 条历史记录？\n固定片段不会被删除。")
            } else {
                Text("没有可清空的历史记录。")
            }
        }
    }

    private var searchPlaceholder: String {
        languageManager.selectedLanguage == "zh-Hans" ? "搜索剪贴板历史..." : "Search clipboard history..."
    }

    private func clearHistory() {
        store.clearAllItems()
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: pinnedOnly ? "star" : "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(pinnedOnly ? (languageManager.selectedLanguage == "zh-Hans" ? "暂无固定片段" : "No pinned items") : (languageManager.selectedLanguage == "zh-Hans" ? "暂无剪贴板历史" : "No clipboard history"))
                .font(.headline)
                .foregroundColor(.secondary)
            if pinnedOnly {
                Text(languageManager.selectedLanguage == "zh-Hans" ? "点击片段右侧 ⭐ 将其固定，被固定的片段不会自动清理" : "Click ⭐ on an item to pin it. Pinned items won't be auto-cleared")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text(languageManager.selectedLanguage == "zh-Hans" ? "复制内容后将自动记录到这里" : "Copied content will appear here automatically")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(displayedItems) { item in
                    ClipboardItemRow(
                        item: item,
                        isRevealed: revealedItems.contains(item.id),
                        onCopy: { copyItem(item) },
                        onPin: { store.togglePin(item) },
                        onDelete: { itemToDelete = item; showingDeleteAlert = true },
                        onToggleReveal: { toggleReveal(item.id) },
                        languageManager: languageManager
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .alert("删除片段", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let item = itemToDelete {
                    store.deleteItem(item)
                }
            }
        } message: {
            Text("确定删除该片段吗？")
        }
    }

    private func copyItem(_ item: ClipboardItem) {
        store.copyToClipboard(item)
    }

    private func toggleReveal(_ id: UUID) {
        if revealedItems.contains(id) {
            revealedItems.remove(id)
        } else {
            revealedItems.insert(id)
        }
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isRevealed: Bool
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onToggleReveal: () -> Void
    let languageManager: LanguageManager

    @State private var isHovered = false

    private var viewText: String {
        languageManager.selectedLanguage == "zh-Hans" ? "查看" : "View"
    }

    private var collapseText: String {
        languageManager.selectedLanguage == "zh-Hans" ? "收起" : "Hide"
    }

    private var pinText: String {
        languageManager.selectedLanguage == "zh-Hans" ? (item.isPinned ? "取消" : "固定") : (item.isPinned ? "Unpin" : "Pin")
    }

    private var sensitiveText: String {
        languageManager.selectedLanguage == "zh-Hans" ? "敏感" : "Sensitive"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    if item.isSensitive && !isRevealed {
                        Text(maskContent(item.displayContent))
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .lineLimit(3)
                            .onTapGesture {
                                onToggleReveal()
                            }
                    } else {
                        Text(item.displayContent)
                            .font(.system(size: 12))
                            .foregroundColor(item.isSensitive ? .orange : .primary)
                            .lineLimit(3)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if item.isSensitive {
                        Label(sensitiveText, systemImage: "exclamationmark.shield")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            HStack(spacing: 8) {
                if item.isSensitive {
                    Button(action: onToggleReveal) {
                        Text(isRevealed ? collapseText : viewText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isRevealed ? "收起敏感内容" : "查看敏感内容")
                }

                Button(action: onPin) {
                    Text(pinText)
                        .font(.caption)
                        .foregroundColor(item.isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "取消固定" : "固定此片段（不会被自动清理）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color(.selectedContentBackgroundColor).opacity(0.3) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { onCopy() }
        .contextMenu {
            Button(action: onCopy) {
                Label("复制", systemImage: "doc.on.doc")
            }
            if item.isSensitive {
                Button(action: onToggleReveal) {
                    Label(isRevealed ? "收起内容" : "显示内容", systemImage: isRevealed ? "eye.slash" : "eye")
                }
            }
            Button(action: onPin) {
                Label(item.isPinned ? "取消固定" : "固定片段", systemImage: item.isPinned ? "star.slash" : "star")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func maskContent(_ content: String) -> String {
        if content.count <= 8 {
            return String(repeating: "•", count: content.count)
        }
        let visibleCount = min(4, content.count / 4)
        let prefix = String(content.prefix(visibleCount))
        let suffix = String(content.suffix(visibleCount))
        let middleCount = content.count - visibleCount * 2
        let middle = String(repeating: "•", count: middleCount)
        return prefix + middle + suffix
    }

    private var iconName: String {
        switch item.type {
        case .text: return "doc.text"
        case .image: return "photo"
        case .link: return "link"
        }
    }

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.createdAt, relativeTo: Date())
    }
}

struct SettingsView: View {
    @Binding var isSettingsOnly: Bool
    @ObservedObject var languageManager = LanguageManager.shared
    @ObservedObject var store = ClipboardStore.shared

    let maxItemOptions = [50, 100, 200, 500]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { isSettingsOnly = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("设置")
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section(header: Text("历史记录")) {
                    Picker("最大条数", selection: Binding(
                        get: { store.maxItems },
                        set: { store.maxItems = $0 }
                    )) {
                        ForEach(maxItemOptions, id: \.self) { count in
                            Text("\(count) 条").tag(count)
                        }
                    }
                }

                Section(header: Text("敏感信息保护")) {
                    Picker("自动清除", selection: Binding(
                        get: { store.sensitiveClearHours },
                        set: { store.sensitiveClearHours = $0 }
                    )) {
                        ForEach(SensitiveClearOption.options) { option in
                            Text(option.label).tag(option.hours)
                        }
                    }
                    Text("检测到密码、API密钥等敏感内容时，自动清除前的等待时间")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("语言 / Language")) {
                    Picker("语言", selection: $languageManager.selectedLanguage) {
                        ForEach(languageManager.availableLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Section(header: Text("关于")) {
                    Text("ClipMemory 剪忆 v1.0")
                        .foregroundColor(.secondary)
                    Text("免费版 · 本地剪贴板历史管理")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(minWidth: 380, minHeight: 400)
    }
}
