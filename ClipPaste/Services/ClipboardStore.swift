import Foundation
import AppKit

class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published var items: [ClipboardItem] = []
    @Published var pinnedItems: [ClipboardItem] = []

    private let storageKey = "ClipboardItems"
    private let maxItemsKey = "maxClipboardItems"
    private let sensitiveClearHoursKey = "sensitiveClearHours"

    var maxItems: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: maxItemsKey)
            return saved > 0 ? saved : 100
        }
        set {
            UserDefaults.standard.set(newValue, forKey: maxItemsKey)
            trimToMaxItems()
            saveItems()
        }
    }

    var sensitiveClearHours: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: sensitiveClearHoursKey)
            return saved > 0 ? saved : 24
        }
        set {
            UserDefaults.standard.set(newValue, forKey: sensitiveClearHoursKey)
        }
    }

    private init() {
        loadItems()
        cleanupExpiredItems()
    }

    func loadItems() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let savedItems = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            items = []
            return
        }
        items = savedItems.filter { !$0.isExpired }
        updatePinnedItems()
    }

    func saveItems() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func addItem(_ item: ClipboardItem) {
        var newItem = item

        if item.isSensitive {
            if let encrypted = CryptoService.shared.encrypt(item.content) {
                newItem = ClipboardItem(
                    id: item.id,
                    content: encrypted,
                    type: item.type,
                    createdAt: item.createdAt,
                    isPinned: item.isPinned,
                    isSensitive: item.isSensitive,
                    expiresAt: item.expiresAt,
                    isEncrypted: true
                )
            }
        }

        if let existingIndex = items.firstIndex(where: { $0.content == newItem.content }) {
            var existing = items.remove(at: existingIndex)
            existing = ClipboardItem(
                id: existing.id,
                content: existing.content,
                type: existing.type,
                createdAt: Date(),
                isPinned: existing.isPinned,
                isSensitive: existing.isSensitive,
                expiresAt: existing.expiresAt,
                isEncrypted: existing.isEncrypted
            )
            items.insert(existing, at: 0)
        } else {
            items.insert(newItem, at: 0)
        }

        trimToMaxItems()
        updatePinnedItems()
        saveItems()
    }

    func getDecryptedContent(_ item: ClipboardItem) -> String {
        if item.isEncrypted {
            return CryptoService.shared.decrypt(item.content) ?? item.content
        }
        return item.content
    }

    private func trimToMaxItems() {
        guard items.count > maxItems else { return }
        let pinned = items.filter { $0.isPinned }
        var nonPinned = items.filter { !$0.isPinned }
        let allowedNonPinned = max(0, maxItems - pinned.count)
        nonPinned = Array(nonPinned.prefix(allowedNonPinned))
        items = pinned + nonPinned
    }

    func deleteItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        updatePinnedItems()
        saveItems()
    }

    func togglePin(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].isPinned.toggle()
            trimToMaxItems()
            updatePinnedItems()
            saveItems()
        }
    }

    func clearSensitiveItems() {
        items.removeAll { $0.isSensitive }
        updatePinnedItems()
        saveItems()
    }

    func clearAllItems() {
        let pinnedIds = Set(pinnedItems.map { $0.id })
        items.removeAll { !pinnedIds.contains($0.id) }
        saveItems()
    }

    func copyToClipboard(_ item: ClipboardItem) {
        let content = getDecryptedContent(item)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }

    private func updatePinnedItems() {
        pinnedItems = items.filter { $0.isPinned }
    }

    func searchItems(_ query: String) -> [ClipboardItem] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.content.localizedCaseInsensitiveContains(query) }
    }

    private func cleanupExpiredItems() {
        let beforeCount = items.count
        items.removeAll { $0.isExpired }
        if items.count != beforeCount {
            updatePinnedItems()
            saveItems()
        }
    }
}
