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
final class ImageDedupTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?
    private var testCrypto: CryptoService!
    private var testUUIDs: [UUID] = []

    private let migrationKey = "ImageStorageMigrationComplete"
    private let startupCleanupKey = "ImageStorageStartupCleanupRan"
    private var savedMigrationValue: Any?
    private var savedStartupCleanupValue: Any?

    override func setUp() {
        super.setUp()
        testCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.crypto = testCrypto

        // ClipboardStore init → loadItems → cleanupOrphanedImages and the
        // ImageStorage singleton both touch these UserDefaults keys. Pin
        // them to a deterministic value for the test and restore the
        // previous values afterwards.
        savedMigrationValue = UserDefaults.standard.object(forKey: migrationKey)
        savedStartupCleanupValue = UserDefaults.standard.object(forKey: startupCleanupKey)
        UserDefaults.standard.set(true, forKey: migrationKey)
        UserDefaults.standard.set(true, forKey: startupCleanupKey)

        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
    }

    override func tearDown() {
        for uuid in testUUIDs {
            ImageStorage.shared.deleteImage(filename: Self.filename(uuid))
        }
        testUUIDs.removeAll()
        restore(migrationKey, savedMigrationValue)
        restore(startupCleanupKey, savedStartupCleanupValue)
        savedMigrationValue = nil
        savedStartupCleanupValue = nil
        if let originalCrypto { ServiceContainer.crypto = originalCrypto }
        originalCrypto = nil
        testCrypto = nil
        store = nil
        backend = nil
        super.tearDown()
    }

    private func restore(_ key: String, _ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
}
