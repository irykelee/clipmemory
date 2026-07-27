import Foundation
import AppKit
import Combine
import os.log

// swiftlint:disable file_length
// (1) Justification: ClipboardStore is the central coordinator of clipboard flow
// (addItem / dedup / persistence / migration). Splitting risks cross-cutting
// regressions — the god-object breakup is a deliberate defer. Tracking the
// 1250-line ceiling explicitly via disable so the discipline is visible in
// code review.
// (2) As of the 2026-07-24 low-audit batch the file is ~1480 lines, well past
// the 1250 threshold. Move logic into separate files in a future refactor pass.

extension Notification.Name {
    static let encryptionFailed = Notification.Name("ClipboardStore.encryptionFailed")
    static let cmdFFindAction = Notification.Name("ClipMemory.cmdFFindAction")
    /// M-9 (2026-07-24 audit): tag backend decode / write failed. Posted
    /// from `ClipboardStore.loadTags()` only (saveTags logs but does not
    /// post) after the logger line.
    /// CLIP-7 (2026-07-24 review): there is currently NO observer for this
    /// notification — it's a reserved channel for a future Settings
    /// diagnostics banner. Carries no payload — the next `loadTags()`
    /// attempt may succeed and overwrite the signal; consumers should
    /// debounce.
    static let tagBackendCorrupted = Notification.Name("ClipboardStore.tagBackendCorrupted")
}

extension ClipboardStore: ClipboardMonitorDelegate {
    func sensitiveClearHoursForMonitor() -> Int {
        // Audit-fix #3 (2026-07-20): ClipboardMonitor calls this delegate
        // from background queues. Reading `sensitiveClearHours` directly
        // is a data race — the @Published wrapper does not synchronize the
        // backing storage. M-4 (2026-07-25) extended the lock to cover writes
        // as well; read the private backing variable directly to avoid
        // deadlocking with the computed property's own lock.
        return withSensitiveClearHoursLock { _sensitiveClearHours }
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

    /// Min/max bounds for `maxItems`. E-1 (2026-07-23 audit): the setter
    /// previously wrote any value (including negatives or absurdly large
    /// numbers from a corrupted UserDefaults or an out-of-bounds slider)
    /// straight to UserDefaults, leading to `trimToMaxItems()` running
    /// with `maxItems = -1` (trims everything) or `maxItems = 1_000_000_000`
    /// (no trimming at all, then UI breaks). Clamp to a sane range.
    static let minMaxItems = 1
    static let maxMaxItems = 10_000

    // @Published with didSet for automatic UserDefaults persistence
    @Published var maxItems: Int {
        didSet {
            let clamped = max(Self.minMaxItems, min(maxItems, Self.maxMaxItems))
            if maxItems != clamped {
                // Re-assignment re-fires didSet with the clamped value,
                // which then falls through to the UserDefaults write.
                // The recursion is bounded by the equality check above.
                maxItems = clamped
                return
            }
            // M-4 (2026-07-24 audit): keep `contentCache.countLimit` in sync
            // with `maxItems`. A fixed `500` cap was half-empty when a user
            // chose `maxItems = 10000`, wasting the upper half of the cache.
            // `rtfPlaintextCache` shares the same shape; tune both.
            contentCache.countLimit = max(maxItems, Self.minCacheCountLimit)
            rtfPlaintextCache.countLimit = max(maxItems, Self.minCacheCountLimit)
            UserDefaults.standard.set(maxItems, forKey: maxItemsKey)
        }
    }
    /// M-4: lower bound for the cache `countLimit` so a user with a small
    /// `maxItems` (e.g. 50) still gets the original 500-entry cache headroom
    /// rather than an undersized cache.
    static let minCacheCountLimit = 500

    // M-4 (2026-07-25 audit): `sensitiveClearHours` is read from the
    // clipboard monitor's background timer and written from the SwiftUI main
    // thread. A plain `@Published` Int has no synchronization on the backing
    // storage. Use a private locked backing variable + computed property so
    // reads and writes share one lock; `objectWillChange.send()` keeps SwiftUI
    // observing changes because the class is an `ObservableObject`.
    var sensitiveClearHours: Int {
        get { withSensitiveClearHoursLock { _sensitiveClearHours } }
        set {
            let changed = withSensitiveClearHoursLock {
                let old = _sensitiveClearHours
                _sensitiveClearHours = newValue
                return old != newValue
            }
            UserDefaults.standard.set(newValue, forKey: sensitiveClearHoursKey)
            if changed { objectWillChange.send() }
        }
    }
    private var _sensitiveClearHours: Int = 24
    private let sensitiveClearHoursLock = NSLock()
    private func withSensitiveClearHoursLock<R>(_ block: () throws -> R) rethrows -> R {
        sensitiveClearHoursLock.lock()
        defer { sensitiveClearHoursLock.unlock() }
        return try block()
    }

    @Published var captureRichText: Bool = true {
        didSet { UserDefaults.standard.set(captureRichText, forKey: captureRichTextKey) }
    }

    /// Comma-separated bundle IDs of apps excluded from clipboard monitoring
    @Published var excludedBundleIdsString: String {
        didSet {
            UserDefaults.standard.set(excludedBundleIdsString, forKey: excludedBundleIdsKey)
            // MED-5: sync excluded apps via closure set by AppDelegate
            onExcludedAppsChanged?(parseExcludedBundleIds())
        }
    }

    /// HIGH-1 (2026-07-26 review): trash subsystem moved to TrashStore.
    /// Forwarding computed properties preserve existing call-site compatibility.
    var trashedItems: [ClipboardItem] {
        get { trashStore.trashedItems }
        set { trashStore.trashedItems = newValue }
    }
    var trashRetentionDays: Int {
        get { trashStore.trashRetentionDays }
        set { trashStore.trashRetentionDays = newValue }
    }

    /// HIGH-1 (2026-07-26 review): extracted trash subsystem.
    let trashStore: TrashStore

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
        // CLIP-8 (2026-07-24 review): removed the dead
        // `startOfDayBeforeYesterday` binding — nothing in this function
        // consumed it (the old BUG-016 comment claimed unpinOlder did, but
        // unpinOlder computes its own date at ~L1272).
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
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
    // trashRetentionDaysKey moved to TrashStore (HIGH-1, 2026-07-26)

    /// Quarantine a corrupt UserDefaults blob: copy it under
    /// `<key>.corrupt-<ISO8601-ts>` then remove the original. Without this,
    /// the next `saveItems` / `saveTags` / `saveTrashedItems` would
    /// overwrite the corrupt blob with `[]`, permanently destroying the
    /// user's history. Quarantining lets recovery tooling (or a future
    /// "restore from backup" affordance) attempt repair.
    /// Post-audit-scan fix: previously `loadItems()` / `loadTrashedItems()`
    /// / `loadTags()` silently swallowed the error and continued with an
    /// empty in-memory collection — the very next save wiped the persist
    /// layer permanently.
    private func quarantineCorruptBlob(key: String, error: Error) {
        let defaults = UserDefaults.standard
        guard let blob = defaults.data(forKey: key) else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let quarantineKey = "\(key).corrupt-\(timestamp)"
        defaults.set(blob, forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        logger.error("Corrupt blob \(key) quarantined to \(quarantineKey). First-decoder error: \(error.localizedDescription). The next save will overwrite the original key with the current (empty) in-memory collection; recover from the quarantined copy or a backup before saving.")
    }
    /// UserDefaults key for persisted items.
    static let itemsStorageKey = "ClipboardItems"
    // trashedItemsStorageKey moved to TrashStore (HIGH-1, 2026-07-26)
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

    // trashBackend moved to TrashStore (HIGH-1, 2026-07-26)

    // MARK: - Initializers

    /// Default initializer — uses FileStorageBackend backed by UserDefaults for
    /// items, tags, and trash (separate UserDefaults keys).
    convenience init() {
        self.init(backend: FileStorageBackend(),
                  tagBackend: FileStorageBackend(storageKey: ClipboardStore.tagStorageKey),
                  trashBackend: FileStorageBackend(storageKey: TrashStore.trashedItemsStorageKey))
    }

    /// E.1: Designated initializer accepting StorageBackend instances for testing.
    /// `tagBackend` and `trashBackend` default to fresh in-memory backends so
    /// existing tests that only care about items don't accidentally hit UserDefaults.
    init(backend: StorageBackend,
         tagBackend: StorageBackend = MemoryStorageBackend(),
         trashBackend: StorageBackend = MemoryStorageBackend()) {
        self.backend = backend
        self.tagBackend = tagBackend
        self.trashStore = TrashStore(backend: trashBackend)

        // M-3 ... (clamp logic unchanged)

        // M-3 (2026-07-24 audit): init validation must match didSet's clamp
        // range [minMaxItems, maxMaxItems]. Previously init used an enum of
        // [50, 100, 200, 500] — any other integer (250, 1000, 1_000_000 from
        // a corrupt UserDefaults or future-migrated value) silently fell
        // back to 100 even when didSet would have accepted it. Clamp with
        // the same bounds as didSet; migrate out-of-range values forward.
        // Absent key must default to 100, NOT clamp: integer(forKey:)
        // returns 0 for a missing key, and clamping 0 yields minMaxItems
        // (1) — fresh installs would silently cap history at a single item.
        let savedMaxItems = UserDefaults.standard.object(forKey: maxItemsKey) as? Int
        let clampedInit = savedMaxItems.map { max(Self.minMaxItems, min($0, Self.maxMaxItems)) } ?? 100
        if savedMaxItems != nil && clampedInit != savedMaxItems {
            UserDefaults.standard.set(clampedInit, forKey: maxItemsKey)
        }
        // M-4: tune the caches to match the resolved value. Done BEFORE the
        // `maxItems =` write because Swift's definite-init rules forbid
        // touching `self.maxItems` from init body while any stored property
        // is still uninitialized — and we compute the same value either way.
        let initialCacheLimit = max(clampedInit, Self.minCacheCountLimit)
        contentCache.countLimit = initialCacheLimit
        rtfPlaintextCache.countLimit = initialCacheLimit
        maxItems = clampedInit

        // M-4 (2026-07-25 audit): `sensitiveClearHours` is now a computed
        // property over `_sensitiveClearHours`. Initialize the backing stored
        // property directly here to satisfy Swift's definite-init rules.
        if UserDefaults.standard.object(forKey: sensitiveClearHoursKey) != nil {
            _sensitiveClearHours = UserDefaults.standard.integer(forKey: sensitiveClearHoursKey)
        } else {
            _sensitiveClearHours = 24
        }

        excludedBundleIdsString = UserDefaults.standard.string(forKey: excludedBundleIdsKey) ?? "com.1password.1password,com.agilebits.onepassword7,com.bitwarden.desktop,com.keepassx.keeweb"

        // trashRetentionDays init moved to TrashStore (HIGH-1, 2026-07-26)

        // Register notification observer AFTER all properties are initialized
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImageMigrationCompleted(_:)),
            name: Notification.Name("ImageStorageMigrationCompleted"),
            object: nil
        )
        // H-2 (2026-07-25 audit): flush captures that were deferred while the
        // encryption key was still being prepared on first launch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCryptoKeyPrepared(_:)),
            name: .cryptoKeyPrepared,
            object: nil
        )

        // Wire caches to trashStore so evictCaches can drop stale entries.
        trashStore.contentCache = contentCache
        trashStore.rtfPlaintextCache = rtfPlaintextCache

        // Trash refresh fix (2026-07-27 user-reported): after HIGH-1 extracted
        // the trash into a separate `TrashStore` ObservableObject, mutations
        // to `trashStore.trashedItems` (deletePermanently, emptyTrash, restore)
        // stopped re-rendering views that observe `ClipboardStore`. ItemListView
        // shows the trash via `store.trashedItems`, but since it only
        // `@ObservedObject`s the parent `ClipboardStore`, the trashStore's
        // `@Published var trashedItems` mutation went unobserved — a user
        // clicking "delete permanently" saw no list refresh until something
        // else (e.g. a clipboard capture) changed `items`.
        //
        // Forward trashStore's change notifications through our own
        // publisher so any view observing `ClipboardStore` re-renders when
        // the trash mutates. The lock-free `.sink` is fine here: SwiftUI
        // dispatches `objectWillChange` on the main thread, which is
        // exactly the contract `trashStore`'s `@Published` already honors
        // (per the TrashStore file-level comment).
        trashStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        loadItems()
        loadTags()
        // loadTrashedItems + purgeExpiredTrash moved to TrashStore.init (HIGH-1)
        // excluded apps sync moved to AppDelegate (MED-5)
        cleanupExpiredItems()
        let queue = DispatchQueue(label: "com.clipmemory.cleanup", qos: .background)
        cleanupTimer = DispatchSource.makeTimerSource(queue: queue)
        cleanupTimer?.schedule(deadline: .now() + 60, repeating: 60)
        cleanupTimer?.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cleanupExpiredItems()
                // NEW-C (2026-07-27 review): HIGH-1 extracted trash to
                // TrashStore and `purgeExpiredTrash` is only called from
                // TrashStore.init. If the app stays running past
                // trashRetentionDays (default 3), expired trashed items
                // accumulate until next launch. Drive it from the same
                // 60s cleanup timer so long-lived sessions don't pile
                // up old trash on disk.
                self.trashStore.purgeExpiredTrash()
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
    /// Trash refresh fix (2026-07-27): forwards `trashStore.objectWillChange`
    /// to our own publisher so views observing `ClipboardStore` re-render
    /// when the trash mutates (deletePermanently, emptyTrash, restore).
    private var cancellables: Set<AnyCancellable> = []
    /// M-2 (2026-07-25 audit): reuse a single serial queue for the save timer
    /// instead of creating a new `DispatchQueue` on every `scheduleSave()` call.
    private let saveTimerQueue = DispatchQueue(label: "com.clipmemory.save", qos: .utility)
    /// HIGH-4 (2026-07-26 review): reuse a single serial queue for the tag
    /// save timer, matching the M-2 reuse pattern applied to saveTimerQueue.
    private let tagSaveTimerQueue = DispatchQueue(label: "com.clipmemory.tagsave", qos: .utility)
    // trashSaveTimerQueue moved to TrashStore (HIGH-1, 2026-07-26)
    private var needsSave = false
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(500)

    /// H-2 (2026-07-25 audit): captures that arrive before the detached
    /// `CryptoService.prepareKey()` task finishes on first launch are held here
    /// instead of being dropped. Once `.cryptoKeyPrepared` fires with success,
    /// they are re-processed through `addItem(_:)`. Protected by its own lock
    /// because the notification may arrive on any queue.
    private var pendingKeyItems: [ClipboardItem] = []
    private let pendingKeyItemsLock = NSLock()

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
        // trashSaveTimer cancelled in TrashStore.deinit (HIGH-1)
        // I-2 fix (2026-07-20 audit): remove the NotificationCenter observer
        // registered in init(). Without this, the dispatch table keeps the
        // selector entry even after dealloc, which causes stale callbacks in
        // tests that create multiple store instances.
        NotificationCenter.default.removeObserver(self)
        flushPendingSaves()
    }

    /// Handles image migration completion — updates isEncrypted flags for migrated image items.
/// NEW-A (2026-07-27 review): the `ImageStorageMigrationCompleted` notification is
/// posted via `DispatchQueue.main.async` from `ImageStorage.migrateFromLegacyIfNeeded`,
/// but the observer registration at :288 does not pin the handler to any queue —
/// it executes on the posting thread. Direct mutation of `@Published var items`
/// from any non-main thread violates SwiftUI's contract (the same hazard CRIT-1
/// called out for `.cryptoKeyPrepared`). Pin to main here too so a future caller
/// that posts the notification from a background queue cannot race the UI.
@objc private func handleImageMigrationCompleted(_ notification: Notification) {
    guard let migratedFilenames = notification.userInfo?["migratedFilenames"] as? [String] else { return }
    let migratedSet = Set(migratedFilenames)
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        var didMigrateAny = false
        for (index, item) in self.items.enumerated() where item.type == .image && migratedSet.contains(item.content) {
            self.items[index] = item.with(isEncrypted: true)
            didMigrateAny = true
        }
        if didMigrateAny {
            self.scheduleSave()
        }
    }
}

    /// H-2 (2026-07-25 audit): retry captures that were deferred while the
    /// encryption key was still being prepared. On success, re-feed every
    /// pending item through `addItem(_:)` (dedup and ordering are preserved).
    /// On failure, drop them with the same encryption-failed notification that
    /// an immediate failure would have posted.
    @objc private func handleCryptoKeyPrepared(_ notification: Notification) {
        let success = notification.userInfo?["success"] as? Bool ?? false
        pendingKeyItemsLock.lock()
        let pending = pendingKeyItems
        pendingKeyItems.removeAll()
        pendingKeyItemsLock.unlock()

        guard !pending.isEmpty else { return }
        // CRIT-1 (2026-07-26 review): the .cryptoKeyPrepared notification is
        // posted from CryptoService.prepareKey() which runs on a detached
        // utility queue — this handler runs on whichever thread the notification
        // was posted from. addItem(_:) directly mutates @Published var items,
        // which SwiftUI requires on main thread. Dispatch to main before
        // touching any @Published or AppKit state.
        if success {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for item in pending { self.addItem(item) }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.logger.error("Encryption key preparation failed; dropping \(pending.count) deferred clipboard capture(s)")
                NotificationCenter.default.post(
                    name: .encryptionFailed,
                    object: nil,
                    userInfo: [
                        "source": "addItem",
                        "itemType": "deferred"
                    ]
                )
            }
        }
    }

    // updateExcludedAppsOnMonitor() removed (MED-5, 2026-07-26).
    // AppDelegate now sets excludedBundleIds on the monitor directly.

    func loadItems() {
        let savedItems: [ClipboardItem]
        do {
            savedItems = try backend.load()
        } catch {
            quarantineCorruptBlob(key: Self.itemsStorageKey, error: error)
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
                repairedItems[index] = item.with(isEncrypted: false, decryptionFailed: false)
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
                    self.items[index] = self.items[index].with(content: newContent, isEncrypted: true)
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

    /// CLIP-2 (2026-07-24): serial queue for JSON-encoding the item array.
    /// `saveItems()` used to run the full-array JSONEncoder pass on the main
    /// thread on every clipboard ingestion (addItem → saveImmediately); with a
    /// large history that blocked the UI per capture. The encode now runs here
    /// at utility QoS; only the encoded Data crosses back for the write.
    private let itemEncodingQueue = DispatchQueue(label: "com.clipmemory.itemencode", qos: .utility)

    func saveItems() {
        // CLIP-2: the `.sync` hop is deliberate — saveImmediately()'s
        // write-through contract (clipboard ingestion must be durable before
        // addItem returns, so kill -9 / power loss after the fact can't lose
        // it) and flushPendingSaves()' terminate-path guarantee both depend on
        // saveItems() staying synchronous. Only the encoding CPU moves off
        // the calling thread; the durability semantics are unchanged.
        // Deadlock-free: saveItems() is main-thread only and nothing else
        // dispatches to this queue.
        // M-5 (2026-07-25 audit): converting this to async would break the
        // write-through contract tested by IntegrationTests and
        // ClipboardCaptureLimitTests. Deferred to a future refactor that can
        // plumb async completion through the call sites.
        let snapshot = items
        do {
            let data = try itemEncodingQueue.sync {
                try JSONEncoder().encode(snapshot)
            }
            try backend.saveBlob(data)
        } catch {
            logger.error("Failed to save items: \(error.localizedDescription)")
        }
    }

    /// Schedules a debounced save — coalesces multiple rapid mutations into a single disk write.
    /// The actual write happens after `saveDebounceInterval` seconds of inactivity.
    func scheduleSave() {
        needsSave = true
        // M-2 (2026-07-25 audit): lazily create and reuse the timer source.
        // Repeated scheduleSave() calls previously allocated a new DispatchQueue
        // + DispatchSource on every keystroke / tag change, which showed up in
        // Instruments as allocation churn. `schedule(deadline:)` restarts the
        // existing source's fire time.
        if saveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: saveTimerQueue)
            timer.setEventHandler { [weak self] in
                // Hop to main before touching @Published `items` — the timer fires on a
                // utility queue, and encoding the array from there races with main-thread
                // mutations (insert/remove) and is UB.
                DispatchQueue.main.async { self?.flushSave() }
            }
            timer.resume()
            saveTimer = timer
        }
        saveTimer?.schedule(deadline: .now() + saveDebounceInterval)
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
        trashStore.flushPendingSave()
    }

    private func flushSave() {
        guard needsSave else { return }
        needsSave = false
        saveTimer?.cancel()
        // M-2 (2026-07-25 audit): keep the timer source alive for reuse rather
        // than nil-ing it out after every flush.
        saveItems()
    }

    /// Insert or replace a tag by its UUID. Tags with the same id overwrite
    /// (idempotent rename/recolor). Triggers a debounced tag save.
    func addTag(_ tag: Tag) {
        // E-6 (2026-07-23 audit): trim leading/trailing whitespace +
        // newlines from the user-supplied tag name before storing.
        // Without this, a tag named "  Work  " persists as-is and the
        // sidebar / search / suggestions all see it as a distinct tag
        // from "Work". Trimming here is defensive — it protects all
        // callers (NewTagSheet, TagPickerSheet bulk-add, future entry
        // points) without each needing to remember to trim.
        let trimmedName = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != tag.name {
            tags[tag.id] = Tag(
                id: tag.id,
                name: trimmedName,
                colorHex: tag.colorHex,
                isAutoSuggested: tag.isAutoSuggested,
                createdAt: tag.createdAt
            )
        } else {
            tags[tag.id] = tag
        }
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
            quarantineCorruptBlob(key: Self.tagStorageKey, error: error)
            logger.error("Failed to load tags: \(error.localizedDescription)")
            // M-9 (2026-07-24 audit): the previous path was silent beyond
            // an os_log entry — the user saw an empty tag sidebar with no
            // explanation. Surface the failure via .tagBackendCorrupted.
            // CLIP-7 (2026-07-24 review): nothing observes this yet — the
            // post is the deliberate M-9 hook for a future Settings
            // diagnostics banner / "restore from backup" affordance.
            NotificationCenter.default.post(name: .tagBackendCorrupted, object: nil)
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

    /// Encrypt tag names for disk storage. Names are plaintext in memory
    /// (decrypted by `loadTags`); the only encrypted names on disk are the
    /// locked placeholders, whose original ciphertext is restored from the
    /// backup map. A name that happens to start with the marker prefix (e.g.
    /// a user-created tag literally named "v2:work") is encrypted like any
    /// other plaintext — the old decrypt probe was unnecessary because
    /// `loadTags` already separates real ciphertext from accidental prefixes.
    /// L-2 (2026-07-25 audit): removed the per-tag AES-GCM decrypt on save.
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
        // HIGH-4 (2026-07-26 review): lazily create the timer once and reuse
        // it via schedule(deadline:), matching the M-2 pattern in scheduleSave().
        if tagSaveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: tagSaveTimerQueue)
            timer.setEventHandler { [weak self] in
                DispatchQueue.main.async { self?.flushTagSave() }
            }
            timer.resume()
            tagSaveTimer = timer
        }
        tagSaveTimer?.schedule(deadline: .now() + saveDebounceInterval)
    }

    private func flushTagSave() {
        guard tagNeedsSave else { return }
        tagNeedsSave = false
        tagSaveTimer?.cancel()
        // HIGH-4 (2026-07-26 review): keep timer alive for reuse, matching
        // the flushSave() pattern — nil-ing it out would force scheduleTagSave
        // to reallocate a new DispatchSource on the next call.
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
                newItem = item.with(content: encrypted, isEncrypted: true, contentHash: newHash)
            } else {
                // H-2 (2026-07-25 audit): on a fresh install the encryption key
                // is prepared in a detached task; captures that arrive before it
                // finishes would otherwise be silently dropped. Defer them and
                // retry once `.cryptoKeyPrepared` signals success.
                if CryptoService.isKeyLoadAttemptedAndMissing() {
                    pendingKeyItemsLock.lock()
                    pendingKeyItems.append(item)
                    pendingKeyItemsLock.unlock()
                    return
                }
                // N2: Encrypt failed — do NOT store as plaintext (security violation).
                // Discard the item (any non-image type — M3 encrypts text + link
                // unconditionally). H-3 (2026-07-24 audit) audit-checks for log +
                // notify on this path; the bare notification is now tagged with
                // `source = "addItem"` and the item type so observers can
                // distinguish addItem from HMAC / OCR / ImageStorage failures
                // and the user-facing alert can be debounced across sources.
                logger.error("Encryption failed for non-image item (type: \(item.type.rawValue, privacy: .public)), discarding to protect data")
                NotificationCenter.default.post(
                    name: .encryptionFailed,
                    object: nil,
                    userInfo: [
                        "source": "addItem",
                        "itemType": item.type.rawValue
                    ]
                )
                return
            }
        } else {
            // CLIP-1: image items arrive with a contentHash computed by
            // ClipboardMonitor over the raw image bytes (HMAC-SHA256, same
            // style as text items). The item's `content` is a fresh UUID
            // filename — useless for dedup — so without adopting this hash
            // the dedup pre-filter below could never match images and every
            // re-copy of the same picture added a new entry + file. nil
            // (legacy items, or crypto failure at capture time) → skip
            // dedup, same contract as the text HMAC-failure path.
            newHash = item.contentHash
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
            // with() also preserves decryptionFailed (HIGH-1: otherwise the
            // a00da7c perf fix is undone on every re-copy of corrupt content)
            // and ocrText/ocrAttempted (STOR-2).
            existing = existing.with(createdAt: Date(), contentHash: existing.contentHash ?? newHash)
            items.insert(existing, at: 0)
            // CLIP-1: the monitor writes the image file BEFORE the store sees
            // the item (saveImage completion → addItem). On a dedup hit the
            // new entry is discarded; delete its just-written file as well,
            // or every re-copy of an already-seen image leaks an orphaned
            // file until the next startup orphan sweep. Guard on differing
            // filenames so the kept entry's file can never be removed.
            if newItem.type == .image, newItem.content != existing.content {
                ImageStorage.shared.deleteImage(filename: newItem.content)
            }
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
        if trashAdded { trashStore.scheduleSavePublic() }
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

    // MARK: - Recycle Bin (Trash) — forwarding stubs (HIGH-1, 2026-07-26)

    func moveToTrash(_ item: ClipboardItem) {
        evictCaches(for: item)
        items.removeAll { $0.id == item.id }
        trashStore.moveToTrash(item, evictCaches: { _ in }, didMove: { [weak self] in
            self?.updatePinnedItems()
            self?.scheduleSave()
        })
    }

    func moveToTrash(_ itemsToMove: [ClipboardItem]) {
        for item in itemsToMove { evictCaches(for: item) }
        let idsToMove = Set(itemsToMove.map { $0.id })
        items.removeAll { idsToMove.contains($0.id) }
        trashStore.moveToTrash(itemsToMove, evictCaches: { _ in }, didMove: { [weak self] in
            self?.updatePinnedItems()
            self?.scheduleSave()
        })
    }

    private func evictCaches(for item: ClipboardItem) {
        contentCache.removeObject(forKey: item.id.uuidString as NSString)
        contentCache.removeObject(forKey: (item.id.uuidString + ".ocr") as NSString)
        rtfPlaintextCache.removeObject(forKey: item.id.uuidString as NSString)
    }

    func restoreFromTrash(_ item: ClipboardItem) {
        trashStore.restoreFromTrash(item, didRestore: { [weak self] restored in
            self?.items.insert(restored, at: 0)
            self?.updatePinnedItems()
            self?.scheduleSave()
        })
    }

    func deletePermanently(_ item: ClipboardItem) { trashStore.deletePermanently(item) }
    func emptyTrash() { trashStore.emptyTrash() }
    func purgeExpiredTrash() { trashStore.purgeExpiredTrash() }

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
            // CLIP-5 (2026-07-24 review): also drop the derived OCR cache key.
            contentCache.removeObject(forKey: (item.id.uuidString + ".ocr") as NSString)
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
            // M-5 (2026-07-24 audit): `loadImageObject` runs legacy-migration
            // disk I/O inside `migrationQueue.sync` — on a cold image that
            // blocked the main thread (this handler runs from UI actions in
            // ContentView / ItemListView / QuickBarView). Warm cache (the
            // common case — the row already rendered the thumbnail) copies
            // synchronously; a cold image loads via `imageStatusAsync` on the
            // status queue and finishes the pasteboard write on main.
            if let cached = ImageStorage.shared.cachedImageObject(filename: item.content) {
                preparedImage = cached
            } else {
                copyColdImageToClipboard(item)
                return
            }
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
        onRecordOwnWrite?()

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

    /// M-5 (2026-07-24 audit): cold-image copy path. Loads via
    /// `imageStatusAsync` (status queue) so legacy-migration disk I/O never
    /// touches the main thread, then finishes the copy on main. Ordering
    /// contracts are preserved: `recordOwnWrite()` still runs BEFORE
    /// `clearContents()` (M-4) and `moveToTop` still mutates `@Published`
    /// items on the main thread.
    private func copyColdImageToClipboard(_ item: ClipboardItem) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let status = await ImageStorage.shared.imageStatusAsync(for: item.content)
            guard case .available(let data) = status,
                  let image = NSImage(data: data) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.onRecordOwnWrite?()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
                self.moveToTop(item)
            }
        }
    }

    // Injected by AppDelegate so copyToClipboard can break the re-capture loop
    /// MED-5 (2026-07-26 review): closures set by AppDelegate to break the
    /// bidirectional ClipboardStore ↔ ClipboardMonitor reference.
    var onRecordOwnWrite: (() -> Void)?
    var onExcludedAppsChanged: ((Set<String>) -> Void)?

    func parseExcludedBundleIds() -> Set<String> {
        Set(excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    private func moveToTop(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var moved = items.remove(at: index)
        moved = moved.with(createdAt: Date())
        items.insert(moved, at: 0)
        scheduleSave()
    }

    private func updatePinnedItems() {
        pinnedItems = items.filter { $0.isPinned }
    }

    internal func cleanupExpiredItems() {
        let expiredImageFilenames = items.filter { $0.isExpired && $0.type == .image }.map { $0.content }
        let expiredIds = Set(items.filter { $0.isExpired }.map { $0.id })
        if expiredImageFilenames.isEmpty && expiredIds.isEmpty { return }

        for filename in expiredImageFilenames {
            ImageStorage.shared.deleteImage(filename: filename)
        }
        for id in expiredIds {
            contentCache.removeObject(forKey: id.uuidString as NSString)
            // CLIP-5 (2026-07-24 review): also drop the derived OCR cache key.
            contentCache.removeObject(forKey: (id.uuidString + ".ocr") as NSString)
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
