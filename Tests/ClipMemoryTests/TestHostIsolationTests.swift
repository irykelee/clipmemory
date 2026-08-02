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
    /// (UpdateServiceTests), ocrPreviewEnabled (OCRTests), trash
    /// retentionDays (TST-0002), and maxItems / hotkey keys
    /// (ID-STORE-0009, 2026-08-02 v6 audit F-1). Same canary
    /// style as above: snapshot before, exercise, assert after. The canary
    /// itself restores everything it writes (see ID-STORE-0009 exercise).
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
            "ClipboardTrashedItems.retentionDays", // TST-0002 (2026-08-02 audit): ClipboardStoreTrashTests
            "maxClipboardItems",            // ID-STORE-0009 (2026-08-02 v6 audit F-1): ClipboardStore.maxItems didSet
            "HotKeyKeyCode",                // ID-STORE-0009: HotKeyConfig.save()
            "HotKeyModifiers",              // ID-STORE-0009: HotKeyConfig.save()
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

        // ID-STORE-0009 (2026-08-02 v6 audit F-1): exercise the maxItems
        // didSet and HotKeyConfig.save() write paths, then restore the raw
        // defaults in-line (a `defer` would run after the assertions below).
        // Restore is absence-aware: on a fresh CI sandbox these keys may not
        // exist, and blindly writing back the read value would make the key
        // "appear" and trip the canary.
        let maxItemsBefore = UserDefaults.standard.object(forKey: "maxClipboardItems")
        store.maxItems = 12345
        if let maxItemsBefore {
            UserDefaults.standard.set(maxItemsBefore, forKey: "maxClipboardItems")
        } else {
            UserDefaults.standard.removeObject(forKey: "maxClipboardItems")
        }
        let hotKeyCodeBefore = UserDefaults.standard.object(forKey: "HotKeyKeyCode")
        let hotKeyModifiersBefore = UserDefaults.standard.object(forKey: "HotKeyModifiers")
        HotKeyConfig(keyCode: 0, modifiers: 256).save()
        if let hotKeyCodeBefore {
            UserDefaults.standard.set(hotKeyCodeBefore, forKey: "HotKeyKeyCode")
        } else {
            UserDefaults.standard.removeObject(forKey: "HotKeyKeyCode")
        }
        if let hotKeyModifiersBefore {
            UserDefaults.standard.set(hotKeyModifiersBefore, forKey: "HotKeyModifiers")
        } else {
            UserDefaults.standard.removeObject(forKey: "HotKeyModifiers")
        }

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
