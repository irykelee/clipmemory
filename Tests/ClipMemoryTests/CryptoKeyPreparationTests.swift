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
}
