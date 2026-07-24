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

    // BUG-026 (2026-07-21): Swift lazy is not thread-safe — concurrent first
    // access can cause double initialization. Use `let` with immediate init.
    // XCTest env check happens at class construction time; XCTest sets
    // XCTestConfigurationFilePath before any test class instance is created.
    private let imagesDirectory: URL = {
        let appSupport = AppDirectories.applicationSupport
        // Under XCTest, redirect to a sandboxed directory. Tests exercise
        // cleanupOrphanedImages/deleteAllExcept with narrow keep lists, and
        // every ClipboardStore(...) in a test runs loadItems -> cleanup —
        // against the real directory that wiped the user's actual image
        // files on every test run (root cause of "screenshots vanish").
        let dirname = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? "ClipMemory/Images-Tests"
            : "ClipMemory/Images"
        let dir = appSupport.appendingPathComponent(dirname, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) == false {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    /// Exposed for backup/export code that needs the real (or test-sandboxed) path.
    var imagesDirectoryURL: URL { imagesDirectory }

    private let legacyImagesDirectory: URL = {
        let appSupport = AppDirectories.applicationSupport
        return appSupport.appendingPathComponent("ClipPaste/Images", isDirectory: true)
    }()

    private let migrationCompleteKey = "ImageStorageMigrationComplete"
    /// Tracks individual filenames that have already been migrated so a
    /// partially-failed migration can resume without re-copying successes.
    private let migratedFilenamesKey = "ImageStorageMigratedFilenames"

    enum ImageLoadStatus: Equatable {
        case available(Data)
        case fileMissing
        case decryptionFailed
    }

    private init() {
        // I-5 fix (2026-07-20 audit): in XCTest, do NOT run legacy migration
        // and do NOT touch UserDefaults.standard. XCTest runs in a separate
        // binary but shares the bundle-id UserDefaults domain with production,
        // so a test that sets `migrationCompleteKey = true` would mask real
        // legacy migration on the user's next production launch — and a test
        // that wrote the migrationComplete key for fake test data would
        // permanently disable the user's real migration. The new test fixture
        // is responsible for setting up its own source/destination if it
        // needs to exercise the migration path.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        migrateFromLegacyIfNeeded()
    }

    /// Migrates unencrypted PNG images from legacy ClipPaste/Images/ to encrypted ClipMemory/Images/.
    /// Tracks migrated filenames so a partially-failed run can resume on the
    /// next launch without re-copying successes. The global completion flag is
    /// only set once every eligible file has been processed successfully.
    private func migrateFromLegacyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: migrationCompleteKey) == false else { return }
        guard fileManager.fileExists(atPath: legacyImagesDirectory.path) else {
            UserDefaults.standard.set(true, forKey: migrationCompleteKey)
            return
        }

        logger.info("Migrating images from legacy ClipPaste/Images/ to ClipMemory/Images/")

        guard let legacyFiles = try? fileManager.contentsOfDirectory(atPath: legacyImagesDirectory.path) else {
            // Directory exists but could not be read; leave flag false so the
            // next launch retries instead of silently dropping images.
            return
        }

        var migratedFilenames: [String] = []
        var migratedSet = Set(UserDefaults.standard.stringArray(forKey: migratedFilenamesKey) ?? [])
        var hadFailure = false

        for filename in legacyFiles {
            guard filename.hasSuffix(".png"), UUID(uuidString: String(filename.dropLast(4))) != nil else { continue }
            guard !migratedSet.contains(filename) else { continue }

            let legacyPath = legacyImagesDirectory.appendingPathComponent(filename)
            // BUG-028 (2026-07-21): check size via attributesOfItem BEFORE
            // Data(contentsOf:) — avoids allocating a potentially-GB-sized
            // buffer for a corrupted/expanded legacy file. L-4 previously
            // checked after the load (50MB cap, but still allocates).
            let fileAttrs = try? fileManager.attributesOfItem(atPath: legacyPath.path)
            let fileSize = (fileAttrs?[.size] as? NSNumber)?.intValue ?? 0
            guard fileSize > 0, fileSize <= maxImageSize else {
                logger.warning("Skipping oversized legacy image: \(filename) (\(fileSize) bytes)")
                hadFailure = true
                continue
            }
            guard let imageData = try? Data(contentsOf: legacyPath) else {
                hadFailure = true
                continue
            }

            var success = false
            // Check if already encrypted (v2 format starts with "v2", legacy format has specific structure)
            // Unencrypted PNG starts with signature 89 50 4E 47
            let isUnencryptedPNG = imageData.count >= 4 &&
                imageData[0] == 0x89 && imageData[1] == 0x50 &&
                imageData[2] == 0x4E && imageData[3] == 0x47
            if isUnencryptedPNG {
                logger.info("Migrating unencrypted image: \(filename)")
                success = migrateUnencryptedPNG(
                    filename: filename, imageData: imageData, legacyPath: legacyPath
                )
            } else {
                // Already encrypted (or legacy format), just copy to new location
                success = copyLegacyImage(
                    filename: filename, imageData: imageData, legacyPath: legacyPath
                )
            }

            if success {
                migratedFilenames.append(filename)
                migratedSet.insert(filename)
                UserDefaults.standard.set(Array(migratedSet), forKey: migratedFilenamesKey)
            } else {
                hadFailure = true
            }
        }

        // Only mark migration complete when every eligible file has been
        // processed. If anything failed, the next launch will retry the rest.
        if !hadFailure {
            UserDefaults.standard.set(true, forKey: migrationCompleteKey)
            // M-3 + 2.1 (2026-07-23 audit): post-migration cleanup. Originally
            // `removeItem(at: legacyImagesDirectory)` deleted the whole dir
            // — but the legacy dir belongs to the old ClipPaste app and may
            // contain user files that never matched our migration filter
            // (non-UUID-prefix files, non-PNG extensions, subfolders, etc.).
            // Removing the whole dir would silently destroy those. Now we
            // remove ONLY the files we successfully migrated; anything else
            // stays. The forensic-residue concern from M-3 is fully addressed
            // because all plaintext PNGs eligible for migration are gone.
            //
            // `try?` per file: removal is best-effort. If a particular file
            // is locked, we still mark the migration complete and move on —
            // at worst one plaintext PNG lingers, which is no worse than
            // the pre-M-3 state.
            for filename in migratedFilenames {
                try? fileManager.removeItem(
                    at: legacyImagesDirectory.appendingPathComponent(filename)
                )
            }
        }

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

        logger.info("Image migration complete: \(migratedFilenames.count) files migrated, hadFailure=\(hadFailure)")
    }

    /// Encrypt and write one unencrypted legacy PNG. Returns true on success.
    /// Original logic preserved verbatim (encrypt failure → no logger, silent skip).
    private func migrateUnencryptedPNG(
        filename: String, imageData: Data, legacyPath: URL
    ) -> Bool {
        // Encrypt and save to new location
        guard let encryptedData = ServiceContainer.crypto.encryptData(imageData) else { return false }
        let newPath = imagesDirectory.appendingPathComponent(filename)
        do {
            try encryptedData.write(to: newPath, options: .atomic)
            try fileManager.removeItem(at: legacyPath)
            logger.info("Successfully migrated: \(filename)")
            return true
        } catch {
            logger.error("Failed to write migrated image: \(error.localizedDescription)")
            return false
        }
    }

    /// Copy an already-encrypted legacy file as-is to the new location.
    private func copyLegacyImage(
        filename: String, imageData: Data, legacyPath: URL
    ) -> Bool {
        let newPath = imagesDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: newPath, options: .atomic)
            try fileManager.removeItem(at: legacyPath)
            return true
        } catch {
            logger.error("Failed to copy image: \(error.localizedDescription)")
            return false
        }
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

    // P1-4 (2026-07-23 audit): in-memory counter for silent disk corruption.
    // imageStatus(for:) returns .decryptionFailed for the same terminal
    // reasons that previously produced no observability — bad sector, partial
    // overwrite, key drift — and users had no way to tell whether a broken
    // image was a one-off or a trend. The counter + per-event log line let
    // diagnostics surface the rate without persisting on disk (deliberate
    // choice: counters reset on launch so a stale "5 events" reading from
    // 2 weeks ago can't mask new corruption).
    //
    // NSLock because imageStatus may be called from the statusQueue (background)
    // and counter reads from any thread; Int is not atomic across threads
    // without a lock. Originally OSAllocatedUnfairLock but C-1 (2026-07-24
    // audit) flagged it as macOS 14+ only; this is a single Int increment
    // path so NSLock has no measurable cost.
    private static let corruptionCountLock = NSLock()
    private static var corruptionCount: Int = 0

    /// Number of times `imageStatus(for:)` has returned `.decryptionFailed`
    /// since process start. Reset on each launch (in-memory only). P1-4.
    static var corruptionEventCount: Int {
        corruptionCountLock.lock()
        defer { corruptionCountLock.unlock() }
        return corruptionCount
    }

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
                // M-8 (2026-07-24 audit): the observer chain (AppDelegate,
                // Settings diagnostics) expects main-thread delivery. Post
                // via main async so any future observer that doesn't pass
                // `queue: .main` still sees the notification on the right
                // queue.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                }
                DispatchQueue.main.async { completion(nil) }
                return
            }

            do {
                try encryptedData.write(to: fileURL, options: .atomic)
                DispatchQueue.main.async { completion(filename) }
            } catch {
                self.logger.error("Failed to save encrypted image: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // Serializes legacy-migration writes across threads. Multiple callers
    // invoking imageStatus(for:) concurrently for the same legacy PNG would
    // otherwise race against each other's re-encrypted file write (per gate 1b Medium #4 fix).
    private static let migrationQueue = DispatchQueue(label: "com.clipmemory.imageStorage.legacyMigration")

    /// Serial queue used by `imageStatus` for off-main disk reads. Same
    /// queue is reused by `imageStatusAsync` so the order of reads is
    /// deterministic and concurrent migrations don't race reads.
    private let statusQueue = DispatchQueue(label: "com.clipmemory.imageStorage.status", qos: .userInitiated)

    func loadImage(filename: String) -> Data? {
        // M-5 (2026-07-24 audit): the inner `migrationQueue.sync` (legacy
        // image migration) can block the caller for hundreds of ms when
        // cold-loading many legacy PNGs. UI callers must use
        // `imageStatusAsync` instead. Today the only production caller is
        // the OCR backfill pipeline (ClipboardStore+OCR.swift), which runs
        // on a detached task — but a future main-thread caller would freeze
        // the app for the duration of every cold image. Surface the contract
        // loudly so the next caller picks the async path on purpose.
        // XCTest owns its main thread for free, so tests are exempt.
        precondition(
            !Thread.isMainThread || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            "loadImage blocks the caller for legacy migrations; use imageStatusAsync on the main thread"
        )
        guard case .available(let data) = imageStatus(for: filename) else {
            return nil
        }
        return data
    }

    /// Async variant of `imageStatus(for:)`. The sync version is still
    /// available for tests and internal callers (loadImage uses it), but
    /// BUG-029 (2026-07-21): UI callers used to call the sync version from
    /// a Task.detached closure — but the inner `Data(contentsOf:)` read +
    /// legacy-decrypt path still ran on the calling thread of `Task.detached`
    /// (a Swift cooperative thread pool worker, not the main thread).
    /// For users with hundreds of cold images on first list render that
    /// worker pool starves. This wrapper hops onto a serial dedicated queue
    /// so heavy image-status work is fully off any SwiftUI render path.
    func imageStatusAsync(for filename: String) async -> ImageLoadStatus {
        await withCheckedContinuation { continuation in
            statusQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .fileMissing)
                    return
                }
                continuation.resume(returning: self.imageStatus(for: filename))
            }
        }
    }

    /// Returns the availability status of an image file without caching.
    /// Used by the UI to distinguish "file missing" from "decryption failed"
    /// so users are not prompted to delete entries whose key has been corrupted.
    func imageStatus(for filename: String) -> ImageLoadStatus {
        guard isValidFilename(filename) else { return .fileMissing }
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        // C-3 (2026-07-24 audit): the prior implementation read the file
        // OUTSIDE migrationQueue (Data(contentsOf:) at line 334) and only
        // serialized the re-encrypted write. Two threads racing on the same
        // legacy PNG could both read pre-migration bytes, both enter the
        // legacy-decrypt path, and produce inconsistent on-disk state with
        // .decryptionFailed returned to the UI for files that are actually
        // fine. Wrap read + process + write in a single migrationQueue.sync
        // so concurrent calls for the same file serialize end-to-end.
        return Self.migrationQueue.sync {
            guard fileManager.fileExists(atPath: fileURL.path),
                  let encryptedData = try? Data(contentsOf: fileURL) else {
                return .fileMissing
            }

            // Detect format by prefix BEFORE calling decryptData — otherwise the
            // v2 path's internal legacy fallback silently succeeds on legacy
            // blobs, masking them from the migration branch below.
            let isV2 = encryptedData.count >= 2 && encryptedData.prefix(2) == Data("v2".utf8)

            // Try new v2 format directly (no legacy fallback needed)
            if isV2, let data = ServiceContainer.crypto.decryptData(encryptedData) {
                return .available(data)
            }

            // Try legacy format; if successful, re-encrypt and save with new format
            if let legacyData = try? legacyDecryptImage(encryptedData) {
                // Already inside migrationQueue.sync — write directly here.
                if let newEncrypted = ServiceContainer.crypto.encryptData(legacyData) {
                    try? newEncrypted.write(to: fileURL, options: .atomic)
                }
                return .available(legacyData)
            }

            // Last resort: raw/unencrypted PNG on disk (pre-encryption history).
            // Detected by PNG magic bytes 89 50 4E 47. Re-encrypt opportunistically
            // so subsequent loads take the v2 fast path.
            if encryptedData.count >= 4 &&
                encryptedData[0] == 0x89 && encryptedData[1] == 0x50 &&
                encryptedData[2] == 0x4E && encryptedData[3] == 0x47 {
                if let newEncrypted = ServiceContainer.crypto.encryptData(encryptedData) {
                    try? newEncrypted.write(to: fileURL, options: .atomic)
                }
                return .available(encryptedData)
            }

            // P1-4 (2026-07-23 audit): every terminal .decryptionFailed now bumps
            // the corruption counter + emits a log line. The log lets a user grep
            // Console.app for "imageCorrupted" to find which filenames are
            // affected; the counter gives Settings/diagnostics a current rate
            // without forcing users to dig through the system log.
            Self.corruptionCountLock.lock()
            Self.corruptionCount += 1
            Self.corruptionCountLock.unlock()
            logger.error("imageCorrupted filename=\(filename, privacy: .public) bytes=\(encryptedData.count)")
            return .decryptionFailed
        }
    }

    /// Decrypts image data using legacy AES-CBC+HMAC format (pre-v2).
    /// Used only for migrating existing image files to the new v2 format.
    private func legacyDecryptImage(_ combined: Data) throws -> Data? {
        // C-2 fix (2026-07-20 audit): post-C1, the file key is gone but the
        // user's Keychain entry carries the same 32 bytes. `CryptoService
        // .loadKeyData()` already implements the "try Keychain first, fall
        // back to key file" resolution (added in C1). Without this fallback,
        // every legacy-encrypted image left behind after upgrade surfaces as
        // `.decryptionFailed` in the UI and is effectively unrecoverable.
        guard let key = CryptoService.loadKeyData(), key.count == 32 else {
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

        // M-5 (2026-07-21 audit): align with CryptoService C4 strategy. The
        // pre-1.2.0 branch (no HMAC, unauthenticated CBC) lets a local process
        // that can write Images/ tamper ciphertext and observe a padding-oracle-
        // style success / timing channel. CryptoService.decryptLegacy removed
        // this path in C4 and refuses; ImageStorage's legacyDecryptImage
        // previously kept it open to read very old archives. We close it: any
        // combined buffer under 49 bytes (no HMAC) is treated as tampered /
        // corrupt and surfaces as `.decryptionFailed` in the UI like the main
        // path. Upgrade tools in the export path don't exercise this code.
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
        // BUG-027 (2026-07-21): pass cost: data.count so totalCostLimit (100MB)
// can trigger eviction. Without cost:, only countLimit (100) is
// effective — 100 large images can far exceed 100MB.
imageCache.setObject(image, forKey: filename as NSString, cost: data.count)
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
        var deleted = 0
        for file in files {
            guard isValidFilename(file) else { continue }
            if !filenames.contains(file) {
                try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(file))
                deleted += 1
            }
        }
        // Bulk deletions used to happen silently — log them so a future
        // "images vanished" report can be traced in the system log.
        if deleted > 0 {
            logger.info("deleteAllExcept: removed \(deleted) orphaned image file(s), kept \(filenames.count)")
        }
    }

    func cleanupOrphanedImages(keptItems: [ClipboardItem]) {
        // Skip cleanup on first call (startup) to avoid deleting freshly migrated images
        // that haven't been added to store.items yet. The flag is set on EVERY first
        // call — even when there are no images in store — so a transient empty-store
        // launch (e.g., right after the user clears their history) doesn't leave the
        // guard permanently unarmed, which would risk deleting images on a later launch
        // when items have been re-added but cleanupOrphanedImages runs with a stale
        // view of the world.
        let startupCleanupKey = "ImageStorageStartupCleanupRan"
        if !UserDefaults.standard.bool(forKey: startupCleanupKey) {
            UserDefaults.standard.set(true, forKey: startupCleanupKey)
            return
        }
        let keptFilenames = Set(keptItems.filter { $0.type == .image }.map { $0.content })
        deleteAllExcept(filenames: keptFilenames)
    }
}
