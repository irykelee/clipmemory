import XCTest
import CryptoKit
@testable import ClipMemory

/// BKP-2 / BKP-3 (2026-07-24 audit) regression tests: a hostile `.clipmemory`
/// package must be rejected as corrupt when its extracted tree contains a
/// symbolic link (BKP-2) or an oversized store JSON blob (BKP-3).
/// Fully sandboxed: temp dirs + throwaway CryptoService keys; the real
/// Application Support and the app's key file are never touched.
final class BackupPackageSecurityTests: XCTestCase {

    private var tempRoot: URL!
    private var imagesDir: URL!
    private var localCrypto: CryptoService!
    private var originalCrypto: CryptoServiceProtocol?
    private var store: ClipboardStore!
    private let passphrase = "secret123"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupPackageSecurityTests-\(UUID().uuidString)", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        localCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0 & 0xFF) }))
        // Route the store's decrypt path through the test key; restored in tearDown.
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
        localCrypto = nil
        store = nil
        super.tearDown()
    }

    /// Builds a structurally valid `.clipmemory` package (HKDF v1 key
    /// derivation, like the ImportExportTests fixtures), then hands the
    /// staging dir to `customize` so a test can plant hostile content
    /// before the archive is zipped.
    private func buildPackage(
        name: String,
        customize: (URL) throws -> Void
    ) throws -> URL {
        let packageCrypto = CryptoService(customKeyData: Data((32..<64).map { UInt8($0 & 0xFF) }))
        let staging = tempRoot.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: staging.appendingPathComponent("items.json"))
        try Data("[]".utf8).write(to: staging.appendingPathComponent("trash.json"))
        try Data("[]".utf8).write(to: staging.appendingPathComponent("tags.json"))

        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let derivedKey = try BackupPackage.deriveKey(passphrase: passphrase, salt: salt, version: 1)
        let sealed = try AES.GCM.seal(packageCrypto.exportKeyDataForTesting(), using: derivedKey)
        try XCTUnwrap(sealed.combined).write(to: staging.appendingPathComponent("key.enc"))
        let manifest = BackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            appVersion: "test",
            keySalt: salt.base64EncodedString(),
            itemCount: 0,
            tagCount: 0,
            imageCount: 0,
            keyDerivationVersion: 1
        )
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        try customize(staging)

        let packageURL = tempRoot.appendingPathComponent(name)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, packageURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "ditto failed building test fixture")
        try FileManager.default.removeItem(at: staging)
        return packageURL
    }

    private func importPackage(_ packageURL: URL) throws -> BackupImportResult {
        try BackupPackage.importPackage(
            from: packageURL,
            passphrase: passphrase,
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir
        )
    }

    // MARK: - BKP-2: extracted-tree validation

    /// A package carrying a symlink (here pointing at a file outside the
    /// staging root) must be rejected as corrupt BEFORE any extracted file
    /// is consumed — `ditto -x` restores symlinks verbatim, and a later
    /// `Data(contentsOf:)` would follow them anywhere on disk.
    func testImportRejectsPackageContainingSymlink() throws {
        let outsideFile = tempRoot.appendingPathComponent("outside-secret.txt")
        try Data("not part of the backup".utf8).write(to: outsideFile)
        let packageURL = try buildPackage(name: "symlink.clipmemory") { staging in
            try FileManager.default.createSymbolicLink(
                at: staging.appendingPathComponent("escape-link"),
                withDestinationURL: outsideFile
            )
        }
        XCTAssertThrowsError(try importPackage(packageURL)) { error in
            guard case BackupPackageError.corruptedData(_, .manifest) = error else {
                return XCTFail("expected corruptedData(_, .manifest), got \(error)")
            }
        }
    }

    /// Symlinks nested in a subdirectory (Images/) are equally dangerous —
    /// an image entry pointing at ~/Library would be followed by the image
    /// import pass. The tree walk must catch nested entries too.
    func testImportRejectsSymlinkInsideImagesSubdirectory() throws {
        let outsideFile = tempRoot.appendingPathComponent("outside-secret.txt")
        try Data("not part of the backup".utf8).write(to: outsideFile)
        let packageURL = try buildPackage(name: "nested-symlink.clipmemory") { staging in
            let images = staging.appendingPathComponent("Images", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: images.appendingPathComponent("evil.png"),
                withDestinationURL: outsideFile
            )
        }
        XCTAssertThrowsError(try importPackage(packageURL)) { error in
            guard case BackupPackageError.corruptedData(_, .manifest) = error else {
                return XCTFail("expected corruptedData(_, .manifest), got \(error)")
            }
        }
    }

    /// Control: a clean package passes tree validation and imports fine.
    func testImportAcceptsCleanPackage() throws {
        let packageURL = try buildPackage(name: "clean.clipmemory") { _ in }
        let result = try importPackage(packageURL)
        XCTAssertEqual(result.itemsImported, 0)
        XCTAssertEqual(result.tagsImported, 0)
    }
}
