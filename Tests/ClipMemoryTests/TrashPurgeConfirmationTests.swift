import XCTest
@testable import ClipMemory

/// ID-CRASH-0035 (2026-10-21) — the retention purge asks BEFORE it
/// deletes a lot of entries.
///
/// The 2026-10-20 incident deleted 106 recycle-bin entries in a single
/// launch. The first fix made the purge announce itself AFTER the fact
/// (a modal alert). This one changes the order: a purge of at least
/// `expiredPurgeConfirmationThreshold` entries waits for the user's
/// confirmation, and a smaller purge stays silent — it is routine
/// housekeeping.
@MainActor
final class TrashPurgeConfirmationTests: XCTestCase {

    /// Entries that are far past any retention window.
    private func makeExpiredItems(_ count: Int) -> [ClipboardItem] {
        (0..<count).map { index in
            ClipboardItem(
                content: "expired-\(index)",
                type: .text,
                deletedAt: Date().addingTimeInterval(-40 * 24 * 60 * 60)
            )
        }
    }

    /// Lets the asynchronously posted notices arrive.
    private func drainNotifications() {
        let settled = expectation(description: "notifications delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }

    /// A purge below the threshold deletes right away and asks nothing.
    func testSmallPurgeDeletesWithoutAskingTheUser() {
        let count = TrashStore.expiredPurgeConfirmationThreshold - 1
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var pendingNotices = 0
        var expiredInfo: [AnyHashable: Any]?
        let pendingToken = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { _ in pendingNotices += 1 }
        let expiredToken = NotificationCenter.default.addObserver(
            forName: .trashItemsExpired, object: nil, queue: .main
        ) { note in expiredInfo = note.userInfo }
        defer {
            NotificationCenter.default.removeObserver(pendingToken)
            NotificationCenter.default.removeObserver(expiredToken)
        }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()

        XCTAssertEqual(pendingNotices, 0,
                       "a purge below the threshold must not ask the user anything")
        XCTAssertEqual(store.trashedItems.count, 0,
                       "a purge below the threshold must delete right away")
        XCTAssertEqual(expiredInfo?["count"] as? Int, count,
                       "the purge must still report what it removed")
    }

    /// A purge at the threshold asks FIRST and deletes nothing.
    func testLargePurgeWaitsForConfirmationAndKeepsTheEntries() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var pendingNotices = 0
        var pendingInfo: [AnyHashable: Any]?
        var expiredInfo: [AnyHashable: Any]?
        let pendingToken = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { note in
            pendingNotices += 1
            pendingInfo = note.userInfo
        }
        let expiredToken = NotificationCenter.default.addObserver(
            forName: .trashItemsExpired, object: nil, queue: .main
        ) { note in expiredInfo = note.userInfo }
        defer {
            NotificationCenter.default.removeObserver(pendingToken)
            NotificationCenter.default.removeObserver(expiredToken)
        }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()

        XCTAssertEqual(pendingNotices, 1,
                       "a large purge must ask the user exactly once")
        XCTAssertEqual(pendingInfo?["count"] as? Int, count,
                       "the notice must say how many entries are waiting")
        XCTAssertEqual(pendingInfo?["retentionDays"] as? Int, 7,
                       "the notice must say which retention window produced them")
        XCTAssertEqual(store.trashedItems.count, count,
                       "nothing may be deleted before the user confirms")
        XCTAssertNil(expiredInfo,
                     "a purge that did not happen must not report a deletion")
    }

    /// The user's confirmation is what actually deletes.
    func testConfirmingThePendingPurgeDeletesTheEntries() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var expiredInfo: [AnyHashable: Any]?
        let expiredToken = NotificationCenter.default.addObserver(
            forName: .trashItemsExpired, object: nil, queue: .main
        ) { note in expiredInfo = note.userInfo }
        defer { NotificationCenter.default.removeObserver(expiredToken) }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()
        XCTAssertEqual(store.trashedItems.count, count,
                       "precondition: the entries are still there")

        store.confirmExpiredPurge()
        drainNotifications()

        XCTAssertEqual(store.trashedItems.count, 0,
                       "the confirmation must delete the expired entries")
        XCTAssertEqual(expiredInfo?["count"] as? Int, count,
                       "the purge must report what it removed")
    }

    /// The 60 s cleanup tick must not re-ask for the same pending purge.
    func testPendingNoticeIsNotRepostedOnEveryCleanupTick() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var pendingNotices = 0
        let pendingToken = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { _ in pendingNotices += 1 }
        defer { NotificationCenter.default.removeObserver(pendingToken) }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()
        XCTAssertEqual(pendingNotices, 1)

        // The cleanup timer calls this every 60 s.
        store.purgeExpiredTrash()
        drainNotifications()

        XCTAssertEqual(pendingNotices, 1,
                       "the pending notice must not be reposted while the count is unchanged")
        XCTAssertEqual(store.trashedItems.count, count,
                       "a repeated tick must still not delete anything")
    }

    /// ID-REVIEW-1025 (2026-10-24, independent review P1): the "already
    /// asked" marker was the pending COUNT. The same count describes a
    /// completely different set of entries later on, so the second batch
    /// was silently swallowed — the retention purge stopped working for
    /// one size class and the bin grew with no user-visible signal,
    /// which is the exact failure ID-CRASH-0035 was raised to prevent.
    ///
    /// The marker is the IDENTITY of the pending set, and it is cleared
    /// whenever the pending state is resolved by ANY path.
    func testANewBatchOfTheSameSizeIsNotSilentlySkipped() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var pendingNotices = 0
        let pendingToken = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { _ in pendingNotices += 1 }
        defer { NotificationCenter.default.removeObserver(pendingToken) }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()
        XCTAssertEqual(pendingNotices, 1)

        // The pending state is resolved WITHOUT the user answering: the
        // entries leave the bin, so the next tick has nothing to purge.
        store.trashedItems = []
        store.purgeExpiredTrash()
        drainNotifications()
        XCTAssertEqual(pendingNotices, 1,
                       "an empty bin has nothing to ask about")

        // A NEW batch of the SAME SIZE arrives (different entries).
        store.trashedItems = makeExpiredItems(count)
        store.purgeExpiredTrash()
        drainNotifications()

        XCTAssertEqual(pendingNotices, 2,
                       "a different batch of the same size must ask again — the marker is keyed on the set, not on its size")
        XCTAssertEqual(store.trashedItems.count, count,
                       "nothing may be deleted before the user confirms")
    }

    /// The same contract through the OTHER resolution path: a routine
    /// purge below the threshold also resolves the pending state, so the
    /// next batch of the same size is not swallowed by a stale counter.
    func testARoutinePurgeResolvesThePendingState() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var pendingNotices = 0
        var expiredNotices = 0
        let pendingToken = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { _ in pendingNotices += 1 }
        let expiredToken = NotificationCenter.default.addObserver(
            forName: .trashItemsExpired, object: nil, queue: .main
        ) { _ in expiredNotices += 1 }
        defer {
            NotificationCenter.default.removeObserver(pendingToken)
            NotificationCenter.default.removeObserver(expiredToken)
        }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()
        XCTAssertEqual(pendingNotices, 1)

        // One entry leaves the bin → the next tick is BELOW the
        // threshold and purges routinely, without asking.
        store.trashedItems.removeLast()
        store.purgeExpiredTrash()
        drainNotifications()
        XCTAssertEqual(pendingNotices, 1,
                       "a routine purge must not ask anything")
        XCTAssertEqual(expiredNotices, 1,
                       "the routine purge must still report what it removed")

        // A new batch of the SAME SIZE must be asked about.
        store.trashedItems = makeExpiredItems(count)
        store.purgeExpiredTrash()
        drainNotifications()
        XCTAssertEqual(pendingNotices, 2,
                       "the routine purge resolved the pending state — the next batch must ask again")
        XCTAssertEqual(store.trashedItems.count, count,
                       "nothing may be deleted before the user confirms")
    }

    /// The menu bar badge exists exactly while there is something to
    /// decide about.
    func testStatusBadgeImageExistsOnlyForAPendingCount() {
        XCTAssertNotNil(AppDelegate.badgedStatusImage(count: 106),
                        "a pending purge must produce a badge")
        XCTAssertNil(AppDelegate.badgedStatusImage(count: 0),
                     "there is no badge when nothing is pending")
    }
}
