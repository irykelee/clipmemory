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
    ///
    /// ID-CRASH-0060 (code-review-2026-10-01 v2.9.6 follow-up): the
    /// unconditional `throw XCTSkip` at the top was the ID-CRASH-0038
    /// mass-skip — it short-circuited the test before the
    /// environment-conditional guard could ever run. With #93 root
    /// cause closed, the conditional guard below (lines 63-67) is
    /// sufficient: skip the failure-mode contract ONLY when the
    /// environment actually permitted registration, otherwise
    /// exercise the contract normally.
    func testFailedRegistration_managerStillDeinits() throws {
        weak var weakManager: HotKeyManager?

        // ID-CRASH-0038 fix-up: the original premise ("registration MUST
        // fail in this environment") was true on local dev (where the
        // ⌘⇧V shortcut is often already taken by another process or
        // the test runner lacks accessibility) but false on GH Actions
        // runners (clean macOS, no shortcuts taken, permission OK). The
        // test's actual property under test is: *if registration fails,
        // the manager must still deinit cleanly* (INFRA-1). When the
        // environment lets registration succeed, the failure-mode
        // path isn't exercised and the assertion doesn't apply.
        let registrationFailed: Bool = autoreleasepool {
            let manager = HotKeyManager()
            weakManager = manager
            manager.register()
            let failed = manager.hotKeyRef == nil
            XCTAssertTrue(manager.registerAttempted,
                          "registerAttempted must record the failed attempt")
            return failed
        }

        guard registrationFailed else {
            // ID-CRASH-0060: environment permitted the registration;
            // the failure-mode contract under test doesn't apply.
            // Skip the rest of the test (XCTest semantics: XCTSkip
            // from mid-test = skipped, not failed).
            throw XCTSkip("hotkey registration succeeded in this environment — failure-mode contract doesn't apply")
        }

        XCTAssertNil(weakManager,
                     "failed register() must not strand the passRetained retain — manager must deinit (INFRA-1)")
    }

    /// The retry leak: each failed attempt used to overwrite `retainedSelfPtr`
    /// with a fresh `passRetained`, leaking the previous pointer forever.
    /// After N failed attempts the manager must still deinit cleanly.
    ///
    /// ID-CRASH-0060: drop the unconditional skip; rely on the
    /// conditional guard below to skip only when the environment
    /// actually permits registration (see testFailedRegistration_
    /// managerStillDeinits for the full rationale).
    func testFailedRegistrationRetries_managerStillDeinits() throws {
        weak var weakManager: HotKeyManager?

        // Probe: does registration reliably fail in this environment?
        let probe = autoreleasepool { () -> Bool in
            let manager = HotKeyManager()
            manager.register()
            return manager.hotKeyRef == nil
        }
        guard probe else {
            // ID-CRASH-0060: environment permitted registration on the
            // first try — the retry-leak contract under test doesn't
            // apply. Skip the rest.
            throw XCTSkip("hotkey registration succeeded in this environment — retry-leak contract doesn't apply")
        }

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
    func testFailedRegistration_thenUnregister_balancesExactly() throws {
        // ID-CRASH-0060: drop the unconditional skip; probe registration
        // and skip only when the environment actually permits it.
        let probe = autoreleasepool { () -> Bool in
            let manager = HotKeyManager()
            manager.register()
            return manager.hotKeyRef == nil
        }
        guard probe else {
            throw XCTSkip("hotkey registration succeeded in this environment — unregister-after-fail contract doesn't apply")
        }

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
