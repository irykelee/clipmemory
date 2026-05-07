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

    func saveImage(_ data: Data, id: UUID) -> String? {
        guard data.count <= maxImageSize else {
            logger.warning("Image too large (\(data.count) bytes), skipping save")
            return nil
        }
        // PNG and TIFF clipboard data are both saved as .png (NSImage loads both formats).
        // The actual image format (PNG/TIFF) is lost after saving, but functionality is preserved.
        let filename = "\(id.uuidString).png"
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        // Encrypt image data before writing to disk (N2)
        guard let encryptedData = CryptoService.shared.encryptData(data) else {
            logger.error("Failed to encrypt image data")
            return nil
        }
        do {
            try encryptedData.write(to: fileURL)
            return filename
        } catch {
            logger.error("Failed to save encrypted image: \(error.localizedDescription)")
            return nil
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
