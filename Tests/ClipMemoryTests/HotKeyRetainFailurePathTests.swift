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
    func testFailedRegistration_managerStillDeinits() throws {
        // ID-CRASH-0038: GH Actions runner diverges from local dev here —
        // the test premise was that hotkey registration MUST fail, which
        // is true on local dev (⌘⇧V already taken or accessibility
        // missing) but false on GH Actions runner (clean macOS, the
        // shortcut is free, registration succeeds). Skip in CI; the
        // failure-mode contract (failed-register must still deinit
        // cleanly) is exercised by local runs.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("GH Actions runner: hotkey registration succeeds here (see ID-CRASH-0038)")
        }

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
            // Environment permitted the registration; the failure-mode
            // contract under test doesn't apply. Skip the rest.
            return
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
