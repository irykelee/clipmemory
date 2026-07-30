import Foundation
import os
import AppKit

/// HIGH-1 (2026-07-26 review): trash subsystem extracted from ClipboardStore
/// (was ~180 lines in the 1594-line god object). Owns the recycle bin, its
/// persistence, retention policy, and debounced save timer.
///
/// **F-1 phase 2 (2026-07-28)**: class is now `@MainActor`. The previously
/// implicit "callers must ensure main thread" contract on `@Published` writes
/// is now enforced by the type system. See 2026-07-28 F-2 audit closeout
/// for the F-2 sweep + future-marker notes.
@MainActor
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
    /// F-1 phase 2 (2026-07-28): `nonisolated` so callers (incl. @MainActor
    /// ClipboardStore init) can read this static let from any isolation domain.
    nonisolated static let trashedItemsStorageKey = "ClipboardTrashedItems"

    /// Reference to the content cache and RTF cache from ClipboardStore, set
    /// after init so evictCaches can drop stale entries.
    var contentCache: NSCache<NSString, NSString>?
    var rtfPlaintextCache: NSCache<NSString, NSString>?

    /// Observer for `NSApplication.willTerminateNotification`. Registered in
    /// `init` so the cleanup logic (cancel timer + flush pending save) runs
    /// on `.main` and can safely touch `@MainActor`-isolated state. `deinit`
    /// only removes this opaque token (no isolated access).
    ///
    /// Invariant: this observer must fire BEFORE `deinit`. The TrashStore
    /// lives as long as NSApp (held via `ClipboardStore.shared` singleton),
    /// so willTerminate always fires first under normal termination.
    /// SIGKILL / power-loss paths are out of scope (no write-through
    /// guarantee). See 2026-07-28 F-1 phase 2 spec §4.
    private var willTerminateObserver: NSObjectProtocol?

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
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Runs on .main queue → safe to access isolated state.
            // Delegate to `handleWillTerminate()` (NOT inline duplicate) so
            // the production path is exactly what tests exercise; any future
            // bugfix in handleWillTerminate automatically applies here.
            self?.handleWillTerminate()
        }
    }

    /// Internal: the actual willTerminate handler body. Extracted so tests
    /// can pin the contract without `NotificationCenter.post` global side
    /// effects (which would fire NSApp + AppDelegate observers).
    func handleWillTerminate() {
        saveTimer?.cancel()
        if needsSave { saveTrashedItems() }
    }

    deinit {
        // Nonisolated deinit reads opaque token (no isolated state touched).
        // All cleanup that touches `@MainActor` state lives in the
        // willTerminate handler registered above.
        if let observer = willTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // ID-LIFE-0001 (2026-07-30 audit): cancel saveTimer in deinit.
        // In tests (no NSApplication.willTerminate), the store deallocates
        // before the timer fires; DispatchSourceTimer + queue + closure stay
        // retained until next fire (500 ms). DispatchSourceTimer.cancel()
        // is Sendable so this is safe from a nonisolated deinit. Mirrors
        // the ClipboardStore.deinit pattern (line 491).
        saveTimer?.cancel()
    }

    // MARK: - Persistence

    func loadTrashedItems() {
        do {
            trashedItems = try backend.load()
        } catch {
            quarantineCorruptBlob(error: error)
            trashedItems = []
        }
    }

    // ID-PERF-0009 (2026-07-30 audit): same fix as ClipboardStore —
    // share a static `ISO8601DateFormatter` instead of allocating one
    // per quarantine call (~1 ms init each).
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func quarantineCorruptBlob(error: Error) {
        let defaults = UserDefaults.standard
        let key = Self.trashedItemsStorageKey
        guard let blob = defaults.data(forKey: key) else { return }
        let timestamp = Self.iso8601Formatter.string(from: Date())
        let quarantineKey = "\(key).corrupt-\(timestamp)"
        defaults.set(blob, forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        logger.error("Corrupt trash blob quarantined to \(quarantineKey): \(error.localizedDescription)")
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
            // ID-PERF-0005 (2026-07-30 audit): append + sort at end instead
            // of insert(at: 0) per item. For K items into an empty array the
            // old path was O(K^2); the new path is O(K log K) and matches
            // the per-item moveToTrash's eventual order (most-recent first).
            trashedItems.append(trashed)
        }
        trashedItems.sort { $0.deletedAt ?? .distantPast > $1.deletedAt ?? .distantPast }
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
