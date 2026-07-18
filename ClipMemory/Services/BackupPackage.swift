import Foundation
import CryptoKit
import os.log

/// Export/import of a `.clipmemory` package (zip archive).
///
/// Layout:
///   manifest.json  {formatVersion, createdAt, appVersion, keySalt, itemCount, tagCount, imageCount}
///   key.enc        machine key encrypted with a passphrase-derived key (HKDF-SHA256 + AES-GCM)
///   items.json / tags.json / trash.json   raw encrypted store blobs
///   Images/        encrypted image files
///
/// The passphrase is mandatory: without it the package key would be a bare copy
/// of the machine's encryption key. GCM's auth tag doubles as passphrase check.
enum BackupPackageError: Error, Equatable {
    case wrongPassword
    case invalidPackage
    case unsupportedFormatVersion(Int)
    case missingKeyMaterial
    case archiveFailed
}

struct BackupManifest: Codable {
    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var keySalt: String
    var itemCount: Int
    var tagCount: Int
    var imageCount: Int
}

struct BackupImportResult {
    var itemsImported = 0
    var itemsSkipped = 0
    var tagsImported = 0
    var imagesImported = 0
}

final class BackupPackage {
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "BackupPackage")
    private static let currentFormatVersion = 1

    // MARK: - Passphrase key derivation

    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let inputKeyMaterial = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: Data("clipmemory-backup-v1".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - ditto helpers

    private static func zipDirectory(_ source: URL, to destination: URL) throws {
        try runDitto(["ditto", "-c", "-k", "--sequesterRsrc", source.path, destination.path])
    }

    private static func unzipArchive(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try runDitto(["ditto", "-x", "-k", archive.path, destination.path])
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = Array(arguments.dropFirst())
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BackupPackageError.archiveFailed }
    }

    // MARK: - Export

    /// Writes a `.clipmemory` package for the current store contents.
    static func exportPackage(
        to destination: URL,
        passphrase: String,
        defaults: UserDefaults = .standard,
        imagesDirectory: URL,
        keyData: Data
    ) throws {
        let salt = randomBytes(16)
        let derivedKey = deriveKey(passphrase: passphrase, salt: salt)
        let sealedKey = try AES.GCM.seal(keyData, using: derivedKey)
        guard let sealedKeyData = sealedKey.combined else { throw BackupPackageError.missingKeyMaterial }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmemory-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Store blobs (still encrypted with the machine key)
        var counts = (items: 0, tags: 0, trash: 0)
        for (filename, key) in [("items.json", "ClipboardItems"), ("tags.json", "ClipMemoryTags"), ("trash.json", "ClipboardTrashedItems")] {
            guard let data = defaults.data(forKey: key) else { continue }
            try data.write(to: staging.appendingPathComponent(filename), options: .atomic)
            switch key {
            case "ClipboardItems": counts.items = (try? JSONDecoder().decode([ClipboardItem].self, from: data).count) ?? 0
            case "ClipMemoryTags": counts.tags = (try? JSONDecoder().decode([Tag].self, from: data).count) ?? 0
            default: counts.trash = (try? JSONDecoder().decode([ClipboardItem].self, from: data).count) ?? 0
            }
        }

        var imageCount = 0
        if FileManager.default.fileExists(atPath: imagesDirectory.path) {
            let imagesDestination = staging.appendingPathComponent("Images", isDirectory: true)
            try FileManager.default.copyItem(at: imagesDirectory, to: imagesDestination)
            imageCount = (try? FileManager.default.contentsOfDirectory(atPath: imagesDestination.path).count) ?? 0
        }

        try sealedKeyData.write(to: staging.appendingPathComponent("key.enc"), options: .atomic)

        let manifest = BackupManifest(
            formatVersion: currentFormatVersion,
            createdAt: Date(),
            appVersion: AppVersion.current,
            keySalt: salt.base64EncodedString(),
            itemCount: counts.items,
            tagCount: counts.tags,
            imageCount: imageCount
        )
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try zipDirectory(staging, to: destination)
        logger.info("Exported backup package to \(destination.path)")
    }

    // MARK: - Import

    /// Imports a `.clipmemory` package, re-encrypting every item with the local
    /// machine key and merging into the store (dedupe by id, then contentHash).
    static func importPackage(
        from archive: URL,
        passphrase: String,
        store: ClipboardStore,
        localCrypto: CryptoServiceProtocol,
        imagesDirectory: URL,
        defaults: UserDefaults = .standard
    ) throws -> BackupImportResult {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmemory-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try unzipArchive(archive, to: staging)

        guard let manifestData = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData) else {
            throw BackupPackageError.invalidPackage
        }
        guard manifest.formatVersion <= currentFormatVersion else {
            throw BackupPackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard let salt = Data(base64Encoded: manifest.keySalt),
              let sealedKeyData = try? Data(contentsOf: staging.appendingPathComponent("key.enc")) else {
            throw BackupPackageError.invalidPackage
        }

        // Passphrase check: GCM open fails on wrong passphrase.
        let derivedKey = deriveKey(passphrase: passphrase, salt: salt)
        let packageKeyData: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: sealedKeyData)
            packageKeyData = try AES.GCM.open(sealedBox, using: derivedKey)
        } catch {
            throw BackupPackageError.wrongPassword
        }
        let packageCrypto = CryptoService(customKeyData: packageKeyData)

        var result = BackupImportResult()

        // Items + trash: re-encrypt content with the local key, then merge.
        let packageItems = decodeItems(from: staging, name: "items.json")
        let packageTrash = decodeItems(from: staging, name: "trash.json")
        let reencryptedItems = packageItems.compactMap { reencrypt(item: $0, from: packageCrypto, to: localCrypto) }
        let reencryptedTrash = packageTrash.compactMap { reencrypt(item: $0, from: packageCrypto, to: localCrypto) }
        let merge = store.importBackupItems(reencryptedItems, trashedItems: reencryptedTrash)
        result.itemsImported = merge.imported
        result.itemsSkipped = merge.skipped

        // Tags: merge by id (re-encrypt nothing — tag names are plaintext).
        let packageTags = decodeTags(from: staging, name: "tags.json")
        result.tagsImported = store.importBackupTags(packageTags)

        // Images: decrypt with package key, re-encrypt with local key.
        let packageImages = staging.appendingPathComponent("Images", isDirectory: true)
        if FileManager.default.fileExists(atPath: packageImages.path) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: packageImages.path)) ?? []
            for file in files {
                guard file.hasSuffix(".png") else { continue }
                let target = imagesDirectory.appendingPathComponent(file)
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                let fileURL = packageImages.appendingPathComponent(file)
                guard let encrypted = try? Data(contentsOf: fileURL),
                      let plain = packageCrypto.decryptData(encrypted),
                      let reencrypted = localCrypto.encryptData(plain) else { continue }
                try? reencrypted.write(to: target, options: .atomic)
                result.imagesImported += 1
            }
        }

        logger.info("Imported backup: \(result.itemsImported) items, \(result.tagsImported) tags, \(result.imagesImported) images (\(result.itemsSkipped) duplicates skipped)")
        return result
    }

    // MARK: - Private helpers

    private static func decodeItems(from directory: URL, name: String) -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let items = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return []
        }
        return items
    }

    private static func decodeTags(from directory: URL, name: String) -> [Tag] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let tags = try? JSONDecoder().decode([Tag].self, from: data) else {
            return []
        }
        return tags
    }

    /// Decrypts item content with the package key and re-encrypts with the
    /// local key. Image items reference filenames (unencrypted) and are
    /// re-keyed at the file level instead. Returns nil when content can't be
    /// decrypted (corrupt entry) or the item is already expired.
    private static func reencrypt(item: ClipboardItem, from packageCrypto: CryptoServiceProtocol, to localCrypto: CryptoServiceProtocol) -> ClipboardItem? {
        if item.isExpired { return nil }
        guard item.type != .image else { return item }

        var newContent = item.content
        var newHash = item.contentHash
        if item.isEncrypted, let plaintext = packageCrypto.decrypt(item.content) {
            guard let encrypted = localCrypto.encrypt(plaintext) else { return nil }
            newContent = encrypted
            newHash = localCrypto.hmacHex(for: plaintext)
        }
        return ClipboardItem(
            id: item.id,
            content: newContent,
            type: item.type,
            createdAt: item.createdAt,
            isPinned: item.isPinned,
            isSensitive: item.isSensitive,
            expiresAt: item.expiresAt,
            isEncrypted: item.isEncrypted,
            contentHash: newHash,
            decryptionFailed: item.decryptionFailed,
            tagIds: item.tagIds,
            deletedAt: item.deletedAt
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}
