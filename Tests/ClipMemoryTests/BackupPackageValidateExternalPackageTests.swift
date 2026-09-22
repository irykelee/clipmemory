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

    // MARK: - P1-AUDIT-2026-09-22 (audit finding P1-2): zip-slip regression
    //
    // The wizard validateExternalPackage path used a bare `/usr/bin/ditto -x -k`
    // and never called unzipArchive. A malicious .clipmemory with a `../`
    // member would write outside the staging dir before validateExtractedTree
    // had a chance to look. Regression tests for the bypass — they must fail
    // BEFORE the fix (currently the bare-ditto call lets ditto itself reject
    // `../`/absolute members with exit status ≠ 0 → throws archiveFailed) and
    // pass AFTER the fix (unzipArchive routes through validateArchiveMembers
    // which throws the canonical corruptedData("unsafe archive member: ...")
    // message).

    /// Builds a real zip archive whose central directory carries the given
    /// member path. The validator must reject at the unzipArchive layer
    /// (validateArchiveMembers) before any extraction happens.
    ///
    /// System `/usr/bin/zip` and `/usr/bin/ditto -c -k` both refuse `..`-
    /// named members on creation; `zipfile.ZipFile.writestr` writes whatever
    /// string is passed. CRC + sizes are filled by zipfile.
    private func makeMaliciousArchive(member: String) throws -> URL {
        let archive = tempRoot.appendingPathComponent("malicious-\(UUID().uuidString).zip")
        let script = "import zipfile,sys\n" +
            "z=zipfile.ZipFile(sys.argv[1],'w')\n" +
            "z.writestr(sys.argv[2], b'x')\n" +
            "z.close()\n"
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-c", script, archive.path, member]
        let errPipe = Pipe()
        py.standardError = errPipe
        try py.run()
        py.waitUntilExit()
        guard py.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "makeMaliciousArchive", code: Int(py.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "python3 failed: \(err)"]
            )
        }
        return archive
    }

    /// P1-AUDIT-2026-09-22 (audit finding P1-2): the wizard
    /// validateExternalPackage path used a bare `ditto -x -k` and never
    /// called unzipArchive. A malicious .clipmemory with a `../` member
    /// would write outside the staging dir before validateExtractedTree
    /// had a chance to look. Regression test for the bypass.
    func testValidateExternalPackageRejectsZipSlipMember() throws {
        let archive = try makeMaliciousArchive(member: "../etc/passwd")
        XCTAssertThrowsError(
            try BackupPackage.validateExternalPackage(at: archive, passphrase: "anything")
        ) { error in
            guard case BackupPackageError.corruptedData(let msg, _) = error else {
                XCTFail("Expected corruptedData, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("unsafe archive member"), msg)
        }
    }

    /// P1-AUDIT-2026-09-22: absolute path member must also reject.
    func testValidateExternalPackageRejectsAbsolutePathMember() throws {
        let archive = try makeMaliciousArchive(member: "/tmp/escape")
        XCTAssertThrowsError(
            try BackupPackage.validateExternalPackage(at: archive, passphrase: "anything")
        ) { error in
            guard case BackupPackageError.corruptedData(let msg, _) = error else {
                XCTFail("Expected corruptedData, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("unsafe archive member"), msg)
        }
    }

    /// P1-AUDIT-2026-09-22: backslash (Windows-style) separator must reject.
    func testValidateExternalPackageRejectsBackslashMember() throws {
        let archive = try makeMaliciousArchive(member: "..\\windows")
        XCTAssertThrowsError(
            try BackupPackage.validateExternalPackage(at: archive, passphrase: "anything")
        ) { error in
            guard case BackupPackageError.corruptedData(let msg, _) = error else {
                XCTFail("Expected corruptedData, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("unsafe archive member"), msg)
        }
    }
}
