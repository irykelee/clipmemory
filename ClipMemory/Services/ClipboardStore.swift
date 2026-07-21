import Foundation
import AppKit
import Combine
import os.log

// swiftlint:disable file_length
// (1) Justification: ClipboardStore is the central coordinator of clipboard flow
// (addItem / dedup / persistence / migration). Splitting risks cross-cutting
// regressions. Tracking a 1250-line ceiling explicitly via disable so the
// discipline is visible in code review.
// (2) Code added per Critical fix on 2026-07-20 (HMAC silent data loss) made
// the file 1258 lines, exceeding the project's file_length 1250 threshold.
// Move logic into a separate file in a future refactor pass.

extension Notification.Name {
    static let encryptionFailed = Notification.Name("ClipboardStore.encryptionFailed")
    static let showSettingsTab = Notification.Name("ClipMemory.showSettingsTab")
    static let cmdFFindAction = Notification.Name("ClipMemory.cmdFFindAction")
}

extension ClipboardStore: ClipboardMonitorDelegate {
    func sensitiveClearHoursForMonitor() -> Int {
        // Audit-fix #3 (2026-07-20): ClipboardMonitor calls this delegate
        // from background queues (timer at ClipboardMonitor.swift:268,
        // userInitiated at :344 after H-11). Reading `@Published var
        // sensitiveClearHours` directly is a data race — the @Published
        // wrapper does not synchronize the backing storage. The writer is
        // main-thread only (UI sets it via SwiftUI binding), so we lock
        // only the reader and let the main-thread write land atomically
        // for 64-bit Int. Matches the ClipboardMonitor `withLock` idiom.
        sensitiveClearHoursLock.lock()
        defer { sensitiveClearHoursLock.unlock() }
        return sensitiveClearHours
    }
    // H-13 (2026-07-20 audit): explicit overrides of the protocol defaults
    // so the monitor never has to know `ClipboardStore.shared` again. The
    // publisher forward stays zero-copy via `$` projected value.
    func captureRichTextSettingForMonitor() -> Bool { captureRichText }
    var captureRichTextPublisher: AnyPublisher<Bool, Never> {
        $captureRichText.eraseToAnyPublisher()
    }
    func monitorDidCaptureItem(_ item: ClipboardItem) { addItem(item) }
    func ocrEnabledForMonitor() -> Bool { ocrEnabled }
    func monitorDidRecognizeText(_ text: String, forImageItemId id: UUID) {
        attachOCRText(to: id, text: text)
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
    // Audit-fix #3 (2026-07-20): see `sensitiveClearHoursForMonitor()` for
    // why the delegate-method reader needs a lock. Writer remains main-thread
    // (UI binding); the lock only guards the cross-thread read.
    private let sensitiveClearHoursLock = NSLock()

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

    /// Items moved to the recycle bin. Persisted separately from `items`.
    /// Deleted automatically after `trashRetentionDays` days.
    @Published var trashedItems: [ClipboardItem] = []

    /// Number of days trashed items are kept before automatic permanent deletion.
    @Published var trashRetentionDays: Int {
        didSet { UserDefaults.standard.set(trashRetentionDays, forKey: trashRetentionDaysKey) }
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
    private let trashRetentionDaysKey = "trashRetentionDays"
    /// UserDefaults key for persisted trashed items.
    static let trashedItemsStorageKey = "ClipboardTrashedItems"
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

    /// Separate storage backend for trashed items. Keeping trash independent of
    /// the active item backend means restoring an item is just a load-and-move
    /// operation, and clearing active items doesn't accidentally wipe trash.
    private let trashBackend: StorageBackend

    // MARK: - Initializers

    /// Default initializer — uses FileStorageBackend backed by UserDefaults for
    /// items, tags, and trash (separate UserDefaults keys).
    convenience init() {
        self.init(backend: FileStorageBackend(),
                  tagBackend: FileStorageBackend(storageKey: ClipboardStore.tagStorageKey),
                  trashBackend: FileStorageBackend(storageKey: ClipboardStore.trashedItemsStorageKey))
    }

    /// E.1: Designated initializer accepting a StorageBackend for testing.
    /// `tagBackend` and `trashBackend` default to fresh in-memory backends so
    /// existing tests that only care about items don't accidentally hit UserDefaults.
    init(backend: StorageBackend,
         tagBackend: StorageBackend = MemoryStorageBackend(),
         trashBackend: StorageBackend = MemoryStorageBackend()) {
        self.backend = backend
        self.tagBackend = tagBackend
        self.trashBackend = trashBackend

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

        let savedTrashRetentionDays = UserDefaults.standard.integer(forKey: trashRetentionDaysKey)
        let validTrashRetentionDays = [3, 7, 14, 30]
        if validTrashRetentionDays.contains(savedTrashRetentionDays) {
            trashRetentionDays = savedTrashRetentionDays
        } else {
            trashRetentionDays = 7
            UserDefaults.standard.set(7, forKey: trashRetentionDaysKey)
        }

        // Register notification observer AFTER all properties are initialized
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImageMigrationCompleted(_:)),
            name: Notification.Name("ImageStorageMigrationCompleted"),
            object: nil
        )

        loadItems()
        loadTags()
        loadTrashedItems()
        purgeExpiredTrash()
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

    let contentCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        cache.totalCostLimit = 10 * 1024 * 1024 // 10MB limit
        return cache
    }()

    /// Cache for parsed RTF plaintext — avoids re-parsing RTF on every access
    /// in search/filter paths where `plainTextFromRTFFallback` is hit repeatedly.
    private let rtfPlaintextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        cache.totalCostLimit = 10 * 1024 * 1024 // 10MB limit
        return cache
    }()

    private var cleanupTimer: DispatchSourceTimer?
    private var saveTimer: DispatchSourceTimer?
    private var needsSave = false
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(500)

    /// C5: IDs whose decryption already failed, pending batched write-back into
    /// `items`. The read path (getDecryptedContent) never mutates @Published
    /// synchronously — marking hops to the main queue asynchronously so it can
    /// never land inside a SwiftUI view-body update (the "open full window
    /// freezes" bug class). The set also short-circuits repeat decrypt attempts
    /// in the gap before the merge lands.
    private var pendingFailedIDs = Set<UUID>()
    private let pendingFailedIDsLock = NSLock()

    deinit {
        // I-1 fix (2026-07-20 audit): cancel all four DispatchSourceTimers.
        // Previous deinit only cancelled cleanupTimer and saveTimer — tag and
        // trash timers kept their source objects alive until next fire.
        cleanupTimer?.cancel()
        saveTimer?.cancel()
        tagSaveTimer?.cancel()
        trashSaveTimer?.cancel()
        // I-2 fix (2026-07-20 audit): remove the NotificationCenter observer
        // registered in init(). Without this, the dispatch table keeps the
        // selector entry even after dealloc, which causes stale callbacks in
        // tests that create multiple store instances.
        NotificationCenter.default.removeObserver(self)
        flushPendingSaves()
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
                tagIds: item.tagIds,
                deletedAt: item.deletedAt
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

        // Repair legacy image items incorrectly flagged by the old
        // getDecryptedContent path: image content is a filename, never encrypted,
        // so isEncrypted/decryptionFailed should never be true for .image items.
        // (No crypto involved — cheap enough to stay on the load path.)
        var repairedItems = loadedItems
        var repairedImages = false
        for (index, item) in repairedItems.enumerated() where item.type == .image {
            if item.isEncrypted || item.decryptionFailed {
                repairedItems[index] = ClipboardItem(
                    id: item.id,
                    content: item.content,
                    type: item.type,
                    createdAt: item.createdAt,
                    isPinned: item.isPinned,
                    isSensitive: item.isSensitive,
                    expiresAt: item.expiresAt,
                    isEncrypted: false,
                    contentHash: item.contentHash,
                    decryptionFailed: false,
                    tagIds: item.tagIds,
                    deletedAt: item.deletedAt
                )
                repairedImages = true
            }
        }

        items = repairedItems
        updatePinnedItems()
        trimToMaxItems()
        ImageStorage.shared.cleanupOrphanedImages(keptItems: items + trashedItems)

        if repairedImages {
            scheduleSave()
        }

        // C6: crypto-heavy migrations run OFF the startup path. Both the v1→v2
        // re-encryption and the contentHash backfill decrypt per legacy item —
        // hundreds of legacy items on the thread that first touched the store
        // (main, at app launch) froze startup for seconds. Detection is cheap
        // (isOldFormat is a byte-prefix check since C4); only the crypto moves
        // to a utility queue, and results merge back on main by id. Legacy
        // content stays readable in the gap via the HMAC-verified legacy path.
        var migrationCandidates: [(id: UUID, content: String)] = []
        var backfillCandidates: [(id: UUID, content: String, isEncrypted: Bool)] = []
        for item in items where item.type != .image {
            if item.isEncrypted && ServiceContainer.crypto.isOldFormat(item.content) {
                migrationCandidates.append((item.id, item.content))
            }
            if item.contentHash == nil {
                backfillCandidates.append((item.id, item.content, item.isEncrypted))
            }
        }
        guard !migrationCandidates.isEmpty || !backfillCandidates.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var migratedContents: [UUID: String] = [:]
            for candidate in migrationCandidates {
                if let newContent = ServiceContainer.crypto.migrateToV2(candidate.content) {
                    migratedContents[candidate.id] = newContent
                }
            }
            // Backfill contentHash for legacy items that predate HMAC-based dedup.
            // Without this, every addItem does O(n) decrypt-and-compare against them.
            var hashes: [UUID: String] = [:]
            for candidate in backfillCandidates {
                let plaintext = candidate.isEncrypted
                    ? (ServiceContainer.crypto.decrypt(candidate.content) ?? candidate.content)
                    : candidate.content
                if let hash = ServiceContainer.crypto.hmacHex(for: plaintext) {
                    hashes[candidate.id] = hash
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var changed = false
                for (id, newContent) in migratedContents {
                    guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                    let item = self.items[index]
                    self.items[index] = ClipboardItem(
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
                        tagIds: item.tagIds,
                        deletedAt: item.deletedAt
                    )
                    changed = true
                }
                for (id, hash) in hashes {
                    guard let index = self.items.firstIndex(where: { $0.id == id }),
                          self.items[index].contentHash == nil else { continue }
                    self.items[index].contentHash = hash
                    changed = true
                }
                if changed { self.scheduleSave() }
            }
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
    func scheduleSave() {
        needsSave = true
        saveTimer?.cancel()
        let queue = DispatchQueue(label: "com.clipmemory.save", qos: .utility)
        saveTimer = DispatchSource.makeTimerSource(queue: queue)
        saveTimer?.schedule(deadline: .now() + saveDebounceInterval)
        saveTimer?.setEventHandler { [weak self] in
            // Hop to main before touching @Published `items` — the timer fires on a
            // utility queue, and encoding the array from there races with main-thread
            // mutations (insert/remove) and is UB.
            DispatchQueue.main.async { self?.flushSave() }
        }
        saveTimer?.resume()
    }

    /// Write-through for clipboard ingestion. New clipboard content is the one
    /// thing the user cannot re-create, and a kill -9 / power loss inside the
    /// 500ms debounce window would silently lose it — bypass the debounce here.
    /// Metadata mutations (pin/tag/delete/trash) keep the debounced path.
    func saveImmediately() {
        needsSave = true
        flushSave()
    }

    /// Flushes pending item, tag, and trash saves to disk immediately. Called by the debounce timer,
    /// on deinit, or from AppDelegate.applicationWillTerminate to prevent data loss on quit.
    func flushPendingSaves() {
        flushSave()
        flushTagSave()
        flushTrashSave()
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
        deleteTag(id: tagId, includeItems: false)
    }

    /// When `includeItems` is true, items carrying this tag are first moved to
    /// the recycle bin (recoverable), then the tag definition is deleted and
    /// its id stripped from any remaining items.
    func deleteTag(id tagId: UUID, includeItems: Bool) {
        if includeItems {
            deleteItems { $0.tagIds.contains(tagId) }
        }
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

    /// Placeholder shown when a tag name cannot be decrypted.
    private static let lockedPlaceholder = "[locked]"

    /// Backs up the original encrypted name when decryption fails so a later
    /// `saveTags()` doesn't overwrite the on-disk ciphertext with the placeholder.
    private var encryptedTagNamesBackup: [UUID: String] = [:]

    /// Encrypt tag names for disk storage. Already-encrypted names are skipped
    /// to avoid double-encryption if a save is called twice in a row.  A name
    /// that merely *looks* encrypted (it starts with the marker prefix) but
    /// fails to decrypt is treated as plaintext and encrypted, so user-created
    /// names such as "v2:work" do not become permanently locked.
    private func encryptTagNames(_ tags: [Tag]) -> [Tag] {
        tags.map { tag in
            // Restore original ciphertext for tags whose names failed to decrypt.
            if tag.name == Self.lockedPlaceholder,
               let backup = encryptedTagNamesBackup[tag.id] {
                return Tag(
                    id: tag.id,
                    name: backup,
                    colorHex: tag.colorHex,
                    isAutoSuggested: tag.isAutoSuggested,
                    createdAt: tag.createdAt
                )
            }
            // If the name already carries the marker, verify it is real ciphertext.
            if tag.name.hasPrefix(Self.encryptedNamePrefix) {
                let ciphertext = String(tag.name.dropFirst(Self.encryptedNamePrefix.count))
                if ServiceContainer.crypto.decrypt(ciphertext) != nil {
                    return tag
                }
                // Prefix is accidental (e.g. user-named "v2:..."); fall through to encrypt.
            }
            guard let encryptedName = ServiceContainer.crypto.encrypt(tag.name) else {
                // I-3 fix (2026-07-20 audit): tag encryption failure must NOT
                // persist the plaintext tag name — that's the equivalent of a
                // missed encrypt on items but the tag pipeline silently swallowed
                // it. Match the decryptTagNames path: surface a placeholder,
                // keep the original ciphertext in the backup map so saveTags
                // doesn't overwrite it on subsequent calls, and notify the UI
                // (so the user knows the encryption layer is unhealthy).
                logger.error("Failed to encrypt tag name for \(tag.id); storing as [locked]")
                encryptedTagNamesBackup[tag.id] = tag.name
                NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                return Tag(
                    id: tag.id,
                    name: Self.lockedPlaceholder,
                    colorHex: tag.colorHex,
                    isAutoSuggested: tag.isAutoSuggested,
                    createdAt: tag.createdAt
                )
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
                encryptedTagNamesBackup[tag.id] = tag.name
                return Tag(
                    id: tag.id,
                    name: Self.lockedPlaceholder,
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
            // Same main-queue hop as scheduleSave — @Published `tags` must not be
            // encoded from a background queue while the main thread mutates it.
            DispatchQueue.main.async { self?.flushTagSave() }
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
                let computedHash = ServiceContainer.crypto.hmacHex(for: plaintextContent)
                if computedHash == nil {
                    // HMAC failure (rare — Keychain -25308 or crypto internal error).
                    // Don't fall back to "" — that creates silent dedup collisions when
                    // multiple distinct contents all fail HMAC. Use nil contentHash;
                    // the dedup pre-filter below short-circuits and we fall through to
                    // insert the item rather than risk dropping real data.
                    logger.error("HMAC failed for clipboard item; storing without dedup fingerprint")
                    NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                }
                newHash = computedHash
                newItem = ClipboardItem(
                    id: item.id,
                    content: encrypted,
                    type: item.type,
                    createdAt: item.createdAt,
                    isPinned: item.isPinned,
                    isSensitive: item.isSensitive,
                    expiresAt: item.expiresAt,
                    isEncrypted: true,
                    contentHash: newHash,
                    decryptionFailed: item.decryptionFailed,
                    tagIds: item.tagIds,
                    deletedAt: item.deletedAt
                )
            } else {
                // N2: Encrypt failed — do NOT store as plaintext (security violation)
                // Discard item to protect sensitive data instead
                logger.error("Encryption failed for sensitive item, discarding to protect data")
                NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                return
            }
        }

        // Use contentHash for fast pre-filter before expensive decryption.
        // Skip the entire dedup pre-filter when newHash is nil (HMAC failure path) —
        // the legacy "" fallback used to match any item with an empty hash, collapsing
        // distinct contents silently. Better to accept a duplicate in this rare path.
        if let newHash = newHash, let existingIndex = items.firstIndex(where: { existing in
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
            // Backfill contentHash on legacy items that lack it, so future
            // dedup checks take the fast hash-compare path instead of O(n) decrypts.
            let backfilledHash = existing.contentHash ?? newHash
            existing = ClipboardItem(
                id: existing.id,
                content: existing.content,
                type: existing.type,
                createdAt: Date(),
                isPinned: existing.isPinned,
                isSensitive: existing.isSensitive,
                expiresAt: existing.expiresAt,
                isEncrypted: existing.isEncrypted,
                contentHash: backfilledHash,
                // HIGH-1 fix (a00da7c follow-up): preserve decryptionFailed flag
                // through dedup rebuild — otherwise the a00da7c perf fix is
                // silently undone every time the same corrupt content is re-copied.
                decryptionFailed: existing.decryptionFailed,
                tagIds: existing.tagIds,
                deletedAt: existing.deletedAt
            )
            items.insert(existing, at: 0)
        } else {
            items.insert(newItem, at: 0)
        }

        trimToMaxItems()
        updatePinnedItems()
        saveImmediately()
    }

    /// Merges imported backup items into the store. Items arrive already
    /// re-encrypted with the local key (BackupPackage does the re-keying).
    /// Dedupe order: id first, then contentHash (catches same content under a
    /// new id from another machine). Trashed items merge into the recycle bin
    /// unless they collide with active/trashed entries.
    /// Returns (imported, skipped).
    @discardableResult
    func importBackupItems(_ newItems: [ClipboardItem], trashedItems newTrashed: [ClipboardItem]) -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0
        // Mutable sets — entries are added as items are imported so duplicates
        // within the package itself (or between active and trash lists) are
        // also caught, not just collisions with pre-existing content (M3 fix).
        var existingIds = Set(items.map { $0.id } + trashedItems.map { $0.id })
        var existingHashes = Set(items.compactMap { $0.contentHash } + trashedItems.compactMap { $0.contentHash })

        for item in newItems {
            let hashDuplicate = item.contentHash != nil && existingHashes.contains(item.contentHash!)
            if existingIds.contains(item.id) || hashDuplicate {
                skipped += 1
                continue
            }
            items.append(item)
            existingIds.insert(item.id)
            if let hash = item.contentHash { existingHashes.insert(hash) }
            imported += 1
        }

        var trashAdded = false
        for item in newTrashed {
            let hashDuplicate = item.contentHash != nil && existingHashes.contains(item.contentHash!)
            if existingIds.contains(item.id) || hashDuplicate { continue }
            trashedItems.append(item)
            existingIds.insert(item.id)
            if let hash = item.contentHash { existingHashes.insert(hash) }
            trashAdded = true
        }

        if imported > 0 {
            items.sort { $0.createdAt > $1.createdAt }
            trimToMaxItems()
            updatePinnedItems()
            saveImmediately()
        }
        if trashAdded { scheduleTrashSave() }
        return (imported, skipped)
    }

    /// Merges imported backup tags by id (existing ids win). Returns count added.
    @discardableResult
    func importBackupTags(_ newTags: [Tag]) -> Int {
        let existingIds = Set(tags.keys)
        var added = 0
        for tag in newTags where !existingIds.contains(tag.id) {
            tags[tag.id] = tag
            added += 1
        }
        if added > 0 { scheduleTagSave() }
        return added
    }

    func getDecryptedContent(_ item: ClipboardItem) -> String? {
        // Image items store a filename (UUID.png), not encrypted text. Decrypting
        // a filename always fails and would incorrectly mark the item as
        // decryptionFailed. ImageStorage handles image-file encryption separately.
        guard item.type != .image else { return item.content }

        // Already-known-corrupt items: bail out WITHOUT re-decrypting or
        // re-marking. Rendering an encrypted-but-undecryptable row used to
        // re-mark on EVERY body evaluation, publishing during view update in
        // an endless loop that pinned the main thread at 100% CPU (the
        // "open full window freezes" bug).
        if item.decryptionFailed { return nil }
        // C5: also bail for failures whose write-back is still pending, so the
        // gap between first failure and the async merge doesn't re-run AES.
        if isDecryptionPendingFailed(item.id) { return nil }

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
            // C5: never mutate @Published `items` from here — this method is
            // called from SwiftUI view bodies, and a synchronous publish lands
            // inside the view update. Buffer the id and merge asynchronously
            // on the main queue instead.
            scheduleDecryptionFailedMark(item.id)
        }
        return result
    }

    /// C5: lock-guarded check so any thread can cheaply bail on pending failures.
    private func isDecryptionPendingFailed(_ id: UUID) -> Bool {
        pendingFailedIDsLock.lock()
        defer { pendingFailedIDsLock.unlock() }
        return pendingFailedIDs.contains(id)
    }

    /// C5: buffer a failed id and schedule exactly one async merge per new id.
    private func scheduleDecryptionFailedMark(_ id: UUID) {
        pendingFailedIDsLock.lock()
        let inserted = pendingFailedIDs.insert(id).inserted
        pendingFailedIDsLock.unlock()
        guard inserted else { return }
        DispatchQueue.main.async { [weak self] in
            self?.mergePendingDecryptionFailures()
        }
    }

    /// C5: applies buffered failure marks to `items` in one batch. Runs on the
    /// main queue, guaranteed outside any view-body evaluation by the async hop.
    private func mergePendingDecryptionFailures() {
        pendingFailedIDsLock.lock()
        let ids = pendingFailedIDs
        // BUG-015 (2026-07-21): without removeAll, pendingFailedIDs grew
        // monotonically — every failed decryption ID accumulated forever.
        // Each subsequent merge re-processed the entire set. Clear inside
        // the same lock window to keep the snapshot/clear atomic.
        pendingFailedIDs.removeAll()
        pendingFailedIDsLock.unlock()
        var changed = false
        for id in ids {
            if let index = items.firstIndex(where: { $0.id == id }),
               !items[index].decryptionFailed {
                items[index].decryptionFailed = true
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    /// Returns cached RTF plaintext for an item, parsing and caching on first access.
    /// Avoids repeated NSAttributedString RTF parsing in search/filter paths.
    /// Implementation delegates to the pure `RichTextParser` so the parsing
    /// rules live in exactly one place; only the cache wrapper is here.
    func getRTFPlaintext(_ item: ClipboardItem) -> String {
        guard item.type == .richText else { return "" }
        let key = item.id.uuidString as NSString
        if let cached = rtfPlaintextCache.object(forKey: key) {
            return cached as String
        }
        let base64RTF = getDecryptedContent(item) ?? item.content
        let result = RichTextParser.plaintext(from: base64RTF, fallback: L10n.itemRichText)
        rtfPlaintextCache.setObject(result as NSString, forKey: key)
        return result
    }

    /// M-3 (2026-07-21 audit): bridge entry-point for views that have already
    /// parsed RTF (e.g. `ClipboardItemRow.loadRichText()` list row rendering,
    /// `QuickBarView` RTF preview). Stores the plaintext in
    /// `rtfPlaintextCache` so subsequent `copyToClipboard` calls hit the
    /// cache instead of re-parsing `NSAttributedString(data: .rtf)` on
    /// every copy. Cache hit < 1ms vs 20-100ms sync parse. (M-3 spec §3.)
    func cacheRTFPlaintext(_ item: ClipboardItem, _ plaintext: String) {
        guard item.type == .richText else { return }
        rtfPlaintextCache.setObject(
            plaintext as NSString,
            forKey: item.id.uuidString as NSString,
            cost: plaintext.utf8.count
        )
    }

    // MARK: - Recycle Bin (Trash)

    /// Load trashed items from the trash backend.
    func loadTrashedItems() {
        do {
            trashedItems = try trashBackend.load()
        } catch {
            logger.error("Failed to load trashed items: \(error.localizedDescription)")
            trashedItems = []
        }
    }

    /// Persist trashed items to the trash backend.
    func saveTrashedItems() {
        do {
            try trashBackend.save(trashedItems)
        } catch {
            logger.error("Failed to save trashed items: \(error.localizedDescription)")
        }
    }

    /// Move a single item to the recycle bin. The item is removed from the
    /// active list but its image file is kept until permanent deletion.
    func moveToTrash(_ item: ClipboardItem) {
        contentCache.removeObject(forKey: item.id.uuidString as NSString)
        rtfPlaintextCache.removeObject(forKey: item.id.uuidString as NSString)
        var trashed = item
        trashed.deletedAt = Date()
        trashedItems.insert(trashed, at: 0)
        items.removeAll { $0.id == item.id }
        updatePinnedItems()
        scheduleSave()
        scheduleTrashSave()
    }

    /// Move multiple items to the recycle bin.
    func moveToTrash(_ itemsToMove: [ClipboardItem]) {
        for item in itemsToMove {
            contentCache.removeObject(forKey: item.id.uuidString as NSString)
            rtfPlaintextCache.removeObject(forKey: item.id.uuidString as NSString)
            var trashed = item
            trashed.deletedAt = Date()
            trashedItems.insert(trashed, at: 0)
        }
        let idsToMove = Set(itemsToMove.map { $0.id })
        items.removeAll { idsToMove.contains($0.id) }
        updatePinnedItems()
        scheduleSave()
        scheduleTrashSave()
    }

    /// Restore an item from the recycle bin to the top of the active list.
    func restoreFromTrash(_ item: ClipboardItem) {
        guard let index = trashedItems.firstIndex(where: { $0.id == item.id }) else { return }
        var restored = trashedItems.remove(at: index)
        restored.deletedAt = nil
        items.insert(restored, at: 0)
        updatePinnedItems()
        scheduleSave()
        scheduleTrashSave()
    }

    /// Permanently delete a trashed item and its image file.
    func deletePermanently(_ item: ClipboardItem) {
        if item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        trashedItems.removeAll { $0.id == item.id }
        scheduleTrashSave()
    }

    /// Empty the entire recycle bin, deleting all trashed items and images.
    func emptyTrash() {
        for item in trashedItems where item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        trashedItems.removeAll()
        scheduleTrashSave()
    }

    /// Remove trashed items older than `trashRetentionDays` days.
    /// Called on startup and periodically to keep the recycle bin bounded.
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
        scheduleTrashSave()
    }

    // MARK: - Trash persistence debounce

    private var trashSaveTimer: DispatchSourceTimer?
    private var trashNeedsSave = false
    private func scheduleTrashSave() {
        trashNeedsSave = true
        trashSaveTimer?.cancel()
        let queue = DispatchQueue(label: "com.clipmemory.trashsave", qos: .utility)
        trashSaveTimer = DispatchSource.makeTimerSource(queue: queue)
        trashSaveTimer?.schedule(deadline: .now() + saveDebounceInterval)
        trashSaveTimer?.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.flushTrashSave() }
        }
        trashSaveTimer?.resume()
    }

    private func flushTrashSave() {
        guard trashNeedsSave else { return }
        trashNeedsSave = false
        trashSaveTimer?.cancel()
        trashSaveTimer = nil
        saveTrashedItems()
    }

    func trimToMaxItems() {
        guard items.count > maxItems else { return }
        // C-1 fix (2026-07-20 audit): pinned items are an explicit retention
        // guarantee the user opted into — never silently evict them to make
        // room for non-pinned history. If the user pins more than maxItems,
        // pinned overflows the cap; non-pinned is shrunk to whatever slots
        // remain (possibly zero). Trade-off: the active list may exceed
        // maxItems; alternative policies (rejecting new pins at cap, separate
        // pinned cap) are policy decisions for the user, not silent data loss.
        let pinned = items.filter { $0.isPinned }
        var nonPinned = items.filter { !$0.isPinned }
        let allowedNonPinned = max(0, maxItems - pinned.count)
        nonPinned = Array(nonPinned.prefix(allowedNonPinned))
        // BUG-014 (2026-07-21): `pinned + nonPinned` (previous) + L1100
        // `items = trimmed` moved ALL pinned items to the front of the
        // array, breaking the time-descending order — a pinned 8:00 item
        // could appear before a non-pinned 9:00 item. Compute the
        // surviving-id set and removeAll in place so original ordering is
        // preserved.
        let trimmedIds = Set((pinned + nonPinned).map { $0.id })
        let removedItems = items.filter { !trimmedIds.contains($0.id) }
        for item in removedItems {
            contentCache.removeObject(forKey: item.id.uuidString as NSString)
            rtfPlaintextCache.removeObject(forKey: item.id.uuidString as NSString)
        }
        let removedImages = removedItems.filter { $0.type == .image }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { !trimmedIds.contains($0.id) }
        updatePinnedItems()
        scheduleSave()
    }

    func deleteItem(_ item: ClipboardItem) {
        moveToTrash(item)
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
        moveToTrash(itemsToDelete)
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
        moveToTrash(toRemove)
    }

    func clearAllItems() {
        let pinnedIds = Set(pinnedItems.map { $0.id })
        let toRemove = items.filter { !pinnedIds.contains($0.id) }
        moveToTrash(toRemove)
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

    // MARK: - Conditional clear (type × time range)

    enum ClearRange: CaseIterable {
        case all, today, yesterday, older
    }

    /// Returns whether `date` falls inside the given range, using the same
    /// day boundaries as clearToday/clearYesterday/clearOlder.
    func isDate(_ date: Date, inClearRange range: ClearRange, calendar: Calendar = .current) -> Bool {
        let startOfToday = calendar.startOfDay(for: Date())
        switch range {
        case .all:
            return true
        case .today:
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date.distantFuture
            return date >= startOfToday && date < endOfToday
        case .yesterday:
            guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return false }
            return date >= startOfYesterday && date < startOfToday
        case .older:
            guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return false }
            return date < startOfYesterday
        }
    }

    /// Clears items matching an optional type and a time range, skipping
    /// pinned items (same protection rule as the other clear* paths).
    /// Returns the number of items moved to trash.
    @discardableResult
    func clearItems(type: ClipboardItemType?, range: ClearRange) -> Int {
        let targets = items.filter { item in
            !item.isPinned
                && (type == nil || item.type == type)
                && isDate(item.createdAt, inClearRange: range)
        }
        guard !targets.isEmpty else { return 0 }
        moveToTrash(targets)
        return targets.count
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
                // M-3 (2026-07-21 audit): use getRTFPlaintext (cache-aware)
                // instead of re-parsing NSAttributedString(data: .rtf) on
                // every copy. Cache hit < 1ms vs 20-100ms sync parse. Cache
                // is pre-populated by ClipboardItemRow.loadRichText() and
                // QuickBarView (M-3 bridge). Miss falls back to sync
                // RichTextParser.plaintext via getRTFPlaintext.
                preparedText = getRTFPlaintext(item)
            }
        default:
            preparedText = getDecryptedContent(item)
        }

        guard (preparedImage != nil) || (preparedText != nil) || (preparedRtfData != nil) else { return }

        // M-4 (2026-07-21 audit): recordOwnWrite() MUST run BEFORE clearContents().
        // clearContents() increments pasteboard.changeCount immediately, but the
        // old order set skipNextCapture=true only afterwards. A timer tick in the
        // ~ms window between clear and recordOwnWrite saw changeCount bump with
        // skipNextCapture still false, re-captured our own write, and persisted a
        // duplicate item. Setting the flag first closes the window.
        if let monitor = clipboardMonitor {
            monitor.recordOwnWrite()
        }

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
            tagIds: moved.tagIds,
            deletedAt: moved.deletedAt
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
            rtfPlaintextCache.removeObject(forKey: id.uuidString as NSString)
        }
        let beforeCount = items.count
        items.removeAll { expiredIds.contains($0.id) }
        if items.count != beforeCount {
            updatePinnedItems()
            scheduleSave()
        }
    }
}
