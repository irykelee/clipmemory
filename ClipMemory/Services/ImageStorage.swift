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

    private init() {}

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
            guard let encryptedData = CryptoService.shared.encryptData(data) else {
                self.logger.error("Failed to encrypt image data")
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

        // Try new v2 format first
        if let data = CryptoService.shared.decryptData(encryptedData) {
            return data
        }

        // Try legacy format; if successful, re-encrypt and save with new format
        if let legacyData = try? legacyDecryptImage(encryptedData) {
            // Re-encrypt with new format and overwrite the file
            if let newEncrypted = CryptoService.shared.encryptData(legacyData) {
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
            let storedHMAC = combined.suffix(hmacSize)
            let ivAndCiphertext = combined.dropLast(hmacSize)

            let computedHMAC = CryptoService.computeLegacyHMAC(data: Data(ivAndCiphertext), key: key)
            guard computedHMAC == storedHMAC else { return nil }

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
        deleteAllExcept(filenames: keptFilenames)
    }
}
