import XCTest
import AppKit
@testable import ClipMemory

/// ID-VIEW-0030/0031/0032 (2026-08-13, user-driven): tests for ShareService,
/// which bridges clipboard image items to NSSharingServicePicker and
/// NSItemProvider for drag.
///
/// Coverage:
/// - `makeShareableFileURL(for:)` writes decrypted PNG bytes to a temp
///   file named after the item's UUID
/// - `makeShareableFileURLs(for:)` skips items whose bytes fail to load
/// - `makeDragProviders(for:)` wraps each temp file in an NSItemProvider
///
/// Test isolation:
/// - Per-test cleanup: track temp file URLs and remove in tearDown.
/// - ImageStorage test fixtures live in Images-Tests (XCTest redirect),
///   never touching production data.
final class ShareServiceTests: XCTestCase {

    private var storage: ImageStorage!
    private var testUUIDs: [UUID] = []
    private var tempURLs: [URL] = []
    private let migrationKey = "ImageStorageMigrationComplete"
    private let startupCleanupKey = "ImageStorageStartupCleanupRan"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = makeTestDefaults()
        testDefaults.set(true, forKey: migrationKey)
        testDefaults.set(true, forKey: startupCleanupKey)
        storage = ImageStorage.shared
    }

    override func tearDown() {
        for uuid in testUUIDs {
            storage.deleteImage(filename: "\(uuid.uuidString).png")
        }
        testUUIDs.removeAll()
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    private func newTestUUID() -> UUID {
        let uuid = UUID()
        testUUIDs.append(uuid)
        return uuid
    }

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

    /// saveImage is async; tests wait for the main-thread completion.
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

    private func trackTempURL(_ url: URL) {
        tempURLs.append(url)
    }

    // MARK: - makeShareableFileURL

    func testMakeShareableFileURLWritesDecryptedBytes() throws {
        let uuid = newTestUUID()
        let original = makePNGData()
        XCTAssertFalse(original.isEmpty, "fixture must produce PNG bytes")
        let filename = try XCTUnwrap(saveAndWait(original, uuid: uuid))

        let item = ClipboardItem(
            content: filename,
            type: .image,
            isPinned: false
        )

        let url = try ShareService.makeShareableFileURL(for: item)
        trackTempURL(url)

        // ID-VIEW-0030: filename = "<uuid>.png" so collision math is
        // deterministic and the user-visible filename is stable.
        XCTAssertEqual(url.lastPathComponent, "\(uuid.uuidString).png")

        // File must exist and contain the original PNG bytes
        // (decrypted + written, NOT re-encoded).
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, original, "temp file must hold decrypted original bytes")
        XCTAssertTrue(written.starts(with: Data([0x89, 0x50, 0x4E, 0x47])),
                      "written bytes must be a valid PNG")
    }

    func testMakeShareableFileURLThrowsForMissingImage() {
        let item = ClipboardItem(
            content: "00000000-0000-0000-0000-000000000000.png",
            type: .image,
            isPinned: false
        )

        XCTAssertThrowsError(try ShareService.makeShareableFileURL(for: item)) { error in
            guard let shareError = error as? ShareService.ShareError else {
                XCTFail("expected ShareError, got \(error)")
                return
            }
            if case .imageLoadFailed = shareError {
                // expected
            } else {
                XCTFail("expected .imageLoadFailed, got \(shareError)")
            }
        }
    }

    // MARK: - makeShareableFileURLs (batch)

    func testMakeShareableFileURLsSkipsUnloadableItems() throws {
        let uuid1 = newTestUUID()
        let uuid2 = newTestUUID()
        let png1 = makePNGData()
        let png2 = makePNGData()
        let filename1 = try XCTUnwrap(saveAndWait(png1, uuid: uuid1))
        let filename2 = try XCTUnwrap(saveAndWait(png2, uuid: uuid2))

        let good1 = ClipboardItem(content: filename1, type: .image, isPinned: false)
        let bad = ClipboardItem(
            content: "deadbeef-dead-beef-dead-beefdeadbeef.png",
            type: .image,
            isPinned: false
        )
        let good2 = ClipboardItem(content: filename2, type: .image, isPinned: false)

        let urls = ShareService.makeShareableFileURLs(for: [good1, bad, good2])
        for url in urls { trackTempURL(url) }

        XCTAssertEqual(urls.count, 2, "unloadable item must be skipped silently")
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "\(uuid1.uuidString).png" })
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "\(uuid2.uuidString).png" })
    }

    // MARK: - makeDragProviders

    func testMakeDragProvidersBuildsOneProviderPerItem() throws {
        let uuid = newTestUUID()
        let png = makePNGData()
        let filename = try XCTUnwrap(saveAndWait(png, uuid: uuid))
        let item = ClipboardItem(content: filename, type: .image, isPinned: false)

        // ID-VIEW-0031: 1 image item → 1 NSItemProvider. The provider
        // vends the temp file URL when Finder asks for the file contents.
        // We don't drill into NSItemProvider's async load APIs here —
        // `makeShareableFileURL` already verifies the temp file's bytes
        // round-trip correctly; this test only checks the count contract.
        let providers = ShareService.makeDragProviders(for: [item])
        for provider in providers {
            // Each provider must declare public.file-url as a known type
            // — that's what makes it droppable into Finder.
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"),
                          "drag provider must advertise public.file-url")
        }
        XCTAssertEqual(providers.count, 1, "one item should produce one NSItemProvider")
    }

    func testMakeDragProvidersSkipsUnloadableItems() throws {
        let uuid = newTestUUID()
        let png = makePNGData()
        let filename = try XCTUnwrap(saveAndWait(png, uuid: uuid))
        let good = ClipboardItem(content: filename, type: .image, isPinned: false)
        let bad = ClipboardItem(
            content: "deadbeef-dead-beef-dead-beefdeadbeef.png",
            type: .image,
            isPinned: false
        )

        let providers = ShareService.makeDragProviders(for: [good, bad])
        XCTAssertEqual(providers.count, 1, "unloadable item must be skipped, matching makeShareableFileURLs")
    }
}