import XCTest
@testable import ClipMemory

/// P0-2 T5: DecryptionDiagnostics state machine + buffer→async-merge (F4 anti-view-body-publish)
@MainActor
final class ClipboardStoreDiagnosticsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        // N7: reset shared diagnostics so test state doesn't leak across tests.
        ClipboardStore.shared.diagnostics = .init()
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        ClipboardStore.shared.diagnostics = .init()
        super.tearDown()
    }

    func testDiagnosticsInitialEmpty() {
        let store = ClipboardStore.shared
        XCTAssertFalse(store.diagnostics.keyUnavailable)
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 0)
    }

    func testKeyUnavailableAggregatedToBool() {
        let store = ClipboardStore.shared
        store.testAddPendingDiagnostic(.keyUnavailable)
        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait diagnostics merge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(store.diagnostics.keyUnavailable)
    }

    func testDataCorruptedCounted() {
        let store = ClipboardStore.shared
        store.testAddPendingDiagnostic(.dataCorrupted)
        store.testAddPendingDiagnostic(.dataCorrupted)
        store.testAddPendingDiagnostic(.internalError)
        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 2)
        XCTAssertEqual(store.diagnostics.internalErrorCount, 1)
    }

    func testDismissedFlagToggles() {
        let store = ClipboardStore.shared
        store.diagnostics.dismissed = true
        XCTAssertTrue(store.diagnostics.dismissed)
    }

    func testMergeIsAsyncNotBlocking() {
        let store = ClipboardStore.shared
        store.testAddPendingDiagnostic(.keyUnavailable)
        let beforeMerge = store.diagnostics.keyUnavailable
        store.mergePendingDiagnostics()
        XCTAssertEqual(beforeMerge, store.diagnostics.keyUnavailable,
                       "mergePendingDiagnostics must async-update @Published, not sync-publish")
    }

    func testEmptySnapshotSetsZeroState() {
        // N4: without the empty-early-return, even an empty snapshot must SET zero state
        let store = ClipboardStore.shared
        store.diagnostics = .init(keyUnavailable: true, dataCorruptedCount: 5, internalErrorCount: 0, dismissed: false)
        // pendingDiagnostics is empty by default
        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait zero state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(store.diagnostics.keyUnavailable, "empty snapshot must SET zero state")
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 0)
    }
}
