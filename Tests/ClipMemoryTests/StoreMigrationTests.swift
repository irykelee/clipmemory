import XCTest
@testable import ClipMemory

/// ID-REVIEW-1024 (PR-B, code-review §八 batch 2): tests for the
/// forward migration from UserDefaults blobs to SQLite. Per docs
/// §4.1, the migration runs ONCE on first launch after the new
/// binary ships, sets `migration.v1.to.v2.completed = 1` in app_meta,
/// and KEEPS the UserDefaults blobs defensively for rollback.
///
/// **Per user hard rule #3 "数据迁移任务必须扫全工件类型"**:
/// the migration covers items / tags / trash / images / OCR / app_meta
/// / migration flags. Each test case below uses one artifact type so
/// a regression in any one path is visible immediately.
@MainActor final class StoreMigrationTests: XCTestCase {

    // MARK: - Test fixtures

    /// In-memory UserDefaults for the source side (the legacy blobs).
    private var sourceDefaults: UserDefaults!

    /// In-memory UserDefaults the migration will write to (PR-B's
    /// contract: the migration uses the storage backend's own
    /// `defaults` — for SQLiteStorageBackend it's still UserDefaults
    /// because app_meta lives there per docs §2).
    private var targetDefaults: UserDefaults!

    private var tempDir: URL!
    private var sqliteDBURL: URL!
    private var backend: SQLiteStorageBackend!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceDefaults = UserDefaults(suiteName: "SourceMigration-\(UUID().uuidString)")!
        targetDefaults = UserDefaults(suiteName: "TargetMigration-\(UUID().uuidString)")!
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreMigrationTests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        sqliteDBURL = tempDir.appendingPathComponent("store.sqlite3")
        backend = try SQLiteStorageBackend(databaseURL: sqliteDBURL, defaults: targetDefaults)
    }

    override func tearDown() {
        // ID-CRASH-0022 (2026-10-20): release the backend BEFORE deleting
        // its directory — deleting the SQLite file while the connection
        // still has it open makes libsqlite3 log "database integrity
        // compromised by API violation: vnode unlinked while in use"
        // (plus the same for -wal / -shm), and the later deinit closes a
        // handle for an already-unlinked file.
        backend = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        sourceDefaults?.removePersistentDomain(forName: sourceDefaults?.dictionaryRepresentation().first?.key ?? "")
        targetDefaults?.removePersistentDomain(forName: targetDefaults?.dictionaryRepresentation().first?.key ?? "")
        sourceDefaults = nil
        targetDefaults = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Per-artifact tests

    /// Items blob → items table. Source: 3 items with different
    /// states (pinned / sensitive / with tagId / expired).
    func testMigrationCopiesItems() throws {
        let item1 = makeTestItem(content: "ciphertext-1", isPinned: true)
        let item2 = makeTestItem(content: "ciphertext-2", isSensitive: true)
        let item3 = makeTestItem(content: "ciphertext-3")
        seedItemsInSourceDefaults([item1, item2, item3])

        try StoreMigration.runOnce(
            source: sourceDefaults,
            target: backend
        )

        let migrated = try backend.load()
        XCTAssertEqual(migrated.count, 3)
        XCTAssertEqual(Set(migrated.map(\.id)), Set([item1.id, item2.id, item3.id]))
        XCTAssertEqual(migrated.first(where: { $0.id == item1.id })?.isPinned, true)
        XCTAssertEqual(migrated.first(where: { $0.id == item2.id })?.isSensitive, true)
    }

    /// Tags blob → tags table. Source: 2 tags.
    func testMigrationCopiesTags() throws {
        let tag1 = Tag(id: UUID(), name: "work", colorHex: "#FF0000")
        let tag2 = Tag(id: UUID(), name: "personal", colorHex: "#00FF00", isAutoSuggested: true)
        seedTagsInSourceDefaults([tag1, tag2])

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        let migrated = try backend.loadTags()
        XCTAssertEqual(migrated.count, 2)
        XCTAssertEqual(Set(migrated.map(\.id)), Set([tag1.id, tag2.id]))
    }

    /// Trash blob → trash_items table. Source: 1 trashed item with
    /// snapshot. Must preserve content at trash time (vs current item).
    func testMigrationHandlesTrashItems() throws {
        let id = UUID()
        let originalContent = "ciphertext-original"
        let trashContent = "ciphertext-trash-snapshot"
        let original = makeTestItem(id: id, content: originalContent)
        seedItemsInSourceDefaults([original])
        seedTrashInSourceDefaults([
            ClipboardItem(id: id, content: trashContent, type: .text,
                          deletedAt: Date())
        ])

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        let migratedTrash = try backend.loadTrashAllForTest()
        XCTAssertEqual(migratedTrash.count, 1)
        XCTAssertEqual(migratedTrash.first?.id, id)
        XCTAssertEqual(migratedTrash.first?.content, trashContent,
                       "trash content must be the snapshot, not the current item.content")
    }

    /// Item ↔ tag membership → item_tags table.
    func testMigrationPreservesItemTags() throws {
        let itemID = UUID()
        let tagID = UUID()
        let item = makeTestItem(id: itemID, content: "x", tagIds: [tagID])
        seedItemsInSourceDefaults([item])

        // We can't easily seed the "tags per item" relationship in
        // the legacy UserDefaults blobs (it's in ClipboardItem.tagIds
        // directly, not a separate table). The migration decodes
        // ClipboardItem and emits per-tag rows into item_tags.
        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        let count = try backend.itemTagCountForTest(itemID: itemID, tagID: tagID)
        XCTAssertEqual(count, 1, "item_tags row for the test item+tag must exist after migration")
    }

    /// ID-CRASH-0022 (2026-10-20): when an item references a tag the
    /// legacy catalog does not carry, the migration must still keep the
    /// item ↔ tag membership — and it does so by creating a
    /// PLACEHOLDER tag row.
    ///
    /// That placeholder is USER-VISIBLE: it lands in the `tags` table
    /// and would show up in the sidebar / tag picker once SQLite
    /// becomes the store. `testMigrationPreservesItemTags` asserts the
    /// membership row count but says nothing about the tags table, so
    /// without this test the placeholder would first be noticed in
    /// production.
    func testMigrationCreatesPlaceholderTagForOrphanTagId() throws {
        let tagID = UUID()
        let item = makeTestItem(id: UUID(), content: "x", tagIds: [tagID])
        seedItemsInSourceDefaults([item])
        // NOTE: no seedTagsInSourceDefaults — the catalog does not
        // carry this tag id, which is exactly the orphan case.

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        XCTAssertEqual(
            try backend.itemTagCountForTest(itemID: item.id, tagID: tagID), 1,
            "the item ↔ tag membership must survive the migration"
        )
        let tags = try backend.loadTags()
        XCTAssertEqual(tags.count, 1, "exactly one placeholder tag row")
        XCTAssertEqual(tags.first?.id, tagID)
        XCTAssertEqual(tags.first?.name, "",
                       "the placeholder carries no name — that emptiness is how it is recognised")
    }

    /// The migration must be idempotent — running it twice produces
    /// the same final state. PR-A's narrow-catch fix (commit 051be13)
    /// preserved this; PR-B's SQLite migration must too.
    func testMigrationIsIdempotent() throws {
        let item = makeTestItem(content: "x")
        seedItemsInSourceDefaults([item])

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)
        let afterFirst = try backend.load().count

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)
        let afterSecond = try backend.load().count

        XCTAssertEqual(afterFirst, afterSecond, "running migration twice must not duplicate rows")
        XCTAssertEqual(afterFirst, 1, "exactly 1 item after migration")
    }

    /// The migration flag must be set after a successful run. PR-B's
    /// SQLite migration writes `migration.v1.to.v2.completed = 1` into
    /// the `schema_version` table (per docs §2).
    func testMigrationSetsCompletedFlag() throws {
        seedItemsInSourceDefaults([makeTestItem(content: "x")])

        XCTAssertNil(try backend.meta(key: "migration.v1.to.v2.completed"),
                     "migration flag must start unset")

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        XCTAssertNotNil(try backend.meta(key: "migration.v1.to.v2.completed"),
                        "migration flag must be set after runOnce")
    }

    /// ID-CRASH-0022 (2026-10-20, auto-review P1): the flag is tagged
    /// `'i64'`, and the schema contract (docs §2) defines `'i64'` as an
    /// 8-byte little-endian signed integer — with the read recipe
    /// `data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }`.
    ///
    /// The flag used to be written as `Data([0x01])` — ONE byte — while
    /// tagged `'i64'`. A flag that says "i64" must BE an i64: the
    /// doc's own read recipe traps on a 1-byte buffer, so the next
    /// reader that follows the contract would crash.
    ///
    /// This test pins the on-disk encoding, and it decodes the value the
    /// way the contract says to — so it fails if the encoding drifts.
    func testMigrationFlagIsStoredAsEightByteLittleEndianI64() throws {
        seedItemsInSourceDefaults([makeTestItem(content: "x")])

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        let raw = try XCTUnwrap(backend.meta(key: "migration.v1.to.v2.completed"),
                                "migration flag must be set after runOnce")
        XCTAssertEqual(raw.count, MemoryLayout<Int64>.size,
                       "the 'i64' contract is an 8-byte value — a 1-byte blob traps the documented read recipe")
        // The documented read recipe TRAPS on a short buffer ("Fatal
        // error: UnsafeRawBufferPointer.load out of bounds"), so the
        // decode below is only reached when the length is right. The
        // assertion above already failed — returning here keeps the
        // failure a clean red instead of a crashed test host.
        guard raw.count == MemoryLayout<Int64>.size else { return }
        let decoded = raw.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        XCTAssertEqual(decoded, 1,
                       "the flag value must decode to 1 with the documented little-endian Int64 read")
    }

    /// ID-CRASH-0022 (2026-10-20): backwards compatibility with the
    /// 1-byte flag the pre-2026-10-20 code wrote.
    ///
    /// A database written by the old code carries `Data([0x01])`. If the
    /// new reader treated that as "not completed", the migration would
    /// run a second time — and a re-run is destructive: `migrateTrash`
    /// moves the legacy trash into the new store, which deletes the
    /// item rows. An item the user had already restored would be
    /// deleted again, silently.
    ///
    /// So the legacy encoding must still count as "completed".
    func testLegacyOneByteMigrationFlagIsStillTreatedAsCompleted() throws {
        seedItemsInSourceDefaults([makeTestItem(content: "x")])
        try backend.setMeta(
            key: "migration.v1.to.v2.completed",
            value: Data([0x01]),
            type: "i64"
        )

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        let items = try backend.load()
        XCTAssertTrue(items.isEmpty,
                      "a legacy 1-byte flag must count as completed — the migration must not run again")
    }

    /// Per docs §4.1 step 6, the migration KEEPS the UserDefaults
    /// blobs defensively — rollback (docs §4.2) needs them. Removing
    /// them at migration time would lose the rollback path.
    func testMigrationKeepsSourceBlobs() throws {
        seedItemsInSourceDefaults([makeTestItem(content: "x")])

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        // Source blob must still exist (rollback path needs it).
        XCTAssertNotNil(
            sourceDefaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue),
            "source items blob must be preserved after migration (rollback path)"
        )
    }

    /// Fresh install: no source blobs → migration must still complete
    /// successfully (sets the completed flag) without creating dummy
    /// rows.
    func testMigrationNoSourceBlobsIsSuccess() throws {
        // No seedItemsInSourceDefaults — fresh install.
        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        XCTAssertNotNil(try backend.meta(key: "migration.v1.to.v2.completed"),
                        "fresh install still marks the migration as complete")
        XCTAssertEqual(try backend.load().count, 0,
                       "fresh install must not invent placeholder rows")
    }

    /// A legacy blob that EXISTS but cannot be decoded is not "there is
    /// nothing to migrate".
    ///
    /// ID-CRASH-0022 (2026-10-20): the old code decoded with
    /// `try? JSONDecoder().decode(...)`, which made a corrupt blob
    /// look like an absent one — so the migration ran to completion,
    /// set the completed flag, and that batch of history was never
    /// migrated and never would be (the flag says "done"). Permanent,
    /// silent data loss.
    ///
    /// The contract now: an unreadable blob FAILS the migration, so
    /// the flag stays unset and the next launch retries.
    func testMigrationFailsOnUnreadableLegacyBlobAndLeavesCompletedFlagUnset() throws {
        // Garbage that is not a JSON array of ClipboardItem.
        sourceDefaults.set(
            Data("this is not a clipboard items blob".utf8),
            forKey: UserDefaultsKey.clipboardItems.rawValue
        )

        XCTAssertThrowsError(
            try StoreMigration.runOnce(source: sourceDefaults, target: backend),
            "an unreadable legacy blob must fail the migration, not be silently skipped"
        )

        XCTAssertNil(
            try backend.meta(key: "migration.v1.to.v2.completed"),
            "the completed flag must stay unset so the next launch retries"
        )
        XCTAssertEqual(try backend.load().count, 0,
                       "no item may be invented out of an unreadable blob")
    }

    // MARK: - Test helpers (seed source-side blobs + backend test seams)

    /// ID-CRASH-0022 (2026-10-20): a garbage flag must NOT trigger a
    /// re-run.
    ///
    /// The migration reads the LEGACY blobs, which it deliberately
    /// KEEPS (docs §4.1 step 6). So a re-run does not re-import the
    /// current state — it re-imports the OLD snapshot over it. A flag
    /// we cannot interpret is an anomaly; re-running on it would roll
    /// the user's newer data back to the legacy one. Skipping is the
    /// safe direction (nothing is lost — the legacy blobs are still
    /// there) and the anomaly is logged.
    func testGarbageMigrationFlagDoesNotTriggerRerun() throws {
        seedItemsInSourceDefaults([makeTestItem(content: "x")])
        // A flag that is neither the legacy 1-byte form nor a valid
        // 8-byte Int64 == 1.
        try backend.setMeta(
            key: "migration.v1.to.v2.completed",
            value: Data([0xFF, 0xFF, 0xFF, 0xFF]),
            type: "i64"
        )

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        let items = try backend.load()
        XCTAssertTrue(items.isEmpty,
                      "an uninterpretable flag must not re-run the migration — a re-run re-imports the stale legacy snapshot")
    }

    /// ID-CRASH-0022 (2026-10-20): the migration must not delete an
    /// item the user RESTORED after the last migration.
    ///
    /// The legacy blobs are kept defensively, so the legacy trash blob
    /// still holds the old snapshot. If the migration runs again (the
    /// flag was cleared deliberately) and the legacy trash blob holds
    /// an id that is also in the items table, `moveToTrash` would
    /// DELETE that row — the restored item would silently leave the
    /// history.
    func testMigrationDoesNotDeleteAlreadyRestoredItems() throws {
        let restored = makeTestItem(content: "restored")
        // The legacy trash blob still holds the item (it was restored
        // after the last migration, and the legacy blob was never
        // rewritten).
        seedTrashInSourceDefaults([restored])
        // The item is in the items table already — i.e. it was
        // restored. A first migration would not have this.
        try backend.upsertItem(restored)

        try StoreMigration.runOnce(source: sourceDefaults, target: backend)

        let items = try backend.load()
        XCTAssertTrue(items.contains { $0.id == restored.id },
                      "an item that is already in the items table must not be moved back to the trash by a re-run")
    }

    private func seedItemsInSourceDefaults(_ items: [ClipboardItem]) {
        let data = try? JSONEncoder().encode(items)
        sourceDefaults.set(data, forKey: UserDefaultsKey.clipboardItems.rawValue)
    }

    private func seedTagsInSourceDefaults(_ tags: [Tag]) {
        let data = try? JSONEncoder().encode(tags)
        sourceDefaults.set(data, forKey: UserDefaultsKey.clipboardTags.rawValue)
    }

    private func seedTrashInSourceDefaults(_ items: [ClipboardItem]) {
        let data = try? JSONEncoder().encode(items)
        sourceDefaults.set(data, forKey: UserDefaultsKey.trashedItems.rawValue)
    }

    private func makeTestItem(
        id: UUID = UUID(),
        content: String = "ciphertext",
        type: ClipboardItemType = .text,
        isPinned: Bool = false,
        isSensitive: Bool = false,
        contentHash: String? = nil,
        tagIds: Set<UUID> = [],
        deletedAt: Date? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            content: content,
            type: type,
            isPinned: isPinned,
            isSensitive: isSensitive,
            contentHash: contentHash,
            tagIds: tagIds,
            deletedAt: deletedAt
        )
    }
}

// MARK: - Test seams on SQLiteStorageBackend
//
// These test seams let StoreMigrationTests verify the migrated state
// without exposing internal cursor/buffer details. PR-C will decide
// whether they ship as `internal` test seams or move to dedicated
// test-suite extensions.

extension SQLiteStorageBackend {
    /// Test-only: load every trash row as a flat array. Production
    /// callers use `restoreFromTrash(itemID:)` for one-at-a-time
    /// reads; this helper exists only for migration tests that verify
    /// "all trashed items survived".
    func loadTrashAllForTest() throws -> [ClipboardItem] {
        // Delegate to the existing low-level loader — it's already
        // public to the backend file (not the protocol). For tests,
        // we expose it via a thin wrapper.
        return try loadAllTrashInternalForTest()
    }

    /// Test-only: count rows in item_tags for (itemID, tagID). Used
    /// to verify the migration emitted the junction row.
    func itemTagCountForTest(itemID: UUID, tagID: UUID) throws -> Int {
        return try countItemTagInternalForTest(itemID: itemID, tagID: tagID)
    }
}
