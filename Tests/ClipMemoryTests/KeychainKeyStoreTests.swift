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

    func testStoreLoadDeleteRoundTrip() {
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        XCTAssertEqual(store.store(key), errSecSuccess)
        XCTAssertEqual(store.load(), key)

        store.delete()
        XCTAssertNil(store.load(), "delete must remove the item")
    }

    func testStoreReplacesExistingItem() {
        let first = Data(repeating: 0x11, count: 32)
        let second = Data(repeating: 0x22, count: 32)

        XCTAssertEqual(store.store(first), errSecSuccess)
        XCTAssertEqual(store.store(second), errSecSuccess, "store must replace, not duplicate")
        XCTAssertEqual(store.load(), second)
    }
}
