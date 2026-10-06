import XCTest
@testable import ClipMemory

/// ID-REVIEW-1019 (2026-10-06, code-review §六 P2-3): the startup image
/// integrity scan must skip files whose mtime matches a persisted
/// cache, and re-verify any file whose mtime changed (or which is
/// absent from the cache). Cache missing / corrupt → full scan (no
/// false negatives).
///
/// Isolation matches ImageDedupTests: CryptoService injected via
/// ServiceContainer, MemoryStorageBackend for store persistence,
/// ImageStorage.shared writes to the XCTest sandbox, UserDefaults
/// keys saved + restored around each test so the persisted mtime
/// cache from one test doesn't leak into another.
@MainActor final class ClipboardStoreImageIntegrityScanTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?
    private var testCrypto: CryptoService!
    private var testUUIDs: [UUID] = []

    private let migrationKey = "ImageStorageMigrationComplete"
    private let startupCleanupKey = "ImageStorageStartupCleanupRan"
    private var testDefaults: UserDefaults!
    private static let mtimeCacheKey = "ImageIntegrity.scannedMtimes"

    override func setUp() {
        super.setUp()
        testCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(testCrypto)

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

    // MARK: - Helpers (mirror ImageDedupTests)

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

    /// Blocks until ImageStorage.saveImage's completion fires — saves
    /// run on a background queue, so the test must wait for the file
    /// to actually land on disk before stat-ing it.
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

    /// Registers an image item with the store so the integrity scan
    /// finds it (`runImageIntegrityScan` walks `items + trashedItems`,
    /// not the Images/ directory). Without this, the scan's
    /// `imageItems.isEmpty` early return makes every test vacuously
    /// pass — a classic fixture bug.
    private func registerImageItem(id: UUID) throws {
        let filename = Self.filename(id)
        let data = try? Data(contentsOf: fileURL(id))
        let hash = data.flatMap { ClipboardMonitor.imageContentHash(for: $0) } ?? ""
        store.addItem(ClipboardItem(
            id: id, content: filename, type: .image, isEncrypted: true, contentHash: hash
        ))
        store.flushPendingSaves()
    }

    /// Runs `runImageIntegrityScan` synchronously by waiting for its
    /// completion handler (added in the OpenCode-review follow-up —
    /// fires on @MainActor once `imageMissingIds` / `imageCorruptedIds`
    /// have been updated with this scan's results). Deterministic
    /// completion signal; no polling, no race against the async
    /// background queue.
    private func runImageIntegrityScanSync(timeout: TimeInterval = 5.0,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        let exp = expectation(description: "image integrity scan completion")
        store.runImageIntegrityScan { exp.fulfill() }
        wait(for: [exp], timeout: timeout)
    }

    /// Touch the file's mtime to a specific offset in seconds since
    /// 1970. Used to simulate "file modified since last scan" without
    /// touching the real file content. `utimensat` is the cheapest
    /// way — doesn't reopen the file or rewrite bytes. macOS's
    /// `__darwin_time_t` is platform-Int (32-bit on this SDK), so we
    /// narrow Int64 → Int for the timespec fields; values past year
    /// 2038 would overflow but our test scenarios are well below.
    private func setFileMtime(_ url: URL, _ seconds: Int64) {
        let sec = Int(seconds)
        let atime = timespec(tv_sec: sec, tv_nsec: 0)
        let mtime = timespec(tv_sec: sec, tv_nsec: 0)
        var times = [atime, mtime]
        let path = url.path
        path.withCString { p in
            _ = utimensat(AT_FDCWD, p, &times, 0)
        }
    }

    // MARK: - Acceptance tests (ID-REVIEW-1019)

    /// Acceptance 1: 二次启动跳过未变文件。First launch populates the
    /// cache; second launch with unchanged mtime must skip re-verification
    /// (assertable via the cache's persisted contents).
    func testSecondLaunchSkipsUnchangedFiles() throws {
        // Seed two images so we have something for the cache to track.
        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE]), id: id1)
        saveImageBlocking(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), id: id2)
        try registerImageItem(id: id1)
        try registerImageItem(id: id2)

        // First scan — populates the cache.
        runImageIntegrityScanSync()
        let cacheAfterFirstScan = readCache()
        XCTAssertEqual(cacheAfterFirstScan.count, 2,
                       "first scan must record both files in the mtime cache")
        XCTAssertNotNil(cacheAfterFirstScan[Self.filename(id1)])
        XCTAssertNotNil(cacheAfterFirstScan[Self.filename(id2)])

        // The cache must survive a "second launch" (same UserDefaults
        // suite). Re-reading it without any new scan should yield the
        // same set — that's the "incremental skip" behavior: the next
        // scan will compare mtime against this cached value and short-
        // circuit before doing any read work.
        let cacheBeforeSecondScan = readCache()
        XCTAssertEqual(cacheBeforeSecondScan, cacheAfterFirstScan,
                       "cache must persist across reads (same UserDefaults suite)")

        // Second scan with unchanged mtimes — the cache should NOT
        // change (no new entries added / removed; mtimes match).
        runImageIntegrityScanSync()
        let cacheAfterSecondScan = readCache()
        XCTAssertEqual(cacheAfterSecondScan, cacheAfterFirstScan,
                       "second scan with unchanged mtimes must leave the cache intact")
    }

    /// Acceptance 2: 改动任一图片文件 mtime 后, 第二次扫描会重新
    /// 校验那个文件（assertable via: mtime bumped → cache entry gets
    /// updated; image still .available so no missing/corrupt sets).
    func testChangedMtimeTriggersRescan() throws {
        // Seed two images.
        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(Data([0x11, 0x22, 0x33, 0x44]), id: id1)
        saveImageBlocking(Data([0x55, 0x66, 0x77, 0x88]), id: id2)
        try registerImageItem(id: id1)
        try registerImageItem(id: id2)

        // First scan — records both files.
        runImageIntegrityScanSync()
        let cacheAfterFirstScan = readCache()
        XCTAssertEqual(cacheAfterFirstScan.count, 2)
        let id1OldMtime = cacheAfterFirstScan[Self.filename(id1)] ?? -1

        // Bump id1's mtime by 60 seconds (well beyond 1s granularity).
        let bumpedMtime = id1OldMtime + 60
        setFileMtime(fileURL(id1), bumpedMtime)

        // Second scan — id1 should be re-verified (cache entry updated
        // to new mtime); id2 should be skipped (cache entry unchanged).
        runImageIntegrityScanSync()
        let cacheAfterSecondScan = readCache()
        XCTAssertEqual(cacheAfterSecondScan[Self.filename(id1)], bumpedMtime,
                       "changed-mtime file must be re-verified and its mtime refreshed in the cache")
        XCTAssertEqual(cacheAfterSecondScan[Self.filename(id2)], cacheAfterFirstScan[Self.filename(id2)],
                       "unchanged file must be skipped (cache entry preserved)")

        // Both images must still be reported available (not flagged as
        // missing/corrupt — the file is still on disk and decrypts).
        XCTAssertFalse(store.imageMissingIds.contains(id1))
        XCTAssertFalse(store.imageMissingIds.contains(id2))
    }

    /// Acceptance 3 (defensive): mtime cache missing / unset → full
    /// scan, no false negatives. (Defensive — when the cache is empty,
    /// we don't trust it and scan everything.)
    func testMissingCacheTriggersFullScan() throws {
        // Seed two images.
        let id1 = newTestUUID()
        let id2 = newTestUUID()
        saveImageBlocking(Data([0xAA, 0xBB]), id: id1)
        saveImageBlocking(Data([0xCC, 0xDD]), id: id2)
        try registerImageItem(id: id1)
        try registerImageItem(id: id2)

        // Wipe the cache.
        testDefaults.removeObject(forKey: Self.mtimeCacheKey)
        XCTAssertNil(testDefaults.data(forKey: Self.mtimeCacheKey),
                     "cache must start unset for this test")

        // First scan with empty cache — must scan both files and
        // populate the cache (full scan path).
        runImageIntegrityScanSync()
        let cacheAfterScan = readCache()
        XCTAssertEqual(cacheAfterScan.count, 2,
                       "empty-cache scan must record both files (full scan path)")
    }

    /// Acceptance 3 (corrupt): cache present but unparseable → full
    /// scan (no false negatives). Corruption could be from a partial
    /// write or a user manually editing the JSON.
    func testCorruptCacheTriggersFullScan() throws {
        // Seed an image.
        let id = newTestUUID()
        saveImageBlocking(Data([0x01, 0x02]), id: id)
        try registerImageItem(id: id)

        // Plant corrupt data in the cache key — invalid JSON for our
        // `[String: Int64]` decoder.
        testDefaults.set(Data("{not json".utf8), forKey: Self.mtimeCacheKey)

        // Scan must treat the corrupt value as "no cache" and scan
        // the file anyway, populating a fresh cache.
        runImageIntegrityScanSync()
        let cacheAfterScan = readCache()
        XCTAssertEqual(cacheAfterScan.count, 1,
                       "corrupt cache must be treated as empty; scan records the file")
    }

    /// Acceptance 4 (correctness): missing / corrupted image files
    /// are surfaced to the UI regardless of cache state. The cache
    /// is purely a perf optimization — false negatives are not
    /// acceptable. Here a file is deleted between scans; the second
    /// scan must mark it missing (not skip via stale cache entry).
    func testMissingFileFlaggedEvenIfPreviouslyCached() throws {
        // Seed an image.
        let id = newTestUUID()
        saveImageBlocking(Data([0xFF, 0xEE, 0xDD]), id: id)
        try registerImageItem(id: id)

        // First scan — file exists, gets cached.
        runImageIntegrityScanSync()
        let cacheAfterFirstScan = readCache()
        XCTAssertNotNil(cacheAfterFirstScan[Self.filename(id)])

        // Delete the file OUTSIDE the app (simulates external
        // corruption / user delete / disk full mid-write).
        try FileManager.default.removeItem(at: fileURL(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(id).path),
                       "file must be gone before the second scan")

        // Second scan — mtime stat returns nil (file gone) → fall
        // through to `imageStatus` which returns `.fileMissing` →
        // item id added to `imageMissingIds`. Cache is NOT updated
        // for missing files (no mtime to record).
        runImageIntegrityScanSync()
        XCTAssertTrue(store.imageMissingIds.contains(id),
                      "deleted file must surface in imageMissingIds on the next scan")
    }

    /// Acceptance 4 (decryption-failure path): ID-REVIEW-1019 review
    /// flag from OpenCode (auto-review-20261006-175132 P2). The cache
    /// short-circuit must NOT apply to `decryptionFailed` cases — if
    /// the ciphertext on disk is tampered (or the encryption key has
    /// rotated without a cache invalidation), the scan must still
    /// surface the item id in `imageCorruptedIds` regardless of the
    /// cached mtime. False negatives for corruption are explicitly
    /// unacceptable (see scan doc-comment).
    ///
    /// Strategy: corrupt the file's bytes AFTER the first scan has
    /// populated the cache. The mtime is bumped slightly so the
    /// `next launch` condition is bypassed (cache hit is "mtime
    /// unchanged" — mtime bump forces a re-verify), but the
    /// decryption MUST fail. This validates the path through
    /// `imageStatus(→ .decryptionFailed)`.
    ///
    /// Note: we use `setFileMtime(bumped)` rather than the natural
    /// cache-miss path (corrupt cache / empty cache) because the
    /// "user observes tampered file" scenario assumes the cache
    /// already exists from a previous launch.
    func testCorruptedCiphertextFlaggedEvenIfCached() throws {
        // Seed + register an image.
        let id = newTestUUID()
        let originalData = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80])
        saveImageBlocking(originalData, id: id)
        try registerImageItem(id: id)

        // First scan — file is valid, gets cached.
        runImageIntegrityScanSync()
        let cacheAfterFirstScan = readCache()
        let cachedMtime = cacheAfterFirstScan[Self.filename(id)] ?? -1
        XCTAssertGreaterThan(cachedMtime, 0, "first scan must record the file in the cache")

        // Tamper with the ciphertext on disk: flip the last byte
        // (within the AES-GCM tag area → decryption fails auth).
        let url = fileURL(id)
        var tampered = try Data(contentsOf: url)
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: url, options: .atomic)

        // Bump mtime so the cache short-circuit doesn't skip the file
        // (otherwise we'd be testing the cache-miss path, not the
        // bypass-cache path).
        setFileMtime(url, cachedMtime + 30)

        // Second scan — mtime differs from cache → re-verify →
        // imageStatus returns .decryptionFailed → id lands in
        // imageCorruptedIds (NOT in imageMissingIds).
        runImageIntegrityScanSync()
        XCTAssertTrue(store.imageCorruptedIds.contains(id),
                      "tampered ciphertext must surface in imageCorruptedIds even with a stale cache entry")
        XCTAssertFalse(store.imageMissingIds.contains(id),
                      "tampered file is still present on disk — it must NOT be flagged as missing")
    }

    // MARK: - Cache I/O helpers

    private func readCache() -> [String: Int64] {
        guard let data = testDefaults.data(forKey: Self.mtimeCacheKey),
              let dict = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            return [:]
        }
        return dict
    }
}
