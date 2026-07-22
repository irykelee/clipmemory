import XCTest
import CryptoKit
@testable import ClipMemory

/// BackupPackage export → import round-trip, passphrase check, merge dedupe.
/// Fully sandboxed: temp dirs + throwaway CryptoService keys; the real
/// Application Support and the app's key file are never touched.
final class ImportExportTests: XCTestCase {

    private var tempRoot: URL!
    private var imagesDir: URL!
    private var defaults: UserDefaults!
    private var localKeyData: Data!
    private var localCrypto: CryptoService!
    private var originalCrypto: CryptoServiceProtocol?
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportExportTests-\(UUID().uuidString)", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ImportExportTests-\(UUID().uuidString)")
        localKeyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        localCrypto = CryptoService(customKeyData: localKeyData)
        // Route the store's decrypt path through the test key so imported items
        // (re-encrypted with that key) are readable; restored in tearDown.
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.crypto = localCrypto
        store = ClipboardStore(backend: MemoryStorageBackend())
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.crypto = originalCrypto }
        originalCrypto = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        imagesDir = nil
        defaults = nil
        localKeyData = nil
        localCrypto = nil
        store = nil
        super.tearDown()
    }

    /// Seed UserDefaults with one text item encrypted with `crypto`, one tag,
    /// and one image file encrypted with the same crypto.
    private func seedPackageSource(crypto: CryptoService) throws {
        let encrypted = try XCTUnwrap(crypto.encrypt("hello backup"))
        let hash = try XCTUnwrap(crypto.hmacHex(for: "hello backup"))
        let item = ClipboardItem(
            content: encrypted,
            type: .text,
            isEncrypted: true,
            contentHash: hash
        )
        defaults.set(try JSONEncoder().encode([item]), forKey: "ClipboardItems")

        // Tag names persist as "v2:<ciphertext>" under the machine key — seed in
        // the production-encrypted form, not plaintext (H1 regression coverage).
        let encryptedName = try XCTUnwrap(crypto.encrypt("工作"))
        let persistedTag = Tag(name: "v2:" + encryptedName, colorHex: "#FF6B6B")
        defaults.set(try JSONEncoder().encode([persistedTag]), forKey: "ClipMemoryTags")

        let imageBytes = Data("fake-png-bytes".utf8)
        let encryptedImage = try XCTUnwrap(crypto.encryptData(imageBytes))
        let name = "\(UUID().uuidString).png"
        try encryptedImage.write(to: imagesDir.appendingPathComponent(name))
    }

    // MARK: - Package construction helpers

    /// Writes items/trash/tags JSON blobs to `staging`, optionally overwriting
    /// with random garbage to simulate corruption.
    private func writePackageContents(
        cryptoForPackage: CryptoService,
        seedItems: Bool,
        seedTags: Bool,
        corruptItems: Bool,
        corruptTrash: Bool,
        corruptTags: Bool,
        to staging: URL
    ) throws {
        let itemsBlob: Data
        if seedItems {
            let item = ClipboardItem(
                content: try XCTUnwrap(cryptoForPackage.encrypt("payload")),
                type: .text,
                isEncrypted: true,
                contentHash: try XCTUnwrap(cryptoForPackage.hmacHex(for: "payload"))
            )
            itemsBlob = try JSONEncoder().encode([item])
        } else {
            itemsBlob = Data("[]".utf8)
        }
        try itemsBlob.write(to: staging.appendingPathComponent("items.json"))

        // Trash: legal empty JSON (`[]\n`), not zero-byte Data().
        // Spec risk §3: BUG-024 P1 fix rejects empty Data() as invalid JSON.
        let trashBlob = Data("[]\n".utf8)
        try trashBlob.write(to: staging.appendingPathComponent("trash.json"))

        let tagsBlob: Data
        if seedTags {
            let tag = Tag(id: UUID(), name: "test-tag", colorHex: "#FF6B6B")
            tagsBlob = try JSONEncoder().encode([tag])
        } else {
            tagsBlob = Data("[]".utf8)
        }
        try tagsBlob.write(to: staging.appendingPathComponent("tags.json"))

        // Corrupt-flags: overwrite named file with garbage before zipping.
        let garbage = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        if corruptItems { try garbage.write(to: staging.appendingPathComponent("items.json")) }
        if corruptTrash { try garbage.write(to: staging.appendingPathComponent("trash.json")) }
        if corruptTags { try garbage.write(to: staging.appendingPathComponent("tags.json")) }
    }

    /// Derives a key, seals `crypto`'s raw key data, writes key.enc and
    /// manifest.json to `staging`, then zips `staging` into a .clipmemory
    /// archive at `packageURL`.
    private func sealAndArchive(
        manifest: BackupManifest,
        salt: Data,
        passphrase: String,
        cryptoForPackage: CryptoService,
        from staging: URL,
        to packageURL: URL
    ) throws {
        let derivedKey = try BackupPackage.deriveKey(passphrase: passphrase, salt: salt, version: 1)
        let packageKeyData = cryptoForPackage.exportKeyDataForTesting()
        let sealed = try AES.GCM.seal(packageKeyData, using: derivedKey)
        try XCTUnwrap(sealed.combined).write(to: staging.appendingPathComponent("key.enc"))
        try XCTUnwrap(JSONEncoder().encode(manifest))
            .write(to: staging.appendingPathComponent("manifest.json"))

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, packageURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "ditto failed building test fixture")
    }

    /// Builds a self-contained `.clipmemory` package in a temp directory and
    /// returns its URL. Items/tags/trash blobs come from a fresh
    /// `MemoryStorageBackend` so the test never touches production storage.
    /// Set `corruptItems`/`corruptTrash`/`corruptTags` to overwrite the named
    /// JSON with garbage so the decoder fails. `seedItems` and `seedTags`
    /// control whether the package's items.json/tags.json are populated or
    /// empty (`[]`).
    private func constructPackage(
        seedItems: Bool = true,
        seedTags: Bool = true,
        corruptItems: Bool = false,
        corruptTrash: Bool = false,
        corruptTags: Bool = false
    ) throws -> URL {
        let cryptoForPackage = CryptoService(customKeyData: Data((32..<64).map { UInt8($0 & 0xFF) }))
        let pkgTemp = tempRoot.appendingPathComponent("pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgTemp, withIntermediateDirectories: true)
        let pkgStaging = pkgTemp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pkgStaging.appendingPathComponent("Images", isDirectory: true),
            withIntermediateDirectories: true
        )

        try writePackageContents(
            cryptoForPackage: cryptoForPackage,
            seedItems: seedItems,
            seedTags: seedTags,
            corruptItems: corruptItems,
            corruptTrash: corruptTrash,
            corruptTags: corruptTags,
            to: pkgStaging
        )

        let passphrase = "secret123"
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let manifest = BackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            appVersion: "test",
            keySalt: salt.base64EncodedString(),
            itemCount: 1,
            tagCount: seedTags ? 1 : 0,
            imageCount: 0,
            keyDerivationVersion: 1
        )
        let packageURL = tempRoot.appendingPathComponent("fixture.clipmemory")
        try sealAndArchive(
            manifest: manifest,
            salt: salt,
            passphrase: passphrase,
            cryptoForPackage: cryptoForPackage,
            from: pkgStaging,
            to: packageURL
        )
        try? FileManager.default.removeItem(at: pkgTemp)
        return packageURL
    }

    /// Builds a `.clipmemory` archive from a caller-supplied `itemsBlob`,
    /// bypassing the seed/corrupt logic of `constructPackage`. Used by tests
    /// that need per-entry key mismatches (good item + corrupt item).
    private func constructPackageWithItemsBlob(
        itemsBlob: Data,
        trashBlob: Data = Data("[]".utf8),
        tagsBlob: Data = Data("[]".utf8),
        passphrase: String = "secret123",
        cryptoForPackage: CryptoService,
        itemCount: Int,
        tagCount: Int = 0
    ) throws -> URL {
        let pkgTemp = tempRoot.appendingPathComponent("pcbi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgTemp, withIntermediateDirectories: true)
        let pkgStaging = pkgTemp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pkgStaging.appendingPathComponent("Images", isDirectory: true),
            withIntermediateDirectories: true
        )

        try itemsBlob.write(to: pkgStaging.appendingPathComponent("items.json"))
        try trashBlob.write(to: pkgStaging.appendingPathComponent("trash.json"))
        try tagsBlob.write(to: pkgStaging.appendingPathComponent("tags.json"))

        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let manifest = BackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            appVersion: "test",
            keySalt: salt.base64EncodedString(),
            itemCount: itemCount,
            tagCount: tagCount,
            imageCount: 0,
            keyDerivationVersion: 1
        )
        let packageURL = tempRoot.appendingPathComponent("per-entry.clipmemory")
        try sealAndArchive(
            manifest: manifest,
            salt: salt,
            passphrase: passphrase,
            cryptoForPackage: cryptoForPackage,
            from: pkgStaging,
            to: packageURL
        )
        try? FileManager.default.removeItem(at: pkgTemp)
        return packageURL
    }

    func testExportImportRoundTripRestoresContent() throws {
        try seedPackageSource(crypto: localCrypto)
        let packageURL = tempRoot.appendingPathComponent("backup.clipmemory")

        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: "secret123",
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: localKeyData
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))

        let result = try BackupPackage.importPackage(
            from: packageURL,
            passphrase: "secret123",
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir
        )

        XCTAssertEqual(result.itemsImported, 1)
        XCTAssertEqual(result.itemsSkipped, 0)
        XCTAssertEqual(result.tagsImported, 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.getDecryptedContent(store.items[0]), "hello backup")
        // H1 regression: the persisted tag name ("v2:<ciphertext>") must be
        // decrypted with the package key, not stored as garbage text.
        XCTAssertEqual(store.tags.values.first?.name, "工作")
    }

    func testImportDeduplicatesWithinSamePackage() throws {
        // Two entries with different ids but identical content/hash in one
        // package — the second must be skipped (M3 regression coverage).
        let encrypted = try XCTUnwrap(localCrypto.encrypt("dup content"))
        let hash = try XCTUnwrap(localCrypto.hmacHex(for: "dup content"))
        let makeDup = { ClipboardItem(content: encrypted, type: .text, isEncrypted: true, contentHash: hash) }
        defaults.set(try JSONEncoder().encode([makeDup(), makeDup()]), forKey: "ClipboardItems")
        defaults.set(try JSONEncoder().encode([Tag]()), forKey: "ClipMemoryTags")

        let packageURL = tempRoot.appendingPathComponent("dup.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: "secret123",
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: localKeyData
        )
        let result = try BackupPackage.importPackage(
            from: packageURL,
            passphrase: "secret123",
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir
        )

        XCTAssertEqual(result.itemsImported, 1, "first copy imported")
        XCTAssertEqual(result.itemsSkipped, 1, "duplicate within the same package skipped")
        XCTAssertEqual(store.items.count, 1)
    }

    func testImportWithWrongPasswordFailsAndWritesNothing() throws {
        try seedPackageSource(crypto: localCrypto)
        let packageURL = tempRoot.appendingPathComponent("backup.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: "secret123",
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: localKeyData
        )

        XCTAssertThrowsError(
            try BackupPackage.importPackage(
                from: packageURL,
                passphrase: "wrong-passphrase",
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir
            )
        ) { error in
            XCTAssertEqual(error as? BackupPackageError, .wrongPassword)
        }
        XCTAssertEqual(store.items.count, 0, "failed import must not mutate the store")
    }

    func testImportSamePackageTwiceCreatesNoDuplicates() throws {
        try seedPackageSource(crypto: localCrypto)
        let packageURL = tempRoot.appendingPathComponent("backup.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: "secret123",
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: localKeyData
        )

        _ = try BackupPackage.importPackage(from: packageURL, passphrase: "secret123",
                                            store: store, localCrypto: localCrypto, imagesDirectory: imagesDir)
        let second = try BackupPackage.importPackage(from: packageURL, passphrase: "secret123",
                                                     store: store, localCrypto: localCrypto, imagesDirectory: imagesDir)

        XCTAssertEqual(second.itemsImported, 0)
        XCTAssertEqual(second.itemsSkipped, 1, "second import must dedupe by id")
        XCTAssertEqual(second.tagsImported, 0)
        XCTAssertEqual(store.items.count, 1)
    }

    // MARK: - M-1 (2026-07-21 audit) PBKDF2 KDF upgrade regression coverage

    /// Construct a legacy v1 `.clipmemory` package in the temp dir using HKDF
    /// (the pre-M-1 derivation path) plus a manifest JSON that **omits** the
    /// `keyDerivationVersion` field. Used by both `testImportLegacyHKDFPackage`
    /// and `testOldManifestMissingKeyDerivationVersionDefaultsToLegacy` to prove
    /// the decoder's `decodeIfPresent ?? 1` default transparently dispatches
    /// to the HKDF read path for legacy `.clipmemory` files. (M-1 spec §7.)
    private func constructLegacyPackage(passphrase: String, machineKey: Data) throws -> URL {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: salt,
            info: Data("clipmemory-backup-v1".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(machineKey, using: derivedKey)
        guard let sealedData = sealed.combined else {
            throw NSError(domain: "ImportExportTests", code: 0)
        }

        let staging = tempRoot.appendingPathComponent("legacy-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try sealedData.write(to: staging.appendingPathComponent("key.enc"), options: .atomic)
        // Manifest JSON **without** `keyDerivationVersion` — decoder defaults to 1.
        // createdAt must be `timeIntervalSinceReferenceDate` (Double), matching
        // JSONEncoder's default Date strategy — ISO 8601 strings won't decode.
        let manifest: [String: Any] = [
            "formatVersion": 1,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "appVersion": "2.5.8",
            "keySalt": salt.base64EncodedString(),
            "itemCount": 0, "tagCount": 0, "imageCount": 0
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try Data("[]\n".utf8).write(to: staging.appendingPathComponent("items.json"), options: .atomic)
        try Data("[]\n".utf8).write(to: staging.appendingPathComponent("tags.json"), options: .atomic)
        try Data("[]\n".utf8).write(to: staging.appendingPathComponent("trash.json"), options: .atomic)

        let archiveURL = tempRoot.appendingPathComponent("legacy-\(UUID().uuidString).clipmemory")
        // Note: file is freshly named (UUID), guaranteed not to exist yet —
        // do NOT call `FileManager.removeItem` here (it would throw).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()
        return archiveURL
    }

    /// M-1 spec §11 A2: a `.clipmemory` package written by pre-M-1 ClipMemory
    /// (v2.5.8 or earlier) has no `keyDerivationVersion` field. The decoder
    /// must default to 1, dispatch to the HKDF path, and successfully
    /// re-encrypt the machine key.
    func testImportLegacyHKDFPackage() throws {
        let archiveURL = try constructLegacyPackage(passphrase: "secret123", machineKey: localKeyData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        let result = try BackupPackage.importPackage(
            from: archiveURL,
            passphrase: "secret123",
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir
        )

        // Legacy package has no items / tags / images — the round-trip proves
        // the machine-key derivation path, not the payload.
        XCTAssertEqual(result.itemsImported, 0)
        XCTAssertEqual(result.tagsImported, 0)
        XCTAssertEqual(result.imagesImported, 0)
        XCTAssertEqual(result.itemsSkipped, 0)
    }

    /// M-1 spec §11 A4: a package whose `keyDerivationVersion` is outside the
    /// supported set {1, 2} must throw the new `.unsupportedKeyDerivationVersion`
    /// error — distinct from the pre-existing `.unsupportedFormatVersion`.
    func testImportUnsupportedKeyDerivationVersion() throws {
        // Export a normal v2 package, then mutate its manifest to advertise
        // version=99, recompress, and verify the new error path fires.
        try seedPackageSource(crypto: localCrypto)
        let packageURL = tempRoot.appendingPathComponent("bad-version.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: "secret123",
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: localKeyData
        )

        let extractDir = tempRoot.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", packageURL.path, extractDir.path]
        try extract.run()
        extract.waitUntilExit()

        let manifestURL = extractDir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        var mutated = manifest
        mutated["keyDerivationVersion"] = 99
        let mutatedData = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])
        try mutatedData.write(to: manifestURL, options: .atomic)

        // Recompress from extractDir into the same path — `ditto -c` overwrites
        // by default, no `removeItem` needed before recompress.
        let recompress = Process()
        recompress.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        recompress.arguments = ["-c", "-k", "--sequesterRsrc", extractDir.path, packageURL.path]
        try recompress.run()
        recompress.waitUntilExit()

        XCTAssertThrowsError(
            try BackupPackage.importPackage(
                from: packageURL,
                passphrase: "secret123",
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir
            )
        ) { error in
            XCTAssertEqual(
                error as? BackupPackageError,
                .unsupportedKeyDerivationVersion(99)
            )
        }
    }

    /// M-1 spec §11 A5: a manifest that omits `keyDerivationVersion` must
    /// decode with the default value 1, dispatch to the HKDF path, and import
    /// successfully. Reuses `constructLegacyPackage` from `testImportLegacyHKDFPackage`.
    func testOldManifestMissingKeyDerivationVersionDefaultsToLegacy() throws {
        let archiveURL = try constructLegacyPackage(passphrase: "secret123", machineKey: localKeyData)
        XCTAssertNoThrow(
            try BackupPackage.importPackage(
                from: archiveURL,
                passphrase: "secret123",
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir
            )
        )
    }

    /// BUG-024: corrupt `items.json` aborts the whole import with a typed
    /// error pointing at the offending file. Before this fix, decodeItems
    /// returned [] and the UI cheerfully reported "imported 0 items".
    func testImportThrowsWhenItemsJSONCorrupt() throws {
        let url = try constructPackage(corruptItems: true)
        XCTAssertThrowsError(
            try BackupPackage.importPackage(
                from: url,
                passphrase: "secret123",
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir
            )
        ) { error in
            guard case BackupPackageError.corruptedData(_, .items) = error else {
                XCTFail("expected .corruptedData(_, .items), got \(error)")
                return
            }
        }
        // Transaction check: items must NOT have been merged into the store.
        XCTAssertTrue(store.items.isEmpty, "items should not have been merged on package-level failure")
    }

    func testImportThrowsWhenTrashJSONCorrupt() throws {
        let url = try constructPackage(corruptTrash: true)
        XCTAssertThrowsError(
            try BackupPackage.importPackage(
                from: url,
                passphrase: "secret123",
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir
            )
        ) { error in
            guard case BackupPackageError.corruptedData(_, .trash) = error else {
                XCTFail("expected .corruptedData(_, .trash), got \(error)")
                return
            }
        }
    }

    func testImportThrowsWhenTagsJSONCorrupt() throws {
        let url = try constructPackage(corruptTags: true)
        XCTAssertThrowsError(
            try BackupPackage.importPackage(
                from: url,
                passphrase: "secret123",
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir
            )
        ) { error in
            guard case BackupPackageError.corruptedData(_, .tags) = error else {
                XCTFail("expected .corruptedData(_, .tags), got \(error)")
                return
            }
        }
    }

    /// BUG-024 boundary guard: a legit empty backup (items.json = [],
    /// tags.json = []) must NOT throw. This is the easiest regression
    /// in the fix — if a future change accidentally throws on the empty
    /// array path, this test fails before users see "package corrupted"
    /// for legitimately empty backups.
    func testImportSucceedsWithLegitEmptyItemsAndTags() throws {
        let url = try constructPackage(seedItems: false, seedTags: false)
        let result = try BackupPackage.importPackage(
            from: url,
            passphrase: "secret123",
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir
        )
        XCTAssertEqual(result.itemsImported, 0)
        XCTAssertEqual(result.itemsSkippedCorrupt, 0)
    }

    func testImportSkipsCorruptItemsAndCountsThem() throws {
        // Build a package with two items: one encrypted with the package key
        // (decrypts + re-encrypts successfully), one encrypted with a *different*
        // key (decryption fails → reencrypt returns nil → corruptCount += 1).
        let packageCrypto = CryptoService(customKeyData: Data((32..<64).map { UInt8($0 & 0xFF) }))
        let wrongCrypto = CryptoService(customKeyData: Data((64..<96).map { UInt8($0 & 0xFF) }))
        let goodItem = ClipboardItem(
            content: try XCTUnwrap(packageCrypto.encrypt("good")),
            type: .text,
            isEncrypted: true,
            contentHash: try XCTUnwrap(packageCrypto.hmacHex(for: "good"))
        )
        let corruptItem = ClipboardItem(
            content: try XCTUnwrap(wrongCrypto.encrypt("bad")),
            type: .text,
            isEncrypted: true,
            contentHash: try XCTUnwrap(wrongCrypto.hmacHex(for: "bad"))
        )
        let itemsBlob = try JSONEncoder().encode([goodItem, corruptItem])
        let packageURL = try constructPackageWithItemsBlob(
            itemsBlob: itemsBlob,
            trashBlob: Data("[]".utf8),
            tagsBlob: Data("[]".utf8),
            passphrase: "secret123",
            cryptoForPackage: packageCrypto,
            itemCount: 2,
            tagCount: 0
        )

        let result = try BackupPackage.importPackage(
            from: packageURL,
            passphrase: "secret123",
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir
        )
        XCTAssertEqual(result.itemsImported, 1, "good item should import")
        XCTAssertEqual(result.itemsSkippedCorrupt, 1, "wrong-key item should be counted as corrupt")
    }
}
