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
    /// M-10 (2026-07-20 audit): the OS CSPRNG reported a non-success status
    /// during salt/nonce generation; we cannot produce a deterministic HKDF
    /// output from a zero-filled buffer, so surface the failure rather
    /// than silently shipping a weak salt.
    case secureRandomUnavailable
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
        // 30s safety net (LOW, 2026-07-20 audit): without a timeout a stuck
        // `ditto` (broken pipe, SMB stall, sandbox entitlement missing on a
        // future macOS release) could block the main thread forever — UI
        // comes back to life only after we terminate the child here. Long
        // enough for any legitimate large archive, short enough that the
        // user can retry instead of force-quitting the app.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = Array(arguments.dropFirst())
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                // SIGTERM is async — give it a beat, then SIGKILL if needed.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                throw BackupPackageError.archiveFailed
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else { throw BackupPackageError.archiveFailed }
    }

    /// Runs `work` synchronously on the main thread when the caller is
    /// elsewhere — store mutations (@Published) require main.
    private static func onMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
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
        let salt = try randomBytes(16)
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
        // Store mutations (@Published) must run on main even when the caller
        // invoked us from a background queue for a large package (M2 fix).
        let merge = onMain { store.importBackupItems(reencryptedItems, trashedItems: reencryptedTrash) }
        result.itemsImported = merge.imported
        result.itemsSkipped = merge.skipped

        // Tags: names are encrypted at the persistence boundary ("v2:" prefix
        // + ciphertext under the SOURCE machine's key) — decrypt them with the
        // package key so the local store holds plaintext (re-encrypted with
        // the local key on the next saveTags).
        let packageTags = decodeTags(from: staging, name: "tags.json")
        let localizedTags = packageTags.map { reencryptTagName($0, from: packageCrypto) }
        result.tagsImported = onMain { store.importBackupTags(localizedTags) }

        // Images: decrypt with package key, re-encrypt with local key.
        let packageImages = staging.appendingPathComponent("Images", isDirectory: true)
        if FileManager.default.fileExists(atPath: packageImages.path) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: packageImages.path)) ?? []
            // M-2 (2026-07-21 audit): import path lacked a size guard while
            // saveImage caps at 50 MB. A malicious or corrupted 500 MB entry
            // would crash us with OOM during Data(contentsOf:). Cap matches
            // ImageStorage.saveImage so import never exceeds what save would have
            // produced.
            let maxImageBytes = 50 * 1024 * 1024
            for file in files {
                guard file.hasSuffix(".png") else { continue }
                let target = imagesDirectory.appendingPathComponent(file)
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                let fileURL = packageImages.appendingPathComponent(file)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? Int,
                   size > maxImageBytes {
                    logger.warning("Skipping oversized image in backup: \(file) (\(size) bytes > \(maxImageBytes))")
                    continue
                }
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
        if item.isEncrypted {
            // An encrypted entry that won't decrypt under the package key is
            // corrupt — skip it instead of importing ciphertext the local
            // machine can never read (M1 review finding).
            guard let plaintext = packageCrypto.decrypt(item.content) else { return nil }
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

    /// Tag names persist as "v2:<ciphertext>" under the source machine's key.
    /// Decrypt with the package key so the in-memory store holds plaintext;
    /// names that are already plaintext (legacy packages) pass through.
    private static func reencryptTagName(_ tag: Tag, from packageCrypto: CryptoServiceProtocol) -> Tag {
        let prefix = "v2:"
        guard tag.name.hasPrefix(prefix) else { return tag }
        let ciphertext = String(tag.name.dropFirst(prefix.count))
        guard let plaintext = packageCrypto.decrypt(ciphertext) else { return tag }
        return Tag(
            id: tag.id,
            name: plaintext,
            colorHex: tag.colorHex,
            isAutoSuggested: tag.isAutoSuggested,
            createdAt: tag.createdAt
        )
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        // M-10 fix (2026-07-20 audit): the previous `SecRandomCopyBytes`
        // call discarded its `OSStatus` return. On failure the buffer
        // stays zero-filled, and since this salt feeds HKDF the result
        // is a predictable, attacker-friendly wrapper around a still-secret
        // user passphrase. We also `throw` the new `secureRandomUnavailable`
        // case already declared in `BackupPackageError` (the C1 Keychain
        // path already raises that on the same condition).
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BackupPackageError.secureRandomUnavailable
        }
        return data
    }
}
