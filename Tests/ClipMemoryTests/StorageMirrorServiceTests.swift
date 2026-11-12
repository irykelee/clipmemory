import XCTest
import SQLite3
@testable import ClipMemory

/// ID-REVIEW-1027 (2026-11-12) — the local SQLite store as a production
/// component.
///
/// Before this, the SQLite backend had ZERO production call sites, which
/// is precisely why docs/design/storage-migration.md §4.4.1 could say the
/// user-visible obligation "is not implemented yet, and today it cannot
/// be". These tests pin the three properties that make it a production
/// citizen:
///
///  1. it seeds a VERIFIED copy of the user's history;
///  2. it never modifies the source (the user's data stays where it is);
///  3. every failure reaches the user-visible channel — never a silent
///     log line.
final class StorageMirrorServiceTests: XCTestCase {

    private var tempDir: URL!
    private var databaseURL: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageMirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("store.sqlite3")
        suiteName = "StorageMirror-\(UUID().uuidString)"
        defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: self.tempDir)
            TestSuiteCleanup.destroy(self.defaults)
        }
    }

    // MARK: - Fixtures

    private func seedSource(
        items: [ClipboardItem] = [ClipboardItem(content: "hello", type: .text)],
        tags: [Tag] = []
    ) {
        defaults.set(try? JSONEncoder().encode(items),
                     forKey: UserDefaultsKey.clipboardItems.rawValue)
        defaults.set(try? JSONEncoder().encode(tags),
                     forKey: UserDefaultsKey.clipboardTags.rawValue)
    }

    // MARK: - 1. the copy is seeded and verified

    func testSeedCopiesTheHistoryAndVerifiesTheCopy() throws {
        let tag = Tag(id: UUID(), name: "work", colorHex: "#FF0000")
        let items = [
            ClipboardItem(content: "one", type: .text),
            ClipboardItem(content: "two", type: .text, tagIds: [tag.id])
        ]
        seedSource(items: items, tags: [tag])

        let outcome = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)

        guard case .seeded(let itemCount, let tagCount) = outcome else {
            return XCTFail("expected the store to be seeded and verified, got \(outcome)")
        }
        XCTAssertEqual(itemCount, 2, "both items must be in the copy")
        XCTAssertEqual(tagCount, 1, "the tag must be in the copy")

        let backend = try SQLiteStorageBackend(databaseURL: databaseURL)
        let mirrored = try backend.load()
        XCTAssertEqual(Set(mirrored.map(\.id)), Set(items.map(\.id)),
                       "the copy must carry the same items")
        XCTAssertEqual(try backend.loadTags().map(\.id), [tag.id],
                       "the copy must carry the tag")
    }

    /// The seed is a ONE-SHOT: a second launch must not redo it, and it
    /// must not duplicate what is already there.
    func testSeedIsIdempotentAcrossLaunches() throws {
        seedSource(items: [
            ClipboardItem(content: "one", type: .text),
            ClipboardItem(content: "two", type: .text)
        ])

        let first = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)
        guard case .seeded = first else {
            return XCTFail("the first seed must seed the store, got \(first)")
        }

        let second = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)
        guard case .alreadySeeded = second else {
            return XCTFail("the second seed must be a no-op, got \(second)")
        }

        let backend = try SQLiteStorageBackend(databaseURL: databaseURL)
        XCTAssertEqual(try backend.load().count, 2,
                       "a second seed must not duplicate the rows")
    }

    // MARK: - 2. the source is never modified

    /// The safety property that makes the whole phase acceptable: the
    /// local store is a COPY. The user's history lives in UserDefaults
    /// and the seed must not touch it — not the bytes, not the content.
    ///
    /// If this ever fails, a failure in the seed can destroy the user's
    /// data, and the "zero blast radius" claim is void.
    func testSeedDoesNotModifyTheSourceBlobs() throws {
        let items = [ClipboardItem(content: "keep me", type: .text)]
        seedSource(items: items)
        let before = defaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue)

        let tagsBefore = defaults.data(forKey: UserDefaultsKey.clipboardTags.rawValue)
        let trashBefore = defaults.data(forKey: UserDefaultsKey.trashedItems.rawValue)

        _ = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)

        let after = defaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue)
        XCTAssertEqual(after, before, "the seed must not modify the source blob")
        XCTAssertEqual(
            try JSONDecoder().decode([ClipboardItem].self, from: after ?? Data()),
            items,
            "the source must still decode to the same history"
        )
        XCTAssertEqual(
            defaults.data(forKey: UserDefaultsKey.clipboardTags.rawValue),
            tagsBefore,
            "the seed must not modify the tag catalog blob"
        )
        XCTAssertEqual(
            defaults.data(forKey: UserDefaultsKey.trashedItems.rawValue),
            trashBefore,
            "the seed must not modify the trash blob"
        )
    }

    /// A failed seed must leave the migration flag UNSET, so the next
    /// launch retries from the last good state. That is the "honest retry
    /// trigger" §4.4.1 asks for.
    func testAFailedSeedLeavesTheFlagUnsetSoTheNextLaunchRetries() throws {
        // An unreadable blob: the migration refuses to skip it, so the
        // seed fails.
        defaults.set(Data("not json at all".utf8),
                     forKey: UserDefaultsKey.clipboardItems.rawValue)

        XCTAssertThrowsError(try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL))

        let backend = try SQLiteStorageBackend(databaseURL: databaseURL)
        XCTAssertNil(
            try backend.meta(key: StoreMigration.completedFlagKey),
            "a failed seed must not leave the completed flag set"
        )
    }

    // MARK: - 3. failures reach the user-visible channel

    /// Every failure must be POSTED, not logged. A posted notification
    /// nobody observes is the dead channel ID-CRASH-0008 was about, and
    /// the observer is what turns it into a banner.
    func testSeedFailureIsPostedToTheUserVisibleChannel() throws {
        defaults.set(Data("not json at all".utf8),
                     forKey: UserDefaultsKey.clipboardItems.rawValue)

        let expectation = expectation(description: "the failure is posted")
        var posted: [AnyHashable: Any] = [:]
        let token = NotificationCenter.default.addObserver(
            forName: .storageMirrorFailed, object: nil, queue: nil
        ) { note in
            posted = note.userInfo ?? [:]
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        StorageMirrorService.seedAndReport(source: defaults, databaseURL: databaseURL)

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(
            posted["reason"] as? String,
            StorageMirrorService.FailureReason.unavailable.rawValue,
            "an unreadable source must be reported as unavailable"
        )
    }

    /// A database written by a NEWER build must be classified as such —
    /// the user needs "please upgrade", not "the disk failed".
    func testDatabaseFromANewerBuildIsClassifiedAsFromNewerBuild() throws {
        _ = try SQLiteStorageBackend(databaseURL: databaseURL)
        try writeUserVersion(SQLiteSchema.version + 1, at: databaseURL)

        XCTAssertThrowsError(try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)) { error in
            XCTAssertEqual(
                StorageMirrorService.failureReason(for: error),
                .fromNewerBuild,
                "a store from a newer build must be reported as such"
            )
        }
    }

    /// The comparison that decides "the copy is faithful" must reject a
    /// mismatch. End to end the divergence can only be triggered by a
    /// migration bug, so the comparison is exercised directly here —
    /// otherwise it would be a guard nobody can drive.
    func testTheCopyComparisonRejectsAMismatch() throws {
        let itemA = ClipboardItem(content: "a", type: .text)
        let itemB = ClipboardItem(content: "b", type: .text)
        let tag = Tag(id: UUID(), name: "t", colorHex: "#000000")

        XCTAssertTrue(
            StorageMirrorService.contentsMatch(
                sourceItems: [itemA, itemB],
                mirroredItems: [itemB, itemA],
                sourceTags: [tag],
                mirroredTags: [tag]
            ),
            "the same items in a different order are still the same copy"
        )
        XCTAssertFalse(
            StorageMirrorService.contentsMatch(
                sourceItems: [itemA, itemB],
                mirroredItems: [itemA],
                sourceTags: [tag],
                mirroredTags: [tag]
            ),
            "a missing item must fail the comparison"
        )
        XCTAssertFalse(
            StorageMirrorService.contentsMatch(
                sourceItems: [itemA],
                mirroredItems: [itemA],
                sourceTags: [tag],
                mirroredTags: []
            ),
            "a missing tag must fail the comparison"
        )
    }

    // MARK: - 4. the verification must not cry wolf, and must not give up

    /// ID-REVIEW-1027 (2026-11-12, independent verifier P1-1): a tag id
    /// the CATALOG does not carry must not make a faithful copy look
    /// diverged.
    ///
    /// The state is production-reachable: the items blob and the tags
    /// blob are written by two INDEPENDENT debounce timers, so a crash
    /// between them leaves items that reference a tag the catalog does
    /// not have. The migration creates a PLACEHOLDER row for it (the
    /// `item_tags` FOREIGN KEY would otherwise abort the whole batch),
    /// and a comparison that only knows the catalog's ids calls that
    /// placeholder a divergence — a false alarm for a copy that is
    /// faithful.
    func testSeedWithADanglingTagReferenceIsNotReportedAsDiverged() throws {
        let orphanTagID = UUID()
        let items = [
            ClipboardItem(content: "tagged", type: .text, tagIds: [orphanTagID]),
            ClipboardItem(content: "plain", type: .text)
        ]
        // The catalog does NOT carry the tag: this is the failed-decode /
        // crash-between-writes shape.
        seedSource(items: items, tags: [])

        let outcome = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)

        guard case .seeded(let itemCount, _) = outcome else {
            return XCTFail("a faithful copy must not be reported as diverged, got \(outcome)")
        }
        XCTAssertEqual(itemCount, 2, "both items must be in the copy")

        let backend = try SQLiteStorageBackend(databaseURL: databaseURL)
        XCTAssertEqual(
            Set(try backend.loadTags().map(\.id)),
            [orphanTagID],
            "the copy keeps the membership through a placeholder row"
        )
    }

    /// ID-REVIEW-1027 (2026-11-12, independent verifier P1-1 second half):
    /// a copy that FAILED its verification must not be marked verified,
    /// and the next launch must check it again.
    ///
    /// The migration writes its "completed" stamp BEFORE the verification
    /// runs, so a diverged copy used to short-circuit on the next launch
    /// and never be checked again — a copy that stayed unverified forever
    /// behind a one-shot scare.
    func testADivergedCopyIsNotMarkedVerifiedSoTheNextLaunchRetries() throws {
        seedSource(items: [ClipboardItem(content: "real", type: .text)])

        // Put a row into the copy that the source does not have. The
        // migration upserts the source's items and never deletes, so the
        // stray row survives and the comparison must fail.
        var backend: SQLiteStorageBackend? = try SQLiteStorageBackend(databaseURL: databaseURL)
        try backend!.upsertItem(ClipboardItem(content: "stray", type: .text))

        let first = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)
        guard case .diverged = first else {
            return XCTFail("a copy with a stray row must be reported as diverged, got \(first)")
        }

        let verifiedRaw = try backend!.meta(key: StorageMirrorService.verifiedFlagKey)
        XCTAssertFalse(
            StorageMirrorService.isVerified(verifiedRaw),
            "a diverged copy must not be marked as verified"
        )

                // Release the connection: the rebuild deletes the store file, and
        // the backend has no `close()` (only `deinit`), so a connection
        // still open on that file would poison the fresh one. In
        // production this is the next LAUNCH - a new process, no open
        // connection.
        backend = nil

        let second = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)
        if case .alreadySeeded = second {
            return XCTFail("a diverged copy must be re-checked on the next launch, not short-circuited")
        }
        // The rebuild is self-healing: the copy is discarded and seeded
        // again from the CURRENT source, so the next launch succeeds.
        guard case .seeded = second else {
            return XCTFail("the next launch must rebuild the copy, got \(second)")
        }
    }

    /// Ids alone would accept a copy whose every row carries the WRONG
    /// content. The comparison checks the content hashes too.
    func testTheCopyComparisonRejectsAnItemWithTheWrongContent() throws {
        // The SAME id on purpose: the assertion is about the content
        // hash. Without an explicit id each item gets its own random
        // UUID, the ids would differ, and the assertion would pass for
        // the wrong reason - the whole hash comparison could be deleted
        // and this test would still be green (measured: that mutation
        // SURVIVED before this fix).
        let id = UUID()
        let source = ClipboardItem(id: id, content: "a", type: .text, contentHash: "hash-a")
        let mirrored = ClipboardItem(id: id, content: "a", type: .text, contentHash: "hash-b")

        XCTAssertFalse(
            StorageMirrorService.contentsMatch(
                sourceItems: [source],
                mirroredItems: [mirrored],
                sourceTags: [],
                mirroredTags: []
            ),
            "the same id with a different content hash is not the same copy"
        )
    }

    /// ID-REVIEW-1027 (2026-11-12, independent verifier round 2 · P2-1):
    /// a diverged copy must be REBUILT on the next launch, not compared
    /// forever.
    ///
    /// The mirror is a frozen snapshot and the source keeps moving, so a
    /// copy that no longer matches its source used to fail its check on
    /// every single launch: the banner came back every time, and nothing
    /// could fix it (the migration is one-shot, so the copy was never
    /// rebuilt). The fix throws the untrustworthy copy away — it is a
    /// COPY, so nothing of the user's is lost — and the next launch
    /// rebuilds it from the current source.
    func testADivergedCopyIsRebuiltOnTheNextLaunch() throws {
        seedSource(items: [ClipboardItem(content: "real", type: .text)])

        // A row the source does not have: the copy cannot match.
        var backend: SQLiteStorageBackend? = try SQLiteStorageBackend(databaseURL: databaseURL)
        try backend!.upsertItem(ClipboardItem(content: "stray", type: .text))

        let first = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)
        guard case .diverged = first else {
            return XCTFail("a copy with a stray row must be reported as diverged, got \(first)")
        }
        // The copy is MARKED for rebuild: the store file is removed on
        // the next launch, BEFORE the connection is opened (the backend
        // has no `close()`, so deleting the file under an open
        // connection turns every later statement on that connection into
        // "disk I/O error").
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: StorageMirrorService.rebuildMarkerURL(for: databaseURL).path
            ),
            "a copy that failed its check must be marked for rebuild"
        )

                // Release the connection: the rebuild deletes the store file, and
        // the backend has no `close()` (only `deinit`), so a connection
        // still open on that file would poison the fresh one. In
        // production this is the next LAUNCH - a new process, no open
        // connection.
        backend = nil

let second = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)
        guard case .seeded = second else {
            return XCTFail("the next launch must rebuild the copy, got \(second)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: StorageMirrorService.rebuildMarkerURL(for: databaseURL).path
            ),
            "the rebuild marker must be cleared once the copy is rebuilt"
        )
    }

    // MARK: - 5. round 3: the self-healing must CONVERGE, and the source must be read ONCE

    /// ID-REVIEW-1027 (2026-11-12, independent verifier round 3 · P1-1):
    /// an item that is in BOTH the history blob and the trash blob must
    /// not make the copy diverge — and above all, the rebuild must
    /// CONVERGE.
    ///
    /// The state is production-reachable: the history blob and the trash
    /// blob are written by two INDEPENDENT debounce timers, so a kill
    /// between the two writes leaves a restored item in both.
    ///
    /// What used to happen: `moveToTrash` DELETEs the row from `items`,
    /// so the mirror's history lost an item the source still had ⇒ the
    /// comparison said "diverged" ⇒ the copy was marked for rebuild ⇒
    /// the next launch rebuilt it from the SAME source ⇒ the SAME
    /// divergence ⇒ **forever**. A permanent false divergence, a
    /// permanent banner, and a full re-migration on every launch.
    func testAnItemInBothTheHistoryAndTheTrashBlobDoesNotCauseAPermanentDivergence() throws {
        let restored = ClipboardItem(content: "restored", type: .text)
        seedSource(items: [restored])
        // The legacy trash blob still holds it: the user restored it and
        // the legacy blob was never rewritten.
        defaults.set(try? JSONEncoder().encode([restored]),
                     forKey: UserDefaultsKey.trashedItems.rawValue)

        let first = try StorageMirrorService.seed(source: defaults, databaseURL: databaseURL)
        guard case .seeded = first else {
            return XCTFail(
                "an item in both blobs is a RESTORED item, not a divergence — got \(first)"
            )
        }

        let backend = try SQLiteStorageBackend(databaseURL: databaseURL)
        XCTAssertTrue(
            try backend.load().contains { $0.id == restored.id },
            "the restored item must stay in the history — the source still has it"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: StorageMirrorService.rebuildMarkerURL(for: databaseURL).path
            ),
            "nothing diverged, so nothing may be marked for rebuild"
        )
    }

    /// ID-REVIEW-1027 (2026-11-12, independent verifier round 3 · P2-1):
    /// the source must be read ONCE.
    ///
    /// It used to be read twice — once by the migration, once by the
    /// verification — so a source that moved in between was compared
    /// against a FROZEN copy and a faithful copy was declared "diverged"
    /// (the verifier measured it: 4000 items migrated, one added
    /// mid-flight, and the copy was judged divergent even though not one
    /// row differed).
    ///
    /// The drifting defaults below answer the history blob with a
    /// DIFFERENT payload on the second read — so the test fails loudly
    /// if anything reads the source twice.
    func testTheSourceIsReadOnlyOnceSoTheComparisonSeesTheMigratedSnapshot() throws {
        let before = ClipboardItem(content: "before", type: .text)
        let after = ClipboardItem(content: "after", type: .text)

        let drifting = try XCTUnwrap(
            DriftingHistoryDefaults(suiteName: suiteName),
            "the drifting defaults must be creatable for the test's suite"
        )
        drifting.setHistoryPayloads([
            try JSONEncoder().encode([before]),
            try JSONEncoder().encode([before, after])
        ])

        let outcome = try StorageMirrorService.seed(source: drifting, databaseURL: databaseURL)

        guard case .seeded = outcome else {
            return XCTFail(
                "the copy must be compared against the SAME snapshot the migration imported — got \(outcome)"
            )
        }
        XCTAssertEqual(
            drifting.historyReadCount,
            1,
            "the history blob must be read exactly once — a second read can see a newer source"
        )
    }

    /// ID-REVIEW-1027 (2026-11-12, independent verifier round 3 · P2-2):
    /// every path that means "the store is fine" must SAY so.
    ///
    /// The recovery leg fired only on `.seeded`. The short-circuit path
    /// (`.alreadySeeded`) stayed silent — so a launch that found the copy
    /// already in place left the banner claiming a fault that no longer
    /// existed. The banner outlived the failure it was reporting.
    func testTheRecoveryNotificationIsPostedEvenWhenTheCopyWasAlreadySeeded() throws {
        seedSource(items: [ClipboardItem(content: "x", type: .text)])

        // First launch: seeds and verifies.
        StorageMirrorService.seedAndReport(source: defaults, databaseURL: databaseURL)

        var recovered = 0
        let token = NotificationCenter.default.addObserver(
            forName: .storageMirrorRecovered, object: nil, queue: nil
        ) { _ in recovered += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // Second launch: the short-circuit path.
        StorageMirrorService.seedAndReport(source: defaults, databaseURL: databaseURL)

        XCTAssertEqual(
            recovered, 1,
            "the short-circuit path must also report that the store is healthy — "
            + "otherwise the banner outlives the failure it reports"
        )
    }

    // MARK: - Helpers

    /// Writes `PRAGMA user_version` straight into the database file, the
    /// way a NEWER build would have left it.
    private func writeUserVersion(_ version: Int, at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil),
            SQLITE_OK
        )
    }
}

/// A `UserDefaults` whose HISTORY blob answers with a DIFFERENT payload
/// on each read.
///
/// ID-REVIEW-1027 (2026-11-12, independent verifier round 3 · P2-1):
/// the mirror used to read the source twice — once for the migration,
/// once for the verification — and a source that moved in between was
/// compared against a FROZEN copy. This is the deterministic stand-in
/// for "the user copies something during the launch".
///
/// Every other key is answered by the real store, so the migration's
/// trash read and the tag blob behave normally.
final class DriftingHistoryDefaults: UserDefaults {
    private var historyPayloads: [Data?] = []
    private var readCount = 0

    /// No initializer is written on purpose: every stored property has a
    /// default value, so the subclass inherits `UserDefaults`' designated
    /// initializers — and with them the `init?(suiteName:)` convenience
    /// initializer, which is how the suite is created.

    /// The successive payloads the history blob answers with. The last
    /// one is repeated once the list is exhausted.
    func setHistoryPayloads(_ payloads: [Data?]) {
        historyPayloads = payloads
        readCount = 0
    }

    /// How many times the history blob was read.
    var historyReadCount: Int { readCount }

    override func data(forKey defaultName: String) -> Data? {
        guard defaultName == UserDefaultsKey.clipboardItems.rawValue else {
            return super.data(forKey: defaultName)
        }
        guard !historyPayloads.isEmpty else {
            return super.data(forKey: defaultName)
        }
        let index = min(readCount, historyPayloads.count - 1)
        readCount += 1
        return historyPayloads[index]
    }
}
