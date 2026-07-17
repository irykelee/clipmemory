import XCTest
import AppKit
import CommonCrypto
import Security
@testable import ClipMemory

/// I.1-I.8: ImageStorage round-trip + format + cache + bulk-delete tests.
///
/// Coverage map (complementing IntegrationTests):
/// - G.7 (IntegrationTests) covers ClipboardStore.copyImage → ImageStorage.saveImage
///   but only at the call site, not the ImageStorage public API surface.
/// - This file fills the gap in ImageStorage's own public API:
///   - saveImage / loadImage round-trip across formats and sizes
///   - Encrypted file format verification (hex)
///   - Corrupted-file fallback
///   - Path-traversal guard via filename validation
///   - NSCache behavior in loadImageObject
///   - Bulk delete (deleteAllExcept, cleanupOrphanedImages)
///
/// Test isolation:
/// - ImageStorage.shared is a singleton; init() runs migrateFromLegacyIfNeeded()
///   on first access. We set both UserDefaults flags in setUp BEFORE the singleton
///   is touched, so init is a no-op in the test process.
/// - Per-test cleanup: tracked UUIDs → deleteImage in tearDown.
/// - imagesDirectory is `private`; tests recompute the path rather than change
///   production visibility (surgical-changes rule).
final class ImageStorageTests: XCTestCase {

    private var storage: ImageStorage!
    private var testUUIDs: [UUID] = []
    private let migrationKey = "ImageStorageMigrationComplete"
    private let startupCleanupKey = "ImageStorageStartupCleanupRan"

    override func setUp() {
        super.setUp()
        // Force migration + startup cleanup to no-op BEFORE ImageStorage.shared
        // is touched (its private init() runs migrateFromLegacyIfNeeded on first access).
        UserDefaults.standard.set(true, forKey: migrationKey)
        UserDefaults.standard.set(true, forKey: startupCleanupKey)
        storage = ImageStorage.shared
    }

    override func tearDown() {
        for uuid in testUUIDs {
            storage.deleteImage(filename: "\(uuid.uuidString).png")
        }
        testUUIDs.removeAll()
        super.tearDown()
    }

    private func newTestUUID() -> UUID {
        let uuid = UUID()
        testUUIDs.append(uuid)
        return uuid
    }

    /// Recomputes the same path ImageStorage.imagesDirectory uses, without
    /// changing the private visibility of the lazy var.
    private func storageDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ClipMemory/Images", isDirectory: true)
    }

    // MARK: - Fixtures

    /// Generate a small valid PNG via NSBitmapImageRep — exercises real image
    /// encoding path so the test data behaves like production data.
    private func makePNGData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 32
        )
        guard let rep = rep else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private func makeTIFFData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 32
        )
        guard let rep = rep else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        return rep.tiffRepresentation ?? Data()
    }

    /// saveImage runs on a background queue. Tests wait for the main-thread completion.
    private func saveAndWait(_ data: Data, uuid: UUID) -> String? {
        var result: String?
        let exp = expectation(description: "saveImage for \(uuid.uuidString.prefix(8))")
        storage.saveImage(data, id: uuid) { filename in
            result = filename
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        return result
    }

    // MARK: - I.1 saveImage → loadImage round-trip

    func testSaveAndLoadPNGRoundTrip() {
        // I.1.1: Small PNG survives encryption + disk + decryption
        let uuid = newTestUUID()
        let original = makePNGData()
        XCTAssertFalse(original.isEmpty, "Test fixture: NSBitmapImageRep should produce PNG bytes")
        XCTAssertTrue(original.starts(with: Data([0x89, 0x50, 0x4E, 0x47])),
                     "Test fixture: PNG must start with PNG header")

        let filename = saveAndWait(original, uuid: uuid)
        XCTAssertEqual(filename, "\(uuid.uuidString).png")

        let loaded = storage.loadImage(filename: filename ?? "")
        XCTAssertEqual(loaded, original, "Loaded bytes must equal original (decryption succeeded)")
    }

    func testSaveAndLoadTIFFRoundTrip() {
        // I.1.2: ImageStorage is format-agnostic — any bytes in, same bytes out
        let uuid = newTestUUID()
        let original = makeTIFFData()
        XCTAssertFalse(original.isEmpty, "Test fixture: tiffRepresentation should produce bytes")
        // TIFF header is "II" or "MM" (little/big endian), NOT PNG
        XCTAssertFalse(original.starts(with: Data([0x89, 0x50, 0x4E, 0x47])),
                      "Test fixture: TIFF should not start with PNG header")

        let filename = saveAndWait(original, uuid: uuid)
        let loaded = storage.loadImage(filename: filename ?? "")
        XCTAssertEqual(loaded, original)
    }

    func testSaveAndLoadLargeData() {
        // I.1.3: ~5MB payload — exercises buffer paths and ensures no truncation
        let uuid = newTestUUID()
        let original = Data(repeating: 0xAB, count: 5 * 1024 * 1024)

        let filename = saveAndWait(original, uuid: uuid)
        XCTAssertNotNil(filename, "Large data within 50MB cap must save successfully")

        let loaded = storage.loadImage(filename: filename ?? "")
        XCTAssertEqual(loaded?.count, original.count, "No bytes lost in round-trip")
        XCTAssertEqual(loaded, original)
    }

    // MARK: - I.2 Encrypted file is NOT plaintext on disk

    func testSavedFileIsEncryptedNotPlaintext() {
        // I.2.1: Raw file bytes must NOT begin with PNG header
        //        Raw file bytes MUST begin with "v2" marker (CryptoService v2 format)
        let uuid = newTestUUID()
        let original = makePNGData()
        let filename = saveAndWait(original, uuid: uuid) ?? ""
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)

        guard let rawBytes = try? Data(contentsOf: fileURL) else {
            XCTFail("Could not read raw file at \(fileURL.path)")
            return
        }

        // Encryption hides the PNG signature
        XCTAssertFalse(rawBytes.starts(with: Data([0x89, 0x50, 0x4E, 0x47])),
                      "Encrypted file must NOT start with PNG header — that would mean plaintext on disk")
        // CryptoService v2 format prefixes with ASCII "v2"
        XCTAssertEqual(rawBytes.prefix(2), Data("v2".utf8),
                      "Encrypted file must have v2 marker (CryptoService v2 AES-GCM format)")
        // Encrypted blob is longer than plaintext (nonce + tag overhead)
        XCTAssertGreaterThan(rawBytes.count, original.count,
                            "Encrypted blob should be larger due to nonce + auth tag")
    }

    // MARK: - I.3 Corrupted file fallback

    func testLoadCorruptedFileReturnsNil() {
        // I.3.1: Overwriting with garbage bytes → loadImage returns nil (no crash)
        let uuid = newTestUUID()
        let original = makePNGData()
        let filename = saveAndWait(original, uuid: uuid) ?? ""
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)

        // Corrupt the file in place (valid filename, invalid encrypted content)
        let corrupted = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        try? corrupted.write(to: fileURL)

        let loaded = storage.loadImage(filename: filename)
        XCTAssertNil(loaded, "Corrupted encrypted blob must fail decryption and return nil")
    }

    func testLoadEmptyFileReturnsNil() {
        // I.3.2: Empty file (0 bytes) → nil, no crash from decryption pipeline
        let uuid = newTestUUID()
        let filename = "\(uuid.uuidString).png"
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)
        try? Data().write(to: fileURL)
        // Manually written — don't add to testUUIDs (deleteImage would fail anyway)

        let loaded = storage.loadImage(filename: filename)
        XCTAssertNil(loaded)
    }

    // MARK: - Image status

    /// imageStatus distinguishes a genuinely missing file from a decryption
    /// failure so the UI doesn't prompt the user to delete data that could be
    /// recoverable with the right key.
    func testImageStatusReportsMissingVsDecryptionFailed() {
        let uuid = newTestUUID()
        let original = makePNGData()
        let filename = saveAndWait(original, uuid: uuid) ?? ""

        // Existing valid file → available
        XCTAssertEqual(storage.imageStatus(for: filename), .available(original))

        // Missing file → fileMissing
        let missing = "\(UUID().uuidString).png"
        XCTAssertEqual(storage.imageStatus(for: missing), .fileMissing)

        // Corrupted file → decryptionFailed
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)
        try? Data([0x00, 0x01, 0x02, 0x03]).write(to: fileURL, options: .atomic)
        XCTAssertEqual(storage.imageStatus(for: filename), .decryptionFailed)
    }

    // MARK: - I.4 Filename validation (path-traversal guard)

    func testLoadImageRejectsPathTraversalAttempts() {
        // I.4.1: isValidFilename blocks anything that isn't `<UUID>.png`
        //        Prevents leaking files like `../../.ssh/id_rsa.png`
        let maliciousFilenames = [
            "../../../etc/passwd",
            "../../.ssh/id_rsa.png",
            "../foo.png",
            "not-a-uuid.png",
            "random.png",
            ".png",                            // empty UUID
            "abc.png"                          // non-UUID short string
        ]

        for filename in maliciousFilenames {
            XCTAssertNil(
                storage.loadImage(filename: filename),
                "Path-traversal attempt must be rejected (nil): '\(filename)'"
            )
        }
    }

    func testDeleteImageRejectsPathTraversalAttempts() {
        // I.4.2: deleteImage with an invalid filename must be a no-op —
        //        a real file under a valid UUID filename must survive
        let uuid = newTestUUID()
        let realFilename = "\(uuid.uuidString).png"
        let original = makePNGData()
        _ = saveAndWait(original, uuid: uuid)
        XCTAssertNotNil(storage.loadImage(filename: realFilename),
                       "Test fixture: real file must be loadable before delete attempts")

        // Attempt path-traversal / invalid deletes — should all be no-ops
        storage.deleteImage(filename: "../\(realFilename)")
        storage.deleteImage(filename: "../../etc/passwd")
        storage.deleteImage(filename: "")
        storage.deleteImage(filename: "not-a-uuid.png")

        XCTAssertNotNil(storage.loadImage(filename: realFilename),
                       "Real file must survive invalid delete attempts")
    }

    // MARK: - I.5 loadImageObject NSCache behavior

    func testLoadImageObjectCachesAcrossCalls() {
        // I.5.1: After first call, subsequent calls return cached NSImage
        //        even if the on-disk file is later corrupted
        let uuid = newTestUUID()
        let original = makePNGData()
        let filename = saveAndWait(original, uuid: uuid) ?? ""

        // First call: reads from disk, populates NSCache
        let first = storage.loadImageObject(filename: filename)
        XCTAssertNotNil(first, "First load should return a valid NSImage")

        // Corrupt the file on disk
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)
        try? Data([0xFF]).write(to: fileURL)

        // Second call: must hit cache, not re-read corrupted file
        let second = storage.loadImageObject(filename: filename)
        XCTAssertNotNil(second,
                       "Cached image must survive file corruption on disk")
    }

    // MARK: - I.6 deleteImage

    func testDeleteImageRemovesFile() {
        // I.6.1: After delete, loadImage returns nil
        let uuid = newTestUUID()
        let original = makePNGData()
        let filename = saveAndWait(original, uuid: uuid) ?? ""
        XCTAssertNotNil(storage.loadImage(filename: filename))

        storage.deleteImage(filename: filename)

        XCTAssertNil(storage.loadImage(filename: filename),
                    "Deleted file must be unreadable")
    }

    // MARK: - I.7 deleteAllExcept

    func testDeleteAllExceptPreservesListedFiles() {
        // I.7.1: Files in `filenames` survive; everything else is removed
        let keep1 = newTestUUID()
        let keep2 = newTestUUID()
        let drop1 = newTestUUID()
        let drop2 = newTestUUID()

        for uuid in [keep1, keep2, drop1, drop2] {
            _ = saveAndWait(makePNGData(), uuid: uuid)
        }

        let keepSet: Set<String> = [
            "\(keep1.uuidString).png",
            "\(keep2.uuidString).png"
        ]
        storage.deleteAllExcept(filenames: keepSet)

        XCTAssertNotNil(storage.loadImage(filename: "\(keep1.uuidString).png"),
                       "File in keep set should survive")
        XCTAssertNotNil(storage.loadImage(filename: "\(keep2.uuidString).png"),
                       "File in keep set should survive")
        XCTAssertNil(storage.loadImage(filename: "\(drop1.uuidString).png"),
                    "File not in keep set should be deleted")
        XCTAssertNil(storage.loadImage(filename: "\(drop2.uuidString).png"),
                    "File not in keep set should be deleted")
    }

    func testDeleteAllExceptIgnoresNonUUIDFiles() {
        // I.7.2: Stray files (e.g., not-uuid.png) must not be deleted —
        //        isValidFilename guard in deleteAllExcept skips them
        let uuid = newTestUUID()
        _ = saveAndWait(makePNGData(), uuid: uuid)

        // Manually write a stray file directly (not encrypted, not UUID-named)
        let stray = storageDirectoryURL().appendingPathComponent("stray-file.png")
        try? Data("stray".utf8).write(to: stray)

        storage.deleteAllExcept(filenames: ["\(uuid.uuidString).png"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path),
                     "Stray file (not matching UUID pattern) must not be deleted")
        // Cleanup the stray manually
        try? FileManager.default.removeItem(at: stray)
    }

    // MARK: - I.8 cleanupOrphanedImages

    func testCleanupOrphanedImagesRemovesUnreferenced() {
        // I.8.1: Files not in keptItems are deleted (excluding the first-call skip)
        //        Since setUp sets startupCleanupRan=true, the skip is already past.
        let keep = newTestUUID()
        let drop = newTestUUID()
        for uuid in [keep, drop] {
            _ = saveAndWait(makePNGData(), uuid: uuid)
        }

        let item = ClipboardItem(
            content: "\(keep.uuidString).png",
            type: .image
        )
        storage.cleanupOrphanedImages(keptItems: [item])

        XCTAssertNotNil(storage.loadImage(filename: "\(keep.uuidString).png"),
                       "Referenced image should survive cleanup")
        XCTAssertNil(storage.loadImage(filename: "\(drop.uuidString).png"),
                    "Orphan image (not in keptItems) should be deleted")
    }

    /// Regression: the startup guard must be set on the first call regardless
    /// of whether the keep set is empty. Without this, a transient empty-store
    /// launch (e.g. right after the user clears history) leaves the guard
    /// permanently unarmed; a later launch with a partially-loaded store could
    /// then delete images that are still in store.items but whose files are
    /// briefly missing from the keep set's view.
    func testCleanupOrphanedImagesFirstCallSetsStartupFlagEvenWhenKeepSetIsEmpty() {
        // Clear the flag so the next call is "first".
        UserDefaults.standard.removeObject(forKey: startupCleanupKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: startupCleanupKey),
                       "Test fixture: startup flag must be cleared before call")

        // First call with NO images in store — must still mark the flag.
        storage.cleanupOrphanedImages(keptItems: [])

        XCTAssertTrue(UserDefaults.standard.bool(forKey: startupCleanupKey),
                     "Startup flag must be set on the very first call, " +
                     "even with an empty keep set, so the guard is armed " +
                     "for subsequent launches.")
    }

    // MARK: - RS-6: legacyDecryptImage round-trip via loadImage
    //
    // Synthesizes v1-format encrypted blobs (AES-CBC + HMAC-SHA256) and writes
    // them directly to ImageStorage's imagesDirectory, then calls loadImage().
    // loadImage() must:
    //   1. Fail the v2 decrypt attempt (no "v2" prefix in our blob)
    //   2. Fall through to legacyDecryptImage and succeed
    //   3. Re-encrypt to v2 and overwrite the file (migrate-on-read contract)
    //   4. Return the original plaintext bytes
    //
    // Mirrors the CryptoService.decryptLegacy tests but exercises the separate
    // ImageStorage.legacyDecryptImage code path (constantTimeCompare migration
    // in commit a00da7c follow-up + loadImage's try-decrypt chain).

    func testLoadImageMigratesLegacyV1FormatToV2() throws {
        // RS-6: synthesized v1-format blob → loadImage decrypts via
        // legacyDecryptImage fallback and re-encrypts to v2 on disk.
        // Uses newTestUUID() + .png extension to satisfy ImageStorage's
        // isValidFilename guard (UUID stem + .png suffix required);
        // tearDown auto-cleans via deleteImage.
        let uuid = newTestUUID()
        let filename = "\(uuid.uuidString).png"
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)

        let plaintext = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        XCTAssertEqual(key.count, 32, "Test fixture: key file must have 32 bytes")

        let legacyBlob = makeLegacyV1Blob(plaintext: plaintext, key: key)
        try legacyBlob.write(to: fileURL)

        // Pre-condition: file is NOT in v2 format (we just wrote legacy bytes)
        let preBytes = try Data(contentsOf: fileURL)
        XCTAssertFalse(preBytes.starts(with: Data("v2".utf8)),
                     "Pre-condition: written blob must not be v2 format")

        // loadImage triggers legacyDecryptImage fallback path
        let loaded = storage.loadImage(filename: filename)
        XCTAssertEqual(loaded, plaintext,
            "Legacy v1 image must load via legacyDecryptImage path")

        // Post-condition: file is now in v2 format (migrate-on-read)
        let migratedBytes = try Data(contentsOf: fileURL)
        XCTAssertTrue(migratedBytes.starts(with: Data("v2".utf8)),
            "Legacy image must be re-encrypted to v2 on load (migrate-on-read contract)")

        // Subsequent load uses the v2 path (no re-decrypt needed)
        let loadedAgain = storage.loadImage(filename: filename)
        XCTAssertEqual(loadedAgain, plaintext,
            "Re-loading the now-migrated v2 file must still return original bytes")
    }

    func testLoadImageRejectsTamperedLegacyHMAC() throws {
        // RS-6: legacyDecryptImage must reject blobs with mutated HMAC.
        // loadImage returns nil (no exception), so this guards the
        // constantTimeCompare path inside ImageStorage. Uses UUID+.png
        // filename to pass isValidFilename (otherwise loadImage returns
        // nil for the wrong reason — filename validation, not HMAC tamper).
        let uuid = newTestUUID()
        let filename = "\(uuid.uuidString).png"
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)

        let plaintext = Data("Image bytes for tamper test".utf8)
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        var blob = makeLegacyV1Blob(plaintext: plaintext, key: key)

        // Flip a byte in the HMAC region (last 32 bytes)
        blob[blob.count - 32] ^= 0x01
        try blob.write(to: fileURL)

        let loaded = storage.loadImage(filename: filename)
        XCTAssertNil(loaded, "Tampered legacy HMAC must cause loadImage to fail")
    }

    // MARK: - Raw PNG fallback (pre-encryption history)

    /// loadImage must accept raw unencrypted PNG bytes (e.g., from a user's
    /// earlier version that didn't encrypt images) and return the plaintext,
    /// then opportunistically re-encrypt to v2 so subsequent loads take the
    /// fast v2 path. Pre-fix this scenario returned nil because the file
    /// didn't match v2 prefix or legacy V1+AES-CBC+HMAC structure.
    func testLoadImageHandlesRawUnencryptedPNG() throws {
        let uuid = newTestUUID()
        let filename = "\(uuid.uuidString).png"
        let fileURL = storageDirectoryURL().appendingPathComponent(filename)

        let pngBytes = makePNGData()
        XCTAssertTrue(pngBytes.starts(with: Data([0x89, 0x50, 0x4E, 0x47])),
                     "Test fixture: PNG bytes must start with PNG magic")
        try pngBytes.write(to: fileURL)

        // Pre-condition: file is raw PNG, not v2
        let preBytes = try Data(contentsOf: fileURL)
        XCTAssertFalse(preBytes.starts(with: Data("v2".utf8)),
                     "Pre-condition: raw PNG must not start with v2 prefix")

        let loaded = storage.loadImage(filename: filename)
        XCTAssertEqual(loaded, pngBytes,
            "Raw PNG must load via fallback path")

        // Post-condition: file is now in v2 format (opportunistic re-encryption)
        let migratedBytes = try Data(contentsOf: fileURL)
        XCTAssertTrue(migratedBytes.starts(with: Data("v2".utf8)),
            "Raw PNG must be re-encrypted to v2 after load (opportunistic migration)")

        // Subsequent load uses the v2 path (no re-decrypt needed)
        let loadedAgain = storage.loadImage(filename: filename)
        XCTAssertEqual(loadedAgain, pngBytes,
            "Re-loading the now-migrated v2 file must still return original bytes")
    }

    // MARK: - RS-6 Helpers (duplicate of CryptoServiceTests synthesis — kept
    // local to avoid cross-file test helpers + project.pbxproj churn)

    private func makeLegacyV1Blob(plaintext: Data, key: Data) -> Data {
        let iv = rs6RandomBytes(count: 16)
        let ciphertext = rs6AesEncryptCBC(plaintext: plaintext, key: key, iv: iv)
        let hmac = CryptoService.computeLegacyHMAC(data: iv + ciphertext, key: key)
        return iv + ciphertext + hmac
    }

    private func rs6AesEncryptCBC(plaintext: Data, key: Data, iv: Data) -> Data {
        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var encryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, 32,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, plaintext.count,
                        &encryptedBytes, bufferSize,
                        &numBytesEncrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            fatalError("rs6AesEncryptCBC failed with status \(status)")
        }
        return Data(encryptedBytes.prefix(numBytesEncrypted))
    }

    private func rs6RandomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with status \(result)")
        }
        return data
    }
}
