import Foundation
import CryptoKit
import CommonCrypto
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
    /// M-1 spec §3.2 (2026-07-21): `CCKeyDerivationPBKDF` returned a non-success
    /// status — surface rather than silently ship a weak/zero derived key.
    case pbkdf2Failure
    /// M-1 spec §3.2 (2026-07-21): package's `keyDerivationVersion` is outside
    /// the supported set {1, 2}. Distinct from `unsupportedFormatVersion` (which
    /// is about the overall package data format) so log / test can pinpoint
    /// the actual blocker.
    case unsupportedKeyDerivationVersion(Int)
    /// BUG-024 (2026-07-22): file-level corruption that breaks the
    /// whole-package transaction. Distinct from `invalidPackage`
    /// (manifest/keyfile structure) and `wrongPassword` (key check):
    /// these files parse cleanly but contain corrupt data the
    /// decoder or file system rejected.
    case corruptedData(String, BackupFileSource)
}

/// BUG-024 (2026-07-22): identifies which JSON/file in a `.clipmemory`
/// package failed to read or decode, so logs can pinpoint the offending
/// file and tests can assert against a stable enum case. `.image` carries
/// the filename via the `corruptedData` reason string, not here.
enum BackupFileSource: String, Equatable, Sendable {
    case items
    case trash
    case tags
    case image
    /// M-7 (2026-07-24 audit): distinguish "manifest file missing or
    /// unreadable" / "manifest JSON corrupt" from the generic .invalidPackage
    /// the import path used to throw, so logs and tests can pinpoint the
    /// failing file rather than collapsing every early-stage failure into
    /// the same error case.
    case manifest
}

struct BackupManifest: Codable {
    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var keySalt: String
    var itemCount: Int
    var tagCount: Int
    var imageCount: Int
    /// M-1 fix (2026-07-21): backup packages used HKDF-SHA256 to derive a
    /// key from a passphrase, but HKDF is unsuitable for passphrase-to-key
    /// derivation — it has no work factor. An attacker with the package can
    /// crack weak passphrases in milliseconds using a dictionary attack
    /// (baked into Hashcat as mode 1600). PBKDF2-HMAC-SHA256 with 600 000
    /// iterations (OWASP 2023) raises that cost by ~10⁵. Old packages (no
    /// `keyDerivationVersion` field) default to version 1 (HKDF) on read.
    var keyDerivationVersion: Int = 2

    enum CodingKeys: String, CodingKey {
        case formatVersion, createdAt, appVersion, keySalt
        case itemCount, tagCount, imageCount, keyDerivationVersion
    }
}

/// M-1 spec §3.1 (2026-07-21): custom decoder lives in extension so Swift
/// still synthesizes the memberwise init that `exportPackage` relies on
/// (reviewer H-1 fix). Default missing `keyDerivationVersion` field to 1
/// so the HKDF read path activates transparently for legacy `.clipmemory`
/// files written by pre-M-1 ClipMemory (v2.5.8 and earlier).
extension BackupManifest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        keySalt = try container.decode(String.self, forKey: .keySalt)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        tagCount = try container.decode(Int.self, forKey: .tagCount)
        imageCount = try container.decode(Int.self, forKey: .imageCount)
        // Default HKDF (version 1) for old packages without this field.
        keyDerivationVersion = try container.decodeIfPresent(Int.self, forKey: .keyDerivationVersion) ?? 1
    }
}

struct BackupImportResult {
    var itemsImported = 0
    var itemsSkipped = 0
    var tagsImported = 0
    var imagesImported = 0
    /// BUG-024 (2026-07-22): count of items dropped because their
    /// content failed GCM auth (per-entry corruption, not package-level).
    /// Distinct from `itemsSkipped` (dedupe by id/contentHash).
    var itemsSkippedCorrupt = 0
}

final class BackupPackage {
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "BackupPackage")
    private static let currentFormatVersion = 1

    // MARK: - Passphrase key derivation

    /// M-1 fix: version 1 used HKDF-SHA256 (no work factor, vulnerable to
    /// dictionary attack). Version 2 uses PBKDF2-HMAC-SHA256 with 600 000
    /// iterations (OWASP 2023) — ~10⁵× slower than HKDF for weak passphrases.
    private static let pbkdf2Iterations = 600_000

    static func deriveKey(passphrase: String, salt: Data, version: Int = 2) throws -> SymmetricKey {
        switch version {
        case 1:
            // Legacy HKDF path for old packages.
            let inputKeyMaterial = SymmetricKey(data: Data(passphrase.utf8))
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKeyMaterial,
                salt: salt,
                info: Data("clipmemory-backup-v1".utf8),
                outputByteCount: 32
            )
        case 2:
            // PBKDF2-HMAC-SHA256.
            var derivedKey = Data(count: 32)
            let passphraseData = Data(passphrase.utf8)
            let derivationStatus = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
                salt.withUnsafeBytes { saltBytes in
                    passphraseData.withUnsafeBytes { passphraseBytes in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passphraseBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                            passphraseData.count,
                            saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            UInt32(pbkdf2Iterations),
                            derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            32
                        )
                    }
                }
            }
            guard derivationStatus == errSecSuccess else {
                // NEW-2 (2026-07-21): zero the buffer before throw too — on
                // failure the derived bytes are still sensitive.
                derivedKey.resetBytes(in: 0..<32)
                throw BackupPackageError.pbkdf2Failure
            }
            // NEW-2 (2026-07-21): defense-in-depth. SymmetricKey copies the
            // bytes — zero the source buffer AFTER the copy, not before.
            // (Bug found in test: zeroing before SymmetricKey(data:) makes
            // the key all zeros, which silently corrupts AES-GCM and
            // breaks testImportWithWrongPasswordFailsAndWritesNothing.)
            // Salt and passphrase are caller-owned; out of scope here.
            let key = SymmetricKey(data: derivedKey)
            derivedKey.resetBytes(in: 0..<32)
            return key
        default:
            throw BackupPackageError.unsupportedKeyDerivationVersion(version)
        }
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
        // BUG-022 (2026-07-21): the previous loop polled every 50 ms with
        // Thread.sleep — main thread stays blocked the full timeout window
        // even when ditto exits cleanly at 200 ms, and the SIGKILL escalation
        // is racy (process.isRunning read from a non-atomic getter).
        // terminationHandler signals a semaphore the instant ditto exits, so
        // we wake immediately on success or failure. The 30 s timeout is kept
        // as a safety net; on timeout we still terminate + SIGKILL.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = Array(arguments.dropFirst())
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        try process.run()
        let timedOut = semaphore.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            process.terminate()
            // SIGTERM is async — give it a beat, then SIGKILL if needed.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw BackupPackageError.archiveFailed
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
        let derivedKey = try deriveKey(passphrase: passphrase, salt: salt, version: 2)
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
            imageCount: imageCount,
            keyDerivationVersion: 2
        )
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        // BUG-023 (2026-07-21): the old `removeItem` then `zipDirectory` was
        // non-atomic — if zip failed (disk full, permission, sandbox block),
        // the previous backup was already deleted and no new one existed,
        // leaving the user with zero backups. Build the zip at a temp path
        // first; if it succeeds, atomically replace the destination (or move
        // into place if the destination is new). A failed zip leaves both
        // the old backup and the temp file untouched.
        let tempDestination = destination.deletingLastPathComponent()
            .appendingPathComponent(".clipmemory-export-\(UUID().uuidString).tmp")
        do {
            try zipDirectory(staging, to: tempDestination)
        } catch {
            try? FileManager.default.removeItem(at: tempDestination)
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            // replaceItem keeps `destination` valid until the swap is
            // committed; on success the temp file takes its place.
            var resultingURL: NSURL?
            _ = try FileManager.default.replaceItem(
                at: destination,
                withItemAt: tempDestination,
                backupItemName: nil,
                options: [],
                resultingItemURL: &resultingURL
            )
        } else {
            try FileManager.default.moveItem(at: tempDestination, to: destination)
        }
        logger.info("Exported backup package to \(destination.path)")
    }

    // MARK: - Import

    /// Imports a `.clipmemory` package, re-encrypting every item with the local
    /// machine key and merging into the store (dedupe by id, then contentHash).
    ///
    /// H-5 (2026-07-24 audit): **no internal transaction / no rollback.**
    /// The function merges `items.json` + `trash.json` into the store FIRST,
    /// then `tags.json`, then attempts each image. If the image loop throws
    /// (decrypt-auth failure, file I/O error), the previously-merged items
    /// and tags are NOT reverted — the caller is responsible for guaranteeing
    /// a rollback point beforehand. The only existing caller
    /// (`ContentView.importBackup`) does this via `backupService.backupNow()`
    /// on the call site; if a second caller is added it MUST do the same, or
    /// a mid-import image failure will silently leave the user with a
    /// half-overwritten clipboard history and no recovery point.
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

        guard let manifestData = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")) else {
            // M-7: distinguish "manifest file missing" from later corruption.
            throw BackupPackageError.corruptedData("manifest.json missing or unreadable", .manifest)
        }
        guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData) else {
            throw BackupPackageError.corruptedData("manifest.json decode failed", .manifest)
        }
        guard manifest.formatVersion <= currentFormatVersion else {
            throw BackupPackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard let salt = Data(base64Encoded: manifest.keySalt) else {
            throw BackupPackageError.invalidPackage
        }
        guard let sealedKeyData = try? Data(contentsOf: staging.appendingPathComponent("key.enc")) else {
            // M-7: same pattern — surface which file is the offender.
            throw BackupPackageError.corruptedData("key.enc missing or unreadable", .manifest)
        }

        // Passphrase check: GCM open fails on wrong passphrase.
        let derivedKey = try deriveKey(passphrase: passphrase, salt: salt, version: manifest.keyDerivationVersion)
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
        let packageItems = try decodeItems(from: staging, name: "items.json", source: .items)
        let packageTrash = try decodeItems(from: staging, name: "trash.json", source: .trash)
        // BUG-024 (2026-07-22): single-entry GCM auth failures stay per-entry,
        // surfaced via `itemsSkippedCorrupt` so the UI shows "corrupt N" rather
        // than silently dropping them.
        let (reencryptedItems, itemCorruptCount) = reencryptItemsWithCorruptCount(
            packageItems, from: packageCrypto, to: localCrypto
        )
        let (reencryptedTrash, trashCorruptCount) = reencryptItemsWithCorruptCount(
            packageTrash, from: packageCrypto, to: localCrypto
        )
        result.itemsSkippedCorrupt = itemCorruptCount + trashCorruptCount
        // Store mutations (@Published) must run on main even when the caller
        // invoked us from a background queue for a large package (M2 fix).
        let merge = onMain { store.importBackupItems(reencryptedItems, trashedItems: reencryptedTrash) }
        result.itemsImported = merge.imported
        result.itemsSkipped = merge.skipped

        // Tags: names are encrypted at the persistence boundary ("v2:" prefix
        // + ciphertext under the SOURCE machine's key) — decrypt them with the
        // package key so the local store holds plaintext (re-encrypted with
        // the local key on the next saveTags).
        let packageTags = try decodeTags(from: staging, name: "tags.json", source: .tags)
        let localizedTags = packageTags.map { reencryptTagName($0, from: packageCrypto) }
        result.tagsImported = onMain { store.importBackupTags(localizedTags) }

        // Images: decrypt with package key, re-encrypt with local key.
        result.imagesImported = try importImages(
            staging: staging,
            imagesDirectory: imagesDirectory,
            packageCrypto: packageCrypto,
            localCrypto: localCrypto
        )

        logger.info("Imported backup: \(result.itemsImported) items, \(result.tagsImported) tags")
        return result
    }

    // MARK: - Private helpers

    /// Decrypt each PNG in `staging/Images` with the package key and re-encrypt with
    /// the local key. Skips files already present locally. Throws
    /// `BackupPackageError.corruptedData(_, .image)` on file-read, decrypt-auth,
    /// or write failure — see spec risk §1 for why this does not roll back items
    /// already merged into the store before this image pass. Returns count imported.
    private static func importImages(
        staging: URL,
        imagesDirectory: URL,
        packageCrypto: CryptoServiceProtocol,
        localCrypto: CryptoServiceProtocol
    ) throws -> Int {
        let packageImages = staging.appendingPathComponent("Images", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageImages.path) else { return 0 }
        var count = 0
        let files = (try? FileManager.default.contentsOfDirectory(atPath: packageImages.path)) ?? []
        // M-2 (2026-07-21 audit): import path lacked a size guard while
        // saveImage caps at 50 MB. A malicious or corrupted 500 MB entry
        // would crash us with OOM during Data(contentsOf:). Cap matches
        // ImageStorage.saveImage so import never exceeds what save would have
        // produced.
        let maxImageBytes = 50 * 1024 * 1024
        for file in files where file.hasSuffix(".png") {
            let target = imagesDirectory.appendingPathComponent(file)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            let fileURL = packageImages.appendingPathComponent(file)
            // C-4 (2026-07-24 audit): the prior `if let attrs = try?` chain
            // silently bypassed the size cap whenever `attributesOfItem`
            // failed (permissions, broken symlink, network FS error) — a
            // hostile or corrupted package could then `Data(contentsOf:)`
            // a 500 MB entry and crash the app with OOM. Fail closed: skip
            // the file rather than risk unbounded memory.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int else {
                logger.warning("Cannot determine size of image in backup (skipping): \(file)")
                continue
            }
            guard size <= maxImageBytes else {
                logger.warning("Skipping oversized image in backup: \(file) (\(size) bytes > \(maxImageBytes))")
                continue
            }
            let encrypted: Data
            do {
                encrypted = try Data(contentsOf: fileURL)
            } catch {
                logger.error("Failed to read image \(file): \(error.localizedDescription)")
                throw BackupPackageError.corruptedData(
                    "\(file): \(error.localizedDescription)",
                    .image
                )
            }
            guard let plain = packageCrypto.decryptData(encrypted),
                  let reencrypted = localCrypto.encryptData(plain) else {
                logger.error("Failed to decrypt image \(file)")
                throw BackupPackageError.corruptedData(
                    "\(file): decrypt/auth failed",
                    .image
                )
            }
            do {
                try reencrypted.write(to: target, options: .atomic)
            } catch {
                logger.error("Failed to write image \(file): \(error.localizedDescription)")
                throw BackupPackageError.corruptedData(
                    "\(file): \(error.localizedDescription)",
                    .image
                )
            }
            count += 1
        }
        return count
    }

    /// Re-encrypts each item with the local key, dropping entries whose
    /// ciphertext fails GCM auth (BUG-024 per-entry corruption). Returns
    /// the successfully re-encrypted items and a count of dropped entries.
    private static func reencryptItemsWithCorruptCount(
        _ items: [ClipboardItem],
        from packageCrypto: CryptoServiceProtocol,
        to localCrypto: CryptoServiceProtocol
    ) -> (reencrypted: [ClipboardItem], corruptCount: Int) {
        var reencrypted: [ClipboardItem] = []
        reencrypted.reserveCapacity(items.count)
        var corruptCount = 0
        for item in items {
            if let ok = reencrypt(item: item, from: packageCrypto, to: localCrypto) {
                reencrypted.append(ok)
            } else {
                corruptCount += 1
            }
        }
        return (reencrypted, corruptCount)
    }

    private static func decodeItems(
        from directory: URL,
        name: String,
        source: BackupFileSource
    ) throws -> [ClipboardItem] {
        let url = directory.appendingPathComponent(name)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Spec risk §3 (P1 fix 2026-07-22): file missing is a legal empty
            // state (exportPackage skips writing JSON files that would be empty),
            // not package-level corruption. Treat it as an empty array.
            return []
        } catch {
            logger.error("Failed to read \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
        do {
            return try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            logger.error("Failed to decode \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
    }

    private static func decodeTags(
        from directory: URL,
        name: String,
        source: BackupFileSource
    ) throws -> [Tag] {
        let url = directory.appendingPathComponent(name)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Spec risk §3 (P1 fix 2026-07-22): file missing is a legal empty
            // state (exportPackage skips writing JSON files that would be empty),
            // not package-level corruption. Treat it as an empty array.
            return []
        } catch {
            logger.error("Failed to read \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
        do {
            return try JSONDecoder().decode([Tag].self, from: data)
        } catch {
            logger.error("Failed to decode \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
    }

    /// Decrypts item content with the package key and re-encrypts with the
    /// local key. Image items reference filenames (unencrypted) and are
    /// re-keyed at the file level instead. Returns nil when content can't be
    /// decrypted (corrupt entry) or the item is already expired.
    private static func reencrypt(
        item: ClipboardItem,
        from packageCrypto: CryptoServiceProtocol,
        to localCrypto: CryptoServiceProtocol
    ) -> ClipboardItem? {
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
        // BUG-025 (2026-07-21): `$0.baseAddress!` would trap if the caller
        // passes `count == 0` (Data(capacity: 0) reports baseAddress == nil).
        // All current call sites pass 16 or 32, but the public-ish signature
        // doesn't enforce that. Guard the unwrap and throw the same
        // secureRandomUnavailable error rather than crashing.
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw BackupPackageError.secureRandomUnavailable
        }
        return data
    }
}
