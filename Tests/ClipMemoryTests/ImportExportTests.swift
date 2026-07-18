import XCTest
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
}
