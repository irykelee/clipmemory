import SwiftUI
import AppKit

/// Invisible view that captures key events for keyboard navigation.
/// Falls back to ArrowKeyView on macOS 13 (NSEvent monitor).
struct KeyCaptureView: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
    }
}

final class KeyCaptureNSView: NSView {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMonitor()
    }

    private func setupMonitor() {
        // Monitor key events even when other views have focus
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            switch event.keyCode {
            case 126: // upArrow
                self.onUp?()
                return nil
            case 125: // downArrow
                self.onDown?()
                return nil
            case 36: // return
                self.onReturn?()
                return nil
            case 53: // escape
                self.onEscape?()
                return nil
            default:
                return event
            }
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var languageManager = LanguageManager.shared
    @State private var searchText = "" {
        didSet { keyboardSelectedIndex = nil }
    }
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: ClipboardItem?
    @State private var showingClearAlert = false
    @State private var revealedItems: Set<UUID> = []
    @State private var keyboardSelectedIndex: Int? = nil
    @State private var lastCopiedId: UUID? = nil
    @State private var selectedItems: Set<UUID> = []
    @State var pinnedOnly: Bool = false
    @State var settingsOnly: Bool = false

    var displayedItems: [ClipboardItem] {
        let baseItems = pinnedOnly ? store.pinnedItems : store.items
        if searchText.isEmpty {
            return baseItems
        }
        // Search must decrypt content to match — ciphertext would never match plaintext queries
        return baseItems.filter { item in
            item.decryptedContent.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Flat list with global indices for keyboard navigation
    private var flattenedItems: [(item: ClipboardItem, globalIndex: Int)] {
        displayedItems.enumerated().map { (index, item) in (item: item, globalIndex: index) }
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
        .overlay(alignment: .top) {
            KeyCaptureView(
                onUp: {
                    if displayedItems.isEmpty { return }
                    if let idx = keyboardSelectedIndex, idx > 0 {
                        keyboardSelectedIndex = idx - 1
                    } else {
                        keyboardSelectedIndex = displayedItems.count - 1
                    }
                },
                onDown: {
                    if displayedItems.isEmpty { return }
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
                        copyItem(item)
                    }
                },
                onEscape: {
                    NSApp.keyWindow?.close()
                }
            )
            .frame(width: 0, height: 0)
        }
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text(L10n.appName)
                    .font(.title3)

                Spacer()

                Button(action: { showingClearAlert = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(L10n.buttonClear)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tooltipClearHistory)
                .disabled(store.items.isEmpty)

                Button(action: { pinnedOnly.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: pinnedOnly ? "star.fill" : "star")
                        Text(pinnedOnly ? L10n.headerShowAll : L10n.headerShowPinned)
                    }
                    .font(.callout)
                    .foregroundColor(pinnedOnly ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(pinnedOnly ? L10n.tooltipShowAll : L10n.tooltipPinnedOnly)

                Button(action: { settingsOnly = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                        Text(L10n.buttonSettings)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.buttonSettings)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(L10n.searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(.textBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(.windowBackgroundColor).opacity(0.5))
        .alert(L10n.alertClearTitle, isPresented: $showingClearAlert) {
            Button(L10n.buttonCancel, role: .cancel) {}
            Button(L10n.buttonClear, role: .destructive) {
                clearHistory()
            }
        } message: {
            let count = store.items.filter { !$0.isPinned }.count
            if count > 0 {
                Text(L10n.alertClearMessage(count))
            } else {
                Text(L10n.alertClearNone)
            }
        }
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
            Text(pinnedOnly ? L10n.emptyNoPinned : L10n.emptyNoHistory)
                .font(.headline)
                .foregroundColor(.secondary)
            if pinnedOnly {
                Text(L10n.emptyPinnedHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text(L10n.emptyHistoryHint)
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
                if !selectedItems.isEmpty {
                    HStack {
                        Text(L10n.batchSelected(selectedItems.count))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            let itemsToToggle = displayedItems.filter { selectedItems.contains($0.id) }
                            store.togglePinItems(itemsToToggle)
                            selectedItems.removeAll()
                        }) {
                            Image(systemName: "star")
                            Text(L10n.actionPin)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        Button(action: {
                            let itemsToDelete = displayedItems.filter { selectedItems.contains($0.id) }
                            store.deleteItems(itemsToDelete)
                            selectedItems.removeAll()
                        }) {
                            Image(systemName: "trash")
                            Text(L10n.actionDelete)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.red)
                        Button(action: { selectedItems.removeAll() }) {
                            Text(L10n.buttonCancel)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.windowBackgroundColor).opacity(0.8))
                }

                if pinnedOnly && store.pinnedItems.count > 1 {
                    Button(action: { store.unpinAll() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.slash")
                            Text(L10n.headerPinAll)
                        }
                        .font(.callout)
                        .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                }

                ForEach(flattenedItems, id: \.item.id) { entry in
                    ClipboardItemRow(
                        item: entry.item,
                        isRevealed: revealedItems.contains(entry.item.id),
                        isKeyboardSelected: keyboardSelectedIndex == entry.globalIndex,
                        isCopied: lastCopiedId == entry.item.id,
                        isSelected: selectedItems.contains(entry.item.id),
                        searchText: searchText,
                        onCopyWithFeedback: {
                            lastCopiedId = entry.item.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if lastCopiedId == entry.item.id { lastCopiedId = nil }
                            }
                            copyItem(entry.item)
                        },
                        onPin: { store.togglePin(entry.item) },
                        onDelete: { itemToDelete = entry.item; showingDeleteAlert = true },
                        onSelect: { selected in
                            if selected {
                                selectedItems.insert(entry.item.id)
                            } else {
                                selectedItems.remove(entry.item.id)
                            }
                        },
                        onToggleReveal: { toggleReveal(entry.item.id) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .alert(L10n.alertDeleteTitle, isPresented: $showingDeleteAlert) {
            Button(L10n.buttonCancel, role: .cancel) {}
            Button(L10n.buttonDelete, role: .destructive) {
                if let item = itemToDelete {
                    store.deleteItem(item)
                }
            }
        } message: {
            Text(L10n.alertDeleteMessage)
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
    var isKeyboardSelected: Bool = false
    var isCopied: Bool = false
    var isSelected: Bool = false
    var searchText: String = ""
    var onCopyWithFeedback: (() -> Void)?
    let onPin: () -> Void
    let onDelete: () -> Void
    let onSelect: ((Bool) -> Void)?
    let onToggleReveal: () -> Void

    @State private var isHovered = false
    @State private var loadedImage: NSImage?

    private var rowBackground: Color {
        if isCopied { return Color.green.opacity(0.3) }
        if isSelected { return Color.accentColor.opacity(0.15) }
        if isHovered || isKeyboardSelected { return Color(.selectedContentBackgroundColor).opacity(0.3) }
        return Color.clear
    }

    private var pinText: String {
        item.isPinned ? L10n.actionUnpin : L10n.actionPin
    }

    /// Decrypts content for display — delegates to item.decryptedContent
    private var decryptedContent: String {
        item.decryptedContent
    }

    /// Creates attributed string with search term highlighted in yellow
    private func highlightedContent(_ text: String, highlight: String) -> AttributedString {
        var attributed = AttributedString(String(text.prefix(200)))
        if highlight.isEmpty { return attributed }
        let lowerText = text.lowercased()
        let lowerHighlight = highlight.lowercased()
        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: lowerHighlight, range: searchStart..<lowerText.endIndex) {
            let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
            let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            if let attrStart = attrStart, let attrEnd = attrEnd {
                attributed[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
                attributed[attrStart..<attrEnd].foregroundColor = .orange
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: { onSelect?(!isSelected) }) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: iconName)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Button(action: onPin) {
                        Image(systemName: item.isPinned ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundColor(item.isPinned ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? L10n.tooltipUnpin : L10n.tooltipPin)

                    if item.type == .image {
                        Group {
                            if let nsImage = loadedImage {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 80)
                            } else {
                                Text(L10n.itemImage)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onTapGesture { onToggleReveal() }
                        .task(id: item.content) {
                            // Use cached loadImageObject for fast repeated access during scroll
                            if let image = ImageStorage.shared.loadImageObject(filename: item.content) {
                                self.loadedImage = image
                            }
                        }
                    } else if item.isSensitive && !isRevealed {
                        Text(maskedHighlightedContent(decryptedContent, highlight: searchText))
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .lineLimit(3)
                            .onTapGesture {
                                onToggleReveal()
                            }
                    } else {
                        Text(highlightedContent(decryptedContent, highlight: searchText))
                            .font(.system(size: 12))
                            .foregroundColor(item.isSensitive ? .orange : .primary)
                            .lineLimit(3)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    if item.isSensitive {
                        Button(action: onToggleReveal) {
                            Text(isRevealed ? L10n.actionHide : L10n.actionView)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isRevealed ? L10n.tooltipHide : L10n.tooltipReveal)
                    }

                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if item.isSensitive {
                        Label(L10n.itemSensitive, systemImage: "exclamationmark.shield")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tooltipDelete)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .animation(.easeOut(duration: 0.3), value: isCopied)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture(count: 2) { onPin() }
        .onTapGesture { onCopyWithFeedback?() }
        .contextMenu {
            Button(action: { onCopyWithFeedback?() }) {
                Label(L10n.actionCopy, systemImage: "doc.on.doc")
            }
            if item.isSensitive {
                Button(action: onToggleReveal) {
                    Label(isRevealed ? L10n.actionHideContent : L10n.actionShowContent, systemImage: isRevealed ? "eye.slash" : "eye")
                }
            }
            Button(action: onPin) {
                Label(pinText, systemImage: item.isPinned ? "star.slash" : "star")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(L10n.actionDelete, systemImage: "trash")
            }
        }
    }

    private func maskContent(_ content: String) -> String {
        if content.count <= 4 {
            return String(repeating: "•", count: content.count)
        }
        let prefix = String(content.prefix(2))
        let suffix = String(content.suffix(2))
        let middleCount = content.count - 4
        let middle = String(repeating: "•", count: middleCount)
        return prefix + middle + suffix
    }

    /// Returns masked content with highlighted search matches and surrounding context visible
    /// e.g. "•••••• token: sk-abc••••••" when searching "sk" with contextChars=10
    private func maskedHighlightedContent(_ content: String, highlight: String, contextChars: Int = 15) -> AttributedString {
        if highlight.isEmpty {
            return AttributedString(maskContent(content))
        }

        let lowerContent = content.lowercased()
        let lowerHighlight = highlight.lowercased()

        // Find all match ranges expanded with context
        var visibleRanges: [Range<String.Index>] = []
        var searchStart = lowerContent.startIndex

        while let range = lowerContent.range(of: lowerHighlight, range: searchStart..<lowerContent.endIndex) {
            let contextStart = lowerContent.index(range.lowerBound, offsetBy: -contextChars, limitedBy: lowerContent.startIndex) ?? lowerContent.startIndex
            let contextEnd = lowerContent.index(range.upperBound, offsetBy: contextChars, limitedBy: lowerContent.endIndex) ?? lowerContent.endIndex
            visibleRanges.append(contextStart..<contextEnd)
            searchStart = range.upperBound
        }

        guard !visibleRanges.isEmpty else {
            return AttributedString(maskContent(content))
        }

        // Merge overlapping ranges
        visibleRanges.sort { $0.lowerBound < $1.lowerBound }
        var mergedRanges: [Range<String.Index>] = []
        for range in visibleRanges {
            if let last = mergedRanges.last, last.upperBound >= range.lowerBound {
                mergedRanges[mergedRanges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                mergedRanges.append(range)
            }
        }

        // Build result: masked parts + highlighted visible parts
        var result = AttributedString()
        var currentIndex = content.startIndex

        for range in mergedRanges {
            // Masked part before this visible range
            if currentIndex < range.lowerBound {
                let maskedCount = content.distance(from: currentIndex, to: range.lowerBound)
                result += AttributedString(String(repeating: "•", count: maskedCount))
            }

            // Visible highlighted part
            let visibleText = String(content[range])
            var highlighted = AttributedString(visibleText)
            highlighted.backgroundColor = .yellow.opacity(0.4)
            highlighted.foregroundColor = .orange
            result += highlighted

            currentIndex = range.upperBound
        }

        // Masked part after last visible range
        if currentIndex < content.endIndex {
            let maskedCount = content.distance(from: currentIndex, to: content.endIndex)
            result += AttributedString(String(repeating: "•", count: maskedCount))
        }

        return result
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
        formatter.locale = Locale(identifier: LanguageManager.shared.selectedLanguage)
        return formatter.localizedString(for: item.createdAt, relativeTo: Date())
    }
}

struct SettingsView: View {
    @Binding var isSettingsOnly: Bool
    @ObservedObject var languageManager = LanguageManager.shared
    @ObservedObject var store = ClipboardStore.shared

    let maxItemOptions = [50, 100, 200, 500, 1000, 2000]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { isSettingsOnly = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L10n.buttonBack)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(L10n.settingsTitle)
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            Divider()

            settingsForm
                .padding()
        }
        .frame(minWidth: 380, minHeight: 400)
    }

    @ViewBuilder
    private var settingsForm: some View {
        if #available(macOS 14, *) {
            Form {
                settingsSections
            }
            .formStyle(.grouped)
        } else {
            Form {
                settingsSections
            }
            .formStyle(.automatic)
        }
    }

    private var settingsSections: some View {
        Group {
            Section(header: Text(L10n.settingsSectionHistory)) {
                Picker(L10n.settingsMaxItems, selection: $store.maxItems) {
                    ForEach(maxItemOptions, id: \.self) { count in
                        Text(L10n.settingsMaxItemsCount(count)).tag(count)
                    }
                }
                .id(languageManager.selectedLanguage)
            }

            Section(header: Text(L10n.settingsSectionSensitive)) {
                Picker(L10n.settingsAutoClear, selection: $store.sensitiveClearHours) {
                    ForEach(SensitiveClearOption.options) { option in
                        Text(option.label).tag(option.hours)
                    }
                }
                .id(languageManager.selectedLanguage)
                Text(L10n.settingsSensitiveHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text(L10n.settingsSectionLanguage)) {
                Picker(L10n.settingsSectionLanguage, selection: $languageManager.selectedLanguage) {
                    ForEach(languageManager.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
            }

            Section(header: Text(L10n.settingsSectionAbout)) {
                Text(L10n.aboutVersion(AppVersion.current))
                    .foregroundColor(.secondary)
                Text(L10n.aboutFreeEdition)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }
}
