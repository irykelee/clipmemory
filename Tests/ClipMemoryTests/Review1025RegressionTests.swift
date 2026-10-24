import XCTest
@testable import ClipMemory

/// ID-REVIEW-1025 (2026-10-24) — the findings of the independent review
/// that ran against this release branch, pinned as regression tests.
///
/// The review found four defects that the release notes did not (and
/// could not) describe, because they are all invisible from the outside:
///
/// 1. **The retention purge's "already asked" marker was the pending
///    COUNT** (`TrashStore.pendingExpiredPurgeCount`). The same count
///    describes a completely different set of entries later on, so the
///    second batch was silently swallowed — the purge stopped working
///    for one size class and the bin grew with no user-visible signal.
///    That is the exact failure ID-CRASH-0035 was raised to prevent.
/// 2. **The `sk-` sensitive patterns had no left boundary**, so the
///    literal `sk-` was found INSIDE `task-` / `risk-` / `disk-` and
///    ordinary text with a long alphanumeric tail was flagged sensitive
///    → auto-expired after 24 h → the user's own notes silently
///    vanished from the history.
/// 3. **`FileStorageBackend.purgeTrash` derived the surviving set from
///    the PERSISTED blob**, not from the in-memory state. A stale blob
///    therefore resurrected restored entries and dropped newly trashed
///    ones on the next launch.
/// 4. **The backup's quarantine-error record was never cleared** when
///    the quarantined keys disappeared, so a stale red line kept telling
///    the user that copies were missing long after they were recovered.
@MainActor
final class Review1025RegressionTests: XCTestCase {

    // MARK: - 1. The pending-purge marker is the set, not the count

    /// A batch of the same SIZE but different entries must ask again.
    /// See `TrashPurgeConfirmationTests` for the sibling cases; this one
    /// pins the identity rule directly against `TrashStore`.
    ///
    /// The verdict is the NUMBER OF NOTICES, not the pending count: the
    /// count is `count` in both the broken and the fixed implementation
    /// (the broken one simply never asks the second time), so asserting
    /// on it would pass either way.
    func testPendingPurgeMarkerIsTheSetNotTheCount() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: Self.expiredItems(count))
        let defaults = Self.makeDefaults()
        defer { Self.removeDefaults(defaults) }

        var notices = 0
        let token = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()
        XCTAssertEqual(notices, 1, "the first batch must ask")

        // The pending state resolves (the entries leave the bin).
        store.trashedItems = []
        store.purgeExpiredTrash()
        drainNotifications()
        XCTAssertEqual(notices, 1, "an empty bin has nothing to ask about")

        // A NEW batch of the SAME size must ask again.
        store.trashedItems = Self.expiredItems(count)
        store.purgeExpiredTrash()
        drainNotifications()
        XCTAssertEqual(notices, 2,
                       "a different batch of the same size must ask again")
    }

    // MARK: - 2. The `sk-` patterns need a left boundary

    /// The `sk-` literal must not be found inside another word. Without
    /// the boundary, `task-` + 32 hex characters satisfies the "≥24
    /// consecutive alphanumerics" tail requirement and the entry is
    /// flagged sensitive → auto-expired → the user's own text silently
    /// disappears from the history.
    func testHyphenatedPrefixWithLongTailIsNotSensitive() {
        let safe = [
            "task-" + String(repeating: "4f8a2b9c", count: 4),
            "disk-" + String(repeating: "a1b2c3d4", count: 4),
            "risk-" + String(repeating: "Z9", count: 14),
            "desk-proj-" + String(repeating: "T", count: 40),
            "my-sk-" + String(repeating: "a", count: 48)
        ]
        for text in safe {
            XCTAssertFalse(
                ClipboardMonitor.detectSensitive(text),
                "a hyphenated prefix with a long tail must not be flagged: \(text.prefix(24))"
            )
        }
    }

    /// The counterweight: the real keys must still be detected.
    func testRealServiceTokensAreStillSensitive() {
        let keys = [
            "sk-ant-api03-" + String(repeating: "aA1", count: 32),
            "sk-or-v1-" + String(repeating: "0f1a2b3c", count: 8),
            "sk-proj-" + String(repeating: "T", count: 40),
            "sk-" + String(repeating: "a", count: 48)
        ]
        for key in keys {
            XCTAssertTrue(
                ClipboardMonitor.detectSensitive(key),
                "a real service token must be flagged: \(key.prefix(20))"
            )
        }
    }

    // MARK: - 3. The purge must not resurrect a stale blob

    /// `FileStorageBackend.purgeTrash` is a read-modify-write on the
    /// PERSISTED blob. If the blob is stale relative to the in-memory
    /// bin, the rewrite resurrects whatever the stale blob still holds.
    ///
    /// The scenario: the user restores an entry (it leaves the bin, but
    /// the 500 ms debounce has not flushed yet) and then permanently
    /// deletes another entry. Without the fix, the restored entry is
    /// written back into the bin — and it is ALSO in the history, so it
    /// exists twice.
    func testPurgeDoesNotResurrectARestoredEntry() {
        let suiteName = "review-1025-purge-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let key = "Review1025.Trash"
        let backend = FileStorageBackend(storageKey: key, scope: .trash, defaults: suite)
        let store = TrashStore(backend: backend, defaults: suite)

        let restored = ClipboardItem(content: "restored", type: .text)
        let deleted = ClipboardItem(content: "deleted", type: .text)

        // Both entries are in the bin, and the blob is CURRENT (the
        // flush below lands it) — the test is about the blob going
        // STALE afterwards.
        store.moveToTrash(restored, evictCaches: { _ in }, didMove: {})
        store.moveToTrash(deleted, evictCaches: { _ in }, didMove: {})
        store.flushPendingSave()
        XCTAssertEqual((try? backend.loadTrashAll())?.count, 2,
                       "precondition: both entries are persisted")

        // The user restores one entry: it leaves the bin, but the
        // debounced write has not happened yet → the blob is now stale.
        store.restoreFromTrash(restored, didRestore: { _ in })

        // ... and then permanently deletes the other one.
        store.deletePermanently(deleted)

        let persisted = (try? backend.loadTrashAll()) ?? []
        XCTAssertTrue(
            persisted.allSatisfy { $0.id != restored.id },
            "the restored entry must not be resurrected into the persisted bin"
        )
        XCTAssertTrue(
            persisted.allSatisfy { $0.id != deleted.id },
            "the permanently deleted entry must not survive in the persisted bin"
        )
    }

    /// The mirror image: an entry that was trashed but whose blob write
    /// has not landed yet must not be LOST by the purge's rewrite.
    func testPurgeDoesNotDropANewlyTrashedEntry() {
        let suiteName = "review-1025-purge-new-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let key = "Review1025.TrashNew"
        let backend = FileStorageBackend(storageKey: key, scope: .trash, defaults: suite)
        let store = TrashStore(backend: backend, defaults: suite)

        let old = ClipboardItem(content: "old", type: .text)
        let fresh = ClipboardItem(content: "fresh", type: .text)

        // The bin holds one entry and the blob is current.
        store.moveToTrash(old, evictCaches: { _ in }, didMove: {})
        store.flushPendingSave()

        // A new entry is trashed (in memory, blob write still pending)
        // and the old one is permanently deleted — both before the
        // debounce fires, so the blob is stale in BOTH directions.
        store.moveToTrash(fresh, evictCaches: { _ in }, didMove: {})
        store.deletePermanently(old)

        let persisted = (try? backend.loadTrashAll()) ?? []
        XCTAssertEqual(
            persisted.map { $0.id },
            [fresh.id],
            "the newly trashed entry must survive the purge; the deleted one must not"
        )
    }

    // MARK: - 4. The quarantine-error record must not go stale

    /// A stale red line in Settings → Backup is a false alarm: it tells
    /// the user that quarantine copies are missing long after the
    /// quarantined blob was recovered. The record must be cleared when
    /// the quarantined keys are gone.
    func testQuarantineErrorRecordIsClearedWhenTheKeysDisappear() {
        let suiteName = "review-1025-quarantine-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Simulate a previous run's failure record.
        suite.set(Date(), forKey: UserDefaultsKey.lastQuarantineErrorDate.rawValue)
        suite.set("2 of 3 quarantine copies could not be written",
                  forKey: UserDefaultsKey.lastQuarantineErrorMessage.rawValue)

        // The quarantined blob is gone (it was recovered), so there is
        // nothing to copy — and nothing to fail.
        let service = BackupService(
            backupsDirectory: Self.tempDirectory("backups"),
            imagesDirectory: Self.tempDirectory("images"),
            defaults: suite
        )
        try? service.backupNow()

        XCTAssertNil(
            suite.object(forKey: UserDefaultsKey.lastQuarantineErrorMessage.rawValue),
            "a resolved quarantine failure must not leave a stale warning behind"
        )
        XCTAssertNil(
            suite.object(forKey: UserDefaultsKey.lastQuarantineErrorDate.rawValue),
            "the paired date must be cleared with the message"
        )
    }

    // MARK: - Helpers

    private static func expiredItems(_ count: Int) -> [ClipboardItem] {
        (0..<count).map { index in
            ClipboardItem(
                content: "expired-\(index)",
                type: .text,
                deletedAt: Date().addingTimeInterval(-40 * 24 * 60 * 60)
            )
        }
    }

    private static func makeDefaults() -> UserDefaults {
        makeTestDefaults()
    }

    private static func removeDefaults(_ defaults: UserDefaults) {
        removeTestDefaults(defaults)
    }

    /// Lets the asynchronously posted notices arrive.
    private func drainNotifications() {
        let settled = expectation(description: "notifications delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }

    /// A throwaway directory for the backup service to write into.
    private static func tempDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Review1025-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
