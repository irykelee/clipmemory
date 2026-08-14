import Foundation

/// E.1: Storage backend protocol for ClipboardStore dependency injection.
/// Allows swapping between file-based (UserDefaults) and in-memory storage for testing.
protocol StorageBackend {
    /// Loads all stored clipboard items.
    func load() throws -> [ClipboardItem]

    /// Saves the full list of clipboard items.
    func save(_ items: [ClipboardItem]) throws

    /// Loads all stored tags. Default impl returns empty — backends that don't
    /// support tags (or test backends that don't care) can rely on this.
    func loadTags() throws -> [Tag]

    /// Saves the full list of tags. Default impl no-ops; mirrors `loadTags()`.
    func saveTags(_ tags: [Tag]) throws

    /// Saves a pre-encoded JSON blob of the item list. CLIP-2 (2026-07-24):
    /// lets ClipboardStore run `JSONEncoder.encode` off the calling thread and
    /// hand only the finished `Data` back for the write, instead of the
    /// backend encoding a full item array on the main thread. The default
    /// implementation decodes and routes through `save(_:)` so item-array
    /// backends (in-memory test doubles) keep their existing semantics.
    func saveBlob(_ data: Data) throws
}

extension StorageBackend {
    func saveBlob(_ data: Data) throws {
        let items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        try save(items)
    }
}

// MARK: - File Storage (UserDefaults)

/// Production backend backed by UserDefaults — **despite the name, it
/// does NOT touch the filesystem**. The "File" in the name is a
/// historical artifact from when this protocol was first introduced
/// (then FileStorageBackend was intended to write to disk via
/// `~/Library/Application Support/ClipMemory/...`; that plan was
/// dropped in favor of UserDefaults for atomicity). Reads and writes
/// go through `UserDefaults.standard` only — see `init`, `load`,
/// `save`, `saveBlob`. Tests that want real disk isolation should use
/// a different backend or wrap with `testDefaults` via the
/// `makeTestDefaults()` test seam.
///
/// Writes are synchronous so `flushPendingSaves()` can guarantee data hits
/// the UserDefaults store before the app terminates.
final class FileStorageBackend: StorageBackend {
    // ID-PERF-0001 (2026-07-30 audit): hoist JSONEncoder allocation.
    // JSONEncoder is documented thread-safe for `.encode()` since macOS 10.15,
    // so a class-scope static is safe. Used serially per call site (each
    // save/saveTags runs to completion before the next).
    private static let itemsEncoder = JSONEncoder()
    private static let tagsEncoder = JSONEncoder()

    private let storageKey: String

    // ID-STORE-0015 (2026-08-14, L26 live drill path C): inject the defaults
    // suite so callers (notably TrashStore.init(backend:defaults:)) can route
    // the production defaults down to the storage layer. Default `.standard`
    // keeps every existing call-site working — the convenience inits in
    // ClipboardStore() now pass their `defaults` (which is `xcTestDefaults`
    // under XCTest, `.standard` in production) explicitly so this seam is
    // the only path that ever touches the host UserDefaults.
    private let defaults: UserDefaults

    init(storageKey: String = "ClipboardItems",
         defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
    }

    func load() throws -> [ClipboardItem] {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([ClipboardItem].self, from: data)
    }

    func save(_ items: [ClipboardItem]) throws {
        let data = try Self.itemsEncoder.encode(items)
        defaults.set(data, forKey: storageKey)
    }

    /// CLIP-2: persist an already-encoded blob — the write itself is a single
    /// UserDefaults set; the expensive JSONEncoder pass happened on the
    /// caller's encoding queue.
    func saveBlob(_ data: Data) throws {
        defaults.set(data, forKey: storageKey)
    }

    func loadTags() throws -> [Tag] {
        // Same UserDefaults key is used for both items and tags only if the caller
        // reuses the default key for both — but in practice tags use a different
        // key (ClipboardStore.tagStorageKey). This method reads whatever is at
        // `storageKey`; if it's the items array the decode will throw and the
        // caller treats it as empty tags.
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([Tag].self, from: data)
    }

    func saveTags(_ tags: [Tag]) throws {
        let data = try Self.tagsEncoder.encode(tags)
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Memory Storage (Testing)

/// In-memory backend for testing without persisting to UserDefaults.
final class MemoryStorageBackend: StorageBackend {
    // I-7 fix (2026-07-20 audit): the in-memory backend's mutable arrays
    // were not protected against concurrent reads/writes. Swift arrays do
    // not give a hard guarantee against cross-thread mutation (Array
    // mutation is documented as not thread-safe). Production code paths
    // are main-actor; tests typically run synchronously; but a test that
    // races `save()` from two threads, or reads `items` while another
    // thread mutates it, can crash or silently drop data. Use an
    // NSLock to keep the contract honest for any future caller.
    private let lock = NSLock()
    private var _items: [ClipboardItem] = []
    private var _tags: [Tag] = []

    init(items: [ClipboardItem] = []) {
        self._items = items
    }

    func load() throws -> [ClipboardItem] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    func save(_ items: [ClipboardItem]) throws {
        lock.lock(); defer { lock.unlock() }
        self._items = items
    }

    func loadTags() throws -> [Tag] {
        lock.lock(); defer { lock.unlock() }
        return _tags
    }

    func saveTags(_ tags: [Tag]) throws {
        lock.lock(); defer { lock.unlock() }
        self._tags = tags
    }
}
