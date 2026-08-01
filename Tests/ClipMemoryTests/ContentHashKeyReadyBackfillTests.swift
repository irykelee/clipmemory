import XCTest
@testable import ClipMemory

/// M2 (2026-08-01 roadmap) regression: items stored with `contentHash = nil`
/// while the encryption key was unavailable are invisible to addItem's dedup
/// pre-filter, so repeats captured in the key-not-ready window (first launch,
/// Keychain locked) pile up. Once `.cryptoKeyPrepared(success: true)` fires,
/// the store must backfill their hashes and merge the duplicates — earliest
/// capture's entry survives, refreshed to the latest capture time, mirroring
/// addItem's dedup hit (existing entry kept, moved to top).
///
/// Isolation mirrors ImageDedupTests: CryptoService(customKeyData:) injected
/// via ServiceContainer, MemoryStorageBackend for the store, Images-Tests
/// sandbox for image files, UserDefaults flags pinned + restored.
@MainActor final class ContentHashKeyReadyBackfillTests: XCTestCase {

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
        ServiceContainer.setCryptoForTesting(testCrypto)

        // ClipboardStore init → loadItems → cleanupOrphanedImages and the
        // ImageStorage singleton both touch these UserDefaults keys. Pin them
        // and restore the previous values afterwards (ImageDedupTests pattern).
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
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        testCrypto = nil
        store = nil
        backend = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func restore(_ key: String, _ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

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

    /// Posts `.cryptoKeyPrepared(success: true)` and pumps the run loop until
    /// `predicate` holds (the backfill runs on a utility queue and merges back
    /// on main — same settle pattern as DecryptionFailedLoopTests).
    private func postKeyReadyAndWait(timeout: TimeInterval = 5, until predicate: () -> Bool) {
        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": true]
        )
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// saveImage is async (encrypt + write on a background queue, completion
    /// on main). Block the test until it lands (ImageDedupTests pattern).
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

    // MARK: - M2: text duplicates captured in the key-not-ready window

    /// Two captures of the same content stored with contentHash = nil (dedup
    /// skipped at insert) must collapse into one entry once the key is ready:
    /// the earliest capture's entry survives with its createdAt refreshed to
    /// the latest capture time — the same end state addItem's dedup hit would
    /// have produced had the hash been available at capture time.
    func testKeyReadyBackfillsNilHashesAndMergesDuplicates() throws {
        let plaintext = "copied during key-not-ready window"
        let ciphertext = try XCTUnwrap(testCrypto.encrypt(plaintext))
        let older = ClipboardItem(content: ciphertext, type: .text,
                                  createdAt: Date(timeIntervalSince1970: 1000),
                                  isEncrypted: true, contentHash: nil)
        let newer = ClipboardItem(content: ciphertext, type: .text,
                                  createdAt: Date(timeIntervalSince1970: 2000),
                                  isEncrypted: true, contentHash: nil)
        // Distinct control item — must survive untouched (and get its hash).
        let control = ClipboardItem(content: try XCTUnwrap(testCrypto.encrypt("unrelated")),
                                    type: .text,
                                    createdAt: Date(timeIntervalSince1970: 1500),
                                    isEncrypted: true, contentHash: nil)
        // items is newest-first; direct assignment simulates captures that
        // landed while the key was unavailable (dedup pre-filter skipped).
        store.items = [newer, control, older]

        postKeyReadyAndWait(until: { self.store.items.count == 2 })

        XCTAssertEqual(store.items.count, 2, "the duplicate pair must collapse to one entry")
        let survivor = try XCTUnwrap(store.items.first)
        XCTAssertEqual(survivor.id, older.id,
                       "earliest capture's entry survives — addItem's dedup hit keeps the existing entry")
        XCTAssertEqual(survivor.createdAt, Date(timeIntervalSince1970: 2000),
                       "survivor is refreshed to the latest capture time and moves to the top")
        XCTAssertEqual(survivor.contentHash, testCrypto.hmacHex(for: plaintext),
                       "survivor gets the backfilled dedup fingerprint")
        XCTAssertEqual(store.items[1].id, control.id)
        XCTAssertEqual(store.items[1].contentHash, testCrypto.hmacHex(for: "unrelated"),
                       "control item gets its hash backfilled and is otherwise untouched")
    }

    /// ID-STORE-0001 compatibility: an item that still cannot be decrypted
    /// after the key-ready event keeps contentHash = nil — the backfill must
    /// never fingerprint the ciphertext fallback — and the item is kept.
    func testKeyReadyBackfillSkipsUndecryptableItems() throws {
        let bad = ClipboardItem(content: "not-valid-ciphertext", type: .text,
                                isEncrypted: true, contentHash: nil)
        let good = ClipboardItem(content: try XCTUnwrap(testCrypto.encrypt("real content")),
                                 type: .text, isEncrypted: true, contentHash: nil)
        store.items = [bad, good]

        postKeyReadyAndWait(until: {
            self.store.items.first(where: { $0.id == good.id })?.contentHash != nil
        })

        XCTAssertEqual(store.items.count, 2, "undecryptable item is kept, not dropped")
        XCTAssertNil(store.items.first(where: { $0.id == bad.id })?.contentHash,
                     "ID-STORE-0001: decrypt failure must leave contentHash nil — never fingerprint ciphertext")
    }

    // MARK: - M2: image duplicates captured in the key-not-ready window

    /// Two image captures of the same bytes with contentHash = nil must
    /// collapse to one entry once the key is ready; the dropped duplicate's
    /// file is deleted, mirroring addItem's dedup hit (CLIP-1). The image
    /// fingerprint is recovered from the stored file bytes.
    func testKeyReadyMergesImageDuplicatesAndDeletesDuplicateFile() throws {
        let imageData = Data((0..<256).map { UInt8($0 % 251) })
        let id1 = newTestUUID() // older capture
        let id2 = newTestUUID() // newer capture of the same bytes
        saveImageBlocking(imageData, id: id1)
        saveImageBlocking(imageData, id: id2)

        let older = ClipboardItem(id: id1, content: Self.filename(id1), type: .image,
                                  createdAt: Date(timeIntervalSince1970: 1000),
                                  contentHash: nil)
        let newer = ClipboardItem(id: id2, content: Self.filename(id2), type: .image,
                                  createdAt: Date(timeIntervalSince1970: 2000),
                                  contentHash: nil)
        store.items = [newer, older]

        postKeyReadyAndWait(until: { self.store.items.count == 1 })

        XCTAssertEqual(store.items.count, 1, "image duplicates must collapse to one entry")
        let survivor = try XCTUnwrap(store.items.first)
        XCTAssertEqual(survivor.id, id1, "earliest capture's entry survives")
        XCTAssertEqual(survivor.createdAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(survivor.contentHash, ClipboardMonitor.imageContentHash(for: imageData),
                       "survivor gets the CLIP-1 image fingerprint backfilled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id1).path),
                      "kept entry's file must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(id2).path),
                       "the dropped duplicate's file must be deleted (addItem dedup-hit parity)")
        // The merge already deleted id2's file — skip it in tearDown cleanup
        // to avoid a misleading "orphan left on disk" error log.
        testUUIDs.removeAll { $0 == id2 }
    }
}
