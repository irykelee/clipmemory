import XCTest
@testable import ClipMemory

/// ID-STORE-0005 (2026-08-01): the test bundle is injected into the real
/// app, so the convenience-init store (used by `ClipboardStore.shared`) must
/// be memory-backed under XCTest. With FileStorageBackend, any host-side
/// save reached the production UserDefaults domain — encrypted with the
/// host's throwaway fixture key, which production then reported as
/// corrupted ("N 条损坏"), and host saves could overwrite real user data.
final class TestHostIsolationTests: XCTestCase {

    /// Items, tags, and trash saves through a convenience-init store must
    /// never touch the production UserDefaults domain under XCTest.
    @MainActor
    func testConvenienceInitStoreDoesNotPersistUnderXCTest() {
        let itemsKey = "ClipboardItems"
        let tagsKey = "ClipMemoryTags"
        let trashKey = "ClipboardTrashedItems"
        let itemsBefore = UserDefaults.standard.data(forKey: itemsKey)
        let tagsBefore = UserDefaults.standard.data(forKey: tagsKey)
        let trashBefore = UserDefaults.standard.data(forKey: trashKey)

        // Convenience init is what `ClipboardStore.shared` uses — under
        // XCTest it must be memory-backed (ID-STORE-0005).
        let store = ClipboardStore()
        let item = ClipboardItem(content: "test-host-isolation", type: .text,
                                 createdAt: Date(), isPinned: false)
        store.addItem(item)
        store.addTag(Tag(name: "isolation-tag", colorHex: "#FF0000"))
        store.moveToTrash(item)
        store.flushPendingSaves()

        XCTAssertEqual(itemsBefore, UserDefaults.standard.data(forKey: itemsKey),
                       "ID-STORE-0005: items backend must not persist under XCTest")
        XCTAssertEqual(tagsBefore, UserDefaults.standard.data(forKey: tagsKey),
                       "ID-STORE-0005: tag backend must not persist under XCTest")
        XCTAssertEqual(trashBefore, UserDefaults.standard.data(forKey: trashKey),
                       "ID-STORE-0005: trash backend must not persist under XCTest")
    }
}
