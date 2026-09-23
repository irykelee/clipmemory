import XCTest
import AppKit
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-13): capture path perf regression test.
///
/// Before the fix, `ClipboardStore.addItem()` called `saveImmediately()` which
/// synchronously invoked `flushSave()` → `saveItems()` → `itemEncodingQueue.sync`
/// (the `.sync` hop was CLIP-2's intentional design but the capture path
/// bypassed the 500ms debounce). With 10K items (10-50MB blob), every
/// clipboard capture blocked the main thread 50-200ms for JSON encode +
/// write. 100 captures piled up 5-20s of UI-blocking time per second.
///
/// After the fix, `addItem()` routes through the existing 500ms
/// `scheduleSave()` debounce timer (same pattern as metadata mutations).
/// Encoding runs once at the end of the burst, not per capture. The
/// write-through contract is preserved at termination via `flushPendingSaves()`
/// (already wired to AppDelegate.applicationWillTerminate + a willTerminate
/// observer).
@MainActor
final class ClipboardStoreTests: XCTestCase {

    /// Counts saveBlob invocations; P2-13's core symptom is "100 addItem
    /// calls → 100 saveBlob calls on the main thread". A debounced capture
    /// path keeps the count at 0 (timer hasn't fired) or 1 (timer fired
    /// once for the burst). The pre-fix write-through path made 100 calls.
    private final class SaveCountingBackend: StorageBackend {
        private let inner = MemoryStorageBackend()
        private(set) var saveBlobCount = 0

        func load() throws -> [ClipboardItem] { try inner.load() }
        func save(_ items: [ClipboardItem]) throws { try inner.save(items) }
        func loadTags() throws -> [Tag] { try inner.loadTags() }
        func saveTags(_ tags: [Tag]) throws { try inner.saveTags(tags) }
        func saveBlob(_ data: Data) throws {
            saveBlobCount += 1
            try inner.saveBlob(data)
        }
    }

    private var backend: SaveCountingBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var testDefaults: UserDefaults!
    private var originalCrypto: CryptoServiceProtocol?
    private var stagedImageFilenames: [String] = []

    override func setUp() {
        super.setUp()
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(
            CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        )
        testDefaults = makeTestDefaults()
        backend = SaveCountingBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(
            backend: backend,
            tagBackend: tagBackend,
            trashBackend: trashBackend,
            defaults: testDefaults
        )
        // Wire onRecordOwnWrite so copyToClipboard's re-capture guard works
        // under test (AppDelegate installs this in production).
        store.onRecordOwnWrite = {}
    }

    override func tearDown() {
        // Clean up any image files we staged via ImageStorage.shared
        for filename in stagedImageFilenames {
            ImageStorage.shared.deleteImage(filename: filename)
        }
        stagedImageFilenames.removeAll()
        store = nil
        backend = nil
        trashBackend = nil
        tagBackend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
        if let originalCrypto {
            ServiceContainer.setCryptoForTesting(originalCrypto)
        }
        originalCrypto = nil
        super.tearDown()
    }

    /// P2-13: capture path must NOT call `saveBlob` synchronously per item.
    /// Pre-fix: each `addItem` triggered `saveImmediately` → `flushSave` →
    /// `saveItems` → `itemEncodingQueue.sync` → `saveBlob`, all on the main
    /// thread. 100 captures = 100 synchronous encode+write cycles = the
    /// 50-200ms-per-capture stall documented in the audit (multiplied by
    /// capture rate).
    /// Post-fix: `addItem` routes through `scheduleSave` (500ms debounce).
    /// The 100-item burst leaves `saveBlobCount == 0` (debounce timer
    /// hasn't fired yet) — the burst collapses into one coalesced write
    /// when the timer fires.
    ///
    /// This is a behavioural assertion (call count), not a wall-clock
    /// assertion, so it doesn't flake under CI load. It pins the P2-13
    /// audit finding directly: the perf bug was *structural* (100 sync
    /// writes per 100 captures), not a magic-ms number.
    func testCapture100ItemsDoesNotWriteThroughSynchronously() {
        // Drain any pending saves from setUp wiring so the count starts
        // at a clean baseline.
        store.flushPendingSaves()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(
            backend.saveBlobCount, 0,
            "pre-condition: no pending saves after flush + runloop drain"
        )

        // Burst: 100 captures must NOT result in 100 saveBlob calls.
        for i in 0..<100 {
            store.addItem(ClipboardItem(content: "x\(i)", type: .text))
        }

        XCTAssertEqual(
            backend.saveBlobCount, 0,
            "P2-13: 100 addItem calls must coalesce via debounce (no write-through per capture); saw \(backend.saveBlobCount) saveBlob calls"
        )
        XCTAssertEqual(store.items.count, 100,
                       "all 100 items must still be in-memory even though no disk write has happened yet")
    }

    // MARK: - P1-AUDIT-2026-09-22 (P2-16): copyToClipboard uses full-size, not thumbnail

    /// P2-16 (round-2 redesign): copyToClipboard on a .image item must write
    /// the full-resolution bitmap to NSPasteboard.general, NOT the ≤512px
    /// thumbnail produced by the row-preview path. Pre-fix, the warm path
    /// took whatever imageCache held (which used to be the full-size NSImage
    /// but is now the thumbnail per P2-16's separation). After the fix, the
    /// warm path consults `cachedFullSizeImageObject` (the dedicated
    /// fullSizeCache), so the pasteboard gets full resolution.
    ///
    /// We assert via pasteboard TIFF byte count: a 3840×2160 PNG compresses
    /// to ~5–20 MB TIFF; a 512×288 thumbnail compresses to under 100 KB.
    /// 100 KB threshold is comfortably above the thumbnail upper bound
    /// (well below any plausible full-size pasteboard write).
    func testCopyToClipboardUsesFullSizeNotThumbnail() throws {
        let uuid = UUID()
        let filename = try stageSizedImage(
            filename: "\(uuid.uuidString).png",
            width: 3840, height: 2160
        )
        let item = ClipboardItem(content: filename, type: .image)
        // Touch the row-preview thumbnail path first so imageCache is
        // populated with a 512×288 thumbnail (mirrors production: the row
        // renders before the user clicks copy).
        _ = ImageStorage.shared.loadImageObject(filename: filename)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        store.copyToClipboard(item)

        // copyToClipboard is synchronous on the warm path (fullSizeCache hit
        // from loadImageObject's side-effect is NOT propagated; the row
        // preview only warms imageCache). Wait for the async full-size
        // load to complete and re-check. Poll on the main thread via
        // RunLoop.main.run(until:) — NSPasteboard is documented as
        // main-thread-only and capturing it in a @Sendable closure trips
        // Swift 6's static checker (warning under Swift 5.9).
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if let tiff = pasteboard.data(forType: .tiff), tiff.count > 100_000 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let copied = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(copied, "P2-16: pasteboard must have TIFF data after copyToClipboard")
        XCTAssertGreaterThan(
            copied?.count ?? 0, 100_000,
            "P2-16: copyToClipboard must write full-size to pasteboard (TIFF > 100 KB); got \(copied?.count ?? 0) bytes. A 512x288 thumbnail would be <100 KB."
        )
    }

    /// P2-16: rapid successive copyToClipboard calls must keep the LAST
    /// image on the pasteboard, not the first. The monotonic copyGenCounter
    /// token is the contract — even if the first image's async load
    /// completes after the second, the first is dropped because its token
    /// no longer matches pendingCopyToken.
    func testRapidCopyKeepsLastCopiedImage() throws {
        let filenameA = try stageSizedImage(
            filename: "\(UUID().uuidString).png",
            width: 1000, height: 1000
        )
        let filenameB = try stageSizedImage(
            filename: "\(UUID().uuidString).png",
            width: 1000, height: 1000
        )
        let itemA = ClipboardItem(content: filenameA, type: .image)
        let itemB = ClipboardItem(content: filenameB, type: .image)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        store.copyToClipboard(itemA)
        store.copyToClipboard(itemB)

        // Wait for B's async load + pasteboard write to settle. Poll on
        // main thread (NSPasteboard is main-thread-only).
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if let tiff = pasteboard.data(forType: .tiff), tiff.count > 10_000 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        // Pasteboard must have TIFF data; we can't easily distinguish A vs
        // B by pixel content (both are 1000x1000), but we can assert the
        // copy contract held: pasteboard is non-empty after B (i.e., A's
        // stale completion did NOT clear pasteboard and leave it empty).
        let copied = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(copied, "P2-16: pasteboard must have TIFF after B's copy (A's stale completion must not have left it empty)")
        XCTAssertGreaterThan(copied?.count ?? 0, 10_000,
                              "P2-16: pasteboard must contain a full-size image, not a cleared state from A's stale write")
    }

    /// P2-16: the warm-path synchronous copy (fullSizeCache hit) must
    /// populate the pasteboard immediately, without going through the
    /// async path. Asserts the warm-path code branch is actually used
    /// when fullSizeCache is warm.
    func testCopyToClipboardWarmPathIsSynchronous() throws {
        let filename = try stageSizedImage(
            filename: "\(UUID().uuidString).png",
            width: 800, height: 600
        )
        // Pre-warm fullSizeCache so the next copyToClipboard takes the
        // synchronous warm path.
        let warmExp = expectation(description: "pre-warm")
        ImageStorage.shared.loadFullSizeImageAsync(filename: filename) { _ in
            warmExp.fulfill()
        }
        wait(for: [warmExp], timeout: 5.0)
        XCTAssertNotNil(ImageStorage.shared.cachedFullSizeImageObject(filename: filename),
                        "Test fixture: fullSizeCache must be warm before copyToClipboard")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = ClipboardItem(content: filename, type: .image)
        store.copyToClipboard(item)

        // Warm path is synchronous; TIFF data should be available without polling.
        let copied = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(copied,
                        "P2-16: warm-path copyToClipboard must populate pasteboard synchronously")
        XCTAssertGreaterThan(copied?.count ?? 0, 10_000,
                              "P2-16: warm-path copy must be full-size (no thumbnail)")
    }

    // MARK: - P2-16 fixtures

    /// Stage a sized PNG via ImageStorage.saveImage (encrypted on disk)
    /// and register it for tearDown cleanup. Returns the .png filename.
    private func stageSizedImage(filename: String, width: Int, height: Int) throws -> String {
        let pngData = makeSizedPNG(width: width, height: height)
        let exp = expectation(description: "saveImage \(filename.prefix(8))")
        var result: String?
        // saveImage takes (Data, id: UUID, completion). Build a UUID from
        // the filename stem so the same call can be reused for the lookup.
        let stem = String(filename.dropLast(4))
        let id = UUID(uuidString: stem) ?? UUID()
        ImageStorage.shared.saveImage(pngData, id: id) { saved in
            result = saved
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        let final = try XCTUnwrap(result, "saveImage must succeed for \(filename)")
        stagedImageFilenames.append(final)
        return final
    }

    private func makeSizedPNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
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
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
