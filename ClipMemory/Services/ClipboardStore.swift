import Foundation
import AppKit
import os.log

extension Notification.Name {
    static let encryptionFailed = Notification.Name("ClipboardStore.encryptionFailed")
    static let showSettingsTab = Notification.Name("ClipMemory.showSettingsTab")
    static let cmdFFindAction = Notification.Name("ClipMemory.cmdFFindAction")
}

extension ClipboardStore: ClipboardMonitorDelegate {
    func sensitiveClearHoursForMonitor() -> Int {
        return sensitiveClearHours
    }
}

class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published var items: [ClipboardItem] = []
    @Published var pinnedItems: [ClipboardItem] = []

    /// User-defined tags keyed by UUID. Source of truth for tag definitions;
    /// ClipboardItem.tagIds holds only the IDs (Set<UUID>) for O(1) filter checks.
    /// Persistence is handled by `loadTags()` / `saveTags()`.
    @Published var tags: [UUID: Tag] = [:]

    // @Published with didSet for automatic UserDefaults persistence
    @Published var maxItems: Int {
        didSet { UserDefaults.standard.set(maxItems, forKey: maxItemsKey) }
    }

    @Published var sensitiveClearHours: Int {
        didSet { UserDefaults.standard.set(sensitiveClearHours, forKey: sensitiveClearHoursKey) }
    }

    @Published var captureRichText: Bool = true {
        didSet { UserDefaults.standard.set(captureRichText, forKey: captureRichTextKey) }
    }

    /// Comma-separated bundle IDs of apps excluded from clipboard monitoring
    @Published var excludedBundleIdsString: String {
        didSet {
            UserDefaults.standard.set(excludedBundleIdsString, forKey: excludedBundleIdsKey)
            updateExcludedAppsOnMonitor()
        }
    }

    /// 各日期分组未读（未固定）项目计数 — computed once per call from a single O(n) filter pass
    var todayCount: Int { groupCounts.today }
    var yesterdayCount: Int { groupCounts.yesterday }
    var olderCount: Int { groupCounts.older }

    private struct GroupCounts {
        var today: Int
        var yesterday: Int
        var older: Int
    }

    private var groupCounts: GroupCounts {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOfDayBeforeYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return GroupCounts(today: 0, yesterday: 0, older: 0)
        }
        var today = 0, yesterday = 0, older = 0
        for item in items where !item.isPinned {
            if item.createdAt >= startOfToday {
                today += 1
            } else if item.createdAt >= startOfYesterday {
                yesterday += 1
            } else {
                older += 1
            }
        }
        return GroupCounts(today: today, yesterday: yesterday, older: older)
    }

    private let maxItemsKey = "maxClipboardItems"
    private let sensitiveClearHoursKey = "sensitiveClearHours"
    private let captureRichTextKey = "captureRichText"
    private let excludedBundleIdsKey = "excludedBundleIds"
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "ClipboardStore")

    /// UserDefaults key for persisted tags. Public so tests can pre-populate or clean up.
    static let tagStorageKey = "ClipMemoryTags"

    /// E.1: Pluggable storage backend (default: FileStorageBackend via UserDefaults)
    private let backend: StorageBackend

    /// Separate storage backend for the tag dictionary. Defaults to an in-memory
    /// backend in tests; production wires a FileStorageBackend keyed by `tagStorageKey`.
    /// Keeping tags independent of items means clearing items doesn't lose tag
    /// definitions, and the item backend stays unaware of the tag schema.
    private let tagBackend: StorageBackend

    // MARK: - Initializers

    /// Default initializer — uses FileStorageBackend backed by UserDefaults for
    /// both items and tags (separate UserDefaults keys).
    convenience init() {
        self.init(backend: FileStorageBackend(),
                  tagBackend: FileStorageBackend(storageKey: ClipboardStore.tagStorageKey))
    }

    /// E.1: Designated initializer accepting a StorageBackend for testing.
    /// `tagBackend` defaults to a fresh in-memory backend so existing tests that
    /// only care about items don't accidentally hit UserDefaults.
    init(backend: StorageBackend, tagBackend: StorageBackend = MemoryStorageBackend()) {
        self.backend = backend
        self.tagBackend = tagBackend

        let savedMaxItems = UserDefaults.standard.integer(forKey: maxItemsKey)
        // Clamp to valid range [50, 100, 200, 500] to handle corrupted/migrated UserDefaults
        // Note: didSet is NOT called during init, so we must write to UserDefaults directly
        let validMaxItems = [50, 100, 200, 500]
        if validMaxItems.contains(savedMaxItems) {
            maxItems = savedMaxItems
        } else {
            maxItems = 100
            UserDefaults.standard.set(100, forKey: maxItemsKey)
        }

        if UserDefaults.standard.object(forKey: sensitiveClearHoursKey) != nil {
            sensitiveClearHours = UserDefaults.standard.integer(forKey: sensitiveClearHoursKey)
        } else {
            sensitiveClearHours = 24
        }

        excludedBundleIdsString = UserDefaults.standard.string(forKey: excludedBundleIdsKey) ?? "com.1password.1password,com.agilebits.onepassword7,com.bitwarden.desktop,com.keepassx.keeweb"

        // Register notification observer AFTER all properties are initialized
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImageMigrationCompleted(_:)),
            name: Notification.Name("ImageStorageMigrationCompleted"),
            object: nil
        )

        loadItems()
        loadTags()
        updateExcludedAppsOnMonitor()
        cleanupExpiredItems()
        let queue = DispatchQueue(label: "com.clipmemory.cleanup", qos: .background)
        cleanupTimer = DispatchSource.makeTimerSource(queue: queue)
        cleanupTimer?.schedule(deadline: .now() + 60, repeating: 60)
        cleanupTimer?.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.cleanupExpiredItems()
            }
        }
        cleanupTimer?.resume()
    }

    /// H2: NSCache for decrypted content — avoids repeated AES decryption on every view render.
    /// Thread-safety: all `items` mutations (addItem/deleteItem/etc.) are on main thread.
    /// cleanupExpiredItems is dispatched to the main thread from its timer so all
    /// reads and writes of `items` stay on the same queue.
    /// Memory pressure handling: cache evicts entries under memory pressure via NSCache's built-in behavior.
    /// Additionally, totalCostLimit caps memory at ~10MB (500 items × ~20KB each).

    private let contentCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        cache.totalCostLimit = 10 * 1024 * 1024 // 10MB limit
        return cache
    }()

    private var cleanupTimer: DispatchSourceTimer?
    private var saveTimer: DispatchSourceTimer?
    private var needsSave = false
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(500)

    deinit {
        cleanupTimer?.cancel()
        saveTimer?.cancel()
        flushSave()
    }

    /// Handles image migration completion — updates isEncrypted flags for migrated image items.
    @objc private func handleImageMigrationCompleted(_ notification: Notification) {
        guard let migratedFilenames = notification.userInfo?["migratedFilenames"] as? [String] else { return }
        let migratedSet = Set(migratedFilenames)

        var didMigrateAny = false
        for (index, item) in items.enumerated() where item.type == .image && migratedSet.contains(item.content) {
            items[index] = ClipboardItem(
                id: item.id,
                content: item.content,
                type: item.type,
                createdAt: item.createdAt,
                isPinned: item.isPinned,
                isSensitive: item.isSensitive,
                expiresAt: item.expiresAt,
                isEncrypted: true,
                contentHash: item.contentHash,
                decryptionFailed: item.decryptionFailed,
                tagIds: item.tagIds
            )
            didMigrateAny = true
        }

        if didMigrateAny {
            scheduleSave()
        }
    }

    /// Sync excluded bundle IDs from settings string to the clipboard monitor.
    /// Comparisons are case-insensitive because macOS bundle IDs are technically
    /// case-sensitive, but users frequently mis-type capitalization.
    func updateExcludedAppsOnMonitor() {
        let ids = Set(excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        clipboardMonitor?.excludedBundleIds = ids
    }

    func loadItems() {
        let savedItems: [ClipboardItem]
        do {
            savedItems = try backend.load()
        } catch {
            items = []
            return
        }
        let loadedItems = savedItems.filter { !$0.isExpired }

        // Migrate old-format encrypted items to v2 (AES-GCM)
        var migratedItems = loadedItems
        var needsMigrationSave = false
        for (index, item) in migratedItems.enumerated() where item.isEncrypted && item.type != .image {
            if ServiceContainer.crypto.isOldFormat(item.content),
               let newContent = ServiceContainer.crypto.migrateToV2(item.content) {
                migratedItems[index] = ClipboardItem(
                    id: item.id,
                    content: newContent,
                    type: item.type,
                    createdAt: item.createdAt,
                    isPinned: item.isPinned,
                    isSensitive: item.isSensitive,
                    expiresAt: item.expiresAt,
                    isEncrypted: true,
                    contentHash: item.contentHash,
                    decryptionFailed: item.decryptionFailed,
                    tagIds: item.tagIds
                )
                needsMigrationSave = true
            }
        }

        items = migratedItems
        updatePinnedItems()
        trimToMaxItems()
        ImageStorage.shared.cleanupOrphanedImages(keptItems: items)

        // Save migrated items immediately after load
        if needsMigrationSave {
            scheduleSave()
        }
    }

    func saveItems() {
        do {
            try backend.save(items)
        } catch {
            logger.error("Failed to save items: \(error.localizedDescription)")
        }
    }

    /// Schedules a debounced save — coalesces multiple rapid mutations into a single disk write.
    /// The actual write happens after `saveDebounceInterval` seconds of inactivity.
    private func scheduleSave() {
        needsSave = true
        saveTimer?.cancel()
        let queue = DispatchQueue(label: "com.clipmemory.save", qos: .utility)
        saveTimer = DispatchSource.makeTimerSource(queue: queue)
        saveTimer?.schedule(deadline: .now() + saveDebounceInterval)
        saveTimer?.setEventHandler { [weak self] in
            self?.flushSave()
        }
        saveTimer?.resume()
    }

    /// Flushes pending saves to disk immediately. Called by the debounce timer or on deinit.
    /// Exposed for testing via ClipboardStore(backend:) — tests can call this to force sync saves.
    func flushPendingSaves() {
        flushSave()
    }

    private func flushSave() {
        guard needsSave else { return }
        needsSave = false
        saveTimer?.cancel()
        saveTimer = nil
        saveItems()
    }

    /// Insert or replace a tag by its UUID. Tags with the same id overwrite
    /// (idempotent rename/recolor). Triggers a debounced tag save.
    func addTag(_ tag: Tag) {
        tags[tag.id] = tag
        scheduleTagSave()
    }

    /// Attach an existing tag (by id) to an item. Idempotent — adding the same
    /// tag twice is a no-op since tagIds is a Set. Schedules both item and tag
    /// persistence so the attachment survives app restarts.
    func addTag(to itemId: UUID, tagId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].tagIds.insert(tagId)
        scheduleSave()
    }

    /// Detach a tag from an item. Does not delete the tag itself; for that use
    /// deleteTag(id:). Safe to call when the tag isn't attached (no-op).
    func removeTag(from itemId: UUID, tagId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].tagIds.remove(tagId)
        scheduleSave()
    }

    /// Delete a tag definition AND strip its id from every item's tagIds set.
    /// This prevents dangling UUIDs (tag references that no longer resolve).
    /// Safe to call with an unknown id — no-op in that case. Triggers a
    /// debounced save for both tags and items.
    func deleteTag(id tagId: UUID) {
        guard tags.removeValue(forKey: tagId) != nil else { return }
        for index in items.indices where items[index].tagIds.contains(tagId) {
            items[index].tagIds.remove(tagId)
        }
        scheduleTagSave()
        scheduleSave()
    }

    /// Case-insensitive prefix search over tag names. Returns up to `limit`
    /// tags ordered by `createdAt` descending (most recent first), so the
    /// caller's autocomplete surfaces the user's own latest tag first.
    /// Empty prefix → empty result (autocomplete is opt-in).
    func tags(matchingPrefix prefix: String, limit: Int = 8) -> [Tag] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let needle = prefix.lowercased()
        return tags.values
            .filter { $0.name.lowercased().hasPrefix(needle) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Tag persistence

    /// Load the tag dictionary from the tag backend. Called once during init.
    /// Corrupted data is logged and treated as empty — better to lose tag defs
    /// than to crash on startup.
    func loadTags() {
        do {
            let loaded = decryptTagNames(try tagBackend.loadTags())
            tags = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            logger.error("Failed to load tags: \(error.localizedDescription)")
            tags = [:]
        }
    }

    /// Synchronously write the current tag dictionary to the tag backend.
    /// Names are encrypted at the persistence boundary while the in-memory
    /// `tags` dictionary stays plaintext for UI use.
    func saveTags() {
        do {
            try tagBackend.saveTags(encryptTagNames(Array(tags.values)))
        } catch {
            logger.error("Failed to save tags: \(error.localizedDescription)")
        }
    }

    // MARK: - Tag name encryption helpers

    /// Marker prefixed to encrypted tag names so `decryptTagNames` can tell
    /// them apart from plaintext names. Base64 itself never contains a colon,
    /// so "v2:" is unambiguous with encoded ciphertext.
    private static let encryptedNamePrefix = "v2:"

    /// Encrypt tag names for disk storage. Already-encrypted names are skipped
    /// to avoid double-encryption if a save is called twice in a row.
    private func encryptTagNames(_ tags: [Tag]) -> [Tag] {
        tags.map { tag in
            guard !tag.name.hasPrefix(Self.encryptedNamePrefix),
                  let encryptedName = ServiceContainer.crypto.encrypt(tag.name) else {
                return tag
            }
            return Tag(
                id: tag.id,
                name: Self.encryptedNamePrefix + encryptedName,
                colorHex: tag.colorHex,
                isAutoSuggested: tag.isAutoSuggested,
                createdAt: tag.createdAt
            )
        }
    }

    /// Decrypt tag names loaded from disk. Plaintext names (legacy or tests)
    /// are returned unchanged.
    private func decryptTagNames(_ tags: [Tag]) -> [Tag] {
        tags.map { tag in
            guard tag.name.hasPrefix(Self.encryptedNamePrefix) else {
                return tag
            }
            let ciphertext = String(tag.name.dropFirst(Self.encryptedNamePrefix.count))
            guard let decrypted = ServiceContainer.crypto.decrypt(ciphertext) else {
                logger.error("Failed to decrypt tag name for \(tag.id); using placeholder")
                return Tag(
                    id: tag.id,
                    name: "[locked]",
                    colorHex: tag.colorHex,
                    isAutoSuggested: tag.isAutoSuggested,
                    createdAt: tag.createdAt
                )
            }
            return Tag(
                id: tag.id,
                name: decrypted,
                colorHex: tag.colorHex,
                isAutoSuggested: tag.isAutoSuggested,
                createdAt: tag.createdAt
            )
        }
    }

    /// Debounced tag save — coalesces rapid mutations (addTag/deleteTag) into
    /// one write, mirroring the existing scheduleSave() pattern for items.
    private var tagSaveTimer: DispatchSourceTimer?
    private var tagNeedsSave = false
    private func scheduleTagSave() {
        tagNeedsSave = true
        tagSaveTimer?.cancel()
        let queue = DispatchQueue(label: "com.clipmemory.tagsave", qos: .utility)
        tagSaveTimer = DispatchSource.makeTimerSource(queue: queue)
        tagSaveTimer?.schedule(deadline: .now() + saveDebounceInterval)
        tagSaveTimer?.setEventHandler { [weak self] in
            self?.flushTagSave()
        }
        tagSaveTimer?.resume()
    }

    private func flushTagSave() {
        guard tagNeedsSave else { return }
        tagNeedsSave = false
        tagSaveTimer?.cancel()
        tagSaveTimer = nil
        saveTags()
    }

    func addItem(_ item: ClipboardItem) {
        var newItem = item
        let plaintextContent = item.content
        var newHash: String?

        // M3: Always encrypt text and link content (images are encrypted by ImageStorage)
        if item.type != .image {
            if let encrypted = ServiceContainer.crypto.encrypt(item.content) {
                newHash = ServiceContainer.crypto.hmacHex(for: plaintextContent) ?? ""
                newItem = ClipboardItem(
                    id: item.id,
                    content: encrypted,
                    type: item.type,
                    createdAt: item.createdAt,
                    isPinned: item.isPinned,
                    isSensitive: item.isSensitive,
                    expiresAt: item.expiresAt,
                    isEncrypted: true,
                    contentHash: newHash
                )
            } else {
                // N2: Encrypt failed — do NOT store as plaintext (security violation)
                // Discard item to protect sensitive data instead
                logger.error("Encryption failed for sensitive item, discarding to protect data")
                NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                return
            }
        }

        // Use contentHash for fast pre-filter before expensive decryption
        if let existingIndex = items.firstIndex(where: { existing in
            // Type must match
            guard existing.type == newItem.type else { return false }
            // If both have contentHash, compare hashes first (avoids decryption)
            if let existingHash = existing.contentHash, existingHash == newHash {
                return true
            }
            // Fall back to decrypt-and-compare for items without contentHash
            let existingPlaintext = existing.isEncrypted ? (ServiceContainer.crypto.decrypt(existing.content) ?? existing.content) : existing.content
            return existingPlaintext == plaintextContent
        }) {
            var existing = items.remove(at: existingIndex)
            existing = ClipboardItem(
                id: existing.id,
                content: existing.content,
                type: existing.type,
                createdAt: Date(),
                isPinned: existing.isPinned,
                isSensitive: existing.isSensitive,
                expiresAt: existing.expiresAt,
                isEncrypted: existing.isEncrypted,
                contentHash: existing.contentHash,
                // HIGH-1 fix (a00da7c follow-up): preserve decryptionFailed flag
                // through dedup rebuild — otherwise the a00da7c perf fix is
                // silently undone every time the same corrupt content is re-copied.
                decryptionFailed: existing.decryptionFailed,
                tagIds: existing.tagIds
            )
            items.insert(existing, at: 0)
        } else {
            items.insert(newItem, at: 0)
        }

        trimToMaxItems()
        updatePinnedItems()
        scheduleSave()
    }

    func getDecryptedContent(_ item: ClipboardItem) -> String? {
        let key = item.id.uuidString as NSString
        if let cached = contentCache.object(forKey: key) {
            return cached as String
        }
        let result: String?
        if item.isEncrypted {
            result = ServiceContainer.crypto.decrypt(item.content)
        } else {
            result = item.content
        }
        if let result = result {
            contentCache.setObject(result as NSString, forKey: key)
        } else if item.isEncrypted {
            // Mark the in-store copy so subsequent `isDecryptionFailed` reads
            // are O(1) instead of re-triggering AES decrypt on every access.
            // Must publish on the main thread because `items` is @Published.
            let markFailed = { [weak self] in
                guard let self = self else { return }
                if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[index].decryptionFailed = true
                    self.scheduleSave()
                }
            }
            if Thread.isMainThread {
                markFailed()
            } else {
                DispatchQueue.main.async(execute: markFailed)
            }
        }
        return result
    }

    func trimToMaxItems() {
        guard items.count > maxItems else { return }
        let pinned = items.filter { $0.isPinned }
        var nonPinned = items.filter { !$0.isPinned }
        let trimmedPinned = pinned.count > maxItems ? Array(pinned.prefix(maxItems)) : pinned
        let allowedNonPinned = max(0, maxItems - trimmedPinned.count)
        nonPinned = Array(nonPinned.prefix(allowedNonPinned))
        let trimmed = trimmedPinned + nonPinned
        let trimmedIds = Set(trimmed.map { $0.id })
        let removedItems = items.filter { !trimmedIds.contains($0.id) }
        for item in removedItems {
            contentCache.removeObject(forKey: item.id.uuidString as NSString)
        }
        let removedImages = removedItems.filter { $0.type == .image }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items = trimmed
        updatePinnedItems()
        scheduleSave()
    }

    func deleteItem(_ item: ClipboardItem) {
        contentCache.removeObject(forKey: item.id.uuidString as NSString)
        if item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { $0.id == item.id }
        updatePinnedItems()
        scheduleSave()
    }

    func togglePin(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].isPinned.toggle()
            trimToMaxItems()
            updatePinnedItems()
            scheduleSave()
        }
    }

    func togglePinItems(_ itemsToToggle: [ClipboardItem]) {
        for item in itemsToToggle {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].isPinned.toggle()
            }
        }
        trimToMaxItems()
        updatePinnedItems()
        scheduleSave()
    }

    func deleteItems(_ itemsToDelete: [ClipboardItem]) {
        for item in itemsToDelete {
            contentCache.removeObject(forKey: item.id.uuidString as NSString)
        }
        let filenames = itemsToDelete.filter { $0.type == .image }.map { $0.content }
        for filename in filenames {
            ImageStorage.shared.deleteImage(filename: filename)
        }
        let idsToDelete = Set(itemsToDelete.map { $0.id })
        items.removeAll { idsToDelete.contains($0.id) }
        updatePinnedItems()
        scheduleSave()
    }

    func deleteItems(where predicate: (ClipboardItem) -> Bool) {
        let toDelete = items.filter(predicate)
        deleteItems(toDelete)
    }

    func unpinAll() {
        for i in items.indices {
            items[i].isPinned = false
        }
        updatePinnedItems()
        scheduleSave()
    }

    func unpinToday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()
        unpinItems { $0.createdAt >= startOfToday && $0.createdAt < endOfToday }
    }

    func unpinYesterday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        unpinItems { $0.createdAt >= startOfYesterday && $0.createdAt < startOfToday }
    }

    func unpinOlder() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfDayBeforeYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        unpinItems { $0.createdAt < startOfDayBeforeYesterday }
    }

    private func unpinItems(where predicate: (ClipboardItem) -> Bool) {
        for i in items.indices where predicate(items[i]) && items[i].isPinned {
            items[i].isPinned = false
        }
        updatePinnedItems()
        scheduleSave()
    }

    func clearSensitiveItems() {
        let toRemove = items.filter { $0.isSensitive && !$0.isPinned }
        for item in toRemove {
            contentCache.removeObject(forKey: item.id.uuidString as NSString)
        }
        let removedImages = toRemove.filter { $0.type == .image }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { $0.isSensitive && !$0.isPinned }
        updatePinnedItems()
        scheduleSave()
    }

    func clearAllItems() {
        let pinnedIds = Set(pinnedItems.map { $0.id })
        let toRemove = items.filter { !pinnedIds.contains($0.id) }
        for item in toRemove {
            contentCache.removeObject(forKey: item.id.uuidString as NSString)
        }
        let removedImages = toRemove.filter { $0.type == .image }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { !pinnedIds.contains($0.id) }
        updatePinnedItems()
        scheduleSave()
    }

    /// 清除今日的所有非置顶项目
    func clearToday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()
        deleteItems { item in
            !item.isPinned && item.createdAt >= startOfToday && item.createdAt < endOfToday
        }
    }

    /// 清除昨天的所有非置顶项目
    func clearYesterday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        deleteItems { item in
            !item.isPinned && item.createdAt >= startOfYesterday && item.createdAt < startOfToday
        }
    }

    /// 清除更早（昨天之前）的所有非置顶项目
    func clearOlder() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfDayBeforeYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        deleteItems { item in
            !item.isPinned && item.createdAt < startOfDayBeforeYesterday
        }
    }

    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general

        // Prepare content first, then clear + write (prevents data loss if prepare fails)
        var preparedImage: NSImage?
        var preparedText: String?
        var preparedRtfData: Data?

        switch item.type {
        case .image:
            preparedImage = ImageStorage.shared.loadImageObject(filename: item.content)
        case .richText:
            if let base64 = getDecryptedContent(item), let data = Data(base64Encoded: base64) {
                preparedRtfData = data
                preparedText = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string
            }
        default:
            preparedText = getDecryptedContent(item)
        }

        guard (preparedImage != nil) || (preparedText != nil) || (preparedRtfData != nil) else { return }

        pasteboard.clearContents()

        if let image = preparedImage {
            pasteboard.writeObjects([image as NSImage])
        } else if let rtfData = preparedRtfData {
            pasteboard.setData(rtfData, forType: .rtf)
            if let text = preparedText {
                pasteboard.setString(text, forType: .string)
            }
        } else if let text = preparedText {
            pasteboard.setString(text, forType: .string)
        }

        // Update changeCount immediately to prevent ClipboardMonitor from re-capturing
        // what we just wrote. This breaks the copy → re-capture → duplicate loop.
        if let monitor = clipboardMonitor {
            monitor.recordOwnWrite()
        }
        moveToTop(item)
    }

    // Injected by AppDelegate so copyToClipboard can break the re-capture loop
    var clipboardMonitor: ClipboardMonitor?

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
            isEncrypted: moved.isEncrypted,
            contentHash: moved.contentHash,
            decryptionFailed: moved.decryptionFailed,
            tagIds: moved.tagIds
        )
        items.insert(moved, at: 0)
        scheduleSave()
    }

    private func updatePinnedItems() {
        pinnedItems = items.filter { $0.isPinned }
    }

    private func cleanupExpiredItems() {
        let expiredImageFilenames = items.filter { $0.isExpired && $0.type == .image }.map { $0.content }
        let expiredIds = Set(items.filter { $0.isExpired }.map { $0.id })
        if expiredImageFilenames.isEmpty && expiredIds.isEmpty { return }

        for filename in expiredImageFilenames {
            ImageStorage.shared.deleteImage(filename: filename)
        }
        for id in expiredIds {
            contentCache.removeObject(forKey: id.uuidString as NSString)
        }
        let beforeCount = items.count
        items.removeAll { expiredIds.contains($0.id) }
        if items.count != beforeCount {
            updatePinnedItems()
            scheduleSave()
        }
    }
}
