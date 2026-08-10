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

    /// M13 (2026-08-03): with injectable defaults in place (TrashStore,
    /// ClipboardStore+OCR, UpdateService, ImageStorage, WindowManager), the
    /// per-class save/restore样板 has been removed — production defaults are
    /// now protected by construction, not restoration. This canary confirms
    /// that the injection is working: the white-box exercise of production
    /// code paths below must not mutate the production persistent domain.
    ///
    /// The suite-level before/after snapshot (AAASuiteBootstrapTests /
    /// ZZZSuiteTeardownTests) catches any OTHER key pollution from any test.
    /// This canary focuses on the specific M13-injected code paths. Same
    /// canary style: snapshot before, exercise, assert after. The canary
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

    /// Regression test (2026-08-10): ClipboardStore.maxItems didSet must write
    /// to the INJECTED defaults suite, not UserDefaults.standard. The previous
    /// `.standard.set(...)` line meant every test that drove the cap (M-2's
    /// `store.maxItems = 3` and friends) silently polluted the production
    /// `com.clipmemory.app` UserDefaults, leaving the running app with an
    /// out-of-picker-range value (e.g. 3) → blank settings max-items dropdown.
    ///
    /// Both assertions are required: the positive one proves the write went
    /// somewhere useful (the injected suite), the negative one is the actual
    /// guard against test→production pollution. A test that only asserts the
    /// write succeeded without checking WHERE would let a future regression
    /// to `.standard.set` slip through unnoticed.
    ///
    /// The `.standard` snapshot+restore defers below are mandatory: without
    /// them the RED-phase run itself would leave the host's production
    /// UserDefaults with `250` (the value set below), re-creating the very
    /// bug under test on every developer machine that runs the test.
    @MainActor
    func testMaxItemsDidSetUsesInjectedDefaultsNotStandard() {
        let key = "maxClipboardItems"
        let standardBefore = UserDefaults.standard.object(forKey: key)
        defer {
            if let standardBefore {
                UserDefaults.standard.set(standardBefore, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let suiteName = "Regression-MaxItems-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = ClipboardStore(backend: MemoryStorageBackend(), defaults: suite)
        // 250 is deliberately outside the settings picker's [50, 100, 200, 500]
        // range — matches the production failure mode (user's picker went
        // blank because the saved value was 3, not in the picker list).
        let newValue = 250
        store.maxItems = newValue

        XCTAssertEqual(
            suite.object(forKey: key) as? Int, newValue,
            "didSet must write the new value into the injected suite"
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Int, standardBefore as? Int,
            ".standard must NOT be written by maxItems didSet — that path leaks test pollution into production"
        )
    }

    /// ID-STORE-0014 (2026-08-10): the convenience-init XCTest branch
    /// (`ClipboardStore()` → convenience init → XCTest guard → designated
    /// init with `backend: MemoryStorageBackend()`) must inject an isolated
    /// defaults suite. Pre-fix, this branch only swapped the backend and
    /// left `defaults = .standard`, so any test using `ClipboardStore()`
    /// (e.g. `testProductionDefaultsKeysAreNotMutated`, line 78) leaked
    /// `store.maxItems = 12345` straight into the production
    /// `com.clipmemory.app` plist — that's the path that put the user's
    /// settings into `maxClipboardItems = 3` and trimmed 109 real items
    /// into the recycle bin on every test run.
    ///
    /// This test is the **must-pass regression** for user round 3's veto:
    /// the existing `testMaxItemsDidSetUsesInjectedDefaultsNotStandard` only
    /// exercises the explicit-`defaults:` injection path (already isolated
    /// in baseline) and never exercised the convenience init — that's the
    /// design gap that let PR #38 ship as "fix" without actually fixing the
    /// user-visible bug. **Run order matters**: this test must run BEFORE
    /// any convenience-init-using test mutates `store.maxItems`.
    @MainActor
    func testConvenienceInitStoreUnderXCTestDoesNotPolluteProduction() {
        let key = "maxClipboardItems"
        let standardBefore = UserDefaults.standard.object(forKey: key)
        let isolatedSuite = ClipboardStore.xcTestDefaults
        let isolatedBefore = isolatedSuite.object(forKey: key)
        defer {
            if let standardBefore {
                UserDefaults.standard.set(standardBefore, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            isolatedSuite.removePersistentDomain(forName: "ClipboardStore-XCTest-isolation")
        }

        // The convenience init goes through the XCTest branch, which must
        // inject `xcTestDefaults` (an isolated suite under XCTest).
        let store = ClipboardStore()
        let newValue = 250
        store.maxItems = newValue

        XCTAssertEqual(
            isolatedSuite.object(forKey: key) as? Int, newValue,
            "convenience init's XCTest branch must wire `defaults` to xcTestDefaults (isolated suite)"
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Int, standardBefore as? Int,
            "convenience init's XCTest branch must NOT leave `defaults = .standard` — that leaks into production"
        )
    }
}
