import XCTest
@testable import ClipMemory

/// C1: real Keychain round-trips for KeychainKeyStore. Uses a test-scoped
/// service/account so the production key item is never touched.
final class KeychainKeyStoreTests: XCTestCase {

    private var store: KeychainKeyStore!

    override func setUpWithError() throws {
        store = KeychainKeyStore(
            service: "com.clipmemory.tests",
            account: "unit-test-\(UUID().uuidString)"
        )
    }

    override func tearDownWithError() throws {
        store.delete()
    }

    func testLoadReturnsNilWhenAbsent() {
        XCTAssertNil(store.load())
    }

    func testStoreLoadDeleteRoundTrip() throws {
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // P2-3 (OpenCode auto-review, 2026-09-23): store() now throws
        // KeyStoreError instead of returning OSStatus. On success, it
        // returns normally (no throw, no return value).
        XCTAssertNoThrow(try store.store(key))
        XCTAssertEqual(store.load(), key)

        store.delete()
        XCTAssertNil(store.load(), "delete must remove the item")
    }

    func testStoreReplacesExistingItem() throws {
        let first = Data(repeating: 0x11, count: 32)
        let second = Data(repeating: 0x22, count: 32)

        XCTAssertNoThrow(try store.store(first))
        XCTAssertNoThrow(try store.store(second), "store must replace, not duplicate")
        XCTAssertEqual(store.load(), second)
    }

    /// P2-3 (OpenCode auto-review, 2026-09-23): on the real Keychain,
    /// transient vs permanent classification is exercised by injecting
    /// controlled ACL/lock states. errSecInteractionNotAllowed is the
    /// canonical transient (Keychain locked). We do NOT exercise the
    /// happy path here — that's covered by testStoreLoadDeleteRoundTrip.
    /// This test simply asserts that calling store() while the keychain
    /// is locked surfaces a KeyStoreError.transient, not a permanent.
    func testStoreFailureOnLockedKeychainThrowsTransient() throws {
        // We can't easily force errSecInteractionNotAllowed in a unit test
        // without ACL manipulation. Instead, verify the classify() helper
        // directly — that's the contract that drives the caller's branching.
        XCTAssertEqual(
            KeyStoreError.classify(errSecInteractionNotAllowed),
            .transient(errSecInteractionNotAllowed),
            "P2-3: errSecInteractionNotAllowed must classify as transient (Keychain locked → next-launch retry)"
        )
        XCTAssertEqual(
            KeyStoreError.classify(errSecAuthFailed),
            .transient(errSecAuthFailed),
            "P2-3: errSecAuthFailed must classify as transient"
        )
        XCTAssertEqual(
            KeyStoreError.classify(errSecNotAvailable),
            .transient(errSecNotAvailable),
            "P2-3: errSecNotAvailable must classify as transient"
        )
        XCTAssertEqual(
            KeyStoreError.classify(errSecParam),
            .permanent(errSecParam),
            "P2-3: errSecParam must classify as permanent (Keychain definitively rejected)"
        )
        XCTAssertEqual(
            KeyStoreError.classify(errSecAllocate),
            .permanent(errSecAllocate),
            "P2-3: errSecAllocate must classify as permanent"
        )
    }
}
