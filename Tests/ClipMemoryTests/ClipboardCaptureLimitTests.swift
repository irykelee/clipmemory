import XCTest
@testable import ClipMemory

/// CLIP-2 (2026-07-24) regression tests:
/// 1. ClipboardMonitor text capture has a hard size cap (10 MB UTF-8) —
///    over-limit pastes are truncated instead of flowing whole into memory,
///    encryption, and the persistence pipeline.
/// 2. ClipboardStore persistence encodes the item array off the calling
///    thread and hands only the encoded Data to the backend (`saveBlob`),
///    while keeping saveImmediately()'s write-through contract synchronous.
final class ClipboardCaptureLimitTests: XCTestCase {

    private var originalCrypto: CryptoServiceProtocol?

    override func setUp() {
        super.setUp()
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.crypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.crypto = originalCrypto }
        originalCrypto = nil
        super.tearDown()
    }

    // MARK: - Capture size cap

    func testTruncateToCaptureLimitUnderLimitPassesThrough() {
        let content = String(repeating: "abc ", count: 1000)
        let (text, wasTruncated) = ClipboardMonitor.truncateToCaptureLimit(content)
        XCTAssertEqual(text, content)
        XCTAssertFalse(wasTruncated)
    }

    func testTruncateToCaptureLimitOverLimitTruncates() {
        // 10 MB + extra — pure ASCII so 1 char == 1 UTF-8 byte.
        let content = String(repeating: "x", count: ClipboardMonitor.maxTextCaptureBytes + 4096)
        let (text, wasTruncated) = ClipboardMonitor.truncateToCaptureLimit(content)
        XCTAssertTrue(wasTruncated)
        XCTAssertLessThanOrEqual(text.utf8.count, ClipboardMonitor.maxTextCaptureBytes)
        XCTAssertTrue(text.hasPrefix(String(repeating: "x", count: 1000)),
                      "Truncated text must preserve the leading content")
    }

    func testTruncateToCaptureLimitMultiByteBoundaryIsScalarSafe() {
        // "é" is 2 UTF-8 bytes; repeat past the cap so the cut can land
        // mid-scalar. String(decoding:as:) must repair, never trap, and the
        // result must stay within a small tolerance of the cap (a clipped
        // trailing scalar is replaced by U+FFFD, up to 3 bytes).
        let content = String(repeating: "é", count: ClipboardMonitor.maxTextCaptureBytes / 2 + 100)
        XCTAssertGreaterThan(content.utf8.count, ClipboardMonitor.maxTextCaptureBytes,
                             "Test fixture: content must exceed the cap")
        let (text, wasTruncated) = ClipboardMonitor.truncateToCaptureLimit(content)
        XCTAssertTrue(wasTruncated)
        XCTAssertLessThanOrEqual(text.utf8.count, ClipboardMonitor.maxTextCaptureBytes + 3)
        XCTAssertTrue(text.hasPrefix("é"))
    }

    func testTruncateToCaptureLimitExactlyAtLimitPassesThrough() {
        let content = String(repeating: "y", count: ClipboardMonitor.maxTextCaptureBytes)
        let (text, wasTruncated) = ClipboardMonitor.truncateToCaptureLimit(content)
        XCTAssertEqual(text, content)
        XCTAssertFalse(wasTruncated,
                       "Content exactly at the cap is within the limit — no truncation")
    }

    // MARK: - Persistence: saveBlob write-through

    /// Records saveBlob calls so tests can verify the persistence funnel
    /// hands pre-encoded Data to the backend (CLIP-2) instead of asking the
    /// backend to encode on the calling thread.
    private final class BlobRecordingBackend: StorageBackend {
        private let inner = MemoryStorageBackend()
        private(set) var savedBlobs: [Data] = []

        func load() throws -> [ClipboardItem] { try inner.load() }
        func save(_ items: [ClipboardItem]) throws { try inner.save(items) }
        func loadTags() throws -> [Tag] { try inner.loadTags() }
        func saveTags(_ tags: [Tag]) throws { try inner.saveTags(tags) }
        func saveBlob(_ data: Data) throws {
            savedBlobs.append(data)
            try inner.saveBlob(data) // default impl: decode + save
        }
    }

    func testAddItemPersistsViaSaveBlobWithValidEncodedData() throws {
        let backend = BlobRecordingBackend()
        let store = ClipboardStore(backend: backend)
        store.addItem(ClipboardItem(content: "clip2 blob test", type: .text))

        XCTAssertEqual(backend.savedBlobs.count, 1,
                       "addItem's write-through must persist exactly once via saveBlob")
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: backend.savedBlobs[0])
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, store.items[0].id,
                       "The encoded blob must round-trip to the same item the store holds")
        XCTAssertEqual(try backend.load().count, 1,
                       "Write-through contract: backend must hold the item the moment addItem returns")
    }

    func testMemoryBackendDefaultSaveBlobRoundTrips() throws {
        // The protocol-extension default (decode + save) keeps item-array
        // semantics for in-memory backends — this is what the test suite's
        // MemoryStorageBackend relies on.
        let backend = MemoryStorageBackend()
        let store = ClipboardStore(backend: backend)
        store.addItem(ClipboardItem(content: "clip2 memory round trip", type: .text))

        let persisted = try backend.load()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].id, store.items[0].id)
    }

    func testFileBackendSaveBlobPersistsToUserDefaults() throws {
        // Unique key so the test never touches the production "ClipboardItems"
        // blob in the shared UserDefaults domain.
        let key = "CLIP2Test.ClipboardItems.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let backend = FileStorageBackend(storageKey: key)
        let store = ClipboardStore(backend: backend)
        store.addItem(ClipboardItem(content: "clip2 file round trip", type: .text))

        guard let data = UserDefaults.standard.data(forKey: key) else {
            XCTFail("saveBlob must write the encoded blob to UserDefaults synchronously")
            return
        }
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, store.items[0].id)
        XCTAssertEqual(try backend.load().count, 1,
                       "load() must read back what saveBlob wrote")
    }
}
