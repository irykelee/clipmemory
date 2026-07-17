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
}

// MARK: - File Storage (UserDefaults)

/// Production backend backed by UserDefaults.
/// Writes are synchronous so `flushPendingSaves()` can guarantee data hits disk
/// before the app terminates.
final class FileStorageBackend: StorageBackend {
    private let storageKey: String

    init(storageKey: String = "ClipboardItems") {
        self.storageKey = storageKey
    }

    func load() throws -> [ClipboardItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([ClipboardItem].self, from: data)
    }

    func save(_ items: [ClipboardItem]) throws {
        let data = try JSONEncoder().encode(items)
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func loadTags() throws -> [Tag] {
        // Same UserDefaults key is used for both items and tags only if the caller
        // reuses the default key for both — but in practice tags use a different
        // key (ClipboardStore.tagStorageKey). This method reads whatever is at
        // `storageKey`; if it's the items array the decode will throw and the
        // caller treats it as empty tags.
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([Tag].self, from: data)
    }

    func saveTags(_ tags: [Tag]) throws {
        let data = try JSONEncoder().encode(tags)
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Memory Storage (Testing)

/// In-memory backend for testing without persisting to UserDefaults.
final class MemoryStorageBackend: StorageBackend {
    var items: [ClipboardItem] = []
    var tags: [Tag] = []

    init(items: [ClipboardItem] = []) {
        self.items = items
    }

    func load() throws -> [ClipboardItem] {
        return items
    }

    func save(_ items: [ClipboardItem]) throws {
        self.items = items
    }

    func loadTags() throws -> [Tag] {
        return tags
    }

    func saveTags(_ tags: [Tag]) throws {
        self.tags = tags
    }
}
