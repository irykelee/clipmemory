import Foundation
import AppKit
import os.log

// CryptoService is in the same module, no import needed

class ImageStorage {
    static let shared = ImageStorage()

    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "ImageStorage")
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
        // Decrypt image data after reading from disk (N2)
        return CryptoService.shared.decryptData(encryptedData)
    }

    func deleteImage(filename: String) {
        guard isValidFilename(filename) else { return }
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
