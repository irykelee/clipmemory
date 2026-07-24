import XCTest
@testable import ClipMemory

/// INFRA-1 (2026-07-24 audit): HotKeyManager Carbon registration failure
/// paths leaked the H-15 `passRetained(self)` retain.
///
/// Two distinct leaks, both in `register()`:
/// 1. `InstallEventHandler` failure returned without releasing the pointer.
/// 2. `RegisterEventHotKey` failure removed the handler (BUG-012 fix) but
///    kept `retainedSelfPtr` set — the next `register()` retry then
///    overwrote it, permanently leaking one retain per failed attempt.
///
/// The user-visible symptom of the leak: a HotKeyManager whose registration
/// failed could NEVER deinit — the stranded retain kept it alive for the
/// process lifetime. These tests assert exactly that contract via weak
/// references: after failed registration attempts and the last strong
/// reference dropped, the manager must deinit.
///
/// Why weak-lifetime instead of `CFGetRetainCount` arithmetic (the H-15
/// convention): in this environment CFGetRetainCount readings showed
/// order-dependent ±1 ARC/autorelease noise (identical code measured 2 in
/// one test class and 3 in another), while the weak-deinit check measured
/// deterministically. The deinit check also covers BOTH failure paths at
/// once (install-failure and hotkey-conflict), whichever the environment
/// happens to take.
///
/// In this test environment `RegisterEventHotKey` reliably fails (no usable
/// application event target / hotkey already held), which exercises the
/// failure paths deterministically; the premise asserts guard against that
/// changing silently.
///
/// No UserDefaults writes: `register()`/`unregister()` never persist, so no
/// backup/restore is needed here.
final class HotKeyRetainFailurePathTests: XCTestCase {

    /// A single failed registration must not strand a retain: the manager
    /// deinits once the caller drops it.
    func testFailedRegistration_managerStillDeinits() {
        weak var weakManager: HotKeyManager?

        autoreleasepool {
            let manager = HotKeyManager()
            weakManager = manager
            manager.register()
            // Test premise: registration MUST fail in this environment. If
            // the environment ever lets the test runner hold the hotkey,
            // this assert fails first and flags the changed premise.
            XCTAssertNil(manager.hotKeyRef,
                         "premise: hotkey registration must fail in the test environment")
            XCTAssertTrue(manager.registerAttempted,
                          "registerAttempted must record the failed attempt")
        }

        XCTAssertNil(weakManager,
                     "failed register() must not strand the passRetained retain — manager must deinit (INFRA-1)")
    }

    /// The retry leak: each failed attempt used to overwrite `retainedSelfPtr`
    /// with a fresh `passRetained`, leaking the previous pointer forever.
    /// After N failed attempts the manager must still deinit cleanly.
    func testFailedRegistrationRetries_managerStillDeinits() {
        weak var weakManager: HotKeyManager?

        autoreleasepool {
            let manager = HotKeyManager()
            weakManager = manager
            for _ in 0..<3 {
                manager.register()
                XCTAssertNil(manager.hotKeyRef,
                             "premise: registration must fail on every attempt in the test environment")
            }
        }

        XCTAssertNil(weakManager,
                     "repeated failed register() attempts must not accumulate retains (INFRA-1)")
    }

    /// Explicit unregister() after failed attempts must not over-release
    /// either: the manager stays alive while referenced and deinits
    /// exactly when the last strong reference goes away.
    func testFailedRegistration_thenUnregister_balancesExactly() {
        weak var weakManager: HotKeyManager?

        autoreleasepool {
            let manager = HotKeyManager()
            weakManager = manager
            manager.register()
            XCTAssertNil(manager.hotKeyRef,
                         "premise: hotkey registration must fail in the test environment")
            manager.unregister()
            // Still strongly referenced here — must be alive (no over-release
            // crash / premature deinit).
            XCTAssertNotNil(weakManager)
        }

        XCTAssertNil(weakManager,
                     "unregister() after failed attempts must leave the retain count exactly balanced (INFRA-1)")
    }
}
