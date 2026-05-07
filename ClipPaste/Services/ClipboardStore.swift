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
            guard let encrypted = CryptoService.shared.encrypt(item.content) else { return }
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

        if let existingIndex = items.firstIndex(where: { $0.content == newItem.content && $0.type == newItem.type }) {
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
        let trimmed = pinned + nonPinned
        let trimmedIds = Set(trimmed.map { $0.id })
        let removedImages = items.filter { $0.type == .image && !trimmedIds.contains($0.id) }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items = trimmed
    }

    func deleteItem(_ item: ClipboardItem) {
        if item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
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

    func unpinAll() {
        for i in items.indices {
            items[i].isPinned = false
        }
        updatePinnedItems()
        saveItems()
    }

    func clearSensitiveItems() {
        items.removeAll { $0.isSensitive }
        updatePinnedItems()
        saveItems()
    }

    func clearAllItems() {
        let pinnedIds = Set(pinnedItems.map { $0.id })
        let removedImages = items.filter { !pinnedIds.contains($0.id) && $0.type == .image }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { !pinnedIds.contains($0.id) }
        saveItems()
    }

    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.type {
        case .image:
            if let data = ImageStorage.shared.loadImage(filename: item.content),
               let image = NSImage(data: data) {
                pasteboard.writeObjects([image as NSImage])
            }
        default:
            let content = getDecryptedContent(item)
            pasteboard.setString(content, forType: .string)
        }
        moveToTop(item)
    }

    private func moveToTop(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var moved = items.remove(at: index)
        moved = ClipboardItem(
            id: moved.id,
            content: moved.content,
            type: moved.type,
            createdAt: Date(),
            isPinned: moved.isPinned,
            isSensitive: moved.isSensitive,
            expiresAt: moved.expiresAt,
            isEncrypted: moved.isEncrypted
        )
        items.insert(moved, at: 0)
        saveItems()
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
