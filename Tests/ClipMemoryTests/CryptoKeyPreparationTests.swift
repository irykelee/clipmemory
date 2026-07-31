import XCTest
@testable import ClipMemory

/// C1: the root key lives in the Keychain. prepareKey migrates a pre-C1 key
/// file once, never writes new keys to disk, and never fatalErrors (H6) —
/// every failure path routes through the injectable failure handler.
final class CryptoKeyPreparationTests: XCTestCase {

    /// Records failures and replays scripted actions; never alerts and
    /// never terminates. Actions cycle by index, clamped to the last one.
    private final class FailureRecorder {
        private(set) var failures: [CryptoKeyFailure] = []
        private let actions: [KeyFailureAction]

        init(actions: [KeyFailureAction]) {
            self.actions = actions
        }

        var handler: (CryptoKeyFailure) -> KeyFailureAction {
            { failure in
                self.failures.append(failure)
                let index = min(self.failures.count - 1, self.actions.count - 1)
                return self.actions[index]
            }
        }
    }

    /// In-memory key store; store() results can be scripted per call.
    private final class MockKeyStore: KeyStoring {
        private(set) var stored: Data?
        var storeResults: [OSStatus] = [] // default: always succeed
        private(set) var storeCalls = 0
        /// C-2 (2026-07-24 audit): tests simulating Keychain states that load()
        /// alone cannot express (e.g., locked). When nil, loadStatus() mirrors
        /// load(): .found if stored != nil, .notFound otherwise.
        var lockedStatus: KeychainLoadStatus?

        func load() -> Data? {
            switch loadStatus() {
            case .found(let data): return data
            default: return nil
            }
        }

        func loadStatus() -> KeychainLoadStatus {
            if let lockedStatus { return lockedStatus }
            if let stored { return .found(stored) }
            return .notFound
        }

        @discardableResult
        func store(_ keyData: Data) -> OSStatus {
            storeCalls += 1
            let result = storeResults.isEmpty ? errSecSuccess : storeResults.removeFirst()
            if result == errSecSuccess { stored = keyData }
            return result
        }

        func delete() {
            stored = nil
            lockedStatus = nil
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CryptoKeyPreparationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // STOR-1 (2026-07-24 audit): prepareKey now publishes to the shared
        // cache. Reset before each test so a key cached by a previous test
        // doesn't bleed into the next (would also pollute CryptoServiceTests
        // run in the same process).
        CryptoService.resetForTesting()
    }

    override func tearDownWithError() throws {
        CryptoService.resetForTesting()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var keyURL: URL {
        tempDir.appendingPathComponent(".encryption_key")
    }

    // MARK: - Keychain is canonical

    func testPrepareKeyUsesKeychainWhenPresent() {
        let store = MockKeyStore()
        let existing = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        store.store(existing)

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "a Keychain-backed key must not create any key file")
    }

    func testFreshGenerationGoesToKeychainNotDisk() {
        let store = MockKeyStore()
        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [])
        XCTAssertEqual(store.stored?.count, 32, "fresh key must be stored in the Keychain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "C1: new keys are never written to the old file path")
    }

    func testKeychainGarbageIsTreatedAsAbsent() {
        let store = MockKeyStore()
        store.store(Data(repeating: 0xFF, count: 10)) // wrong length = unusable

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key, "garbage in Keychain must be replaced by a fresh key")
        XCTAssertEqual(store.stored?.count, 32)
    }

    // MARK: - Legacy file migration

    func testLegacyKeyFileMigratedIntoKeychainThenDeleted() {
        let legacy = Data((0..<32).map { UInt8($0) })
        XCTAssertNoThrow(try legacy.write(to: keyURL))
        let store = MockKeyStore()

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [])
        XCTAssertEqual(store.stored, legacy, "legacy key bytes must move into the Keychain unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "key file must be removed after a verified migration")
    }

    func testMigrationFailureKeepsKeyFileForNextLaunch() throws {
        let legacy = Data((0..<32).map { UInt8($0) })
        try legacy.write(to: keyURL)
        let store = MockKeyStore()
        store.storeResults = [errSecInteractionNotAllowed] // keychain locked

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key, "migration failure must not break the app — the file key still works")
        XCTAssertEqual(recorder.failures, [], "migration fallback is silent (log only), not an alert")
        XCTAssertEqual(try Data(contentsOf: keyURL), legacy, "key file must survive a failed migration")
        let attrs = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600,
                       "retained key file gets owner-only perms as defense in depth")
    }

    // MARK: - Corrupt file (H6 behavior preserved)

    func testCorruptKeyFileQuitLeavesFileUntouched() {
        let corrupt = Data(repeating: 0xAB, count: 10)
        XCTAssertNoThrow(try corrupt.write(to: keyURL))
        let store = MockKeyStore()

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNil(key)
        XCTAssertEqual(recorder.failures, [.corruptExistingKey])
        XCTAssertEqual(try? Data(contentsOf: keyURL), corrupt,
                       "corrupt file must survive when the user quits")
    }

    func testCorruptKeyFileRegenerateStoresFreshKeyInKeychain() {
        let corrupt = Data(repeating: 0xAB, count: 10)
        XCTAssertNoThrow(try corrupt.write(to: keyURL))
        let store = MockKeyStore()

        let recorder = FailureRecorder(actions: [.regenerate])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [.corruptExistingKey])
        XCTAssertEqual(store.stored?.count, 32, "regeneration writes the fresh key to the Keychain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    // MARK: - Storage failure on fresh generation (H6 behavior preserved)

    func testFreshStorageFailureReturnsNilWhenQuit() {
        let store = MockKeyStore()
        store.storeResults = [errSecInteractionNotAllowed]

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNil(key)
        XCTAssertEqual(recorder.failures, [.keyStorageFailed])
    }

    func testFreshStorageFailureRegenerateRetries() {
        let store = MockKeyStore()
        store.storeResults = [errSecInteractionNotAllowed, errSecSuccess] // locked, then unlocked

        let recorder = FailureRecorder(actions: [.regenerate, .quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key, "regenerate must retry the Keychain store")
        XCTAssertEqual(recorder.failures, [.keyStorageFailed])
        XCTAssertEqual(store.stored?.count, 32)
    }

    // MARK: - STOR-1 (2026-07-24 audit): prepareKey must publish to shared cache

    /// STOR-1: prepareKey's success path must populate `shared.cachedLoadedKey`.
    /// Regression: the cache was previously only populated by `getKey()`'s own
    /// first-call path and `loadKeyData()`. If `getKey()` ran and missed (cold
    /// Keychain + no file = fresh install), it latched `keyLoadAttempted = true`,
    /// then `prepareKey()` succeeded silently in the background — and every
    /// subsequent `encrypt()` for the rest of the session returned nil.
    ///
    /// Verified via a public-for-testing cache probe (added alongside the fix
    /// per the audit's "lock is private and not resettable — fixing makes it
    /// testable" note). This avoids `getKey()`'s production-path read of
    /// `CryptoService.keyFileURL` (which would silently inherit state across
    /// tests and risk touching production data per test-never-touch-prod-data).
    func testPrepareKeyPublishesSuccessToSharedCache() throws {
        CryptoService.resetForTesting()
        let store = MockKeyStore() // initially notFound
        let keyData = Data((0..<32).map { UInt8($0) })
        try keyData.write(to: keyURL, options: .atomic)

        XCTAssertFalse(CryptoService.hasCachedKeyForTesting(),
                       "cache should be empty after reset")

        let key = CryptoService.prepareKey(
            keyURL: keyURL,
            keyStore: store,
            failureHandler: { _ in .quit }
        )
        XCTAssertNotNil(key, "prepareKey should migrate the file to the Keychain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "successful migration must remove the legacy key file")
        XCTAssertEqual(store.stored?.count, 32, "Keychain must hold the migrated key")

        XCTAssertTrue(CryptoService.hasCachedKeyForTesting(),
                      "prepareKey's success must populate shared.cachedLoadedKey")

        // Clean up so subsequent tests don't inherit the cached key.
        CryptoService.resetForTesting()
    }

    // MARK: - C-2 (2026-07-24 audit): Keychain locked must not trigger regeneration

    /// C-2: a locked Keychain (errSecInteractionNotAllowed — typical on
    /// launchd-start before first unlock) must NOT fall through to
    /// `generateAndStoreKey`. Doing so would overwrite the user's existing
    /// Keychain item and permanently destroy all encrypted history.
    /// Fix: prepareKey must detect .interactionLocked from loadStatus() and
    /// return nil without touching the store. Next launch (post-unlock) will
    /// load the key normally.
    func testPrepareKeyDoesNotRegenerateWhenKeychainLocked() {
        let store = MockKeyStore()
        store.lockedStatus = .interactionLocked

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNil(key, "locked Keychain must defer key prep, not regenerate")
        XCTAssertEqual(recorder.failures, [], "no user-facing failure when Keychain is locked")
        XCTAssertNil(store.stored, "no Keychain write may occur when locked")
        XCTAssertEqual(store.storeCalls, 0, "store() must never be called when Keychain reports locked")
    }

    // MARK: - P0-1 (2026-07-28 audit): retry prepareKey after Keychain unlocks

    /// P0-1: when prepareKey fails because the Keychain is locked
    /// (errSecInteractionNotAllowed at launchd start), the user must not
    /// be stranded for the rest of the session. After the Keychain
    /// unlocks (login / wake), retryPrepareKeyIfLocked() must succeed.
    func testRetryPrepareKeyIfLockedAfterUnlock() {
        let store = MockKeyStore()
        store.lockedStatus = .interactionLocked

        let recorder = FailureRecorder(actions: [.quit])
        let key1 = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)
        XCTAssertNil(key1, "First attempt should return nil when Keychain is locked")

        // Simulate Keychain becoming accessible (user logs in / wakes)
        store.lockedStatus = nil
        let stored = Data((0..<32).map { UInt8($0 ^ 0xA5) })
        store.store(stored) // store() on success sets stored = keyData

        let key2 = CryptoService.retryPrepareKeyIfLocked(
            keyURL: keyURL, keyStore: store, failureHandler: recorder.handler
        )
        XCTAssertNotNil(key2, "Retry must succeed after Keychain unlocks")
    }

    // MARK: - P0-1 follow-up (2026-07-29)

    /// P0-1 follow-up: .interactionLocked is a retryable state — prepareKey
    /// must NOT post .cryptoKeyPrepared(success:false), because
    /// handleCryptoKeyPrepared treats success:false as terminal and
    /// permanently drops all pendingKeyItems.
    func testPrepareKeyLockedDoesNotPostTerminalFailureNotification() {
        let store = MockKeyStore()
        store.lockedStatus = .interactionLocked

        // Observe the notification — if it fires, the test fails.
        var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: .cryptoKeyPrepared, object: nil, queue: nil
        ) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(token) }

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNil(key, "Locked Keychain must return nil, not a key")
        XCTAssertFalse(posted,
            ".cryptoKeyPrepared must NOT be posted for .interactionLocked — it is retryable, not terminal")
        XCTAssertEqual(recorder.failures, [],
            "No user-facing failure when Keychain is locked")
    }

    /// P0-1 follow-up: verify the full retry lifecycle — locked → retry
    /// nil → unlock → retry success — does not lose data. After the
    /// initial lock, deferred captures must survive until the retry
    /// succeeds; this requires that prepareKey(.interactionLocked) does
    /// NOT post success:false (tested above).
    func testRetryAfterLockedPreservesSessionUntilUnlock() {
        let store = MockKeyStore()
        store.lockedStatus = .interactionLocked

        let recorder = FailureRecorder(actions: [.quit])
        let key1 = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)
        XCTAssertNil(key1, "First attempt returns nil when Keychain is locked")

        // Retry while still locked — must also return nil (not crash, not
        // regenerate). This simulates didWakeNotification firing before the
        // user enters their password.
        let key2 = CryptoService.retryPrepareKeyIfLocked(
            keyURL: keyURL, keyStore: store, failureHandler: recorder.handler
        )
        XCTAssertNil(key2, "Retry while still locked must return nil")
        XCTAssertEqual(store.storeCalls, 0,
            "store() must never be called when Keychain reports locked")

        // Now the user unlocks — Keychain becomes accessible.
        store.lockedStatus = nil
        let stored = Data((0..<32).map { UInt8($0 ^ 0xA5) })
        store.store(stored)

        let key3 = CryptoService.retryPrepareKeyIfLocked(
            keyURL: keyURL, keyStore: store, failureHandler: recorder.handler
        )
        XCTAssertNotNil(key3, "Retry must succeed after Keychain unlocks")
        XCTAssertTrue(CryptoService.hasCachedKeyForTesting(),
            "Success must populate the shared cache so getKey() works thereafter")
    }

    /// P0-1: retry is a no-op when the key is already loaded — does not
    /// re-store or trigger failure paths. This is what makes the wake /
    /// unlock observer safe to fire on every system event.
    func testRetryPrepareKeyIfLockedIsNoopWhenKeyAlreadyLoaded() {
        let store = MockKeyStore()
        let existing = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        store.store(existing)

        let recorder = FailureRecorder(actions: [.quit])
        let key1 = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)
        XCTAssertNotNil(key1)

        let storeCallsBefore = store.storeCalls
        let key2 = CryptoService.retryPrepareKeyIfLocked(
            keyURL: keyURL, keyStore: store, failureHandler: recorder.handler
        )
        XCTAssertNotNil(key2, "Retry on loaded key must return the key")
        XCTAssertEqual(store.storeCalls, storeCallsBefore,
                       "Retry must not re-store when key is already loaded")
    }

    // MARK: - ID-CRYPTO-0001 (2026-07-31 audit): transient Keychain error must not regenerate

    /// A transient Keychain error (.otherError — errSecAuthFailed,
    /// errSecServiceNotAvailable, ...) must be treated like .interactionLocked:
    /// return nil, touch nothing, wait for the wake retry. Previously it fell
    /// through to the not-found path and could overwrite a valid root key,
    /// permanently destroying all encrypted history.
    func testPrepareKeyDoesNotRegenerateOnTransientKeychainError() {
        let store = MockKeyStore()
        store.lockedStatus = .otherError(errSecAuthFailed)
        // A legacy file on disk must also survive — it may be the only
        // remaining copy of the key material.
        let legacy = Data((0..<32).map { UInt8($0) })
        XCTAssertNoThrow(try legacy.write(to: keyURL))

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNil(key, "transient Keychain error must defer key prep, not regenerate")
        XCTAssertEqual(recorder.failures, [], "no user-facing failure for a transient Keychain error")
        XCTAssertEqual(store.storeCalls, 0, "store() must never be called on a transient Keychain error")
        XCTAssertEqual(try? Data(contentsOf: keyURL), legacy,
                       "legacy key file must survive a transient Keychain error")
    }

    /// Recovery path: after the transient error clears, the retry must pick
    /// up the real Keychain item (no regeneration happened in between).
    func testRetrySucceedsAfterTransientKeychainErrorClears() {
        let store = MockKeyStore()
        store.lockedStatus = .otherError(errSecServiceNotAvailable)

        let recorder = FailureRecorder(actions: [.quit])
        let key1 = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)
        XCTAssertNil(key1)

        store.lockedStatus = nil
        let existing = Data((0..<32).map { UInt8($0 ^ 0xA5) })
        store.store(existing)

        let key2 = CryptoService.retryPrepareKeyIfLocked(
            keyURL: keyURL, keyStore: store, failureHandler: recorder.handler
        )
        XCTAssertNotNil(key2, "retry must load the existing key once the transient error clears")
        XCTAssertEqual(recorder.failures, [])
    }

    // MARK: - ID-CRYPTO-0003 (2026-07-31 audit): Keychain-hit path cleans up legacy file

    /// When the Keychain already holds a valid key, a lingering pre-C1
    /// plaintext key file (from an interrupted/failed migration) must be
    /// removed idempotently instead of sitting on disk forever.
    func testKeychainHitRemovesLingeringLegacyKeyFile() {
        let store = MockKeyStore()
        let existing = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        store.store(existing)
        let legacy = Data((0..<32).map { UInt8($0) })
        XCTAssertNoThrow(try legacy.write(to: keyURL))

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "Keychain-hit path must remove the lingering legacy key file")
    }

    // MARK: - ID-CRYPTO-0002 (2026-07-31 audit): secure erase overwrites in place

    /// `.atomic` writes are temp-file + rename, leaving the original key
    /// blocks untouched in unallocated space. The overwrite must happen on
    /// the same inode: a hard-link alias observes the SAME blocks, so after
    /// secure removal it must see random bytes, not the original key.
    func testSecureRemoveKeyFileOverwritesOriginalBlocksInPlace() throws {
        let original = Data((0..<32).map { UInt8($0) })
        try original.write(to: keyURL)
        let aliasURL = tempDir.appendingPathComponent("key-alias")
        try FileManager.default.linkItem(at: keyURL, to: aliasURL) // hard link = same inode

        CryptoService.secureRemoveKeyFile(at: keyURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "key file must be unlinked after secure removal")
        let aliasData = try Data(contentsOf: aliasURL)
        XCTAssertEqual(aliasData.count, 32)
        XCTAssertNotEqual(aliasData, original,
                          "in-place overwrite must clobber the original blocks (alias sees the same inode)")
    }

    // MARK: - ID-CRYPTO-0004 (2026-07-31 audit): shared key-material zeroing helper

    func testWipeKeyMaterialZeroesAllBytes() {
        var keyData = Data((0..<32).map { UInt8($0 | 0x01) }) // no accidental zeros
        CryptoService.wipeKeyMaterial(&keyData)
        XCTAssertEqual(keyData, Data(count: 32), "every byte of the key copy must be zeroed")

        var empty = Data()
        CryptoService.wipeKeyMaterial(&empty) // must not crash on empty buffers
        XCTAssertEqual(empty.count, 0)
    }
}
