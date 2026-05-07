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
                        copyItem(displayedItems[idx])
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

                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                    ClipboardItemRow(
                        item: item,
                        isRevealed: revealedItems.contains(item.id),
                        isKeyboardSelected: keyboardSelectedIndex == index,
                        onCopy: { copyItem(item) },
                        onPin: { store.togglePin(item) },
                        onDelete: { itemToDelete = item; showingDeleteAlert = true },
                        onToggleReveal: { toggleReveal(item.id) }
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
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onToggleReveal: () -> Void

    @State private var isHovered = false

    private var pinText: String {
        item.isPinned ? L10n.actionUnpin : L10n.actionPin
    }

    /// Decrypts content for display — uses item.decryptedContent which caches per instance
    private var decryptedContent: String {
        item.decryptedContent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
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
                        if let data = ImageStorage.shared.loadImage(filename: item.content),
                           let nsImage = NSImage(data: data),
                           nsImage.isValid {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 80)
                                .onTapGesture {
                                    onToggleReveal()
                                }
                        } else {
                            Text(L10n.itemImage)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    } else if item.isSensitive && !isRevealed {
                        Text(maskContent(decryptedContent))
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .lineLimit(3)
                            .onTapGesture {
                                onToggleReveal()
                            }
                    } else {
                        Text(String(decryptedContent.prefix(200)))
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
        .background(isHovered || isKeyboardSelected ? Color(.selectedContentBackgroundColor).opacity(0.3) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture(count: 2) { onPin() }
        .onTapGesture { onCopy() }
        .contextMenu {
            Button(action: onCopy) {
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
