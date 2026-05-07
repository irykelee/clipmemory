import Foundation
import AppKit

class ImageStorage {
    static let shared = ImageStorage()

    private let fileManager = FileManager.default
    private lazy var imagesDirectory: URL = {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClipPaste/Images", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private init() {}

    func saveImage(_ data: Data, id: UUID) -> String? {
        let filename = "\(id.uuidString).png"
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            return filename
        } catch {
            print("ImageStorage: failed to save image - \(error)")
            return nil
        }
    }

    func loadImage(filename: String) -> Data? {
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        return try? Data(contentsOf: fileURL)
    }

    func deleteImage(filename: String) {
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: fileURL)
    }

    func deleteAllExcept(filenames: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        for file in files {
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
