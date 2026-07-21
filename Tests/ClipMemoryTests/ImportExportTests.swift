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
        try Data().write(to: staging.appendingPathComponent("items.json"), options: .atomic)
        try Data().write(to: staging.appendingPathComponent("tags.json"), options: .atomic)
        try Data().write(to: staging.appendingPathComponent("trash.json"), options: .atomic)

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
}
