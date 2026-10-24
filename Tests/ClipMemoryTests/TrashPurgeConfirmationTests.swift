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
    ///
    /// NOTE (ID-REVIEW-1025, second round): the first version of this
    /// test emptied the bin before the second batch, which routes
    /// through the "nothing is expired" path — so it never exercised
    /// "same count, DIFFERENT set", the case the count marker actually
    /// gets wrong. The scenario below keeps the same NUMBER of pending
    /// entries but swaps their identity.
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

        // The first batch is pending and the user has NOT answered.
        // Now the batch CHANGES but keeps its SIZE: one entry leaves the
        // bin (restored) and a different one joins it.
        var current = store.trashedItems
        let leaving = current.removeLast()
        let joining = ClipboardItem(
            content: "joining",
            type: .text,
            deletedAt: Date().addingTimeInterval(-40 * 24 * 60 * 60)
        )
        current.append(joining)
        store.trashedItems = current
        store.purgeExpiredTrash()
        drainNotifications()

        XCTAssertEqual(pendingNotices, 2,
                       "a different batch of the same size must ask again — the marker is keyed on the set, not on its size")
        XCTAssertEqual(store.trashedItems.count, count,
                       "nothing may be deleted before the user confirms")
        XCTAssertFalse(store.trashedItems.contains { $0.id == leaving.id },
                       "the restored entry must not be deleted")
    }

    /// ID-REVIEW-1025 (2026-10-24, independent review P2): an OUTSTANDING
    /// question must not be bypassed by the count falling below the
    /// threshold.
    ///
    /// The badge promises "a big batch can never disappear without a
    /// decision". It was broken: 25 entries expired → the user was asked
    /// → the user restored 6 of them → the next tick saw 19, which is
    /// below the threshold → the ROUTINE branch deleted the remaining 19
    /// with no decision at all.
    func testAnOpenQuestionIsNotBypassedWhenTheCountFallsBelowTheThreshold() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var expiredNotices = 0
        let expiredToken = NotificationCenter.default.addObserver(
            forName: .trashItemsExpired, object: nil, queue: .main
        ) { _ in expiredNotices += 1 }
        defer { NotificationCenter.default.removeObserver(expiredToken) }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()
        XCTAssertEqual(store.trashedItems.count, count,
                       "precondition: the batch is pending, nothing deleted")

        // The user restores enough of them to fall below the threshold.
        store.trashedItems.removeLast()
        store.purgeExpiredTrash()
        drainNotifications()

        XCTAssertEqual(store.trashedItems.count, count - 1,
                       "an open question must not be bypassed by a routine purge")
        XCTAssertEqual(expiredNotices, 0,
                       "nothing may be deleted while the user still has to decide")
    }

    /// ID-REVIEW-1025 (2026-10-24, independent review P1): when the
    /// pending entries leave the bin without the user answering, the UI
    /// must be told — the badge gates the QuickBar, so a stale count
    /// leaves the app unreachable until it is restarted.
    func testResolvingThePendingStateTellsTheUI() {
        let count = TrashStore.expiredPurgeConfirmationThreshold
        let backend = InMemoryStorageBackend(items: makeExpiredItems(count))
        let defaults = makeTestDefaults()
        defer { removeTestDefaults(defaults) }

        var resolvedNotices: [Int] = []
        let pendingToken = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { note in
            if let count = note.userInfo?["count"] as? Int, count == 0 {
                resolvedNotices.append(count)
            }
        }
        defer { NotificationCenter.default.removeObserver(pendingToken) }

        let store = TrashStore(backend: backend, defaults: defaults)
        drainNotifications()

        // The user empties the bin by hand: the entries the question
        // referred to are gone, so there is nothing left to decide.
        store.trashedItems = []
        store.purgeExpiredTrash()
        drainNotifications()

        XCTAssertEqual(resolvedNotices.count, 1,
                       "the resolution must be announced — a stale badge would block the QuickBar")
    }

    /// The same contract through the OTHER resolution path: a routine
    /// purge below the threshold leaves NO stale marker behind, so the
    /// next batch of the same size is not swallowed.
    ///
    /// ID-REVIEW-1025 (2026-10-24): the premise changed with the gate.
    /// While a question is OPEN, a routine purge must not happen at all
    /// (that was the bypass the review found) — so the routine purge
    /// this test needs has to run with NO open question.
    func testARoutinePurgeLeavesNoStaleMarker() {
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

        // The first batch is BELOW the threshold → a routine purge, no
        // question is ever opened.
        let backend2 = InMemoryStorageBackend(items: makeExpiredItems(count - 1))
        let store = TrashStore(backend: backend2, defaults: defaults)
        drainNotifications()
        XCTAssertEqual(pendingNotices, 0,
                       "a batch below the threshold must not ask anything")
        XCTAssertEqual(expiredNotices, 1,
                       "the routine purge must still report what it removed")
        XCTAssertEqual(store.trashedItems.count, 0,
                       "the routine purge deletes right away")

        // A batch of the SAME SIZE as the routine one must be asked
        // about — the routine purge must not have left a marker behind.
        store.trashedItems = makeExpiredItems(count)
        store.purgeExpiredTrash()
        drainNotifications()
        XCTAssertEqual(pendingNotices, 1,
                       "a batch at the threshold must ask again — the routine purge left no stale marker")
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
