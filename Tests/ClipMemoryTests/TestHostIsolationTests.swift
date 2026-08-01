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

    /// M13 (2026-08-01 audit): keys that tests write into the production
    /// UserDefaults domain must read back unchanged once the writes go
    /// through save/restore. Covers fontScale (ID-STORE-0007) and the M13
    /// sweep findings — ImageStorage migration / startup-cleanup flags
    /// (ImageStorageTests), UpdateService policy / consent / baseline date
    /// (UpdateServiceTests), and ocrPreviewEnabled (OCRTests). Same canary
    /// style as above: snapshot before, exercise, assert after. The canary
    /// itself is strictly read-only — it never writes to UserDefaults.
    @MainActor
    func testProductionDefaultsKeysAreNotMutated() {
        let canaryKeys = [
            "fontScale",                    // ID-STORE-0007
            "ImageStorageMigrationComplete",   // M13: ImageStorageTests
            "ImageStorageStartupCleanupRan",   // M13: ImageStorageTests
            "UpdateFeedPolicy",             // M13: UpdateServiceTests
            "UpdateFallbackFeedConsent",    // M13: UpdateServiceTests
            "LastPrimaryAppcastItemDate",   // M13: UpdateServiceTests
            "ocrPreviewEnabled",            // M13: OCRTests
        ]
        // .some(...) wrapping keeps an explicit "key was absent" entry —
        // assigning a bare nil to a Dictionary subscript would delete it.
        var before: [String: Any?] = [:]
        for key in canaryKeys {
            before[key] = .some(UserDefaults.standard.object(forKey: key))
        }

        // Exercise the production code paths that touch these keys under
        // save/restore discipline: a convenience-init store round (as above)
        // plus a read of each canary key through the production accessors.
        let store = ClipboardStore()
        store.addItem(ClipboardItem(content: "m13-canary", type: .text,
                                    createdAt: Date(), isPinned: false))
        store.flushPendingSaves()
        // M12 (2026-08-01): read via the local store — the accessor is
        // UserDefaults-backed and instance-agnostic (was ClipboardStore.shared).
        _ = store.ocrPreviewEnabled
        _ = UpdateService.feedPolicy
        _ = UpdateService.fallbackFeedConsent
        _ = UpdateService.lastPrimaryItemDate

        for key in canaryKeys {
            let after = UserDefaults.standard.object(forKey: key)
            switch (before[key]!, after) {
            case (nil, nil):
                break
            case let (a?, b?):
                // UserDefaults values are plist types (NSNumber/NSString/
                // NSDate/NSData/...), so NSObject isEqual is a value compare.
                XCTAssertTrue((a as AnyObject).isEqual(b),
                              "M13: production UserDefaults key \"\(key)\" must not be mutated by the test suite")
            default:
                XCTFail("M13: production UserDefaults key \"\(key)\" appeared or vanished during the test suite")
            }
        }
    }
}
