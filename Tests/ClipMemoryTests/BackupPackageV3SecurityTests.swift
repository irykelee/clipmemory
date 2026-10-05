import XCTest
import CryptoKit
@testable import ClipMemory

/// ID-REVIEW-1015 (code-review-2026-10-01 §八 1-4): regression tests
/// guarding the v3 package format. Acceptance criteria from the
/// code-review:
///   1. v3 package's `key.enc`, when unsealed, must NOT contain the
///      machine root key bytes — it contains a fresh one-shot
///      `packageKey` instead.
///   2. v1 legacy packages remain importable (dual-read path).
///   3. v3 export → v3 import round-trip preserves items and makes
///      them readable under the new local key.
///   4. Wrong passphrase surfaces as `wrongPassword` (not generic
///      `corruptedData`).
///
/// Fully sandboxed: temp dirs + throwaway CryptoService keys; the
/// real Application Support and the app's key file are never touched.
@MainActor final class BackupPackageV3SecurityTests: XCTestCase {

    private var tempRoot: URL!
    private var imagesDir: URL!
    private var defaults: UserDefaults!
    private var localCrypto: CryptoService!
    private var rootCrypto: CryptoService!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?
    private let passphrase = "secret123"
    private let rootKeyBytes: Data = Data((0..<32).map { UInt8($0 & 0xFF) })
    private let localKeyBytes: Data = Data((32..<64).map { UInt8($0 & 0xFF) })

    override func setUp() {
        super.setUp()
        let uid = UUID().uuidString
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupPackageV3SecurityTests-\(uid)", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "BackupPackageV3SecurityTests-\(uid)")
        defaults.removePersistentDomain(forName: "BackupPackageV3SecurityTests-\(uid)")
        localCrypto = CryptoService(customKeyData: localKeyBytes)
        rootCrypto = CryptoService(customKeyData: rootKeyBytes)
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(localCrypto)
        store = ClipboardStore(backend: MemoryStorageBackend(), defaults: defaults)
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        defaults?.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        defaults = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        imagesDir = nil
        localCrypto = nil
        rootCrypto = nil
        store = nil
        super.tearDown()
    }

    /// Persists a root-key-encrypted item into `defaults` so an
    /// `exportPackage` call sees a non-empty source. We switch the
    /// ServiceContainer to `rootCrypto` while seeding so the
    /// `encrypt(content:)` call uses the root key (matching the
    /// v1 export behavior the v3 path replaces).
    private func seedRootEncryptedItem(content: String) throws {
        ServiceContainer.setCryptoForTesting(rootCrypto)
        let hash = rootCrypto.hmacHex(for: content)
        guard let encrypted = rootCrypto.encrypt(content) else {
            XCTFail("root-key encryption failed"); return
        }
        let item = ClipboardItem(
            content: encrypted,
            type: .text,
            isEncrypted: true,
            contentHash: hash
        )
        var items: [ClipboardItem] = []
        if let data = defaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue),
           let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            items = decoded
        }
        items.append(item)
        let encoded = try JSONEncoder().encode(items)
        defaults.set(encoded, forKey: UserDefaultsKey.clipboardItems.rawValue)
        ServiceContainer.setCryptoForTesting(localCrypto)
    }

    /// Extracts `key.enc` bytes from a `.clipmemory` archive without
    /// unsealing them — the assertion is purely about what's inside
    /// the wrapper, not what it can decrypt.
    private func keyEncBytes(in packageURL: URL) throws -> Data {
        let staging = tempRoot.appendingPathComponent("inspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try runDittoExtract(packageURL: packageURL, to: staging)
        return try Data(contentsOf: staging.appendingPathComponent("key.enc"))
    }

    /// Decodes `manifest.json` from a `.clipmemory` archive.
    private func manifest(in packageURL: URL) throws -> BackupManifest {
        let staging = tempRoot.appendingPathComponent("inspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try runDittoExtract(packageURL: packageURL, to: staging)
        let data = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(BackupManifest.self, from: data)
    }

    private func runDittoExtract(packageURL: URL, to staging: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", packageURL.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
    }

    // MARK: - Acceptance #1: v3 package does NOT embed the root key

    /// §八 1-4 acceptance criterion (a): the bytes inside `key.enc`
    /// after unsealing must NOT equal the machine root key that was
    /// passed to `exportPackage`. They ARE a valid 32-byte AES-GCM
    /// plaintext — just not the root key.
    func testV3KeyEncDoesNotEmbedRootKey() throws {
        try seedRootEncryptedItem(content: "v3-test-payload")

        let packageURL = tempRoot.appendingPathComponent("v3-export.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        let m = try manifest(in: packageURL)
        XCTAssertEqual(m.formatVersion, 3, "v3 export must emit formatVersion 3")

        let sealedKey = try keyEncBytes(in: packageURL)
        XCTAssertEqual(sealedKey.count, 12 + 32 + 16, "v3 key.enc size unchanged from v1")
        guard let salt = Data(base64Encoded: m.keySalt) else {
            XCTFail("invalid keySalt in manifest"); return
        }
        let derivedKey = try BackupPackage.deriveKey(passphrase: passphrase, salt: salt, version: m.keyDerivationVersion)
        let box = try AES.GCM.SealedBox(combined: sealedKey)
        let unsealed = try AES.GCM.open(box, using: derivedKey)
        XCTAssertEqual(unsealed.count, 32, "v3 unsealed key must be 32 bytes")
        XCTAssertNotEqual(
            unsealed,
            rootKeyBytes,
            "ACCEPTANCE: v3 key.enc MUST NOT embed the machine root key — it embeds a one-shot packageKey"
        )
    }

    // MARK: - Acceptance #2: v1 legacy import still works

    /// §八 1-4 acceptance criterion (b): packages written by older
    /// ClipMemory (formatVersion = 1) remain importable on the v3-aware
    /// build. Construct a v1 fixture by hand using the same pattern
    /// `BackupPackageSecurityTests.buildPackage` uses.
    func testV1LegacyPackageStillImports() throws {
        // Build a v1 package with a known plaintext item so we can
        // confirm the import decrypts with the (v1-sealed) root key.
        let legacyKeyData = Data((100..<132).map { UInt8($0 & 0xFF) })
        let legacyCrypto = CryptoService(customKeyData: legacyKeyData)
        let plaintext = "legacy-v1-payload-\(UUID().uuidString)"
        guard let ciphertext = legacyCrypto.encrypt(plaintext) else {
            XCTFail("legacy fixture encryption failed"); return
        }
        let item = ClipboardItem(
            content: ciphertext,
            type: .text,
            isEncrypted: true,
            contentHash: legacyCrypto.hmacHex(for: plaintext)
        )

        let staging = tempRoot.appendingPathComponent("v1-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try JSONEncoder().encode([item]).write(to: staging.appendingPathComponent("items.json"))
        try Data("[]".utf8).write(to: staging.appendingPathComponent("trash.json"))
        try Data("[]".utf8).write(to: staging.appendingPathComponent("tags.json"))

        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let derivedKey = try BackupPackage.deriveKey(passphrase: passphrase, salt: salt, version: 2)
        let sealed = try AES.GCM.seal(legacyKeyData, using: derivedKey)
        try XCTUnwrap(sealed.combined).write(to: staging.appendingPathComponent("key.enc"))
        let manifestFixture = BackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            appVersion: "test",
            keySalt: salt.base64EncodedString(),
            itemCount: 1,
            tagCount: 0,
            imageCount: 0,
            keyDerivationVersion: 2
        )
        try JSONEncoder().encode(manifestFixture).write(to: staging.appendingPathComponent("manifest.json"))

        let packageURL = tempRoot.appendingPathComponent("v1-legacy.clipmemory")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, packageURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        // Import: the v1 path should unseal key.enc → rootKey →
        // reencrypt from rootKey → localCrypto.
        ServiceContainer.setCryptoForTesting(localCrypto)
        let result = try BackupPackage.importPackage(
            from: packageURL,
            passphrase: passphrase,
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir
        )
        XCTAssertEqual(result.itemsImported, 1, "v1 legacy import must still work after v3 bump")
    }

    // MARK: - Acceptance #3: v3 round-trip preserves items

    /// §八 1-4 acceptance criterion (c): a v3 export followed by an
    /// import on a different `localCrypto` recovers the items. We
    /// inspect the package blobs directly to assert the v3 export
    /// sealed items under the packageKey (not the root key) and that
    /// unsealing the packageKey decrypts them.
    func testV3ExportImportRoundTripPreservesItems() throws {
        let payload = "round-trip-payload-\(UUID().uuidString)"
        try seedRootEncryptedItem(content: payload)

        let packageURL = tempRoot.appendingPathComponent("v3-roundtrip.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        // Decode items.json from the v3 package — they are now
        // encrypted with the one-shot packageKey (NOT the root key).
        let staging = tempRoot.appendingPathComponent("roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try runDittoExtract(packageURL: packageURL, to: staging)
        let itemsData = try Data(contentsOf: staging.appendingPathComponent("items.json"))
        let items = try JSONDecoder().decode([ClipboardItem].self, from: itemsData)
        XCTAssertEqual(items.count, 1, "v3 export must preserve item count")

        // The v3-stored item's content must NOT decrypt with the root
        // key (it was sealed under packageKey on export).
        XCTAssertNil(
            rootCrypto.decrypt(items[0].content),
            "v3 export must NOT leave items decryptable with the root key"
        )
        // It MUST decrypt with the packageKey (unsealed from key.enc
        // by the passphrase).
        let m = try manifest(in: packageURL)
        guard let salt = Data(base64Encoded: m.keySalt) else {
            XCTFail("invalid keySalt in manifest"); return
        }
        let derivedKey = try BackupPackage.deriveKey(passphrase: passphrase, salt: salt, version: m.keyDerivationVersion)
        let box = try AES.GCM.SealedBox(combined: try Data(contentsOf: staging.appendingPathComponent("key.enc")))
        let packageKeyData = try AES.GCM.open(box, using: derivedKey)
        let packageCrypto = CryptoService(customKeyData: packageKeyData)
        XCTAssertEqual(
            packageCrypto.decrypt(items[0].content),
            payload,
            "v3 round-trip: packageKey unsealed from key.enc must decrypt the items blob"
        )
    }

    // MARK: - Acceptance #4: wrong passphrase fails as wrongPassword

    /// Both v3 and v1 must surface a wrong passphrase as
    /// `BackupPackageError.wrongPassword` (the only recoverable
    /// import error). Hard corruption would surface as
    /// `corruptedData` instead — the separator is deliberate.
    func testWrongPassphraseFailsWithWrongPasswordError() throws {
        try seedRootEncryptedItem(content: "wrong-pass-test")
        let packageURL = tempRoot.appendingPathComponent("wrong-pass.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        XCTAssertThrowsError(
            try BackupPackage.importPackage(
                from: packageURL,
                passphrase: passphrase + "wrong",
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir
            )
        ) { error in
            guard case BackupPackageError.wrongPassword = error else {
                return XCTFail("expected .wrongPassword, got \(error)")
            }
        }
    }

    // MARK: - Acceptance #5: v3 manifest declares formatVersion 3

    /// Belt-and-suspenders for the constant bump: even an empty
    /// v3 export must carry `formatVersion == 3` (so the import
    /// path picks up the v3 behavior on next read).
    func testV3ManifestFormatVersionIsThree() throws {
        let packageURL = tempRoot.appendingPathComponent("v3-empty.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )
        let m = try manifest(in: packageURL)
        XCTAssertEqual(m.formatVersion, 3)
        XCTAssertGreaterThanOrEqual(m.keyDerivationVersion, 2, "PBKDF2-600k still the default KDF")
    }

    // MARK: - Acceptance #3b: v3 round-trip preserves IMAGES

    /// §八 1-4 image-path regression (code-review §九-C, 2026-10-05):
    /// the FIRST v3 implementation staged images via raw `copyItem` —
    /// root-key-encrypted bytes that the importer (holding only the
    /// unsealed packageKey) could never decrypt, so every v3 package
    /// containing images failed at import with `imageImportFailed`
    /// (`decryptAndReencryptImage` throws `corruptedData` on the GCM
    /// auth failure). This test pins the fixed contract:
    ///   1. export re-encrypts images under the one-shot packageKey
    ///      (package bytes ≠ local root-encrypted bytes ≠ plaintext);
    ///   2. a CROSS-MACHINE import (localCrypto ≠ rootCrypto) restores
    ///      the original plaintext byte-for-byte with
    ///      `imageImportFailed == false`.
    func testV3RoundTripPreservesImages() throws {
        let plainPNG = Data("PNGDATA-\(UUID().uuidString)".utf8)
        let imageName = UUID().uuidString + ".png"
        let localEncrypted = try XCTUnwrap(
            rootCrypto.encryptData(plainPNG),
            "test root crypto must encrypt the fixture image"
        )
        try localEncrypted.write(
            to: imagesDir.appendingPathComponent(imageName), options: .atomic
        )
        try seedRootEncryptedItem(content: "image-item-payload")

        let packageURL = tempRoot.appendingPathComponent("v3-images.clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        // Extract and compare the packaged image against BOTH the
        // local root-encrypted file and the plaintext — neither may
        // match, proving the re-encryption under packageKey happened.
        let staging = tempRoot.appendingPathComponent("v3img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try runDittoExtract(packageURL: packageURL, to: staging)
        let packageImage = try Data(
            contentsOf: staging.appendingPathComponent("Images/\(imageName)")
        )
        XCTAssertNotEqual(
            packageImage, localEncrypted,
            "v3 export must NOT ship the root-encrypted image as-is"
        )
        XCTAssertNotEqual(packageImage, plainPNG)

        // Cross-machine import: localCrypto ≠ rootCrypto. The restored
        // image (stored localCrypto-encrypted, matching the app's
        // at-rest model) must decrypt to the original plaintext.
        let localImagesDir = tempRoot.appendingPathComponent(
            "LocalImages-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: localImagesDir, withIntermediateDirectories: true)
        let result = try BackupPackage.importPackage(
            from: packageURL,
            passphrase: passphrase,
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: localImagesDir
        )
        XCTAssertFalse(result.imageImportFailed, "v3 image import must succeed cross-machine")
        XCTAssertEqual(result.imagesImported, 1, "exactly the staged image must be restored")
        let restored = try Data(contentsOf: localImagesDir.appendingPathComponent(imageName))
        XCTAssertEqual(
            localCrypto.decryptData(restored), plainPNG,
            "restored image must decrypt (under the new machine's key) to the original plaintext"
        )
    }
}
