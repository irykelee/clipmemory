import XCTest
import Carbon.HIToolbox
@testable import ClipMemory

/// H.1-H.4: HotKeyManager + HotKeyConfig tests.
///
/// Coverage map:
/// - No existing coverage. This file fills the entire HotKeyManager test gap.
/// - Pure logic (H.1) is fully testable.
/// - Carbon-backed `register`/`unregister` lifecycle (H.4) is partially testable:
///   `hotKeyRef` is public, so we can verify the post-unregister state and
///   that no-crash invariants hold; we do NOT trigger hotkey events.
/// - UserDefaults pollution guarded via setUp/tearDown backup-and-restore.
final class HotKeyManagerTests: XCTestCase {

    private let keyCodeKey = "HotKeyKeyCode"
    private let modifiersKey = "HotKeyModifiers"
    private var savedKeyCode: Any?
    private var savedModifiers: Any?

    override func setUp() {
        super.setUp()
        // Back up real values so we can restore them in tearDown — these are
        // the same UserDefaults keys the production app uses, so pollution
        // between tests would corrupt the user's actual hotkey preference.
        savedKeyCode = UserDefaults.standard.object(forKey: keyCodeKey)
        savedModifiers = UserDefaults.standard.object(forKey: modifiersKey)
        // Clean slate for this test
        UserDefaults.standard.removeObject(forKey: keyCodeKey)
        UserDefaults.standard.removeObject(forKey: modifiersKey)
    }

    override func tearDown() {
        // Restore the original UserDefaults state
        if let saved = savedKeyCode {
            UserDefaults.standard.set(saved, forKey: keyCodeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: keyCodeKey)
        }
        if let saved = savedModifiers {
            UserDefaults.standard.set(saved, forKey: modifiersKey)
        } else {
            UserDefaults.standard.removeObject(forKey: modifiersKey)
        }
        super.tearDown()
    }

    // MARK: - H.1 HotKeyConfig defaults & displayString

    func testDefaultConfigIsCmdCtrlV() {
        // H.1.1: Production default is ⌘⌃V (menu-bar app convention)
        let config = HotKeyConfig.defaultConfig
        XCTAssertEqual(config.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(config.modifiers, UInt32(cmdKey | controlKey))
    }

    func testDisplayStringCmdCtrlV() {
        // H.1.2: Modifier symbols + key letter
        let config = HotKeyConfig.defaultConfig
        XCTAssertEqual(config.displayString, "⌘⌃V")
    }

    func testDisplayStringAllModifiers() {
        // H.1.3: All four modifiers render in the order the code checks
        // them: cmd → control → option → shift, then key letter.
        let config = HotKeyConfig(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey)
        )
        XCTAssertEqual(config.displayString, "⌘⌃⌥⇧A")
    }

    func testDisplayStringNoModifiers() {
        // H.1.4: Just the key letter when no modifier is set
        let config = HotKeyConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: 0)
        XCTAssertEqual(config.displayString, "K")
    }

    func testDisplayStringOnlyShift() {
        // H.1.5: Single modifier, edge case
        let config = HotKeyConfig(
            keyCode: UInt32(kVK_ANSI_Z),
            modifiers: UInt32(shiftKey)
        )
        XCTAssertEqual(config.displayString, "⇧Z")
    }

    func testDisplayStringSpecialKeys() {
        // H.1.6: Special key glyphs (Return, Space, Escape, Tab, Delete)
        let cases: [(UInt32, String)] = [
            (UInt32(kVK_Return), "⏎"),
            (UInt32(kVK_Space), "Space"),
            (UInt32(kVK_Escape), "ESC"),
            (UInt32(kVK_Tab), "⇥"),
            (UInt32(kVK_Delete), "⌫")
        ]
        for (code, expected) in cases {
            let config = HotKeyConfig(keyCode: code, modifiers: 0)
            XCTAssertEqual(config.displayString, expected,
                          "Special key \(code) should render as '\(expected)'")
        }
    }

    func testDisplayStringUnknownKeyFallback() {
        // H.1.7: Unknown keyCode renders as "Key <code>" — defensive
        let config = HotKeyConfig(keyCode: 999, modifiers: 0)
        XCTAssertEqual(config.displayString, "Key 999")
    }

    // MARK: - H.2 HotKeyConfig persistence (UserDefaults)

    func testLoadReturnsDefaultWhenNotSet() {
        // H.2.1: First launch (no saved config) → default config
        let loaded = HotKeyConfig.load()
        XCTAssertEqual(loaded, .defaultConfig)
    }

    func testSaveThenLoadRoundTrip() {
        // H.2.2: Custom config persists across load() calls
        let original = HotKeyConfig(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey | shiftKey)
        )
        original.save()
        let loaded = HotKeyConfig.load()
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.keyCode, UInt32(kVK_ANSI_B))
        XCTAssertEqual(loaded.modifiers, UInt32(cmdKey | shiftKey))
    }

    // MARK: - H.3 HotKeyManager config flow

    func testManagerInitialConfigMatchesDefaults() {
        // H.3.1: Manager's config is loaded from UserDefaults at init
        let manager = HotKeyManager()
        XCTAssertEqual(manager.config, .defaultConfig)
    }

    func testUpdateHotKeyUpdatesConfigAndPersists() {
        // H.3.2: updateHotKey must (1) update in-memory config,
        // (2) save to UserDefaults, (3) re-register with Carbon
        let manager = HotKeyManager()
        let newKeyCode = UInt32(kVK_ANSI_C)
        let newModifiers = UInt32(cmdKey | optionKey)

        manager.updateHotKey(keyCode: newKeyCode, modifiers: newModifiers)

        // In-memory config reflects the change
        XCTAssertEqual(manager.config.keyCode, newKeyCode)
        XCTAssertEqual(manager.config.modifiers, newModifiers)
        XCTAssertEqual(manager.config.displayString, "⌘⌥C")

        // Persistence: a fresh load() returns the same config
        let reloaded = HotKeyConfig.load()
        XCTAssertEqual(reloaded.keyCode, newKeyCode)
        XCTAssertEqual(reloaded.modifiers, newModifiers)
    }

    // MARK: - H.4 Carbon register/unregister lifecycle

    func testUnregisterClearsHotKeyRef() {
        // H.4.1: After unregister(), hotKeyRef is nil regardless of whether
        // Carbon registration succeeded in the test environment.
        let manager = HotKeyManager()
        manager.register()   // may or may not register with Carbon; no crash
        manager.unregister()
        XCTAssertNil(manager.hotKeyRef,
                    "unregister() must clear hotKeyRef")
    }

    func testDoubleUnregisterIsSafe() {
        // H.4.2: Calling unregister twice in a row must not crash —
        // guards the `if let hotKeyRef = hotKeyRef` pattern from a
        // regression where the optional handling is removed.
        let manager = HotKeyManager()
        manager.register()
        manager.unregister()
        manager.unregister()
        XCTAssertNil(manager.hotKeyRef)
    }

    func testReRegisterIsSafe() {
        // H.4.3: register → unregister → register cycle must not leak refs.
        // After second unregister, hotKeyRef is nil.
        let manager = HotKeyManager()
        manager.register()
        manager.unregister()
        manager.register()
        manager.unregister()
        XCTAssertNil(manager.hotKeyRef)
    }

    func testRegisterDoesNotCrash() {
        // H.4.4: Carbon-backed register in the test env must not crash.
        // We don't assert hotKeyRef is non-nil (Carbon may legitimately
        // fail to register in XCTest without an event loop), only that
        // the call is safe.
        let manager = HotKeyManager()
        manager.register()
        // No assertion needed — reaching this line is the test
        manager.unregister()
    }

    func testRegisterIsIdempotent() {
        // H.4.5: A second register() call while already registered must be a
        // no-op (keeps the same hotKeyRef, no re-install). Previously each
        // call unregistered + re-registered, and WelcomeView's conflict check
        // triggered it on every onAppear — the -9878 log spam.
        let manager = HotKeyManager()
        manager.register()
        let firstRef = manager.hotKeyRef
        manager.register()
        XCTAssertTrue(manager.hotKeyRef == firstRef,
                      "second register() must not replace the existing hotKeyRef")
        manager.unregister()
    }

    // MARK: - RS-3.4: Reject modifiers=0

    func testUpdateHotKeyRejectsZeroModifiers() {
        // RS-3.4: A bare key (modifiers=0) would register a single-letter
        // global hotkey — extremely annoying UX. Must reject silently.
        let manager = HotKeyManager()
        let originalConfig = manager.config

        manager.updateHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)

        XCTAssertEqual(manager.config, originalConfig,
                       "modifiers=0 must not change the registered hotkey")
    }

    func testUpdateHotKeyRejectsZeroModifiersDoesNotPersist() {
        // RS-3.4 follow-up: rejection must not corrupt UserDefaults either.
        UserDefaults.standard.removeObject(forKey: modifiersKey)
        let manager = HotKeyManager()
        // Re-seed UserDefaults with a known good value first
        manager.updateHotKey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(manager.config.modifiers, UInt32(cmdKey | shiftKey))

        // Now attempt the bad call — config and UserDefaults must stay put
        manager.updateHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        let persisted = HotKeyConfig.load()
        XCTAssertEqual(persisted.modifiers, UInt32(cmdKey | shiftKey),
                       "Rejected update must not write zero to UserDefaults")
    }

    // MARK: - RS-3.4: load() rejects persisted modifiers=0

    func testLoadReturnsDefaultWhenSavedModifiersIsZero() {
        // RS-3.4 hardening: a persisted config with modifiers=0 would
        // re-register a bare key (e.g. just "V") as the global hotkey.
        // load() must fall back to defaultConfig in this case — same
        // defense as updateHotKey's modifiers!=0 guard, but on the
        // read path so legacy/corrupted UserDefaults can't bypass it.
        UserDefaults.standard.set(Int(kVK_ANSI_V), forKey: keyCodeKey)
        UserDefaults.standard.set(0, forKey: modifiersKey)
        let loaded = HotKeyConfig.load()
        XCTAssertEqual(loaded, .defaultConfig,
                       "load() must reject modifiers=0 and return defaultConfig")
    }

    func testLoadReturnsDefaultWhenOnlyKeyCodeSaved() {
        // RS-3.4 hardening: partial save (keyCodeKey set, modifiersKey
        // missing → modifiers defaults to 0 via UserDefaults.integer)
        // is also invalid. Falls back to defaultConfig.
        UserDefaults.standard.set(Int(kVK_ANSI_X), forKey: keyCodeKey)
        // modifiersKey intentionally not set
        let loaded = HotKeyConfig.load()
        XCTAssertEqual(loaded, .defaultConfig,
                       "Partial save with missing modifiers must fall back to defaultConfig")
    }

    /// Corrupted UserDefaults (negative integers saved via raw plist edits)
    /// must not trap on UInt32 conversion.
    func testLoadReturnsDefaultWhenPersistedValuesAreNegative() {
        UserDefaults.standard.set(-1, forKey: keyCodeKey)
        UserDefaults.standard.set(-1, forKey: modifiersKey)
        let loaded = HotKeyConfig.load()
        XCTAssertEqual(loaded, .defaultConfig,
                       "Negative persisted values must fall back to defaultConfig")
    }

    /// Persisted keyCode outside the Carbon virtual-key range is invalid.
    func testLoadReturnsDefaultWhenKeyCodeIsOutOfRange() {
        UserDefaults.standard.set(999, forKey: keyCodeKey)
        UserDefaults.standard.set(Int(cmdKey | controlKey), forKey: modifiersKey)
        let loaded = HotKeyConfig.load()
        XCTAssertEqual(loaded, .defaultConfig,
                       "Out-of-range keyCode must fall back to defaultConfig")
    }
}
