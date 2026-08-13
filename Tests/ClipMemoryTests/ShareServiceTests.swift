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
        // ID-VIEW-0038: remove temp folders created by makeTestFolder
        // for the saveToFolder conflict-path tests.
        for url in testFolderURLs {
            try? FileManager.default.removeItem(at: url)
        }
        testFolderURLs.removeAll()
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

    // MARK: - saveToFolder / conflict resolution (ID-VIEW-0038)

    private var testFolderURLs: [URL] = []

    private func makeTestFolder(named name: String = "export-target") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        testFolderURLs.append(url)
        return url
    }

    /// ID-VIEW-0038: pure-function part of the keep-both naming.
    /// "foo.png" already exists → "foo (1).png"; both exist → "foo (2).png".
    func testUniqueDestinationAppendsNumberSuffix() {
        let folder = makeTestFolder()

        // Pre-create foo.png and foo (1).png so the next free name
        // has to skip both.
        try? Data().write(to: folder.appendingPathComponent("foo.png"))
        try? Data().write(to: folder.appendingPathComponent("foo (1).png"))

        let candidate = ShareService.uniqueDestination(in: folder, baseName: "foo.png")
        XCTAssertEqual(
            candidate.lastPathComponent,
            "foo (2).png",
            "must skip existing foo.png and foo (1).png, return next free name"
        )
    }

    func testUniqueDestinationPreservesExtension() {
        let folder = makeTestFolder()
        try? Data().write(to: folder.appendingPathComponent("image.png"))
        try? Data().write(to: folder.appendingPathComponent("image (1).png"))

        let candidate = ShareService.uniqueDestination(in: folder, baseName: "image.png")
        XCTAssertEqual(candidate.lastPathComponent, "image (2).png")
    }

    /// Happy path — no conflicts, all sources copied to destination
    /// folder under their original basenames. conflictChoice should
    /// never be invoked (no existing files → no prompt needed).
    @MainActor
    func testCopyImagesToFolderNoConflict() throws {
        let uuid1 = newTestUUID()
        let uuid2 = newTestUUID()
        let png1 = makePNGData()
        let png2 = makePNGData()
        let filename1 = try XCTUnwrap(saveAndWait(png1, uuid: uuid1))
        let filename2 = try XCTUnwrap(saveAndWait(png2, uuid: uuid2))
        // Use `makeShareableFileURL` (not `FileManager.temporaryDirectory +
        // filename`) — the temp file lives at the URL the service writes
        // to. Constructing the URL by hand would point at a nonexistent
        // file because ImageStorage and the temp dir use different roots.
        let item1 = ClipboardItem(content: filename1, type: .image, isPinned: false)
        let item2 = ClipboardItem(content: filename2, type: .image, isPinned: false)
        let source1 = try ShareService.makeShareableFileURL(for: item1)
        let source2 = try ShareService.makeShareableFileURL(for: item2)
        trackTempURL(source1)
        trackTempURL(source2)
        let sources = [source1, source2]
        let folder = makeTestFolder()

        var promptedFor: [String] = []
        let result = ShareService.copyImagesToFolder(
            sources: sources,
            to: folder,
            conflictChoice: { filename in
                promptedFor.append(filename)
                return .cancel
            }
        )

        XCTAssertEqual(result.copied.count, 2)
        XCTAssertEqual(result.keptBoth.count, 0)
        XCTAssertNil(result.cancelledAt)
        XCTAssertTrue(promptedFor.isEmpty, "conflict prompt must NOT fire when destination doesn't exist")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(filename1)), png1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(filename2)), png2)
    }

    /// User picks Replace → old file is deleted, new file written
    /// under the original basename. The other (non-conflicting)
    /// file still uses its original name.
    @MainActor
    func testCopyImagesToFolderReplaceOnConflict() throws {
        let uuidNew = newTestUUID()
        let pngNew = makePNGData()
        let filename = try XCTUnwrap(saveAndWait(pngNew, uuid: uuidNew))
        let item = ClipboardItem(content: filename, type: .image, isPinned: false)
        let source = try ShareService.makeShareableFileURL(for: item)
        trackTempURL(source)

        let folder = makeTestFolder()

        // Pre-create an older "filename" with stale contents.
        let dest = folder.appendingPathComponent(filename)
        let stale = Data(repeating: 0xAA, count: 64)
        try stale.write(to: dest)

        // Add a second non-conflicting source so we verify Replace
        // doesn't affect unrelated files.
        let uuidOther = newTestUUID()
        let pngOther = makePNGData()
        let filenameOther = try XCTUnwrap(saveAndWait(pngOther, uuid: uuidOther))
        let itemOther = ClipboardItem(content: filenameOther, type: .image, isPinned: false)
        let sourceOther = try ShareService.makeShareableFileURL(for: itemOther)
        trackTempURL(sourceOther)

        let result = ShareService.copyImagesToFolder(
            sources: [source, sourceOther],
            to: folder,
            conflictChoice: { _ in .replace }
        )

        XCTAssertEqual(result.copied.count, 2)
        XCTAssertEqual(result.keptBoth.count, 0)
        XCTAssertNil(result.cancelledAt)
        XCTAssertEqual(try Data(contentsOf: dest), pngNew, "stale file must be replaced with new bytes")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(filenameOther)), pngOther)
    }

    /// User picks Keep Both → new file is written under
    /// "filename (1).png" (per uniqueDestination); original
    /// destination file is untouched.
    @MainActor
    func testCopyImagesToFolderKeepBothOnConflict() throws {
        let uuidNew = newTestUUID()
        let pngNew = makePNGData()
        let filename = try XCTUnwrap(saveAndWait(pngNew, uuid: uuidNew))
        let item = ClipboardItem(content: filename, type: .image, isPinned: false)
        let source = try ShareService.makeShareableFileURL(for: item)
        trackTempURL(source)

        let folder = makeTestFolder()
        let dest = folder.appendingPathComponent(filename)
        let stale = Data(repeating: 0xBB, count: 64)
        try stale.write(to: dest)

        let result = ShareService.copyImagesToFolder(
            sources: [source],
            to: folder,
            conflictChoice: { _ in .keepBoth }
        )

        XCTAssertEqual(result.copied.count, 0)
        XCTAssertEqual(result.keptBoth.count, 1)
        // uniqueDestination splits filename into stem + ext, then
        // appends " (1)" before re-adding ext. So "<uuid>.png" →
        // "<uuid> (1).png" (the stem drops the .png extension).
        let stem = (filename as NSString).deletingPathExtension
        XCTAssertEqual(
            result.keptBoth.first?.lastPathComponent,
            "\(stem) (1).png",
            "keep-both must use uniqueDestination's stem + ' (1).png' pattern"
        )
        XCTAssertEqual(try Data(contentsOf: result.keptBoth.first!), pngNew)
        // Original must remain untouched.
        XCTAssertEqual(try Data(contentsOf: dest), stale, "keep-both must NOT overwrite the existing file")
    }

    /// User picks Cancel on the conflicting file → loop stops
    /// immediately. Files copied before the cancelled index are
    /// written; the cancelled file and everything after are NOT
    /// written. `cancelledAt` reports the index of the cancelled
    /// source so tests / future code can resume from there.
    @MainActor
    func testCopyImagesToFolderCancelStopsLoop() throws {
        let folder = makeTestFolder()

        // Build 3 sources: a.png (no conflict), b.png (CONFLICT → cancel),
        // c.png (would be written if loop continued).
        let uuidA = newTestUUID()
        let uuidB = newTestUUID()
        let uuidC = newTestUUID()
        let pngA = makePNGData()
        let pngB = makePNGData()
        let pngC = makePNGData()
        let nameA = try XCTUnwrap(saveAndWait(pngA, uuid: uuidA))
        let nameB = try XCTUnwrap(saveAndWait(pngB, uuid: uuidB))
        let nameC = try XCTUnwrap(saveAndWait(pngC, uuid: uuidC))
        let itemA = ClipboardItem(content: nameA, type: .image, isPinned: false)
        let itemB = ClipboardItem(content: nameB, type: .image, isPinned: false)
        let itemC = ClipboardItem(content: nameC, type: .image, isPinned: false)
        let sources = try [
            ShareService.makeShareableFileURL(for: itemA),
            ShareService.makeShareableFileURL(for: itemB),
            ShareService.makeShareableFileURL(for: itemC)
        ]
        for s in sources { trackTempURL(s) }

        // Pre-create b.png in destination so the loop will prompt.
        let stale = Data(repeating: 0xCC, count: 64)
        try stale.write(to: folder.appendingPathComponent(nameB))

        let result = ShareService.copyImagesToFolder(
            sources: sources,
            to: folder,
            conflictChoice: { filename in
                XCTAssertEqual(filename, nameB, "only the conflicting file should prompt")
                return .cancel
            }
        )

        XCTAssertEqual(result.copied.count, 1, "only the first (non-conflicting) file is written")
        XCTAssertEqual(result.keptBoth.count, 0)
        XCTAssertEqual(result.cancelledAt, 1, "cancel happened at index 1 (b.png)")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(nameA)), pngA)
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent(nameB)),
            stale,
            "b.png must remain untouched on cancel"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(nameC).path),
            "c.png must NOT be written after cancel"
        )
    }
}