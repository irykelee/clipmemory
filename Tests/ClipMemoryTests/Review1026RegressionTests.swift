import XCTest
@testable import ClipMemory

/// ID-REVIEW-1026 (2026-10-24) — production-path regression tests for the
/// load-failed sentinel vs. the quarantined copy.
///
/// ## The hole
///
/// After a corrupt blob is quarantined, the quarantine MOVES the blob to
/// `<key>.corrupt-<timestamp>` and REMOVES the original key. The next
/// launch therefore loads whatever the store wrote AFTER the quarantine —
/// a FRESH, non-empty blob — and the old "non-empty means healthy" rule
/// cleared the sentinel. The orphan-image sweep then ran and deleted every
/// image the quarantined copy still refers to. The images are the
/// irrecoverable half: the blob survives under the `.corrupt-*` key, the
/// image files do not.
///
/// ## Why ID-REVIEW-1025's fix could not close it
///
/// ID-REVIEW-1025 (same day) asked "does the loaded set cover the ids the
/// quarantined copy holds?" and recovered those ids by decoding the
/// quarantined copy as `[ClipboardItem]`. But the quarantined bytes ARE the
/// bytes that just failed that exact decode — `FileStorageBackend.load()`
/// throws on nothing else, and the quarantine copies those same bytes. The
/// id set was therefore always empty, the coverage check was always
/// trivially true, and the rule always cleared the sentinel: exactly the
/// behaviour it was written to prevent.
///
/// Its own regression test hid the problem — it wrote a DECODABLE blob
/// under a `.corrupt-*` key, a state production cannot produce. Test green,
/// production broken.
///
/// ## What these tests do instead
///
/// They walk the real path: a real `FileStorageBackend` over an isolated
/// `UserDefaults` suite, bytes that genuinely fail to decode, the real
/// quarantine (which moves the blob), a real fresh blob written afterwards,
/// and a SECOND store instance standing in for the next launch. The
/// production path is `init` → `loadItemsInBackgroundAsync` →
/// `performLoadWork` → `applyLoadResult` — the one ID-REVIEW-1025 never
/// touched.
@MainActor final class Review1026RegressionTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = makeTestDefaults()
    }

    override func tearDown() {
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Bytes that genuinely fail to decode as `[ClipboardItem]` — the one
    /// condition `FileStorageBackend.load()` throws on.
    private func seedUndecodableBlob(key: String) {
        testDefaults.set(Data(#"{"not":"an array"}"#.utf8), forKey: key)
    }

    private func quarantinedCopyKeys(for key: String) -> [String] {
        testDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(key).corrupt-") }
            .sorted()
    }

    private func itemsBackend() -> FileStorageBackend {
        FileStorageBackend(
            storageKey: ClipboardStore.itemsStorageKey,
            scope: .items,
            defaults: testDefaults
        )
    }

    private func trashBackend() -> FileStorageBackend {
        FileStorageBackend(
            storageKey: TrashStore.trashedItemsStorageKey,
            scope: .trash,
            defaults: testDefaults
        )
    }

    /// A store over the REAL file backend. `init` fires the background
    /// load, which is the production path (`applyLoadResult`).
    private func makeStore(backend: StorageBackend) -> ClipboardStore {
        ClipboardStore(
            backend: backend,
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: testDefaults
        )
    }

    // MARK: - The premise ID-REVIEW-1025 rested on

    /// Pins the premise as FALSE: the bytes the quarantine preserves cannot
    /// be decoded back into items. Any rule that tries to recover ids from
    /// the quarantined copy is therefore structurally void — this test is
    /// why the rule is now "does a quarantined copy EXIST".
    func testTheQuarantinedCopyCannotBeDecodedBackIntoItems() throws {
        seedUndecodableBlob(key: ClipboardStore.itemsStorageKey)
        let store = makeStore(backend: itemsBackend())
        XCTAssertTrue(store.waitForFirstLoadSync(), "the background load must finish")

        let quarantined = quarantinedCopyKeys(for: ClipboardStore.itemsStorageKey)
        XCTAssertEqual(quarantined.count, 1, "the corrupt blob must be quarantined under a .corrupt-* key")
        let bytes = try XCTUnwrap(testDefaults.data(forKey: quarantined[0]))
        XCTAssertThrowsError(
            try JSONDecoder().decode([ClipboardItem].self, from: bytes),
            "the quarantined bytes are the bytes that just failed to decode — an id-coverage rule over them can never fire"
        )
    }

    // MARK: - The items side (P0)

    /// The P0 regression, on the production path: launch 1 quarantines the
    /// corrupt blob, the user copies something, launch 2 loads that FRESH
    /// (non-empty) blob — and the sentinel must still be standing, because
    /// the quarantined copy still refers to image files nothing else
    /// references.
    func testTheItemsSentinelSurvivesTheNextLaunchWhileAQuarantinedCopyExists() throws {
        // LAUNCH 1 — the blob is corrupt → the real quarantine runs.
        seedUndecodableBlob(key: ClipboardStore.itemsStorageKey)
        let backend = itemsBackend()
        let store1 = makeStore(backend: backend)
        XCTAssertTrue(store1.waitForFirstLoadSync(), "launch 1 must finish its background load")

        XCTAssertEqual(
            quarantinedCopyKeys(for: ClipboardStore.itemsStorageKey).count,
            1,
            "launch 1 must quarantine the corrupt blob"
        )
        XCTAssertNil(
            testDefaults.data(forKey: ClipboardStore.itemsStorageKey),
            "the quarantine MOVES the blob — the original key must be gone, which is what makes launch 2 load something else"
        )
        XCTAssertTrue(store1.itemsLoadFailed, "launch 1 must record the failure")

        // The user copies something → the store writes a FRESH blob.
        try backend.save([ClipboardItem(content: "brand new", type: .text)])

        // LAUNCH 2 — loads the FRESH blob (non-empty!) via the production path.
        let store2 = makeStore(backend: itemsBackend())
        XCTAssertTrue(store2.waitForFirstLoadSync(), "launch 2 must finish its background load")

        XCTAssertEqual(store2.items.count, 1, "the fresh blob must load")
        XCTAssertTrue(
            store2.itemsLoadFailed,
            "the sentinel must survive while the quarantined copy exists — clearing it lets the "
                + "orphan-image sweep delete the images that copy still refers to"
        )
        XCTAssertTrue(
            testDefaults.bool(forKey: ClipboardStore.itemsLoadFailedSentinelKey),
            "the persistent sentinel must survive too — it is what the NEXT launch reads"
        )
    }

    /// The crash window: the quarantine write and the sentinel write are two
    /// separate `defaults` writes. A crash between them leaves a
    /// quarantined copy with NO sentinel — and if the user copied
    /// something before the next launch, the next load is NON-EMPTY, so a
    /// "non-empty means healthy" rule would clear a sentinel that was never
    /// set and let the orphan sweep delete the images that copy refers to.
    func testTheItemsSentinelIsWrittenOnANonEmptyLoadWhenItWasLostToACrash() throws {
        // LAUNCH 1 — the blob is corrupt → the real quarantine runs.
        seedUndecodableBlob(key: ClipboardStore.itemsStorageKey)
        let backend = itemsBackend()
        let store1 = makeStore(backend: backend)
        XCTAssertTrue(store1.waitForFirstLoadSync(), "launch 1 must finish its background load")
        XCTAssertTrue(store1.itemsLoadFailed, "launch 1 writes the sentinel")

        // Simulate the crash: the sentinel is lost, the quarantined copy stays.
        testDefaults.removeObject(forKey: ClipboardStore.itemsLoadFailedSentinelKey)

        // The user copies something → the store writes a FRESH blob.
        try backend.save([ClipboardItem(content: "brand new", type: .text)])

        // LAUNCH 2 — a non-empty load with a quarantined copy.
        let store2 = makeStore(backend: itemsBackend())
        XCTAssertTrue(store2.waitForFirstLoadSync(), "launch 2 must finish its background load")

        XCTAssertEqual(store2.items.count, 1, "the fresh blob must load")
        XCTAssertTrue(
            store2.itemsLoadFailed,
            "the sentinel must be WRITTEN on a non-empty load when a quarantined copy exists — "
                + "otherwise the crash window leaves the sweep free to delete the images"
        )
    }

    /// The degraded case: a decode error that healed on its own. There is no
    /// quarantined copy, so there is nothing to protect and the sentinel
    /// clears as before.
    func testTheItemsSentinelClearsWhenNoQuarantinedCopyExists() throws {
        testDefaults.set(true, forKey: ClipboardStore.itemsLoadFailedSentinelKey)
        let seeded = MemoryStorageBackend()
        try seeded.save([ClipboardItem(content: "healthy", type: .text)])

        let store = ClipboardStore(
            backend: seeded,
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: testDefaults
        )
        store.loadItems()

        XCTAssertFalse(
            store.itemsLoadFailed,
            "a healthy load with no quarantined copy must clear the sentinel so the orphan sweep resumes"
        )
        XCTAssertFalse(
            testDefaults.bool(forKey: ClipboardStore.itemsLoadFailedSentinelKey),
            "the persistent sentinel must be removed too"
        )
    }

    /// Precision: only the blob's OWN quarantine protects it. A trash
    /// quarantine must not keep the ITEMS sentinel standing (that would
    /// disable the items-side orphan sweep for a healthy history).
    func testATrashQuarantineDoesNotKeepTheItemsSentinelAlive() throws {
        seedUndecodableBlob(key: TrashStore.trashedItemsStorageKey)
        let trash = TrashStore(backend: trashBackend(), defaults: testDefaults)
        XCTAssertTrue(trash.lastLoadFailed, "the trash quarantine must be recorded")

        testDefaults.set(true, forKey: ClipboardStore.itemsLoadFailedSentinelKey)
        let backend = itemsBackend()
        try backend.save([ClipboardItem(content: "healthy", type: .text)])
        let store = makeStore(backend: backend)
        XCTAssertTrue(store.waitForFirstLoadSync())

        XCTAssertFalse(
            store.itemsLoadFailed,
            "a trash quarantine must not keep the ITEMS sentinel set — the items blob is healthy"
        )
    }

    // MARK: - The trash side

    /// The trash-side twin: the bin's blob is quarantined, the user trashes
    /// something, the next launch loads that FRESH (non-empty) bin — and
    /// the trash sentinel must still be standing.
    func testTheTrashSentinelSurvivesTheNextLaunchWhileAQuarantinedCopyExists() throws {
        // LAUNCH 1 — the trash blob is corrupt → the real quarantine runs.
        seedUndecodableBlob(key: TrashStore.trashedItemsStorageKey)
        let backend = trashBackend()
        let trash1 = TrashStore(backend: backend, defaults: testDefaults)

        XCTAssertEqual(
            quarantinedCopyKeys(for: TrashStore.trashedItemsStorageKey).count,
            1,
            "launch 1 must quarantine the corrupt trash blob"
        )
        XCTAssertNil(
            testDefaults.data(forKey: TrashStore.trashedItemsStorageKey),
            "the quarantine MOVES the blob — the original key must be gone"
        )
        XCTAssertTrue(trash1.lastLoadFailed, "launch 1 must record the failure")
        XCTAssertTrue(
            testDefaults.bool(forKey: TrashStore.loadFailedSentinelKey),
            "launch 1 must persist the trash sentinel"
        )

        // The user trashes something → the store writes a FRESH trash blob.
        try backend.save([ClipboardItem(content: "freshly trashed", type: .text)])

        // LAUNCH 2 — the prior-failure path loads the FRESH (non-empty) bin.
        let trash2 = TrashStore(backend: trashBackend(), defaults: testDefaults)

        XCTAssertEqual(trash2.trashedItems.count, 1, "the fresh trash blob must load")
        XCTAssertTrue(
            trash2.lastLoadFailed,
            "the trash sentinel must survive while the quarantined copy exists — clearing it lets the "
                + "orphan-image sweep delete the images that copy still refers to"
        )
        XCTAssertTrue(
            testDefaults.bool(forKey: TrashStore.loadFailedSentinelKey),
            "the persistent trash sentinel must survive too"
        )
    }

    /// The degraded case on the trash side: a healthy bin with no
    /// quarantined copy clears the sentinel as before.
    func testTheTrashSentinelClearsWhenNoQuarantinedCopyExists() throws {
        testDefaults.set(true, forKey: TrashStore.loadFailedSentinelKey)
        let seeded = MemoryStorageBackend()
        try seeded.saveTrash([ClipboardItem(content: "healthy trash", type: .text)])

        let trash = TrashStore(backend: seeded, defaults: testDefaults)

        XCTAssertEqual(trash.trashedItems.count, 1, "the healthy bin must load")
        XCTAssertFalse(
            trash.lastLoadFailed,
            "a healthy load with no quarantined copy must clear the trash sentinel"
        )
        XCTAssertFalse(
            testDefaults.bool(forKey: TrashStore.loadFailedSentinelKey),
            "the persistent trash sentinel must be removed too"
        )
    }
}
