import Foundation
import os

/// HIGH-1 (2026-07-26 review): trash subsystem extracted from ClipboardStore
/// (was ~180 lines in the 1594-line god object). Owns the recycle bin, its
/// persistence, retention policy, and debounced save timer.
///
/// All `@Published` writes happen on the main thread — callers must ensure this.
final class TrashStore: ObservableObject {
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "Trash")

    /// Items moved to the recycle bin. Persisted separately from `items`.
    @Published var trashedItems: [ClipboardItem] = []

    /// Number of days trashed items are kept before automatic permanent deletion.
    @Published var trashRetentionDays: Int {
        didSet { UserDefaults.standard.set(trashRetentionDays, forKey: TrashStore.trashedItemsStorageKey + ".retentionDays") }
    }

    private let backend: StorageBackend
    private let saveTimerQueue = DispatchQueue(label: "com.clipmemory.trashsave", qos: .utility)
    private var saveTimer: DispatchSourceTimer?
    private var needsSave = false
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(500)

    /// Shared storage key, retained for migration compatibility.
    static let trashedItemsStorageKey = "ClipboardTrashedItems"

    /// Reference to the content cache and RTF cache from ClipboardStore, set
    /// after init so evictCaches can drop stale entries.
    var contentCache: NSCache<NSString, NSString>?
    var rtfPlaintextCache: NSCache<NSString, NSString>?

    init(backend: StorageBackend) {
        self.backend = backend
        let retentionKey = TrashStore.trashedItemsStorageKey + ".retentionDays"
        let saved = UserDefaults.standard.integer(forKey: retentionKey)
        let valid = [3, 7, 14, 30]
        if valid.contains(saved) {
            trashRetentionDays = saved
        } else {
            trashRetentionDays = 7
            UserDefaults.standard.set(7, forKey: retentionKey)
        }
        loadTrashedItems()
        purgeExpiredTrash()
    }

    deinit {
        saveTimer?.cancel()
        if needsSave { saveTrashedItems() }
    }

    // MARK: - Persistence

    func loadTrashedItems() {
        do {
            trashedItems = try backend.load()
        } catch {
            logger.error("Failed to load trashed items: \(error.localizedDescription)")
            trashedItems = []
        }
    }

    func saveTrashedItems() {
        do {
            try backend.save(trashedItems)
        } catch {
            logger.error("Failed to save trashed items: \(error.localizedDescription)")
        }
    }

    // MARK: - Operations

    /// Move a single item to the recycle bin.
    func moveToTrash(_ item: ClipboardItem, evictCaches: (ClipboardItem) -> Void, didMove: () -> Void) {
        evictCaches(item)
        var trashed = item
        trashed.deletedAt = Date()
        trashedItems.insert(trashed, at: 0)
        didMove()
        scheduleSave()
    }

    /// Move multiple items to the recycle bin (shared timestamp, L-5).
    func moveToTrash(_ itemsToMove: [ClipboardItem], evictCaches: (ClipboardItem) -> Void, didMove: () -> Void) {
        let now = Date()
        for item in itemsToMove {
            evictCaches(item)
            var trashed = item
            trashed.deletedAt = now
            trashedItems.insert(trashed, at: 0)
        }
        didMove()
        scheduleSave()
    }

    func restoreFromTrash(_ item: ClipboardItem, didRestore: (ClipboardItem) -> Void) {
        guard let index = trashedItems.firstIndex(where: { $0.id == item.id }) else { return }
        var restored = trashedItems.remove(at: index)
        restored.deletedAt = nil
        didRestore(restored)
        scheduleSave()
    }

    func deletePermanently(_ item: ClipboardItem) {
        if item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        trashedItems.removeAll { $0.id == item.id }
        scheduleSave()
    }

    func emptyTrash() {
        for item in trashedItems where item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        trashedItems.removeAll()
        scheduleSave()
    }

    func purgeExpiredTrash() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(trashRetentionDays * 24 * 60 * 60))
        let expired = trashedItems.filter { item in
            guard let deletedAt = item.deletedAt else { return false }
            return deletedAt < cutoff
        }
        guard !expired.isEmpty else { return }
        for item in expired where item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        let expiredIds = Set(expired.map { $0.id })
        trashedItems.removeAll { expiredIds.contains($0.id) }
        scheduleSave()
    }

    // MARK: - Debounced save

    private func scheduleSave() {
        needsSave = true
        if saveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: saveTimerQueue)
            timer.setEventHandler { [weak self] in
                DispatchQueue.main.async { self?.flushSave() }
            }
            timer.resume()
            saveTimer = timer
        }
        saveTimer?.schedule(deadline: .now() + saveDebounceInterval)
    }

    private func flushSave() {
        guard needsSave else { return }
        needsSave = false
        saveTimer?.cancel()
        saveTrashedItems()
    }

    func flushPendingSave() {
        if needsSave { saveTrashedItems(); needsSave = false }
    }

    /// Trigger a debounced save — for callers that batch-modify trashedItems directly.
    func scheduleSavePublic() { scheduleSave() }
}
