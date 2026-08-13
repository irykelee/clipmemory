import XCTest
@testable import ClipMemory

final class BackupPackageValidateExternalPackageTests: XCTestCase {
    var tempRoot: URL!
    var imagesDir: URL!
    var defaults: UserDefaults!
    var localKeyData: Data!
    var localCrypto: CryptoService!
    var originalCrypto: CryptoServiceProtocol!

    override func setUp() {
        super.setUp()
        let uid = UUID().uuidString
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidateExt-\(uid)", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ValidateExt-\(uid)")
        // Deterministic 32-byte test key — no Keychain required.
        localKeyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        localCrypto = CryptoService(customKeyData: localKeyData)
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(localCrypto)
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// Helper: generate a real `.clipmemory` with given passphrase using
    /// `BackupPackage.exportPackage`. The test's deterministic key is what
    /// `exportPackage` encrypts with, so the produced archive is round-trip
    /// readable via the same key.
    private func makeFixture(passphrase: String) throws -> URL {
        let url = tempRoot.appendingPathComponent("fixture-\(UUID().uuidString).clipmemory")
        try BackupPackage.exportPackage(
            to: url, passphrase: passphrase, defaults: defaults,
            imagesDirectory: imagesDir, keyData: localKeyData
        )
        return url
    }

    func testValidPassphraseReturnsManifest() throws {
        let url = try makeFixture(passphrase: "right-password")
        let manifest = try BackupPackage.validateExternalPackage(at: url, passphrase: "right-password")
        XCTAssertEqual(manifest.itemCount, 0)
        XCTAssertEqual(manifest.keyDerivationVersion, 2)
    }

    func testWrongPassphraseThrowsWrongPassword() throws {
        let url = try makeFixture(passphrase: "right-password")
        XCTAssertThrowsError(try BackupPackage.validateExternalPackage(at: url, passphrase: "WRONG")) { err in
            guard case BackupPackageError.wrongPassword = err else {
                XCTFail("expected .wrongPassword, got \(err)"); return
            }
        }
    }

    func testCorruptedKeyEncThrowsCorruptedData() throws {
        let url = try makeFixture(passphrase: "p")
        // Truncate key.enc to a length other than 60 bytes.
        let staging = tempRoot.appendingPathComponent("corrupt-staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, staging.path]
        try ditto.run(); ditto.waitUntilExit()
        try Data(repeating: 0, count: 10).write(to: staging.appendingPathComponent("key.enc"))
        let corruptURL = staging.appendingPathComponent("x.clipmemory")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, corruptURL.path]
        try zip.run(); zip.waitUntilExit()
        XCTAssertThrowsError(try BackupPackage.validateExternalPackage(at: corruptURL, passphrase: "p")) { err in
            guard case BackupPackageError.corruptedData = err else {
                XCTFail("expected .corruptedData, got \(err)"); return
            }
        }
    }

    func testOversizedManifestThrowsCorruptedData() throws {
        let url = try makeFixture(passphrase: "p")
        let staging = tempRoot.appendingPathComponent("oversized-staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, staging.path]
        try ditto.run(); ditto.waitUntilExit()
        // Write 2 MB into manifest.json (exceeds maxManifestBytes = 1 MB).
        try Data(repeating: 0x41, count: 2 * 1024 * 1024).write(to: staging.appendingPathComponent("manifest.json"))
        let oversizedURL = staging.appendingPathComponent("oversized.clipmemory")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, oversizedURL.path]
        try zip.run(); zip.waitUntilExit()
        XCTAssertThrowsError(try BackupPackage.validateExternalPackage(at: oversizedURL, passphrase: "p")) { err in
            guard case BackupPackageError.corruptedData = err else {
                XCTFail("expected .corruptedData, got \(err)"); return
            }
        }
    }

    func testNonExistentFileThrowsArchiveFailed() {
        let url = URL(fileURLWithPath: "/tmp/doesnt-exist-\(UUID().uuidString).clipmemory")
        XCTAssertThrowsError(try BackupPackage.validateExternalPackage(at: url, passphrase: "x")) { err in
            guard case BackupPackageError.archiveFailed = err else {
                XCTFail("expected .archiveFailed, got \(err)"); return
            }
        }
    }
}
