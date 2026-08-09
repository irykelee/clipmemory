import XCTest
@testable import ClipMemory

/// CLIP-1 regression: repeated captures of the same image must dedup to a
/// single entry + a single file. Previously ClipboardMonitor minted a new
/// UUID per capture and ClipboardStore.addItem skipped contentHash for
/// `.image`, so copying the same picture N times produced N files + N list
/// rows.
///
/// Isolation:
/// - CryptoService(customKeyData:) injected via ServiceContainer (saved /
///   restored around each test).
/// - MemoryStorageBackend keeps all store persistence in memory.
/// - ImageStorage.shared writes to the XCTest-sandboxed Images-Tests dir;
///   files this suite saves are tracked and deleted in tearDown.
/// - UserDefaults keys the store/ImageStorage may write are saved in setUp
///   and restored in tearDown.
@MainActor final class ImageDedupTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?
    private var testCrypto: CryptoService!
    private var testUUIDs: [UUID] = []

    private let migrationKey = "ImageStorageMigrationComplete"
    private let startupCleanupKey = "ImageStorageStartupCleanupRan"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(testCrypto)

        // M13 (2026-08-03): use isolated defaults suite so ClipboardStore+OCR
        // writes (ocrPreviewEnabled etc.) never touch production.
        testDefaults = makeTestDefaults()
        testDefaults.set(true, forKey: migrationKey)
        testDefaults.set(true, forKey: startupCleanupKey)

        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend, defaults: testDefaults)
    }

    override func tearDown() {
        for uuid in testUUIDs {
            ImageStorage.shared.deleteImage(filename: Self.filename(uuid))
        }
        testUUIDs.removeAll()
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        testCrypto = nil
        store = nil
        backend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func filename(_ id: UUID) -> String {
        "\(id.uuidString).png"
    }

    private func fileURL(_ id: UUID) -> URL {
        ImageStorage.shared.imagesDirectoryURL.appendingPathComponent(Self.filename(id))
    }

    private func newTestUUID() -> UUID {
        let uuid = UUID()
        testUUIDs.append(uuid)
        return uuid
    }

    /// saveImage is async (encrypt + write on a background queue, completion
    /// on main). Block the test until it lands.
    private func saveImageBlocking(_ data: Data, id: UUID,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(description: "saveImage \(id.uuidString)")
        var saved: String?
        ImageStorage.shared.saveImage(data, id: id) { filename in
            saved = filename
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(saved, Self.filename(id), "image save must succeed", file: file, line: line)
    }

    // MARK: - Hash helper

    func testImageContentHash_deterministicAndDistinct() throws {
        let dataA = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        let dataB = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9, 9])
        let h1 = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: dataA))
        let h2 = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: dataA))
        let h3 = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: dataB))
        XCTAssertEqual(h1, h2, "same bytes must hash identically across calls")
        XCTAssertNotEqual(h1, h3, "different bytes must hash differently")
    }

    // MARK: - Store dedup

    /// Core CLIP-1 scenario: the same image bytes captured twice arrive as
    /// two items with different UUIDs/filenames but identical contentHash.
    /// The store must keep ONE entry (the original, moved to top) and delete
    /// the duplicate's just-written file.
    func testAddItem_sameImageHash_dedupsToSingleEntryAndDeletesDuplicateFile() throws {
        let imageData = Data((0..<512).map { UInt8($0 % 251) })
        let hash = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: imageData))

        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(imageData, id: id1)
        saveImageBlocking(imageData, id: id2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id2).path))

        store.addItem(ClipboardItem(id: id1, content: Self.filename(id1), type: .image, contentHash: hash))
        store.addItem(ClipboardItem(id: id2, content: Self.filename(id2), type: .image, contentHash: hash))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1, "same image re-copied must collapse to one entry")
        XCTAssertEqual(store.items[0].id, id1, "the original entry is kept (moved to top)")
        XCTAssertEqual(store.items[0].content, Self.filename(id1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id1).path),
                      "kept entry's file must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(id2).path),
                       "dedup hit must delete the duplicate's just-written file")
    }

    /// Dedup hit must move the existing entry to the top and — per STOR-2 —
    /// preserve its OCR fields via the with() copy helper.
    func testAddItem_dedupHit_movesExistingToTopAndPreservesOcrFields() throws {
        let hash = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: Data([7, 7, 7])))
        let ocrCiphertext = try XCTUnwrap(testCrypto.encrypt("recognized text"))
        let id1 = newTestUUID()
        let id2 = newTestUUID()

        store.addItem(ClipboardItem(id: id1, content: Self.filename(id1), type: .image,
                                    contentHash: hash, ocrText: ocrCiphertext, ocrAttempted: true))
        store.addItem(ClipboardItem(content: "some text in between", type: .text))
        store.addItem(ClipboardItem(id: id2, content: Self.filename(id2), type: .image, contentHash: hash))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items[0].id, id1, "dedup hit must move the existing entry to the top")
        XCTAssertEqual(store.items[0].ocrText, ocrCiphertext, "OCR text must survive the dedup copy")
        XCTAssertTrue(store.items[0].ocrAttempted, "ocrAttempted must survive the dedup copy")
    }

    /// Different images (different bytes → different hashes) must both be
    /// kept, each with its own file.
    func testAddItem_differentImages_bothKept() throws {
        let dataA = Data([1, 2, 3])
        let dataB = Data([4, 5, 6])
        let hashA = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: dataA))
        let hashB = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: dataB))
        let idA = newTestUUID()
        let idB = newTestUUID()
        saveImageBlocking(dataA, id: idA)
        saveImageBlocking(dataB, id: idB)

        store.addItem(ClipboardItem(id: idA, content: Self.filename(idA), type: .image, contentHash: hashA))
        store.addItem(ClipboardItem(id: idB, content: Self.filename(idB), type: .image, contentHash: hashB))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(idA).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(idB).path))
    }

    /// Legacy image items (no contentHash) must never collapse into each
    /// other — the filename fallback comparison stays distinct per UUID.
    func testAddItem_imageWithoutContentHash_neverDedups() {
        let id1 = newTestUUID()
        let id2 = newTestUUID()
        store.addItem(ClipboardItem(id: id1, content: Self.filename(id1), type: .image))
        store.addItem(ClipboardItem(id: id2, content: Self.filename(id2), type: .image))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2,
                       "image items without a contentHash must not be deduped")
    }

    // MARK: - H-3 (2026-08-08 audit): recover broken entries via re-copy

    /// When the dedup hit lands on an existing entry whose image file is
    /// already missing on disk, the duplicate's just-written file must be
    /// KEPT and the existing entry's `content` rewritten to point at it.
    /// Otherwise the user can never self-heal a missing-image entry by
    /// re-copying the picture.
    func testAddItem_dedupHit_existingImageMissing_keepsNewFileAndSwapsContent() throws {
        let imageData = Data((0..<512).map { UInt8($0 % 251) })
        let hash = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: imageData))

        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(imageData, id: id1)
        store.addItem(ClipboardItem(id: id1, content: Self.filename(id1), type: .image, contentHash: hash))
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)

        // Simulate the on-disk file going missing (user delete / disk error).
        try FileManager.default.removeItem(at: fileURL(id1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(id1).path))

        // Mark the entry as missing — exactly what runImageIntegrityScan
        // populates after the disk state changes.
        store.imageMissingIds = [id1]
        XCTAssertTrue(store.imageMissingIds.contains(id1))

        // User re-copies the same image: new file lands under id2's UUID.
        saveImageBlocking(imageData, id: id2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id2).path))

        store.addItem(ClipboardItem(id: id2, content: Self.filename(id2), type: .image, contentHash: hash))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1,
                       "dedup must still collapse to one entry")
        XCTAssertEqual(store.items[0].id, id1,
                       "the original entry is kept (moved to top, not deleted)")
        XCTAssertEqual(store.items[0].content, Self.filename(id2),
                       "existing entry's content must point to the new (good) file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id2).path),
                      "new file must survive the dedup hit — H-3 swap")
        XCTAssertFalse(store.imageMissingIds.contains(id1),
                       "id1 must be cleared from the missing set after recovery")
    }

    /// Same scenario but the existing image is *corrupt* (decryption fails)
    /// rather than missing. Old file may still be on disk, so it must be
    /// actively deleted to avoid leaving a stale corrupt blob behind.
    func testAddItem_dedupHit_existingImageCorrupted_keepsNewFileAndSwapsContent() throws {
        let imageData = Data((0..<512).map { UInt8($0 % 251) })
        let hash = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: imageData))

        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(imageData, id: id1)
        store.addItem(ClipboardItem(id: id1, content: Self.filename(id1), type: .image, contentHash: hash))
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)

        // File still on disk (corrupt on read), entry flagged via the
        // integrity-scan set.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id1).path))
        store.imageCorruptedIds = [id1]

        saveImageBlocking(imageData, id: id2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id2).path))

        store.addItem(ClipboardItem(id: id2, content: Self.filename(id2), type: .image, contentHash: hash))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1,
                       "dedup must still collapse to one entry")
        XCTAssertEqual(store.items[0].id, id1,
                       "the original entry is kept (moved to top)")
        XCTAssertEqual(store.items[0].content, Self.filename(id2),
                       "existing entry's content must point to the new (good) file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id2).path),
                      "new file must survive the dedup hit — H-3 swap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(id1).path),
                       "old corrupt file must be deleted as part of the swap")
        XCTAssertFalse(store.imageCorruptedIds.contains(id1),
                       "id1 must be cleared from the corrupted set after recovery")
    }

    /// Healthy baseline must still hold: if existing's image file is fine
    /// (not missing, not corrupted), the duplicate's just-written file is
    /// deleted and the existing entry's content is unchanged. Sanity check
    /// that the H-3 fix doesn't regress the original dedup contract.
    func testAddItem_dedupHit_existingImageHealthy_keepsOldFileAndDeletesDuplicate() throws {
        let imageData = Data((0..<512).map { UInt8($0 % 251) })
        let hash = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: imageData))

        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(imageData, id: id1)
        saveImageBlocking(imageData, id: id2)
        store.addItem(ClipboardItem(id: id1, content: Self.filename(id1), type: .image, contentHash: hash))
        store.flushPendingSaves()

        // No missing/corrupted flags — this is the original CLIP-1 path.
        XCTAssertTrue(store.imageMissingIds.isEmpty)
        XCTAssertTrue(store.imageCorruptedIds.isEmpty)

        store.addItem(ClipboardItem(id: id2, content: Self.filename(id2), type: .image, contentHash: hash))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].id, id1)
        XCTAssertEqual(store.items[0].content, Self.filename(id1),
                       "healthy baseline: existing's content pointer must NOT change")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id1).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(id2).path),
                       "healthy baseline: duplicate file must be deleted")
    }

    /// Race window: existing's image file is missing on disk but the
    /// integrity-scan sets (`imageMissingIds` / `imageCorruptedIds`) have
    /// not yet been populated — the fallback `!ImageStorage.fileExists`
    /// sub-clause is the only thing that can detect this case. Without
    /// it the freshly-saved good file would be deleted, exactly like
    /// the set-populated case.
    func testAddItem_dedupHit_fileExistsReturnsFalse_keepsNewFileAndSwapsContent() throws {
        let imageData = Data((0..<512).map { UInt8($0 % 251) })
        let hash = try XCTUnwrap(ClipboardMonitor.imageContentHash(for: imageData))

        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(imageData, id: id1)
        store.addItem(ClipboardItem(id: id1, content: Self.filename(id1), type: .image, contentHash: hash))
        store.flushPendingSaves()

        // Disk state: id1's file is gone (user delete / external corruption).
        try FileManager.default.removeItem(at: fileURL(id1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(id1).path))

        // Sets NOT populated — the only signal for the swap is the
        // direct FileManager check inside the fix.
        XCTAssertFalse(store.imageMissingIds.contains(id1),
                       "race precondition: integrity scan has not yet seen the missing file")
        XCTAssertFalse(store.imageCorruptedIds.contains(id1))

        saveImageBlocking(imageData, id: id2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id2).path))

        store.addItem(ClipboardItem(id: id2, content: Self.filename(id2), type: .image, contentHash: hash))
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1,
                       "race-window dedup must still collapse to one entry")
        XCTAssertEqual(store.items[0].id, id1,
                       "the original entry is kept (moved to top)")
        XCTAssertEqual(store.items[0].content, Self.filename(id2),
                       "existing entry's content must point to the new (good) file — proves fileExists fallback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id2).path),
                      "new file must survive the dedup hit — fileExists fallback swap")
    }
}
