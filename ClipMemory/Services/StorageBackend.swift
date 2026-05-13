import Foundation

/// E.1: Storage backend protocol for ClipboardStore dependency injection.
/// Allows swapping between file-based (UserDefaults) and in-memory storage for testing.
protocol StorageBackend {
    /// Loads all stored clipboard items.
    func load() throws -> [ClipboardItem]

    /// Saves the full list of clipboard items.
    func save(_ items: [ClipboardItem]) throws
}

// MARK: - File Storage (UserDefaults)

/// Production backend backed by UserDefaults.
/// UserDefaults writes are dispatched to main thread to match the original behavior.
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
        DispatchQueue.main.async {
            UserDefaults.standard.set(data, forKey: self.storageKey)
        }
    }
}

// MARK: - Memory Storage (Testing)

/// In-memory backend for testing without persisting to UserDefaults.
final class MemoryStorageBackend: StorageBackend {
    var items: [ClipboardItem] = []

    init(items: [ClipboardItem] = []) {
        self.items = items
    }

    func load() throws -> [ClipboardItem] {
        return items
    }

    func save(_ items: [ClipboardItem]) throws {
        self.items = items
    }
}
