import XCTest
import Carbon.HIToolbox
@testable import ClipMemory

/// ID-REVIEW-1035 (2026-10-26) — regression guards for the same-pattern leaks
/// the independent review of ID-REVIEW-1034 found.
///
/// The review's three structural findings, all in the "restore targets the
/// wrong domain" family that hid the original incident for four months:
///
/// 1. `HotKeyManagerTests` published `HotKeyKeyCode` / `HotKeyModifiers` into
///    the process-shared `HotKeyManager-XCTest-isolation` suite (via the
///    no-arg `HotKeyManager()`), while its restore targeted
///    `UserDefaults.standard` ⇒ the shared-suite write was never undone.
///    The same class also seeded and loaded `.standard` directly, i.e. it
///    overwrote the USER'S REAL hotkey preference for the duration of every
///    test and restored it only if the host survived.
/// 2. `ImportExportTests` kept a snapshot/restore of the PRODUCTION
///    `maxClipboardItems` — dead code since ID-STORE-0014 moved the write to
///    the injected suite, whose "absent before ⇒ remove" branch could delete
///    the user's real setting if the host died before tearDown.
/// 3. The write guard only watched ONE key in ONE suite, so the HotKey-suite
///    write in (1) was invisible to it.
///
/// The invariants below pin the two directions: the widened guard must SEE a
/// write into the HotKey suite, and a manager pointed at an injected suite
/// must not publish into the shared one.
@MainActor final class Review1035RegressionTests: XCTestCase {

    /// The shared suite a no-arg `HotKeyManager()` resolves to under XCTest.
    private static let hotKeySuiteName = "HotKeyManager-XCTest-isolation"

    // MARK: - 1. The widened guard must see a write into the HotKey suite

    /// The guard used to watch `maxClipboardItems` in the ClipboardStore
    /// suite only. A write of the hotkey config into the shared HotKey suite
    /// was therefore invisible — and that is exactly the write
    /// `HotKeyManagerTests` performed.
    func testWriteIntoSharedHotKeySuiteIsDetected() {
        let shared = UserDefaults(suiteName: Self.hotKeySuiteName)!
        shared.set(Int(kVK_ANSI_C), forKey: "HotKeyKeyCode")
        defer {
            shared.removeObject(forKey: "HotKeyKeyCode")
            shared.removeObject(forKey: "HotKeyModifiers")
            XCTestIsolationSuiteBootstrap.forgetViolations(forTestCase: "SelfTest")
        }

        XCTestIsolationSuiteBootstrap.recordSharedSuiteViolationIfPresent(testCase: "SelfTest")

        XCTAssertTrue(
            XCTestIsolationSuiteBootstrap.sharedSuiteViolations.contains {
                $0.contains("SelfTest") && $0.contains(Self.hotKeySuiteName)
            },
            "a write into the shared HotKey isolation suite must be recorded"
        )
    }

    /// The second watched key of the ClipboardStore suite. `excludedBundleIds`
    /// is persisted by the same `didSet` path as `maxClipboardItems`, so a
    /// leak through it must be just as visible.
    func testWriteOfExcludedBundleIdsIntoSharedClipboardStoreSuiteIsDetected() {
        let shared = UserDefaults(
            suiteName: XCTestIsolationSuiteBootstrap.clipboardStoreSuiteName
        )!
        shared.set(["com.example.blocked"], forKey: "excludedBundleIds")
        defer {
            shared.removeObject(forKey: "excludedBundleIds")
            XCTestIsolationSuiteBootstrap.forgetViolations(forTestCase: "SelfTest")
        }

        XCTestIsolationSuiteBootstrap.recordSharedSuiteViolationIfPresent(testCase: "SelfTest")

        XCTAssertTrue(
            XCTestIsolationSuiteBootstrap.sharedSuiteViolations.contains {
                $0.contains("SelfTest") && $0.contains("excludedBundleIds")
            },
            "a write of excludedBundleIds into the shared ClipboardStore suite must be recorded"
        )
    }

    // MARK: - 2. An injected suite must keep the publish out of the shared one

    /// The fix for (1): `updateHotKey` persists through the manager's OWN
    /// `defaults`. Point it at an injected suite and the shared suite stays
    /// clean — which is what `HotKeyManagerTests` now does.
    ///
    /// If this ever fails, the widened guard above will also start firing on
    /// `HotKeyManagerTests` and the ZZZ canary will name the offending test.
    func testUpdateHotKeyWithInjectedSuiteDoesNotPublishIntoTheSharedSuite() {
        let shared = UserDefaults(suiteName: Self.hotKeySuiteName)!
        let injected = makeTestDefaults()
        defer { removeTestDefaults(injected) }

        let manager = HotKeyManager(defaults: injected)
        manager.updateHotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey))

        XCTAssertNil(shared.object(forKey: "HotKeyKeyCode"),
                     "the hotkey config must not be published into the shared suite")
        XCTAssertNil(shared.object(forKey: "HotKeyModifiers"),
                     "the hotkey modifiers must not be published into the shared suite")
        XCTAssertEqual(
            HotKeyConfig.load(from: injected).keyCode, UInt32(kVK_ANSI_C),
            "the config must be persisted in the INJECTED suite"
        )
    }
}
