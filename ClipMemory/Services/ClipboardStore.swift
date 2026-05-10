import Foundation
import AppKit
import CommonCrypto
import os.log

extension Notification.Name {
    static let encryptionFailed = Notification.Name("ClipboardStore.encryptionFailed")
    static let showSettingsTab = Notification.Name("ClipMemory.showSettingsTab")
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

    // @Published with didSet for automatic UserDefaults persistence
    @Published var maxItems: Int {
        didSet { UserDefaults.standard.set(maxItems, forKey: maxItemsKey) }
    }

    @Published var sensitiveClearHours: Int {
        didSet { UserDefaults.standard.set(sensitiveClearHours, forKey: sensitiveClearHoursKey) }
    }

    /// Comma-separated bundle IDs of apps excluded from clipboard monitoring
    @Published var excludedBundleIdsString: String {
        didSet {
            UserDefaults.standard.set(excludedBundleIdsString, forKey: excludedBundleIdsKey)
            updateExcludedAppsOnMonitor()
        }
    }

    private let storageKey = "ClipboardItems"
    private let maxItemsKey = "maxClipboardItems"
    private let sensitiveClearHoursKey = "sensitiveClearHours"
    private let excludedBundleIdsKey = "excludedBundleIds"
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "ClipboardStore")

    private var cleanupTimer: Timer?
    private var saveTimer: Timer?
    private var needsSave = false
    private let saveDebounceInterval: TimeInterval = 0.5

    private init() {
        let savedMaxItems = UserDefaults.standard.integer(forKey: maxItemsKey)
        maxItems = savedMaxItems > 0 ? min(savedMaxItems, 500) : 100

        // Use object(forKey:) to distinguish "key doesn't exist" (nil) from "user selected Never" (0)
        if UserDefaults.standard.object(forKey: sensitiveClearHoursKey) != nil {
            sensitiveClearHours = UserDefaults.standard.integer(forKey: sensitiveClearHoursKey)
        } else {
            sensitiveClearHours = 24 // Default: clear after 24 hours
        }

        excludedBundleIdsString = UserDefaults.standard.string(forKey: excludedBundleIdsKey) ?? "com.1password.1password,com.agilebits.onepassword7,com.bitwarden.desktop,com.keepassx.keeweb"

        loadItems()
        updateExcludedAppsOnMonitor()
        cleanupExpiredItems()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupExpiredItems()
        }
        if let t = cleanupTimer {
            RunLoop.current.add(t, forMode: .common)
        }
    }

    deinit {
        cleanupTimer?.invalidate()
        saveTimer?.invalidate()
        flushSave()
    }

    /// Sync excluded bundle IDs from settings string to the clipboard monitor
    func updateExcludedAppsOnMonitor() {
        let ids = Set(excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        clipboardMonitor?.excludedBundleIds = ids
    }

    func loadItems() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let savedItems = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            items = []
            return
        }
        let loadedItems = savedItems.filter { !$0.isExpired }

        // Migrate old-format encrypted items to v2 (AES-GCM)
        var migratedItems = loadedItems
        var needsMigrationSave = false
        for (index, item) in migratedItems.enumerated() where item.isEncrypted && item.type != .image {
            if CryptoService.shared.isOldFormat(item.content),
               let newContent = CryptoService.shared.migrateToV2(item.content) {
                migratedItems[index] = ClipboardItem(
                    id: item.id,
                    content: newContent,
                    type: item.type,
                    createdAt: item.createdAt,
                    isPinned: item.isPinned,
                    isSensitive: item.isSensitive,
                    expiresAt: item.expiresAt,
                    isEncrypted: true,
                    contentHash: item.contentHash
                )
                needsMigrationSave = true
            }
        }

        items = migratedItems
        updatePinnedItems()
        ImageStorage.shared.cleanupOrphanedImages(keptItems: migratedItems)

        // Save migrated items immediately after load
        if needsMigrationSave {
            flushSave()
        }
    }

    func saveItems() {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(items)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            logger.error("Failed to save clipboard items: \(error.localizedDescription)")
        }
    }

    /// Schedules a debounced save — coalesces multiple rapid mutations into a single disk write.
    /// The actual write happens after `saveDebounceInterval` seconds of inactivity.
    private func scheduleSave() {
        needsSave = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDebounceInterval, repeats: false) { [weak self] _ in
            self?.flushSave()
        }
        if let t = saveTimer {
            RunLoop.current.add(t, forMode: .common)
        }
    }

    /// Flushes pending saves to disk immediately. Called by the debounce timer or on deinit.
    private func flushSave() {
        guard needsSave else { return }
        needsSave = false
        saveTimer?.invalidate()
        saveTimer = nil
        saveItems()
    }

    func addItem(_ item: ClipboardItem) {
        var newItem = item
        let plaintextContent = item.content
        var newHash: String?

        // M3: Always encrypt text and link content (images are encrypted by ImageStorage)
        if item.type != .image {
            if let encrypted = CryptoService.shared.encrypt(item.content) {
                newHash = sha256(plaintextContent)
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
            let existingPlaintext = existing.isEncrypted ? (CryptoService.shared.decrypt(existing.content) ?? existing.content) : existing.content
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
                contentHash: existing.contentHash
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
        if item.isEncrypted {
            // Return nil if decryption fails (e.g., key lost after reinstall).
            // Caller must handle nil — never fall back to ciphertext (which is garbage text).
            return CryptoService.shared.decrypt(item.content)
        }
        return item.content
    }

    private func trimToMaxItems() {
        guard items.count > maxItems else { return }
        let pinned = items.filter { $0.isPinned }
        var nonPinned = items.filter { !$0.isPinned }
        let trimmedPinned = pinned.count > maxItems ? Array(pinned.prefix(maxItems)) : pinned
        let allowedNonPinned = max(0, maxItems - trimmedPinned.count)
        nonPinned = Array(nonPinned.prefix(allowedNonPinned))
        let trimmed = trimmedPinned + nonPinned
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
        let filenames = itemsToDelete.filter { $0.type == .image }.map { $0.content }
        for filename in filenames {
            ImageStorage.shared.deleteImage(filename: filename)
        }
        let idsToDelete = Set(itemsToDelete.map { $0.id })
        items.removeAll { idsToDelete.contains($0.id) }
        updatePinnedItems()
        scheduleSave()
    }

    func unpinAll() {
        for i in items.indices {
            items[i].isPinned = false
        }
        updatePinnedItems()
        scheduleSave()
    }

    func clearSensitiveItems() {
        let removedImages = items.filter { $0.isSensitive && !$0.isPinned && $0.type == .image }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { $0.isSensitive && !$0.isPinned }
        updatePinnedItems()
        scheduleSave()
    }

    func clearAllItems() {
        let pinnedIds = Set(pinnedItems.map { $0.id })
        let removedImages = items.filter { !pinnedIds.contains($0.id) && $0.type == .image }
        for item in removedImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { !pinnedIds.contains($0.id) }
        updatePinnedItems()
        scheduleSave()
    }

    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general

        // Prepare content first, then clear + write (prevents data loss if prepare fails)
        var preparedImage: NSImage?
        var preparedText: String?

        switch item.type {
        case .image:
            // Use cached image load for fast access on repeated copies
            preparedImage = ImageStorage.shared.loadImageObject(filename: item.content)
        default:
            preparedText = getDecryptedContent(item)
        }

        // Only clear and write if we have content ready
        guard (preparedImage != nil) || (preparedText != nil) else { return }

        pasteboard.clearContents()

        if let image = preparedImage {
            pasteboard.writeObjects([image as NSImage])
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
            contentHash: moved.contentHash
        )
        items.insert(moved, at: 0)
        scheduleSave()
    }

    private func updatePinnedItems() {
        pinnedItems = items.filter { $0.isPinned }
    }

    private func sha256(_ string: String) -> String {
        guard let data = string.data(using: .utf8), !data.isEmpty else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupExpiredItems() {
        let beforeCount = items.count
        let expiredImages = items.filter { $0.isExpired && $0.type == .image }
        for item in expiredImages {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
        items.removeAll { $0.isExpired }
        if items.count != beforeCount {
            updatePinnedItems()
            scheduleSave()
        }
    }
}
