import Foundation
import AppKit
import Combine
import os.log

// ID-PERF-0001 (2026-07-30 audit): hoist JSONEncoder allocation. File-scope
// (not class-scope) because ClipboardStore is @MainActor and the encode
// runs on itemEncodingQueue — file-scope `let` is non-isolated and JSONEncoder
// is documented thread-safe for `.encode()` since macOS 10.15.
// ARCH-0002 PR #1 (2026-08-11): visibility loosened from `private` to
// `internal` so the methods moved to `ClipboardStore+Persistence.swift`
// can read this file-scope encoder. Logic unchanged.
let itemsSaveEncoder = JSONEncoder()

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
    /// ID-SILENT-0021 (2026-08-08 audit): `ClipboardStore.flushSave()` caught
    /// an error from `saveItems()` (e.g., disk full, permission denied,
    /// iCloud sync conflict) and previously only logged it while leaving
    /// `needsSave = false`, so the next debounce timer fired and exited via
    /// the early `guard` — silently losing the user's clipboard capture for
    /// the rest of the session. Posted from `flushSave` after restoring
    /// `needsSave = true` so the next timer retries. Carries no payload —
    /// consumers (e.g., a future Settings diagnostics banner) should debounce
    /// because a single transient backend hiccup can fire this repeatedly
    /// before the user takes action.
    static let clipboardSaveFailed = Notification.Name("ClipboardStore.clipboardSaveFailed")
    /// H-2 (2026-08-08): posted by `TrashStore.loadTrashedItems()` when
    /// either (a) `backend.load()` throws a fresh error (corrupt blob
    /// just detected) or (b) the persistent sentinel from a prior
    /// launch's `quarantineCorruptBlob` is still set (the corrupt blob
    /// was quarantined on a previous launch and is no longer present,
    /// but the failure signal must survive). `userInfo["persistent"]
    /// : Bool` distinguishes (b) from (a). The observer must be in
    /// production code so the user gets a visible signal — otherwise
    /// the quarantine + sweep-skip happens silently and the user's
    /// trash appears empty with no explanation.
    static let trashLoadFailed = Notification.Name("TrashStore.loadFailed")
    /// NOTIFY-0001 (2026-08-10): posted by `LanguageManager` after the
    /// in-memory mirror is updated so any consumer reacting to the
    /// notification (e.g. AppDelegate refreshing `NSApp.appearance`) sees
    /// the new language code. Carries no payload — read `LanguageManager
    /// .currentLanguageCode` from the observer.
    static let languageDidChange = Notification.Name("LanguageManager.languageDidChange")
    /// NOTIFY-0001: posted by `ImageStorage.migrateFromLegacyIfNeeded`
    /// when a legacy plaintext image file has been re-encrypted into the
    /// v2 AES-GCM format. `userInfo["migratedFilenames"]: [String]` lists
    /// the filenames that were just migrated (used by `ClipboardStore`
    /// to flip `isEncrypted` on the matching items).
    static let imageStorageMigrationCompleted = Notification.Name("ImageStorage.migrationCompleted")
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
    func monitorDidRecognizeText(_ text: String, forImageItemId id: UUID, contentHash: String?) {
        attachOCRText(to: id, text: text, contentHash: contentHash)
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published var items: [ClipboardItem] = []
    @Published var pinnedItems: [ClipboardItem] = []

    /// User-defined tags keyed by UUID. Source of truth for tag definitions;
    /// ClipboardItem.tagIds holds only the IDs (Set<UUID>) for O(1) filter checks.
    /// Persistence is handled by `loadTags()` / `saveTags()`.
    @Published var tags: [UUID: Tag] = [:]

    // P0-2: search-path diagnostics aggregation (@Published → ContentView/QuickBarView)
    // P7: non-private(set) — @testable does not unlock private setter; tests need write access
    @Published var diagnostics: DecryptionDiagnostics = .init()

    /// Items whose image files are missing/corrupt on disk. Populated by the
    /// startup integrity scan (runImageIntegrityScan). ContentView/QuickBarView
    /// use these to show immediate status without waiting for per-row disk I/O.
    @Published var imageMissingIds: Set<UUID> = []
    @Published var imageCorruptedIds: Set<UUID> = []

    /// Min/max bounds for `maxItems`. E-1 (2026-07-23 audit): the setter
    /// previously wrote any value (including negatives or absurdly large
    /// numbers from a corrupted UserDefaults or an out-of-bounds slider)
    /// straight to UserDefaults, leading to `trimToMaxItems()` running
    /// with `maxItems = -1` (trims everything) or `maxItems = 1_000_000_000`
    /// (no trimming at all, then UI breaks). Clamp to a sane range.
    ///
    /// Two-tier strategy (v2.8.4):
    /// - **`minMaxItems = 1` / `maxMaxItems = 10_000`** — hard safety clamp.
    ///   Defends the store against corrupted / externally-edited UserDefaults
    ///   values that would otherwise break trim or UI. NEVER raised without
    ///   re-running the 1000-items audit in `maxItems-audit-1000.swift`.
    /// - **UI Picker preset is 1000 (since v2.8.4)** — soft product cap.
    ///   Power users can pick 1000 from `HistoryCaptureSettingsView`; the
    ///   underlying clamp still allows up to 10_000 if a future feature or
    ///   migration path needs it. Audit 2026-08-11: 1000 items → 673 KB
    ///   JSON, 7.9 ms decode on M-series — well under the 50 ms startup
    ///   budget. Beyond ~1000 items the data becomes harder to manage
    ///   (search/tags/cleanup become mandatory) without a corresponding
    ///   value bump; the picker stops at 1000 to discourage data graveyards.
    static let minMaxItems = 1
    static let maxMaxItems = 10_000

    /// ID-STORE-0014 (2026-08-10): XCTest-only isolated `UserDefaults` suite.
    /// Returned by the `defaults:` parameter default in `init(backend:...)`
    /// and used by the convenience init's XCTest branch — together they ensure
    /// that every ClipboardStore instantiation under XCTest reads/writes through
    /// a dedicated test suite instead of the production `com.clipmemory.app`
    /// plist (which is what `.standard` resolves to in the XCTest host
    /// process — the test bundle is injected into the host app, so
    /// `Bundle.main.bundleIdentifier == "com.clipmemory.app"`).
    ///
    /// Production behavior unchanged: when `XCTestConfigurationFilePath` is
    /// not set (i.e. real app run), returns `.standard`.
    ///
    /// The suite name is process-scoped (UserDefaults caches by name); the
    /// underlying plist lives in `~/Library/Preferences/` and accumulates
    /// keys during the test run, but those keys never cross into production
    /// because `.standard` keeps pointing at the host's `com.clipmemory.app`
    /// plist. The ZZZ canary (`testNoProductionPollution`) enforces this.
    ///
    /// `nonisolated` so the `defaults:` parameter default (which is evaluated
    /// outside the class's actor isolation) can reference it.
    nonisolated static var xcTestDefaults: UserDefaults {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            return .standard
        }
        return UserDefaults(suiteName: "ClipboardStore-XCTest-isolation") ?? .standard
    }

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
            // ID-STORE-0014 (2026-08-10): write to the INJECTED defaults suite,
            // not UserDefaults.standard — every test that drove `store.maxItems`
            // (M-2's `store.maxItems = 3` and friends) silently polluted the
            // production `com.clipmemory.app` UserDefaults with values outside
            // the picker range (e.g. 3), leaving the running app's settings
            // max-items dropdown blank. Production behavior unchanged because
            // `defaults` is `.standard` in the convenience init path; tests
            // that inject a test suite now stay isolated.
            defaults.set(maxItems, forKey: maxItemsKey)
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
            // ID-STORE-0014 (2026-08-10): write to the injected `defaults`
            // suite (not UserDefaults.standard). Production (.standard) and
            // XCTest (isolated suite) flows both go through here.
            defaults.set(newValue, forKey: sensitiveClearHoursKey)
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
        // ID-STORE-0014 (2026-08-10): write to the injected `defaults`
        // suite (not UserDefaults.standard).
        didSet { defaults.set(captureRichText, forKey: captureRichTextKey) }
    }

    /// Comma-separated bundle IDs of apps excluded from clipboard monitoring
    @Published var excludedBundleIdsString: String {
        didSet {
            // ID-STORE-0014 (2026-08-10): write to the injected `defaults`
            // suite (not UserDefaults.standard).
            defaults.set(excludedBundleIdsString, forKey: excludedBundleIdsKey)
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
    // ID-PERF-0009 (2026-07-30 audit): ISO8601DateFormatter init is ~1 ms
    // (locale + dateFormat + calendar setup). `quarantineCorruptBlob` is
    // called from `loadItems` / `loadTags` error paths. Hoist to a
    // `static let` so all calls share one instance (same pattern as
    // the date-formatter cache in DateHelpers.swift).
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func quarantineCorruptBlob(key: String, error: Error) {
        let defaults = UserDefaults.standard
        guard let blob = defaults.data(forKey: key) else { return }
        let timestamp = Self.iso8601Formatter.string(from: Date())
        let quarantineKey = "\(key).corrupt-\(timestamp)"
        defaults.set(blob, forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        logger.error("Corrupt blob \(key) quarantined to \(quarantineKey). First-decoder error: \(error.localizedDescription). The next save will overwrite the original key with the current (empty) in-memory collection; recover from the quarantined copy or a backup before saving.")
    }
    /// UserDefaults key for persisted items.
    static let itemsStorageKey = "ClipboardItems"
    // trashedItemsStorageKey moved to TrashStore (HIGH-1, 2026-07-26)
    // ARCH-0002 PR #1 (2026-08-11): visibility loosened from `private`
    // to `internal` so the methods moved to `ClipboardStore+Persistence.swift`
    // can call `logger.error(...)` from the extension. Logic unchanged.
    let logger = Logger(subsystem: "com.clipmemory.app", category: "ClipboardStore")

    /// UserDefaults key for persisted tags. Public so tests can pre-populate or clean up.
    static let tagStorageKey = "ClipMemoryTags"

    /// E.1: Pluggable storage backend (default: FileStorageBackend via UserDefaults)
    // ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so extension can call `backend.saveBlob(...)`. Logic unchanged.
    let backend: StorageBackend

    /// Separate storage backend for the tag dictionary. Defaults to an in-memory
    /// backend in tests; production wires a FileStorageBackend keyed by `tagStorageKey`.
    /// Keeping tags independent of items means clearing items doesn't lose tag
    /// definitions, and the item backend stays unaware of the tag schema.
    private let tagBackend: StorageBackend

    /// M13 (2026-08-03): injectable UserDefaults suite for TrashStore.
/// Stored here so it can be passed to TrashStore during init. Production
/// callers get `.standard`; tests inject a suite through the designated
/// init (see `Tests/.../TestHostIsolationTests.swift` for the canary).
///
/// NEW-9 (2026-08-03 audit): the previous comment enumerated specific
/// write sites (`:315-317`, `:336`) as "the only writes" to `.standard`.
/// That description rotted the moment any didSet added a new
/// `UserDefaults.standard.set(...)` line, which is exactly what
/// happened — `maxItems` didSet, `sensitiveClearHours` setter,
/// `captureRichText` didSet, and `excludedBundleIdsString` didSet all
/// also write to `.standard`. Tests that drive these setters MUST
/// restore the prior state in an absence-aware way (see
/// `TestHostIsolationTests.swift:95-101` for the canonical pattern),
/// or the canary's `key ADDED` check will fire on a fresh CI sandbox.
/// This block now describes the invariant, not the implementation
/// line numbers.
    let defaults: UserDefaults

    // trashBackend moved to TrashStore (HIGH-1, 2026-07-26)

    // MARK: - Initializers

    /// Default initializer — uses FileStorageBackend backed by UserDefaults for
    /// items, tags, and trash (separate UserDefaults keys).
    convenience init() {
        // ID-STORE-0005 (2026-08-01): under XCTest the test bundle is injected
        // into the real app — FileStorageBackend would read AND write the
        // production UserDefaults domain. The host's fixture key differs from
        // the production Keychain key (each test run generates a throwaway
        // key), so any host-side save (OCR backfill, debounced persist, tag
        // ops, test fixtures) plants items the production app cannot decrypt
        // ("N 条损坏") and can overwrite real user data. ID-MON-0002 stopped
        // the live monitor; this closes the remaining persistence path.
        // Isolate all three backends in memory; production behavior unchanged.
        //
        // ID-STORE-0014 (2026-08-10): XCTest branch now ALSO passes the
        // isolated defaults suite (parallels the backend isolation above —
        // was only swapping backend, leaving `defaults = .standard`, which
        // caused `IntegrationTests.testTrimToMaxItemsRemovesOldest` and
        // friends to leak `maxClipboardItems = 3` into the production
        // `com.clipmemory.app` plist). `xcTestDefaults` is a no-op
        // (`.standard`) when XCTestConfigurationFilePath is unset.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            self.init(backend: MemoryStorageBackend(), defaults: Self.xcTestDefaults)
            return
        }
        self.init(backend: FileStorageBackend(),
                  tagBackend: FileStorageBackend(storageKey: ClipboardStore.tagStorageKey),
                  trashBackend: FileStorageBackend(storageKey: TrashStore.trashedItemsStorageKey))
    }

    /// E.1: Designated initializer accepting StorageBackend instances for testing.
    /// `tagBackend` and `trashBackend` default to fresh in-memory backends so
    /// existing tests that only care about items don't accidentally hit UserDefaults.
    /// `defaults` allows tests to isolate TrashStore writes to a test suite.
    ///
    /// ID-STORE-0014 (2026-08-10): `defaults` parameter defaults to
    /// `Self.xcTestDefaults` instead of `.standard`. Under XCTest, that
    /// returns an isolated suite so the production `com.clipmemory.app`
    /// UserDefaults stays untouched (1-arg `ClipboardStore(backend: ...)`
    /// convenience init's XCTest branch passes the same isolated suite
    /// explicitly; the rest of this designated init's body reads/writes
    /// via `defaults` so they stay isolated). Under production, returns
    /// `.standard` — behavior unchanged.
    init(backend: StorageBackend,
         tagBackend: StorageBackend = MemoryStorageBackend(),
         trashBackend: StorageBackend = MemoryStorageBackend(),
         defaults: UserDefaults = ClipboardStore.xcTestDefaults) {
        self.backend = backend
        self.tagBackend = tagBackend
        self.defaults = defaults
        self.trashStore = TrashStore(backend: trashBackend, defaults: defaults)

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
        let savedMaxItems = defaults.object(forKey: maxItemsKey) as? Int
        let clampedInit = savedMaxItems.map { max(Self.minMaxItems, min($0, Self.maxMaxItems)) } ?? 100
        if savedMaxItems != nil && clampedInit != savedMaxItems {
            defaults.set(clampedInit, forKey: maxItemsKey)
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
        if defaults.object(forKey: sensitiveClearHoursKey) != nil {
            _sensitiveClearHours = defaults.integer(forKey: sensitiveClearHoursKey)
        } else {
            _sensitiveClearHours = 24
        }

        // ID-EXCLUDE-0001 (2026-08-14): default list moved to
        // KnownExcludedApps (verified ids + friendly names + the opt-in
        // correction table share one source). Fresh installs only — an
        // existing stored value is the user's setting and is never rewritten.
        excludedBundleIdsString = defaults.string(forKey: excludedBundleIdsKey)
            ?? KnownExcludedApps.defaultBundleIds.joined(separator: ",")

        // trashRetentionDays init moved to TrashStore (HIGH-1, 2026-07-26)

        // Register notification observers AFTER all properties are initialized.
        // F-3 (2026-07-28): convert from selector-based to block-based with
        // `queue: .main` so handlers are type-system guaranteed to run on main
        // thread (SwiftUI @Published mutations + AppKit state). Replaces the
        // previous defensive `DispatchQueue.main.async` wrap inside each handler.
        imageMigrationObserver = NotificationCenter.default.addObserver(
            forName: .imageStorageMigrationCompleted, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let migratedFilenames = notification.userInfo?["migratedFilenames"] as? [String] else { return }
            let migratedSet = Set(migratedFilenames)
            var didMigrateAny = false
            for (index, item) in self.items.enumerated() where item.type == .image && migratedSet.contains(item.content) {
                self.items[index] = item.with(isEncrypted: true)
                didMigrateAny = true
            }
            if didMigrateAny {
                self.scheduleSave()
            }
        }
        // H-2 (2026-07-25 audit): flush captures that were deferred while the
        // encryption key was still being prepared on first launch.
        cryptoKeyPreparedObserver = NotificationCenter.default.addObserver(
            forName: .cryptoKeyPrepared, object: nil, queue: .main
        ) { [weak self] notification in
            self?.handleCryptoKeyPrepared(notification)
        }

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
            // F-1 phase 3 (2026-07-28): collapsed double-hop
            // (DispatchQueue.main.async + MainActor.assumeIsolated) into single
            // `Task { @MainActor in ... }`. Behavior identical: 60s repeat, fires
            // on bg queue, hops to main actor via Swift Concurrency. Sync method
            // calls inside @MainActor closure don't need `await` (same isolation).
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cleanupExpiredItems()
                // NEW-C (2026-07-27 review): drives trash purge on the same
                // 60s cleanup cadence so long-lived sessions don't pile up old
                // trash on disk.
                self.trashStore.purgeExpiredTrash()
            }
        }
        cleanupTimer?.resume()

        // F-1 phase 3 (2026-07-28): mirror TrashStore willTerminate pattern.
        // Observer fires on .main queue, safely invokes @MainActor-isolated
        // handleWillTerminate(). Deinit only removes the opaque token.
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

    /// H2: NSCache for decrypted content — avoids repeated AES decryption on every view render.
    /// Thread-safety: all `items` mutations (addItem/deleteItem/etc.) are on main thread.
    /// cleanupExpiredItems is dispatched to the main thread from its timer so all
    /// reads and writes of `items` stay on the same queue.
    /// P2 (2026-07-29 audit): O(1) contentHash dedup set. Maintained in sync
    /// with `items` array — each non-nil contentHash maps to one entry.
    /// Rebuilt after batch mutations (delete, trim, clear, import, backfill).
    private var dedupHashes: Set<String> = []

    // ID-PERF-0015 (2026-07-30 audit): UUID → items-array-index map.
    // O(n) `items.firstIndex(where:)` was hit on every addTag / removeTag
    // / togglePin / moveToTop — for 10K items that's 10K UUID compares
    // per user action. Maintain a dict; rebuild only when items changes
    // (cheap O(n) build, amortized O(1) per call). Stale index is
    // detected by a version counter — every items mutation increments it.
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` →
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // State stays here because Swift extensions can't have stored properties.
    // Logic unchanged.
    var itemIndexVersion: Int = 0
    var itemIndex: [UUID: Int] = [:]
    var itemIndexBuiltForVersion: Int = -1

    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // Logic unchanged.
    func rebuildItemIndexIfStale() {
        if itemIndexBuiltForVersion == itemIndexVersion { return }
        var built: [UUID: Int] = [:]
        built.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            built[item.id] = i
        }
        itemIndex = built
        itemIndexBuiltForVersion = itemIndexVersion
    }

    /// Call after every `items` mutation. Cheap (one Int increment)
    /// and makes subsequent `rebuildItemIndexIfStale()` calls skip the
    /// O(n) rebuild until the next mutation.
    private func invalidateItemIndex() {
        itemIndexVersion &+= 1
    }

    /// ID-PERF-0026 (2026-08-11 audit): O(1) item lookup by id. Replaces
    /// the row-level `liveIndexByID` computed property that rebuilt a
    /// full `[UUID: ClipboardItem]` dict on every property access —
    /// measured 11× slower than the pre-ID-PERF-0012 `first(where:)`
    /// baseline under multi-access-per-body call patterns.
    /// `rebuildItemIndexIfStale()` keeps the index amortized O(1);
    /// `items.indices.contains` defends against the index/map drift
    /// window that a raw `items[dict[id]!]` would not.
    func item(forID id: UUID) -> ClipboardItem? {
        // PR54-H (v2.8.4 latent bug batch): route through `resolvedIndex(for:)`
        // so the rebuild-stale + bounds-check dance lives in exactly one
        // place — the other 5 internal callers (`addTag`, `removeTag`,
        // `togglePin`, `togglePinItems`, `moveToTop`) plus the
        // `mergePendingDecryptionFailures` site in `ClipboardStore+Encryption`
        // share the same stale-defending contract.
        guard let idx = resolvedIndex(for: id) else { return nil }
        return items[idx]
    }

    /// PR54-H (v2.8.4 latent bug batch): single chokepoint for
    /// "find the index of the item with this id". Wraps the
    /// `rebuildItemIndexIfStale()` + `itemIndex[id]` + `items.indices.contains`
    /// trio so a future caller can't accidentally read a stale or
    /// out-of-bounds index. Returns `nil` when the id is unknown or the
    /// cached map is being rebuilt — callers then early-return or no-op.
    ///
    /// The bounds check (`items.indices.contains`) defends the staleness
    /// window between an `items.remove/insert` and the next
    /// `invalidateItemIndex()` — a raw `items[itemIndex[id]!]` would crash
    /// or silently target the wrong item there. `item(forID:)` already
    /// had this guard; this helper extracts it for the 5+1 other sites.
    func resolvedIndex(for id: UUID) -> Int? {
        rebuildItemIndexIfStale()
        guard let idx = itemIndex[id], items.indices.contains(idx) else { return nil }
        return idx
    }

    /// P2: rebuild dedupHashes from current items array.
    private func rebuildDedupHashSet() {
        dedupHashes = Set(items.compactMap { $0.contentHash })
    }

    // ID-SYNC-0003 (2026-08-01 audit): nonisolated(unsafe) so the nonisolated
    // decrypt kernels (getDecryptedContent / getRTFPlaintext /
    // getDecryptedOcrText) can touch the caches from prewarm's utility-queue
    // workers without violating @MainActor isolation. Safe: NSCache is
    // documented thread-safe for concurrent object(forKey:)/setObject.
    nonisolated(unsafe) let contentCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        cache.totalCostLimit = 10 * 1024 * 1024 // 10MB limit
        return cache
    }()

    /// Cache for parsed RTF plaintext — avoids re-parsing RTF on every access
    /// in search/filter paths where RTF plaintext is read repeatedly.
    /// ID-SYNC-0003: nonisolated(unsafe), same NSCache thread-safety contract
    /// as contentCache above.
    nonisolated(unsafe) private let rtfPlaintextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        cache.totalCostLimit = 10 * 1024 * 1024 // 10MB limit
        return cache
    }()

    /// Observer for `NSApplication.willTerminateNotification`. Registered in
    /// `init` so the flush logic (`flushPendingSaves`) runs on `.main` and
    /// can safely touch `@MainActor`-isolated state. `deinit` only removes
    /// this opaque token (no isolated access).
    ///
    /// Invariant: this observer must fire BEFORE `deinit`. The ClipboardStore
    /// lives as long as NSApp (held via `AppDelegate.applicationDidFinishLaunching`
    /// as the singleton), so willTerminate always fires first under normal
    /// termination. SIGKILL / power-loss paths are out of scope (no write-through
    /// guarantee). Mirrors TrashStore pattern (2026-07-28 F-1 phase 2).
    private var willTerminateObserver: NSObjectProtocol?

    private var cleanupTimer: DispatchSourceTimer?
    // ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so `ClipboardStore+Persistence.swift` can manage the debounce timer.
    var saveTimer: DispatchSourceTimer?
    /// Trash refresh fix (2026-07-27): forwards `trashStore.objectWillChange`
    /// to our own publisher so views observing `ClipboardStore` re-render
    /// when the trash mutates (deletePermanently, emptyTrash, restore).
    private var cancellables: Set<AnyCancellable> = []
    /// M-2 (2026-07-25 audit): reuse a single serial queue for the save timer
    /// instead of creating a new `DispatchQueue` on every `scheduleSave()` call.
    // ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so extension can reference the queue when (re)creating saveTimer.
    let saveTimerQueue = DispatchQueue(label: "com.clipmemory.save", qos: .utility)
    /// HIGH-4 (2026-07-26 review): reuse a single serial queue for the tag
    /// save timer, matching the M-2 reuse pattern applied to saveTimerQueue.
    private let tagSaveTimerQueue = DispatchQueue(label: "com.clipmemory.tagsave", qos: .utility)
    // trashSaveTimerQueue moved to TrashStore (HIGH-1, 2026-07-26)
    // ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so extension can read/write the dirty flag.
    var needsSave = false
    // ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so extension's scheduleSave() can compute debounce deadlines.
    let saveDebounceInterval: DispatchTimeInterval = .milliseconds(500)

    /// H-2 (2026-07-25 audit): captures that arrive before the detached
    /// `CryptoService.prepareKey()` task finishes on first launch are held here
    /// instead of being dropped. Once `.cryptoKeyPrepared` fires with success,
    /// they are re-processed through `addItem(_:)`. Protected by its own lock
    /// because the notification may arrive on any queue.
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // State stays here because Swift extensions can't have stored properties.
    // Logic unchanged.
    var pendingKeyItems: [ClipboardItem] = []
    let pendingKeyItemsLock = NSLock()

    /// C5: IDs whose decryption already failed, pending batched write-back into
    /// `items`. The read path (getDecryptedContent) never mutates @Published
    /// synchronously — marking hops to the main queue asynchronously so it can
    /// never land inside a SwiftUI view-body update (the "open full window
    /// freezes" bug class). The set also short-circuits repeat decrypt attempts
    /// in the gap before the merge lands.
    // ID-SYNC-0003 (2026-08-01 audit): nonisolated(unsafe) — every access is
    // bracketed by the paired NSLock (contract unchanged since C5/P0-2), so
    // the nonisolated decrypt kernels may read/append from any thread.
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // State stays here because Swift extensions can't have stored properties.
    // Logic unchanged.
    nonisolated(unsafe) var pendingFailedIDs = Set<UUID>()
    nonisolated(unsafe) let pendingFailedIDsLock = NSLock()

    // P0-2 F4: 诊断聚合 buffer（复用 C5 模式，避免 view-body 内 publish）
    // ID-SYNC-0003: nonisolated(unsafe), same NSLock contract as above.
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // State stays here because Swift extensions can't have stored properties.
    // Logic unchanged.
    nonisolated(unsafe) var pendingDiagnostics: [PendingDiagnostic] = []
    nonisolated(unsafe) let pendingDiagnosticsLock = NSLock()

    enum PendingDiagnostic {
        // N4 minor: .success 删除（getDecryptedContent 不再 append）
        case keyUnavailable
        case dataCorrupted
        case internalError
    }

    /// F-3 (2026-07-28): opaque tokens for block-based NotificationCenter
    /// observers. Stored so deinit can `removeObserver(_:)` each one — the
    /// selector-based `removeObserver(self)` API no longer applies since
    /// F-3 converted ImageStorageMigrationCompleted + .cryptoKeyPrepared to
    /// block-based form with `queue: .main`. Handler now guaranteed to run on
    /// main thread by type system, replacing the previous defensive
    /// `DispatchQueue.main.async` wrap inside each handler.
    private var imageMigrationObserver: NSObjectProtocol?
    private var cryptoKeyPreparedObserver: NSObjectProtocol?

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
        // F-1 phase 3 (2026-07-28): Task 2 removes MainActor.assumeIsolated
        // flushPendingSaves call; Task 4 moves it to a willTerminate observer
        // registered in init. Deinit stays nonisolated; only removes the
        // opaque willTerminateObserver token (no isolated state touched).
        if let observer = willTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // F-3 (2026-07-28): remove block-based observer tokens. `removeObserver(self)`
        // above only handles selector-based observers registered with `self` as
        // target — block-based observers return opaque tokens that need explicit
        // removal. Without these, the observer chain keeps closures alive after
        // dealloc (same hazard I-2 fix noted for selector observers).
        if let observer = imageMigrationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = cryptoKeyPreparedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // ARCH-0002 PR #3 (2026-08-12): handleCryptoKeyPrepared moved to
    // ClipboardStore+Encryption.swift extension. Cross-file access to
    // pendingKeyItems/pendingKeyItemsLock/pendingFailedIDs/pendingFailedIDsLock
    // is the reason those state vars were loosened from `private` to internal.
    /// M2 (2026-08-01 roadmap): items stored while the encryption key was
    /// unavailable carry `contentHash = nil` — the addItem dedup pre-filter
    /// skips them ("accept a duplicate rather than risk a false collision"),
    /// so repeats captured inside the key-not-ready window (first launch,
    /// Keychain locked) pile up and stay invisible to dedup for the rest of
    /// the session. Once `.cryptoKeyPrepared` reports success, backfill their
    /// hashes off-main (same C6 pattern as the load-time backfill) and merge
    /// the duplicates on main (`mergeBackfilledHashes`).
    ///
    /// ID-STORE-0001 semantics preserved: an item that still cannot be
    /// decrypted keeps `contentHash = nil` — never fingerprint the ciphertext
    /// fallback — and is retried on the next key-ready event / launch.
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // Logic unchanged.
    func backfillHashesAndMergeDuplicatesAfterKeyReady() {
        struct Candidate {
            let id: UUID
            let type: ClipboardItemType
            let content: String
            let isEncrypted: Bool
        }
        let candidates = items.filter { $0.contentHash == nil }.map {
            Candidate(id: $0.id, type: $0.type, content: $0.content, isEncrypted: $0.isEncrypted)
        }
        guard !candidates.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var hashes: [UUID: String] = [:]
            for candidate in candidates {
                let plaintext: String
                if candidate.type == .image {
                    // CLIP-1: the image dedup fingerprint is HMAC over the
                    // base64 of the raw bytes (ClipboardMonitor.imageContentHash).
                    // Recover it from the stored file; a missing / undecryptable
                    // file skips the item — hash stays nil.
                    guard let data = ImageStorage.shared.loadImage(filename: candidate.content) else { continue }
                    plaintext = data.base64EncodedString()
                } else if candidate.isEncrypted {
                    // ID-STORE-0001: decrypt failure → skip; do NOT hash the
                    // ciphertext as a fallback fingerprint.
                    guard let decrypted = ServiceContainer.crypto.decrypt(candidate.content) else { continue }
                    plaintext = decrypted
                } else {
                    plaintext = candidate.content
                }
                if let hash = ServiceContainer.crypto.hmacHex(for: plaintext) {
                    hashes[candidate.id] = hash
                }
            }
            guard !hashes.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.mergeBackfilledHashes(hashes)
            }
        }
    }

    /// M2: main-actor half of `backfillHashesAndMergeDuplicatesAfterKeyReady`.
    /// Applies the computed hashes, then collapses duplicate groups with the
    /// same semantics as addItem's dedup hit: the EARLIEST capture's entry
    /// survives (identity, OCR fields, image filename), its createdAt is
    /// refreshed to the latest capture time and the list re-sorted
    /// newest-first; later duplicates are dropped and their image files
    /// deleted (mirrors addItem's `ImageStorage.shared.deleteImage` on a
    /// dedup hit).
    private func mergeBackfilledHashes(_ hashes: [UUID: String]) {
        var applied = false
        for (id, hash) in hashes {
            guard let index = items.firstIndex(where: { $0.id == id }),
                  items[index].contentHash == nil else { continue }
            items[index].contentHash = hash
            applied = true
        }
        guard applied else { return }

        // Only groups containing a just-backfilled item can be NEW collisions —
        // pre-existing hashed items were already deduped at insertion time.
        let backfilledIds = Set(hashes.keys)
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            guard let hash = item.contentHash else { continue }
            groups["\(item.type.rawValue)|\(hash)", default: []].append(index)
        }

        var removedIndices = Set<Int>()
        var imageFilesToDelete: [String] = []
        for indices in groups.values where indices.count > 1 {
            guard indices.contains(where: { backfilledIds.contains(items[$0].id) }),
                  let survivorIndex = indices.min(by: { items[$0].createdAt < items[$1].createdAt }),
                  let latestCapture = indices.map({ items[$0].createdAt }).max() else { continue }
            for index in indices where index != survivorIndex {
                removedIndices.insert(index)
                let dropped = items[index]
                if dropped.type == .image, dropped.content != items[survivorIndex].content {
                    imageFilesToDelete.append(dropped.content)
                }
            }
            items[survivorIndex] = items[survivorIndex].with(createdAt: latestCapture)
        }

        if !removedIndices.isEmpty {
            items = items.enumerated().filter { !removedIndices.contains($0.offset) }.map { $0.element }
            items.sort { $0.createdAt > $1.createdAt }
            invalidateItemIndex()
            for filename in imageFilesToDelete {
                ImageStorage.shared.deleteImage(filename: filename)
            }
            trimToMaxItems()
            updatePinnedItems()
        }
        rebuildDedupHashSet()
        scheduleSave()
    }

    /// P0-2: user taps banner ✕ → dismiss until next key event.
    func dismissDiagnostics() {
        var d = diagnostics
        d.dismissed = true
        diagnostics = d
    }

    /// P0-2 N4: reset diagnostics.dismissed so the banner reappears after a
    /// key-preparation event (dismiss is session-scoped; new key = new state).
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // Logic unchanged.
    func resetDiagnosticsDismissed() {
        if diagnostics.dismissed {
            var d = diagnostics
            d.dismissed = false
            diagnostics = d
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
            // ID-CRASH-0003 (2026-08-02 audit): keep the ID-CRASH-0001
            // invariant — every `items` mutation invalidates itemIndex.
            invalidateItemIndex()
            return
        }
        // ID-STORE-0002 (2026-07-31 audit): the old `!$0.isExpired` filter
        // dropped expired items silently — including PINNED ones — and the
        // next save wiped them permanently, bypassing the recycle bin.
        // Pinned items are exempt from expiry (pin = explicit retention);
        // expired unpinned items route to the trash below (recoverable).
        let expiredItems = savedItems.filter { $0.isExpired && !$0.isPinned }
        let loadedItems = savedItems.filter { !$0.isExpired || $0.isPinned }

        // Repair legacy image items incorrectly flagged by the old
        // getDecryptedContent path: image content is a filename, never encrypted,
        // so isEncrypted/decryptionFailed should never be true for .image items.
        // (No crypto involved — cheap enough to stay on the load path.)
        //
        // ID-FIX-loadItems-text (2026-07-30 audit): also clear
        // `decryptionFailed` on non-image items. A transient Keychain lock
        // or a one-off decrypt failure sets the flag permanently, but the
        // NEXT launch (with the lock released) successfully decrypts —
        // `getDecryptedContent` short-circuits on the flag and returns nil
        // forever, leaving the row blank. Image items were already reset
        // here; text / richText / link items were stuck. Repaired the
        // same way: clear the flag, let the display path retry on view.
        // Truly-corrupt items get the flag set again on the next failed
        // decrypt — no data loss, just an extra render round-trip.
        var repairedItems = loadedItems
        var repairedImages = false
        var repairedTexts = false
        for (index, item) in repairedItems.enumerated() where item.type == .image {
            if item.isEncrypted || item.decryptionFailed {
                repairedItems[index] = item.with(isEncrypted: false, decryptionFailed: false)
                repairedImages = true
            }
        }
        for (index, item) in repairedItems.enumerated() where item.type != .image {
            if item.decryptionFailed {
                repairedItems[index] = item.with(decryptionFailed: false)
                repairedTexts = true
            }
        }

        items = repairedItems
        invalidateItemIndex()
        updatePinnedItems()
        trimToMaxItems()
        rebuildDedupHashSet()
        if !expiredItems.isEmpty {
            // ID-STORE-0002: trash load-time-expired items BEFORE the
            // orphan-image sweep so their image files stay referenced
            // (restorable from the bin) instead of being swept as orphans.
            // Idempotent across relaunches via TrashStore's per-id dedup
            // (ID-STORE-0003) if the kill lands before the debounced save.
            moveToTrash(expiredItems)
        }
        // H-2 (2026-08-08 user inspect): the ImageStorage guard
        // (`cleanupOrphanedImages` `:903`) only catches the case where
        // BOTH items and trashedItems are empty. If only trashedItems is
        // empty (because the trash blob was corrupt and `loadTrashedItems`
        // swallowed the throw by setting `trashedItems = []`), the guard
        // passes — `keptFilenames` only contains `items`' image filenames
        // and `deleteAllExcept` sweeps every trash image as an orphan.
        // That's irrecoverable data loss from a corrupt trash blob.
        // Skip the sweep entirely while the trash load is in a failed
        // state; the next successful loadItems() / loadTrashedItems() will
        // clear the flag and resume the normal sweep path.
        if !trashStore.lastLoadFailed {
            ImageStorage.shared.cleanupOrphanedImages(keptItems: items + trashedItems)
        } else {
            logger.error("H-2: trash blob load failed; skipping cleanupOrphanedImages to preserve possibly-referenced images. Will retry on next successful loadTrashedItems().")
        }

        if repairedImages || repairedTexts {
            scheduleSave()
        }

        // P0-3 T2: startup image integrity scan. Async batch-check of all image
        // files on disk so the UI can show "image missing" immediately when the
        // user scrolls to a damaged item, without waiting for per-row disk I/O.
        runImageIntegrityScan()

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
                // ID-STORE-0001 (2026-07-31 audit): on decrypt failure
                // (key not ready / corrupt blob) skip the backfill instead
                // of falling back to the ciphertext as "plaintext" — the
                // old `?? candidate.content` fallback persisted an HMAC of
                // the WRONG content as the dedup fingerprint, permanently
                // poisoning dedup for the real content. Leave contentHash
                // nil so a later launch (key available) retries.
                let plaintext: String
                if candidate.isEncrypted {
                    guard let decrypted = ServiceContainer.crypto.decrypt(candidate.content) else { continue }
                    plaintext = decrypted
                } else {
                    plaintext = candidate.content
                }
                if let hash = ServiceContainer.crypto.hmacHex(for: plaintext) {
                    hashes[candidate.id] = hash
                }
            }
            Task { @MainActor [weak self] in
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
                if changed { self.scheduleSave(); self.rebuildDedupHashSet() }
            }
        }
    }

    /// Startup image integrity scan: checks every image item's file on disk
    /// and populates `imageMissingIds` / `imageCorruptedIds`. Runs async on a
    /// utility queue so it never blocks startup. Results merge back on main.
    func runImageIntegrityScan() {
        let imageItems = (items + trashedItems).filter { $0.type == .image }
        guard !imageItems.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var missing: Set<UUID> = []
            var corrupted: Set<UUID> = []
            for item in imageItems {
                let status = ImageStorage.shared.imageStatus(for: item.content)
                switch status {
                case .available: break
                case .fileMissing: missing.insert(item.id)
                case .decryptionFailed: corrupted.insert(item.id)
                }
            }
            Task { @MainActor [weak self] in
                self?.imageMissingIds = missing
                self?.imageCorruptedIds = corrupted
            }
        }
    }

    /// CLIP-2 (2026-07-24): serial queue for JSON-encoding the item array.
    /// `saveItems()` used to run the full-array JSONEncoder pass on the main
    /// thread on every clipboard ingestion (addItem → saveImmediately); with a
    /// large history that blocked the UI per capture. The encode now runs here
    /// at utility QoS; only the encoded Data crosses back for the write.
    // ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so extension's saveItems() can dispatch encoding to utility QoS.
    let itemEncodingQueue = DispatchQueue(label: "com.clipmemory.itemencode", qos: .utility)

    /// H-1: observable retry state — exposed for tests + diagnostics.
    /// (State stays in main class — Swift extensions can't have stored properties.)
    /// H-1: observable retry state — exposed for tests + diagnostics.
    /// ARCH-0002 PR #1 (2026-08-11): visibility loosened from `private(set)`
    /// to `internal` so `ClipboardStore+Persistence.swift` can call
    /// `saveRetryState.recordSuccess()` / `recordFailure()` (mutating
    /// methods require write access). Logic unchanged.
    var saveRetryState = SaveRetryState()

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
        // ID-PERF-0015 (2026-07-30 audit): use the maintained UUID→index
        // map for O(1) lookup instead of `firstIndex(where:)` (O(n) per
        // call). The map is rebuilt by `rebuildItemIndexIfStale()` (inside
        // `resolvedIndex(for:)`) after every items mutation, so it's
        // correct under the O(1) read. PR54-H (v2.8.4): route through
        // `resolvedIndex(for:)` for the bounds-check guard.
        guard let index = resolvedIndex(for: itemId) else { return }
        items[index].tagIds.insert(tagId)
        scheduleSave()
    }

    /// Detach a tag from an item. Does not delete the tag itself; for that use
    /// deleteTag(id:). Safe to call when the tag isn't attached (no-op).
    func removeTag(from itemId: UUID, tagId: UUID) {
        // ID-PERF-0015 + PR54-H (v2.8.4): see addTag above.
        guard let index = resolvedIndex(for: itemId) else { return }
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
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // Logic unchanged.
    static let encryptedNamePrefix = "v2:"

    /// Placeholder shown when a tag name cannot be decrypted.
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // Logic unchanged.
    static let lockedPlaceholder = "[locked]"

    /// Backs up the original encrypted name when decryption fails so a later
    /// `saveTags()` doesn't overwrite the on-disk ciphertext with the placeholder.
    // ARCH-0002 PR #3 (2026-08-12): visibility loosened from `private` to
    // `internal` for cross-file extension access (ClipboardStore+Encryption).
    // State stays here because Swift extensions can't have stored properties.
    // Logic unchanged.
    var encryptedTagNamesBackup: [UUID: String] = [:]

    // ARCH-0002 PR #3 (2026-08-12): encryptTagNames + decryptTagNames moved to
    // ClipboardStore+Encryption.swift extension. Cross-file access to
    // encryptedTagNamesBackup / Self.lockedPlaceholder / Self.encryptedNamePrefix
    // is the reason those were loosened from `private` to internal.

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
                Task { @MainActor [weak self] in
                    self?.flushTagSave()
                }
            }
            timer.resume()
            tagSaveTimer = timer
        }
        tagSaveTimer?.schedule(deadline: .now() + saveDebounceInterval)
    }

    // ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so extension's flushPendingSaves() can call it.
    func flushTagSave() {
        guard tagNeedsSave else { return }
        tagNeedsSave = false
        // ID-LIFE-0023 (2026-07-31): no cancel() here — see flushSave().
        // A cancelled source silently ignores later schedule() calls,
        // which used to kill every debounced tag save after the first flush.
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

        // P2 (2026-07-29 audit): O(1) contentHash dedup via Set lookup.
        // Replaces the previous O(n) firstIndex(where:) scan that degraded
        // to per-item AES-GCM decrypt for legacy items without contentHash.
        // Skip dedup when newHash is nil (HMAC failure) — same contract as
        // before: accept a duplicate rather than risk false collision.
        if let newHash = newHash, dedupHashes.contains(newHash) {
            if let existingIndex = items.firstIndex(where: { $0.contentHash == newHash && $0.type == newItem.type }) {
                var existing = items.remove(at: existingIndex)
                existing = existing.with(createdAt: Date(), contentHash: existing.contentHash ?? newHash)
                // H-3 (2026-08-08 audit): if the existing entry's image file
                // is already missing/corrupt, the user can never self-heal
                // by re-copying — the branch below would unconditionally
                // delete the freshly-saved good file and leave the broken
                // entry in place. Swap instead: point `existing.content` at
                // the new file, drop the old (if still on disk), and clear
                // the id from the integrity-scan sets so ContentView's
                // "image missing" badge disappears reactively.
                if newItem.type == .image, newItem.content != existing.content {
                    let existingIsBroken = imageMissingIds.contains(existing.id)
                        || imageCorruptedIds.contains(existing.id)
                        || !ImageStorage.shared.fileExists(filename: existing.content)
                    if existingIsBroken {
                        let oldFilename = existing.content
                        existing = existing.with(content: newItem.content)
                        imageMissingIds.remove(existing.id)
                        imageCorruptedIds.remove(existing.id)
                        // Old file may already be missing (no delete
                        // needed, and deleteImage would log a misleading
                        // "orphan left on disk" error). Skip the call in
                        // that case to keep the log honest.
                        if ImageStorage.shared.fileExists(filename: oldFilename) {
                            ImageStorage.shared.deleteImage(filename: oldFilename)
                        }
                        logger.info("H-3 swap: recovered broken image entry \(existing.id, privacy: .public) with new file \(newItem.content, privacy: .public)")
                    } else {
                        ImageStorage.shared.deleteImage(filename: newItem.content)
                    }
                }
                items.insert(existing, at: 0)
                invalidateItemIndex()
            } else {
                // Hash in set but item not found (stale from incomplete
                // rebuild after a prior mutation). Insert as new and
                // repair the set below.
                items.insert(newItem, at: 0)
        invalidateItemIndex()
                dedupHashes.insert(newHash)
            }
        } else {
            items.insert(newItem, at: 0)
            invalidateItemIndex()
            if let newHash = newHash { dedupHashes.insert(newHash) }
        }

        trimToMaxItems()
        updatePinnedItems()
        saveImmediately()
        if !isRunningTests, let top = items.first { prewarmDecryptionCache(items: [top], cap: 1) }
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
        invalidateItemIndex()
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
        invalidateItemIndex()
            // M-2 (2026-08-08 audit): `trimToMaxItems` now routes every
            // cap-driven overflow through the recycle bin. For imports
            // specifically, log how much overflowed so users debugging
            // "where did my old entries go?" find the answer in unified log.
            let overflowCount = itemsExceedingMaxItems().count
            trimToMaxItems()
            if overflowCount > 0 {
                logger.warning("M-2: import overflowed \(overflowCount) item(s) beyond maxItems=\(self.maxItems); routed to trash (recoverable for \(self.trashStore.trashRetentionDays)-day retention)")
            }
            updatePinnedItems()
            saveImmediately()
            rebuildDedupHashSet()
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

    // ARCH-0002 PR #3 (2026-08-12): getDecryptedContent / isDecryptionPendingFailed /
    // recordPendingDiagnostic moved to ClipboardStore+Encryption.swift extension.
    // The DEBUG test seams (testAddPendingDiagnostic / testAddPendingFailedID /
    // testContainsPendingFailedID) stay here because tests reach them via the
    // store class directly. Cross-file access to contentCache /
    // pendingFailedIDs(Lock) / pendingDiagnostics(Lock) is the reason those
    // were loosened from `private` to internal.

    #if DEBUG
    /// Test-only: directly inject a pending diagnostic without going through
    /// the getDecryptedContent search path.
    func testAddPendingDiagnostic(_ d: PendingDiagnostic) {
        recordPendingDiagnostic(d)
    }

    /// ID-STORE-NEG-CACHE-SYNC (2026-08-07): Test-only seams for the
    /// pendingFailedIDs buffer so tests can stage a "key re-ready with
    /// pending failures present" scenario without having to manufacture
    /// a real decrypt failure (which requires a wrong-key ciphertext
    /// fixture). Mirrors `testAddPendingDiagnostic`.
    func testAddPendingFailedID(_ id: UUID) {
        pendingFailedIDsLock.lock()
        pendingFailedIDs.insert(id)
        pendingFailedIDsLock.unlock()
    }

    func testContainsPendingFailedID(_ id: UUID) -> Bool {
        isDecryptionPendingFailed(id)
    }
    #endif

    // ARCH-0002 PR #3 (2026-08-12): mergePendingDiagnostics moved to
    // ClipboardStore+Encryption.swift extension. Cross-file access to
    // pendingDiagnostics / pendingDiagnosticsLock / diagnostics is the reason
    // those state vars were loosened from `private` to internal.

    // ID-PERF-0019 (2026-08-01 audit): in-flight batch coalescing. Rapid
    // successive prewarm calls used to overlap N independent background
    // batches — each with its own semaphore — reaching N×prewarmMaxConcurrent
    // concurrent AES-GCM decrypts. Now, while a batch runs, later calls only
    // record their "latest request" (workingSet + completion); the running
    // batch drains the pending request as an immediate follow-up round, so
    // concurrency never exceeds prewarmMaxConcurrent. NSLock-guarded because
    // the drain check runs on a utility queue while calls arrive on main.
    // ARCH-0002 PR #2 (2026-08-11): visibility loosened from `private` →
    // `internal` so the cross-file extension `ClipboardStore+Prewarm.swift`
    // can access this state. State stays here because Swift extensions can't
    // have stored properties. Logic unchanged.
    nonisolated(unsafe) let prewarmStateLock = NSLock()
    nonisolated(unsafe) var prewarmInFlight = false
    nonisolated(unsafe) var prewarmPendingItems: [ClipboardItem]?
    nonisolated(unsafe) var prewarmPendingCompletions: [() -> Void] = []
    // ID-PERF-0024 (2026-08-03 audit): throttle wrapper previously dropped
    // throttled calls forever when no subsequent call landed after the
    // window. Pending re-fire is scheduled via DispatchWorkItem so the
    // dropped items still get prewarmed once the throttle expires.
    // Main-only (asyncAfter fires on main), same access discipline as the
    // nonisolated(unsafe) mutable state above (Swift 6 removal candidate).
    // ARCH-0002 PR #2 (2026-08-11): visibility loosened from `private` →
    // `internal` for cross-file extension access.
    nonisolated(unsafe) var pendingPrewarmWorkItem: DispatchWorkItem?

    /// ID-PERF-0023 (2026-08-02 audit): view-driven prewarm entry with the
    /// same 5 s throttle as AppDelegate's activation prewarm
    /// (`lastPrewarmTime`, AppDelegate.swift:323). ID-VIEW-0012 made the two
    /// view call sites (ContentView / QuickBarView) feed the FULL item set
    /// after every debounced search / items change, so the main-thread
    /// uncached filter in prewarmDecryptionCache ran per keystroke. Both
    /// views now go through this shared wrapper — one timestamp for both,
    /// so ContentView and QuickBarView can't each trigger their own pass
    /// inside the same window. AppDelegate's observer prewarm, the
    /// new-capture single-item prewarm (:1347), and tests keep calling
    /// prewarmDecryptionCache directly (unthrottled).
    // ARCH-0002 PR #2 (2026-08-11): visibility loosened from `private` →
    // `internal` for cross-file extension access.
    var lastViewPrewarmTime: Date = .distantPast

    // ARCH-0002 PR #3 (2026-08-12): scheduleDecryptionFailedMark /
    // mergePendingDecryptionFailures moved to ClipboardStore+Encryption.swift
    // extension. Cross-file access to pendingFailedIDs(Lock) / itemIndex /
    // rebuildItemIndexIfStale / scheduleSave is the reason those were
    // loosened from `private` to internal.

    /// P1 (2026-07-29 audit): returns cached RTF plaintext without decrypting.
    /// Used by filter paths (QuickBarView, ContentView) to check cache warmth
    /// without blocking the main thread on AES-GCM. Returns nil when the
    /// rtfPlaintextCache is cold for this item.
    func cachedRtfPlaintext(_ item: ClipboardItem) -> String? {
        guard item.type == .richText else { return nil }
        return rtfPlaintextCache.object(forKey: item.id.uuidString as NSString) as? String
    }

    /// Returns cached RTF plaintext for an item, parsing and caching on first access.
    /// Avoids repeated NSAttributedString RTF parsing in search/filter paths.
    /// Implementation delegates to the pure `RichTextParser` so the parsing
    /// rules live in exactly one place; only the cache wrapper is here.
    ///
    /// P0-2 T5: switched from routing through getDecryptedContent (which already
    /// uses decryptWithReason) to calling decryptWithReason directly. This lets
    /// the RTF path avoid caching a stale fallback when .keyUnavailable later
    /// resolves — the old path cached "Rich Text" (the fallback label) and
    /// returned it forever even after the key became available.
    // ID-SYNC-0003 (2026-08-01 audit): nonisolated decrypt kernel — touches
    // only rtfPlaintextCache (NSCache), ServiceContainer.crypto (internally
    // locked), RichTextParser/L10n (stateless / lock-guarded), and the
    // NSLock-guarded failure/diagnostics helpers. Callable off-main.
    nonisolated func getRTFPlaintext(_ item: ClipboardItem) -> String {
        guard item.type == .richText else { return "" }
        let key = item.id.uuidString as NSString
        if let cached = rtfPlaintextCache.object(forKey: key) {
            return cached as String
        }
        let base64RTF: String
        if item.isEncrypted {
            let outcome = ServiceContainer.crypto.decryptWithReason(item.content, itemID: item.id)
            switch outcome {
            case .success(let plaintext):
                base64RTF = plaintext
            case .keyUnavailable:
                // N10: transient — do NOT mark decryptionFailed, do NOT cache
                recordPendingDiagnostic(.keyUnavailable)
                return L10n.itemRichText
            case .dataCorrupted:
                scheduleDecryptionFailedMark(item.id)
                recordPendingDiagnostic(.dataCorrupted)
                let result = RichTextParser.plaintext(from: item.content, fallback: L10n.itemRichText)
                // ID-PERF-0017: cost = plaintext bytes so totalCostLimit works.
                rtfPlaintextCache.setObject(result as NSString, forKey: key, cost: result.utf8.count)
                return result
            case .internalError:
                scheduleDecryptionFailedMark(item.id)
                recordPendingDiagnostic(.internalError)
                let result = RichTextParser.plaintext(from: item.content, fallback: L10n.itemRichText)
                // ID-PERF-0017: cost = plaintext bytes so totalCostLimit works.
                rtfPlaintextCache.setObject(result as NSString, forKey: key, cost: result.utf8.count)
                return result
            }
        } else {
            base64RTF = item.content
        }
        let result = RichTextParser.plaintext(from: base64RTF, fallback: L10n.itemRichText)
        // ID-PERF-0017: cost = plaintext bytes so totalCostLimit works.
        rtfPlaintextCache.setObject(result as NSString, forKey: key, cost: result.utf8.count)
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
        trashStore.moveToTrash(item, evictCaches: { _ in }, didMove: { [weak self] in
            self?.items.removeAll { $0.id == item.id }
            // ID-CRASH-0001 (2026-07-31): every `items` mutation MUST
            // invalidate the ID-PERF-0015 index — a stale map crashes or
            // silently targets the wrong item on the next pin/tag/moveToTop.
            self?.invalidateItemIndex()
            self?.updatePinnedItems()
            self?.scheduleSave()
            self?.rebuildDedupHashSet()
        })
    }

    func moveToTrash(_ itemsToMove: [ClipboardItem]) {
        for item in itemsToMove { evictCaches(for: item) }
        let idsToMove = Set(itemsToMove.map { $0.id })
        trashStore.moveToTrash(itemsToMove, evictCaches: { _ in }, didMove: { [weak self] in
            self?.items.removeAll { idsToMove.contains($0.id) }
            self?.invalidateItemIndex() // ID-CRASH-0001
            self?.updatePinnedItems()
            self?.scheduleSave()
            self?.rebuildDedupHashSet()
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
            self?.invalidateItemIndex() // ID-CRASH-0001
            self?.updatePinnedItems()
            self?.scheduleSave()
            self?.rebuildDedupHashSet()
        })
    }

    /// NEW-batch-restore: restore N trash items in one call. Delegates
    /// to the single-item path per element so each restore gets its own
    /// dedup rebuild + index invalidation (one bad item doesn't fail the
    /// whole batch). Insertion order in the resulting `items` array is
    /// the REVERSE of the input order — each `insert(at: 0)` pushes the
    /// previous to position 1, so the LAST item in the input ends up at
    /// index 0. UI callers should pass items in the order they want them
    /// to appear top-to-bottom.
    func restoreFromTrash(_ items: [ClipboardItem]) {
        for item in items {
            restoreFromTrash(item)
        }
    }

    func deletePermanently(_ item: ClipboardItem) { trashStore.deletePermanently(item) }
    func emptyTrash() { trashStore.emptyTrash() }
    func purgeExpiredTrash() { trashStore.purgeExpiredTrash() }

    /// M-2 (2026-08-08 audit): pure helper that returns the items that
    /// would be evicted to make `items` fit within `maxItems` — without
    /// applying any side effects. Lets callers choose the eviction path
    /// (physical delete vs. trash) without duplicating the trim math.
    /// C-1 pinned exemption lives here; non-pinned overflow candidates
    /// are returned in their original `items` order.
    private func itemsExceedingMaxItems() -> [ClipboardItem] {
        guard items.count > maxItems else { return [] }
        let pinned = items.filter { $0.isPinned }
        var nonPinned = items.filter { !$0.isPinned }
        let allowedNonPinned = max(0, maxItems - pinned.count)
        nonPinned = Array(nonPinned.prefix(allowedNonPinned))
        let trimmedIds = Set((pinned + nonPinned).map { $0.id })
        return items.filter { !trimmedIds.contains($0.id) }
    }

    func trimToMaxItems() {
        let overflow = itemsExceedingMaxItems()
        guard !overflow.isEmpty else { return }
        // M-2 (2026-08-08 audit): route every cap-driven eviction
        // through the recycle bin instead of physically deleting. This
        // covers both bulk imports (the audit's primary concern) AND
        // steady-state addItem / togglePin / loadItems overflow, where the
        // same "silent data loss on cap hit" bug applies. Image files
        // stay on disk referenced from the trashed ClipboardItem — the
        // user can restore them via the recycle bin UI.
        // C-1 pinned exemption: `overflow` already excludes pinned items.
        moveToTrash(overflow)
    }

    func deleteItem(_ item: ClipboardItem) {
        moveToTrash(item)
    }

    func togglePin(_ item: ClipboardItem) {
        // PR54-H (v2.8.4): route through `resolvedIndex(for:)` — the bounds
        // check defends against the staleness window after any concurrent
        // items mutation that this method doesn't itself trigger.
        guard let index = resolvedIndex(for: item.id) else { return }
        items[index].isPinned.toggle()
        trimToMaxItems()
        updatePinnedItems()
        scheduleSave()
    }

    func togglePinItems(_ itemsToToggle: [ClipboardItem]) {
        // PR54-H (v2.8.4): same `resolvedIndex` chokepoint. Note we resolve
        // each index INSIDE the loop — between iterations of a rapid-fire
        // batch (or interleaved with another mutator on the main actor),
        // a previous index could go stale. `resolvedIndex` rebuilds the
        // map on each call so the per-iteration lookup is always fresh.
        var didToggleAny = false
        for item in itemsToToggle {
            if let index = resolvedIndex(for: item.id) {
                items[index].isPinned.toggle()
                didToggleAny = true
            }
        }
        trimToMaxItems()
        updatePinnedItems()
        if didToggleAny { scheduleSave() }
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

        // ID-SECURITY-0003 (2026-07-30 audit): stamp
        // `org.nspasteboard.ConcealedType` when copying sensitive items so
        // other apps + the system clipboard monitor can honour "don't
        // log / don't sync / don't share" semantics. Without this marker,
        // any app can pull our pasteboard content (1Password / Bitwarden
        // / Dashlane all stamp this on secret writes). Detection on the
        // read side is at ClipboardMonitor.swift:374-384 — already
        // honours the marker to skip capture.
        // NEW-8 (2026-08-03 audit): the old anchor `:289-296` pointed at
        // the own-write fingerprint helper, which is unrelated to
        // concealed-type detection. Update to the real read-side site
        // (`concealedTypes` set + `isDisjoint` check).
        if item.isSensitive {
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }

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
                // ID-SECURITY-0003 (2026-07-30 audit): mirror the warm-path
                // marker in copyToClipboard — stamp ConcealedType when the
                // item is sensitive so well-behaved apps (and our own
                // ClipboardMonitor read path) suppress/skip the entry.
                if item.isSensitive {
                    pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                }
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
        // PR54-H (v2.8.4): route through `resolvedIndex(for:)`. Note this
        // method also `invalidateItemIndex()` below because `remove/insert`
        // reorders `items` — the index is invalidated, not relied on, after
        // the initial lookup.
        guard let index = resolvedIndex(for: item.id) else { return }
        var moved = items.remove(at: index)
        moved = moved.with(createdAt: Date())
        items.insert(moved, at: 0)
        invalidateItemIndex()
        scheduleSave()
    }

    private func updatePinnedItems() {
        pinnedItems = items.filter { $0.isPinned }
    }

    internal func cleanupExpiredItems() {
        // ID-STORE-0002 (2026-07-31 audit): two fixes —
        // 1. The predicate now exempts pinned items: pin is an explicit
        //    long-term retention guarantee; an expiresAt deadline must not
        //    silently destroy pinned content (same exemption rule as
        //    trimToMaxItems / clearAllItems / clearSensitiveItems).
        // 2. Deletion routes through moveToTrash so expired items land in
        //    the recycle bin (recoverable until trash retention expires)
        //    instead of being permanently removed. Image files are NOT
        //    deleted here — TrashStore's purge / deletePermanently own the
        //    file lifecycle, so a restored expired item keeps its image.
        //    Cache eviction happens inside moveToTrash (evictCaches).
        let expired = items.filter { $0.isExpired && !$0.isPinned }
        guard !expired.isEmpty else { return }
        moveToTrash(expired)
    }
}
