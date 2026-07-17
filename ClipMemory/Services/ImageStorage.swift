import Foundation
import AppKit
import CommonCrypto
import os.log

// CryptoService is in the same module, no import needed

class ImageStorage {
    static let shared = ImageStorage()

    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "ImageStorage")
    /// Memory cache for loaded images — avoids repeated disk I/O for items visible in the list or copied shortly after
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB memory cap
        return cache
    }()

    private lazy var imagesDirectory: URL = {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClipMemory/Images", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private let legacyImagesDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClipPaste/Images", isDirectory: true)
    }()

    private let migrationCompleteKey = "ImageStorageMigrationComplete"

    private init() {
        migrateFromLegacyIfNeeded()
    }

    /// Migrates unencrypted PNG images from legacy ClipPaste/Images/ to encrypted ClipMemory/Images/.
    /// Only runs once per installation.
    private func migrateFromLegacyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: migrationCompleteKey) == false else { return }
        guard fileManager.fileExists(atPath: legacyImagesDirectory.path) else {
            UserDefaults.standard.set(true, forKey: migrationCompleteKey)
            return
        }

        logger.info("Migrating images from legacy ClipPaste/Images/ to ClipMemory/Images/")

        guard let legacyFiles = try? fileManager.contentsOfDirectory(atPath: legacyImagesDirectory.path) else {
            UserDefaults.standard.set(true, forKey: migrationCompleteKey)
            return
        }

        var migratedFilenames: [String] = []

        for filename in legacyFiles {
            guard filename.hasSuffix(".png"), UUID(uuidString: String(filename.dropLast(4))) != nil else { continue }

            let legacyPath = legacyImagesDirectory.appendingPathComponent(filename)
            guard let imageData = try? Data(contentsOf: legacyPath) else { continue }

            // Check if already encrypted (v2 format starts with "v2", legacy format has specific structure)
            // Unencrypted PNG starts with signature 89 50 4E 47
            let isUnencryptedPNG = imageData.count >= 4 &&
                imageData[0] == 0x89 && imageData[1] == 0x50 &&
                imageData[2] == 0x4E && imageData[3] == 0x47

            if isUnencryptedPNG {
                logger.info("Migrating unencrypted image: \(filename)")
                // Encrypt and save to new location
                if let encryptedData = ServiceContainer.crypto.encryptData(imageData) {
                    let newPath = imagesDirectory.appendingPathComponent(filename)
                    do {
                        try encryptedData.write(to: newPath)
                        migratedFilenames.append(filename)
                        logger.info("Successfully migrated: \(filename)")
                    } catch {
                        logger.error("Failed to write migrated image: \(error.localizedDescription)")
                    }
                }
            } else {
                // Already encrypted (or legacy format), just copy to new location
                let newPath = imagesDirectory.appendingPathComponent(filename)
                do {
                    try imageData.write(to: newPath)
                    migratedFilenames.append(filename)
                } catch {
                    logger.error("Failed to copy image: \(error.localizedDescription)")
                }
            }
        }

        // Mark migration complete AFTER all files are migrated
        UserDefaults.standard.set(true, forKey: migrationCompleteKey)

        // Post notification so ClipboardStore can update isEncrypted flags.
        // Use async to ensure ClipboardStore.init() registers its observer first (avoids race condition).
        if !migratedFilenames.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("ImageStorageMigrationCompleted"),
                    object: nil,
                    userInfo: ["migratedFilenames": migratedFilenames]
                )
            }
        }

        logger.info("Image migration complete: \(migratedFilenames.count) files migrated")
    }

    /// Validates that a filename is safe: must be a UUID string + ".png" extension.
    /// Prevents path traversal attacks where content like "../../.ssh/id_rsa" could be used.
    private func isValidFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".png") else { return false }
        let nameWithoutExt = String(filename.dropLast(4))
        return UUID(uuidString: nameWithoutExt) != nil
    }

    private let maxImageSize = 50 * 1024 * 1024 // 50MB limit
    private let backgroundQueue = DispatchQueue(label: "com.clipmemory.imagestorage", qos: .userInitiated)

    /// Saves image data asynchronously on a background queue to avoid blocking the main thread.
    /// Encryption and disk I/O happen off the main thread.
    func saveImage(_ data: Data, id: UUID, completion: @escaping (String?) -> Void) {
        guard data.count <= maxImageSize else {
            logger.warning("Image too large (\(data.count) bytes), skipping save")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        backgroundQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let filename = "\(id.uuidString).png"
            let fileURL = self.imagesDirectory.appendingPathComponent(filename)

            // Encrypt image data before writing to disk (N2)
            guard let encryptedData = ServiceContainer.crypto.encryptData(data) else {
                self.logger.error("Failed to encrypt image data — image not saved")
                NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                DispatchQueue.main.async { completion(nil) }
                return
            }

            do {
                try encryptedData.write(to: fileURL)
                DispatchQueue.main.async { completion(filename) }
            } catch {
                self.logger.error("Failed to save encrypted image: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    func loadImage(filename: String) -> Data? {
        guard isValidFilename(filename) else { return nil }
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        guard let encryptedData = try? Data(contentsOf: fileURL) else { return nil }

        // Detect format by prefix BEFORE calling decryptData — otherwise the
        // v2 path's internal legacy fallback silently succeeds on legacy
        // blobs, masking them from the migration branch below.
        let isV2 = encryptedData.count >= 2 && encryptedData.prefix(2) == Data("v2".utf8)

        // Try new v2 format directly (no legacy fallback needed)
        if isV2, let data = ServiceContainer.crypto.decryptData(encryptedData) {
            return data
        }

        // Try legacy format; if successful, re-encrypt and save with new format
        if let legacyData = try? legacyDecryptImage(encryptedData) {
            // Re-encrypt with new format and overwrite the file
            if let newEncrypted = ServiceContainer.crypto.encryptData(legacyData) {
                try? newEncrypted.write(to: fileURL)
            }
            return legacyData
        }

        return nil
    }

    /// Decrypts image data using legacy AES-CBC+HMAC format (pre-v2).
    /// Used only for migrating existing image files to the new v2 format.
    private func legacyDecryptImage(_ combined: Data) throws -> Data? {
        guard let key = try? Data(contentsOf: CryptoService.keyFileURL), key.count == 32 else {
            return nil
        }

        if combined.count >= 49 {
            let hmacSize = 32
            // Wrap slice with Data(...) — same fix as CryptoService.decryptLegacy:
            // `combined.suffix(_:)` returns Slice<Data> with non-zero startIndex;
            // constantTimeCompare's 0-based loop would trap on the raw slice.
            let storedHMAC = Data(combined.suffix(hmacSize))
            let ivAndCiphertext = combined.dropLast(hmacSize)

            let computedHMAC = CryptoService.computeLegacyHMAC(data: Data(ivAndCiphertext), key: key)
            // C1 fix (a00da7c follow-up): use constant-time compare. The previous
            // `==` short-circuits on first byte mismatch, leaking the position of
            // the first differing byte to a local timing oracle. CryptoService's
            // decryptLegacy path was migrated in a00da7c; ImageStorage's
            // legacyDecryptImage was missed and is the second HMAC verification
            // site that has the same risk.
            guard CryptoService.constantTimeCompare(computedHMAC, storedHMAC) else { return nil }

            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16).dropLast(hmacSize)

            return try aesDecryptCBC(data: Data(ciphertext), key: key, iv: Data(iv))
        }

        if combined.count > 16 {
            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16)
            return try aesDecryptCBC(data: Data(ciphertext), key: key, iv: Data(iv))
        }

        return nil
    }

    private func aesDecryptCBC(data: Data, key: Data, iv: Data) throws -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, 32,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        &decryptedBytes, bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess, numBytesDecrypted > 0 else { return nil }
        return Data(decryptedBytes.prefix(numBytesDecrypted))
    }

    /// Loads image as NSImage, checking memory cache first for fast repeated access.
    func loadImageObject(filename: String) -> NSImage? {
        guard isValidFilename(filename) else { return nil }
        // Check memory cache first
        if let cached = imageCache.object(forKey: filename as NSString) {
            return cached
        }
        // Load from disk and cache
        guard let data = loadImage(filename: filename),
              let image = NSImage(data: data) else {
            return nil
        }
        imageCache.setObject(image, forKey: filename as NSString)
        return image
    }

    func deleteImage(filename: String) {
        guard isValidFilename(filename) else { return }
        imageCache.removeObject(forKey: filename as NSString)
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: fileURL)
    }

    func deleteAllExcept(filenames: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        for file in files {
            guard isValidFilename(file) else { continue }
            if !filenames.contains(file) {
                try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(file))
            }
        }
    }

    func cleanupOrphanedImages(keptItems: [ClipboardItem]) {
        let keptFilenames = Set(keptItems.filter { $0.type == .image }.map { $0.content })
        guard !keptFilenames.isEmpty else { return }
        // Skip cleanup on first call (startup) to avoid deleting freshly migrated images
        // that haven't been added to store.items yet
        let startupCleanupKey = "ImageStorageStartupCleanupRan"
        if !UserDefaults.standard.bool(forKey: startupCleanupKey) {
            UserDefaults.standard.set(true, forKey: startupCleanupKey)
            return
        }
        deleteAllExcept(filenames: keptFilenames)
    }
}
