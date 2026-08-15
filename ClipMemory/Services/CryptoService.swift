import Foundation
import AppKit
import CryptoKit
import CommonCrypto
import Security
import os.log

extension Notification.Name {
    /// H-2 (2026-07-25 audit): posted once `CryptoService.prepareKey()` has
    /// finished, regardless of success or failure. Observers (e.g.
    /// ClipboardStore's deferred-capture queue) can flush pending items when
    /// the key becomes available, or drop them and surface an error when key
    /// preparation definitively failed.
    static let cryptoKeyPrepared = Notification.Name("CryptoService.keyPrepared")
}

/// Why the app encryption key could not be prepared (H6).
enum CryptoKeyFailure {
    /// Key file exists but is unreadable or not 32 bytes. Regenerating
    /// makes all existing encrypted history undecryptable.
    case corruptExistingKey
    /// SecRandomCopyBytes failed; no key material can be created.
    case secureRandomUnavailable
    /// Key generated but could not be written to disk.
    case keyStorageFailed
}

/// User decision after a `CryptoKeyFailure`.
enum KeyFailureAction {
    /// (Re)generate the key. For a corrupt key this accepts data loss.
    case regenerate
    /// Quit the app. The default handler performs the termination.
    case quit
}

/// P0-2: 搜索路径解密结果分类。让调用方区分"瞬态" vs "永久"失败，
/// 是修 MF-2 潜伏 bug（瞬态锁永久标记条目不可解密）的关键。
enum DecryptResult: Equatable {
    case success(String)
    case keyUnavailable      // 瞬态：getKey() == nil，等 prepareKey 后重试
    case dataCorrupted       // 永久：AES-GCM tag 失败 / legacy HMAC 不匹配
    case internalError       // 永久：标称加密但结构不可解析（不变量 violation）

    var isTransient: Bool {
        if case .keyUnavailable = self { return true }
        return false
    }
}

/// Encryption format versions:
/// - v2 (current): "v2" prefix + AES-GCM sealed box (nonce + ciphertext + tag)
/// - v1 (legacy): AES-CBC + HMAC-SHA256, no prefix, for backwards compatibility
/// - pre-1.2.0 (AES-CBC without HMAC) is REJECTED (C4): unauthenticated CBC is
///
/// ID-DOCS-0005 (LOW §50.12 audit cross-reference, 2026-08-15):
/// NIST AES-GCM and RFC 4231 HMAC test vectors are NOT integrated.
/// The v2 AES-GCM path is verified by roundtrip tests
/// (`CryptoServiceTests.testEncryptDecryptRoundTrip*`) and the legacy
/// HMAC path by `testLegacyV1Decryption`; both are property-based on
/// real ClipboardItem fixtures, not on the canonical NIST/RFC vectors.
/// Adding the official vectors is a LOW-priority backlog item —
/// a future commit can drop the vectors into a `vectors/` directory
/// and add a parametrized test that runs them.
///   a padding-oracle / tampering hole for anyone who can write UserDefaults.
class CryptoService: CryptoServiceProtocol {
    static let shared = CryptoService()

    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "CryptoService")

    // P0-2: 否定缓存。keyUnavailable 永不写入（瞬态）。
    private static let negativeCacheLock = NSLock()
    private static var negativeCache: [String: (DecryptResult, Date)] = [:]
    private static let negativeCacheTTL: TimeInterval = 60
    // ID-PERF-0003 (2026-07-30 audit): cap negativeCache size to bound memory.
    // Lazy TTL eviction (decryptWithReason:644) only fires on hit; without a
    // cap, 10K corrupted items would leave ~800 KB resident. 1000 entries
    // ≈ 80 KB worst case while keeping recently-seen failures cacheable.
    private static let negativeCacheMaxSize = 1000

    // NEW-6 (2026-08-03 audit): the `_negativeCacheClock` test-injection
    // hook (formerly at :70-73) was a dead interface — no setter ever
    // existed, so the variable always evaluated `Date()`, paying 2 extra
    // lock/unlock round-trips per cache lookup for nothing. Removed
    // along with the matching lock. The `cachedNegativeResult(forKey:)`
    // and `cacheAndReturn(_:key:)` readers now use `Date()` directly;
    // if a future TTL test needs a fake clock, re-introduce it through
    // a properly-typed test seam (e.g. a protocol) rather than a bare
    // `var () -> Date`.

    // H-2 (2026-07-21 audit fix): Cache the loaded Keychain/file key so
    // subsequent encrypt/decrypt skip the Keychain round-trip (~1–10ms each).
    // Without this, list rendering triggered N Keychain queries per uncached
    // item, pinning the main thread.
    //
    // Threading: protect with NSLock — encrypt/decrypt are called from both
    // main thread (`getDecryptedContent`) and background queues
    // (`ImageStorage.backgroundQueue → encryptData`). Unchecked read+write
    // of a `var` from multiple threads is undefined behavior. Originally
    // OSAllocatedUnfairLock but C-1 (2026-07-24 audit) flagged it as
    // macOS 14+ only; this is a near-zero-contention read-mostly path so
    // NSLock has no measurable cost.
    //
    // Invariants:
    // - Only populated when `customKey` is nil (shared instance, app key).
    // - custom-key instances (init(customKeyData:)) never populate this.
    // - `prepareKey` resets customKey on regenerate and reloads into the cache.
    private let cachedLoadedKeyLock = NSLock()
    private var cachedLoadedKey: SymmetricKey?
    /// H-2 (2026-07-24 audit): once the first load attempt completes — success
    /// OR failure — this flips to true and `getKey()` returns nil on a cache
    /// miss instead of re-querying the Keychain / key file. Without this, a
    /// transient Keychain state (.interactionLocked pre-unlock, missing key
    /// file, deleted item) would trigger one Keychain round-trip per
    /// encrypt/decrypt call (1–10ms each), pinning the main thread.
    /// Recovery requires process restart — intentional: the prepared-key
    /// path already surfaces a user-visible alert on the same conditions.
    private var keyLoadAttempted = false

    private func withCachedLoadedKey<R>(_ block: () throws -> R) rethrows -> R {
        cachedLoadedKeyLock.lock()
        defer { cachedLoadedKeyLock.unlock() }
        return try block()
    }

    /// ID-SECURITY-0001 (2026-07-30 audit): wipe the in-memory root key
    /// when the app loses focus / locks / suspends so a memory-dump attack
    /// on a suspended process can't recover raw key bytes (hibernate /
    /// RAM disk image). Safe to call any time — `getKey()` already
    /// re-loads from Keychain on demand when `cachedLoadedKey == nil`,
    /// so the next foreground operation transparently re-prepares.
    /// Also resets `keyLoadAttempted` so a transient Keychain state at
    /// the next foreground (`.interactionLocked` pre-unlock) gets a
    /// fresh attempt instead of the cached failure.
    ///
    /// ID-CRYPTO-0004 (2026-07-31 audit): `SymmetricKey` exposes no
    /// mutable-bytes API, so the cached key itself can only be dropped —
    /// best-effort. The transient raw `Data` copies that fed it CAN be
    /// zeroed, and every such path now routes through the shared
    /// `wipeKeyMaterial` helper (generate/migration paths here, package-key
    /// path in BackupPackage) so the zeroing behavior is consistent.
    func clearInMemoryKey() {
        withCachedLoadedKey {
            cachedLoadedKey = nil
            keyLoadAttempted = false
        }
    }

    /// ID-CRYPTO-0004 (2026-07-31 audit): single best-effort zeroing helper
    /// for transient key-material `Data` copies, shared by every path that
    /// handles raw key bytes (previously each path zeroed differently — or
    /// not at all — so sensitive bytes could linger in freed heap memory).
    static func wipeKeyMaterial(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress, !ptr.isEmpty else { return }
            memset(base, 0, ptr.count)
        }
    }

    /// Legacy key file location (pre-C1). Still consulted as a read-only
    /// fallback and migrated into the Keychain by `prepareKey`; new keys
    /// are never written here. Exposed for ImageStorage migration.
    static var keyFileURL: URL {
        let appSupport = AppDirectories.applicationSupport
        let dir = appSupport.appendingPathComponent("ClipMemory", isDirectory: true)
        // ID-SILENT-0012 + ID-SECURITY-0005 (2026-07-30 audit):
        // surface both directory-creation failures AND enforce 0o700
        // on the parent (defense-in-depth; image-dir fix in commit 4df9fd7
        // only covered ImageStorage). `try?` previously swallowed both
        // signals — first-time launch on a locked-down host would silently
        // fall back to Keychain with a world-readable parent dir.
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Don't crash — Keychain read path takes over on first launch.
            // But log loud so the operator sees it.
            NSLog("ClipMemory: failed to prepare key-file parent dir at %@: %@", dir.path, error.localizedDescription)
        }
        return dir.appendingPathComponent(".encryption_key")
    }

    /// S1 (2026-07-29 audit): securely erase a key file before deletion.
    /// Overwrites the file with random data before unlinking to prevent
    /// recovery of the plaintext root key from unallocated disk blocks.
    /// Internal (not private) so tests can verify the in-place overwrite
    /// (ID-CRYPTO-0002 regression test).
    static func secureRemoveKeyFile(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            let fileSize = (attrs[.size] as? UInt64) ?? 0
            if fileSize > 0 {
                var random = Data(count: Int(fileSize))
                random.withUnsafeMutableBytes { ptr in
                    _ = SecRandomCopyBytes(kSecRandomDefault, Int(fileSize), ptr.baseAddress!)
                }
                // ID-CRYPTO-0002 (2026-07-31 audit): the previous
                // `random.write(to: url, options: .atomic)` was temp-file +
                // rename — the ORIGINAL key blocks were never overwritten,
                // so the claimed "prevent recovery from unallocated disk
                // blocks" guarantee did not hold. Overwrite in place on the
                // same inode via FileHandle + synchronize instead.
                let handle = try FileHandle(forWritingTo: url)
                do {
                    try handle.write(contentsOf: random)
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
            }
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Failed to securely remove key file: \(error.localizedDescription)")
            try? fileManager.removeItem(at: url)
        }
    }

    /// E1 (2026-07-29 audit): read the legacy key file with explicit error
    /// handling so transient IO errors (permissions, disk hiccup) are logged
    /// and distinguished from "file does not exist", instead of both
    /// collapsing to nil via `try?`.
    private static func readKeyFile(at url: URL, caller: String) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            let domain = nsError.domain
            let code = nsError.code
            if domain == NSCocoaErrorDomain && code == NSFileReadNoSuchFileError {
                return nil
            }
            logger.error("[\(caller, privacy: .public)] Key file read error (domain=\(domain, privacy: .public) code=\(code, privacy: .public)): \(nsError.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// When set (import/test instances), this key is used instead of the app key.
    private let customKey: SymmetricKey?

    /// True under XCTest. Tests never touch the real Keychain: prepareKey's
    /// migration is skipped (test-never-touch-prod-data) and key reads stay
    /// on the legacy file — the test runner is a different binary, so
    /// querying the production Keychain item could trigger an ACL prompt.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private init() {
        customKey = nil
        if Self.isRunningTests {
            Self.prepareLegacyFileKeyForTests()
        } else {
            // M-2 (2026-07-24 audit): defer prepareKey to a background task so
            // the first access to `CryptoService.shared` doesn't block on a
            // Keychain round-trip (~1–10ms) + ACL check + file migration.
            // `getKey()` independently loads from Keychain/keyfile via the
            // cache, so callers don't need to wait for migration before
            // encrypting — `prepareKeyIfNeeded()` is the explicit async
            // barrier for callers that care (tests asserting the file is
            // gone, etc.).
            Task.detached(priority: .utility) {
                _ = Self.prepareKey()
            }
        }
    }

    /// Instance operating on an explicit key rather than the app key.
    /// Used by BackupPackage to decrypt package data with the source machine's
    /// key and re-encrypt with the local one during import.
    init(customKeyData: Data) {
        customKey = SymmetricKey(data: customKeyData)
    }

    /// Exposes the custom key bytes for test fixtures. Tests that call this
    /// must initialize CryptoService with customKeyData.
    func exportKeyDataForTesting() -> Data {
        guard let key = customKey else {
            fatalError("CryptoService was not initialized with customKeyData; test fixtures require it")
        }
        return key.withUnsafeBytes { Data($0) }
    }

    /// Raw key bytes of the app key (needed to embed into export packages).
    /// H-2: routes through the in-memory cache when available, so the
    /// BackupPackage export path does not also hit the Keychain.
    /// BUG-018 (2026-07-21): also writes back to cache on miss so
    /// subsequent calls (e.g. multiple BackupPackage exports in one
    /// session) don't re-query the Keychain each time.
    /// B-7 (2026-07-27): mirror the `getKey()` nil-check guard — never
    /// overwrite a populated cache. Today both paths always write the same
    /// bytes (the Keychain is the canonical store and the file is just a
    /// migration source), so there is no observed bug — but the foot-gun
    /// is real if a future code path generates a different key on demand.
    static func loadKeyData() -> Data? {
        if let cached = shared.withCachedLoadedKey({ shared.cachedLoadedKey }) {
            return cached.withUnsafeBytes { Data($0) }
        }
        let keyData: Data?
        if !isRunningTests, let data = KeychainKeyStore().load(), data.count == 32 {
            keyData = data
        } else {
            keyData = readKeyFile(at: keyFileURL, caller: "loadKeyData")
        }
        if let keyData, keyData.count == 32 {
            shared.withCachedLoadedKey {
                if shared.cachedLoadedKey == nil {
                    shared.cachedLoadedKey = SymmetricKey(data: keyData)
                }
            }
        }
        return keyData
    }

    /// XCTest only: many fixtures are built against the key file's bytes, so
    /// tests need a stable file key. Ensures one exists (atomic temp write,
    /// 0o600) without ever touching the Keychain. Failures are logged only —
    /// affected tests then fail loudly on their own.
    private static func prepareLegacyFileKeyForTests() {
        let keyURL = keyFileURL
        if let existing = try? Data(contentsOf: keyURL), existing.count == 32 { return }
        var keyData = Data(count: 32)
        // ID-CRYPTO-0004 (2026-07-31 audit): zero the transient raw-key
        // copy on every exit path via the shared helper.
        defer { wipeKeyMaterial(&keyData) }
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            logger.error("Tests: failed to generate random key bytes")
            return
        }
        let tempURL = keyURL.appendingPathExtension("tmp")
        do {
            try keyData.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            try FileManager.default.moveItem(at: tempURL, to: keyURL)
        } catch {
            logger.error("Tests: failed to store key file: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Called instead of crashing when the app key cannot be prepared (H6).
    /// HIGH-3 (2026-07-26 review): pluggable key-failure alert presenter.
    /// The default calls `presentKeyFailureAlert` on the CryptoService (legacy
    /// behavior). Set from AppDelegate in `applicationDidFinishLaunching` to
    /// relocate the AppKit dependency (NSAlert, NSApp.terminate) out of the
    /// service layer. Tests can replace the broader `keyFailureHandler` instead
    /// (see below).
    static var keyFailureAlertPresenter: (CryptoKeyFailure) -> KeyFailureAction = {
        presentKeyFailureAlert($0)
    }

    /// H-2 / C-2 (2026-07-25 audit): test-injectable handler for key
    /// preparation failures. Defaults to calling `defaultKeyFailureHandler`
    /// which blocks the caller until the user chooses an action (or 5s timeout).
    /// Tests replace this to return .quit or .regenerate without showing UI.
    static var keyFailureHandler: (CryptoKeyFailure) -> KeyFailureAction = { failure in
        CryptoService.defaultKeyFailureHandler(failure)
    }

    /// M-2 (2026-07-24 audit): async barrier for the one-time prepareKey
    /// migration. Awaitable from any task; production encrypt/decrypt paths
    /// don't need to wait — `getKey()` reads from Keychain/keyfile directly
    /// via the cache. Use this when a caller must observe migration
    /// completion (e.g. tests asserting the legacy key file has been
    /// removed, or a startup path that wants Keychain canonicality before
    /// the first encrypt).
    static func prepareKeyIfNeeded() async {
        _ = Self.prepareKey()
    }

    /// STOR-1 (2026-07-24 audit): clear the shared in-memory cache + latch
    /// so a test can exercise the prepareKey/getKey race deterministically.
    /// Production code never calls this — init's `Task.detached { prepareKey() }`
    /// runs exactly once per process, after which the cache is the source of
    /// truth until the next process launch.
    static func resetForTesting() {
        shared.withCachedLoadedKey {
            shared.cachedLoadedKey = nil
            shared.keyLoadAttempted = false
        }
    }

    /// P0-2 (2026-07-28): test-only hook to simulate "key load attempted but
    /// still no key" without touching the user's prod key file. Sets
    /// `keyLoadAttempted = true` so `getKey()` short-circuits to nil on the
    /// next call without reading `keyFileURL`. Lets tests exercise the
    /// `.keyUnavailable` branch when the prod key file is present.
    /// Mirrors `resetForTesting()`'s pattern (XCTest-only, production never
    /// calls).
    static func simulateKeyLoadAttemptedForTesting() {
        shared.withCachedLoadedKey {
            shared.cachedLoadedKey = nil
            shared.keyLoadAttempted = true
        }
    }

    /// STOR-1 (2026-07-24 audit): test-only probe for `cachedLoadedKey`.
    /// Avoids routing through `getKey()` (which reads the production
    /// `keyFileURL` and would leak state across tests). Returns true iff
    /// `prepareKey` (or `loadKeyData` on cache miss) has populated the cache
    /// at least once this process.
    static func hasCachedKeyForTesting() -> Bool {
        shared.withCachedLoadedKey { shared.cachedLoadedKey } != nil
    }

    /// ID-CRYPTO-0005 (2026-08-01 audit): test-only probe for the negative
    /// cache size, so tests can prove a failure path actually WROTE an entry
    /// (result-equality alone can't distinguish a cache hit from a re-run —
    /// both return the same reason).
    static func negativeCacheCountForTesting() -> Int {
        negativeCacheLock.lock()
        defer { negativeCacheLock.unlock() }
        return negativeCache.count
    }

    /// Prepares the app key: Keychain first, then one-time migration of the
    /// pre-C1 key file, then fresh generation into the Keychain (C1).
    /// A corrupt key file is never silently overwritten (H6): the failure
    /// handler decides whether to regenerate — accepting that existing
    /// history becomes undecryptable — or quit.
    /// - Returns: the key when available; nil only when a custom failure
    ///   handler declined to regenerate (the default handler quits the app
    ///   in that case, so production never silently runs keyless).
    @discardableResult
    static func prepareKey(
        keyURL: URL = CryptoService.keyFileURL,
        keyStore: KeyStoring = KeychainKeyStore(),
        failureHandler: (CryptoKeyFailure) -> KeyFailureAction = CryptoService.keyFailureHandler
    ) -> SymmetricKey? {
        // 1. Keychain is the canonical store.
        // C-2 (2026-07-24 audit): distinguish locked Keychain from "not found".
        // Pre-fix, any non-success SecItemCopyMatching status (including
        // errSecInteractionNotAllowed at pre-unlock launchd start) collapsed
        // to nil, then fell through to generateAndStoreKey — overwriting the
        // user's real key and permanently destroying all encrypted history.
        switch keyStore.loadStatus() {
        case .found(let data) where data.count == 32:
            // ID-CRYPTO-0003 (2026-07-31 audit): a pre-C1 plaintext key file
            // can linger on disk from an interrupted/failed migration even
            // when the Keychain item is healthy. Remove it idempotently on
            // this path too (secureRemoveKeyFile no-ops when absent) so the
            // plaintext root key does not sit on disk forever.
            secureRemoveKeyFile(at: keyURL)
            return publishToSharedCache(SymmetricKey(data: data))
        case .found:
            logger.error("Keychain contains invalid key (not 32 bytes); treating as absent")
            // fall through to file migration / fresh generation
        case .interactionLocked:
            // P0-1 follow-up (2026-07-29): .interactionLocked is retryable — do
            // NOT post .cryptoKeyPrepared(success:false). Posting a terminal
            // failure here would cause handleCryptoKeyPrepared to permanently
            // drop all pendingKeyItems, losing clipboard captures that arrive
            // between the initial failure and the retry success. The retry
            // (retryPrepareKeyIfLocked) fires on wake / session-become-active,
            // and publishToSharedCache posts success:true when it succeeds.
            // Meanwhile, getKey() independently loads from Keychain/file via
            // its own short-circuit, so encrypt/decrypt don't depend on this
            // notification to start working.
            logger.error("Keychain interaction not allowed (locked); deferring key prep until unlock")
            return nil
        case .notFound:
            break // fall through to file migration / fresh generation
        case .otherError(let status):
            // ID-CRYPTO-0001 (2026-07-31 audit): transient Keychain errors
            // (errSecAuthFailed, errSecServiceNotAvailable, ...) previously
            // collapsed into the not-found path — a flaky read could then
            // trigger regeneration and SecItemUpdate would overwrite the
            // valid root key, permanently destroying all encrypted history.
            // Treat exactly like .interactionLocked: log, return nil, wait
            // for the wake retry (retryPrepareKeyIfLocked). Only a
            // definitive .notFound may migrate / generate.
            logger.error("Keychain load failed (OSStatus \(status, privacy: .public)); deferring key prep to avoid overwriting a possibly-valid root key")
            return nil
        }
        // 2. Migrate a pre-C1 key file, then remove it.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: keyURL.path) {
            // E1 (2026-07-29 audit): distinguish "file exists but unreadable"
            // (transient IO/permission error — keep file, do not alert) from
            // "read succeeded but wrong format" (corrupt — alert user).
            let keyData = readKeyFile(at: keyURL, caller: "prepareKey")
            if let keyData, keyData.count == 32 {
                if keyStore.store(keyData) == errSecSuccess, keyStore.load() == keyData {
                    secureRemoveKeyFile(at: keyURL)
                } else {
                    logger.error("Keychain migration failed; keeping key file until next launch")
                    // ID-SILENT-0013 (2026-07-30 audit): `try?` previously
                    // swallowed chmod failures — if the file already
                    // existed at 0o644 (typical world-readable), the key
                    // would stay that way until the next successful
                    // migration. Replace with explicit do/catch + log.
                    do {
                        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
                    } catch {
                        logger.error("Failed to chmod legacy key file to 0o600: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return publishToSharedCache(SymmetricKey(data: keyData))
            }
            // E1: nil from readKeyFile after fileExists confirmed → transient
            // read error (already logged by readKeyFile). Keep the file and
            // treat as "key preparation deferred" rather than "corrupt".
            if keyData == nil {
                logger.warning("Key file exists but could not be read; deferring key prep until next launch")
                return nil
            }
            // keyData is non-nil but count != 32 → genuinely corrupt.
            // Corrupt or tampered key file — ask before destroying it.
            guard failureHandler(.corruptExistingKey) == .regenerate else {
                notifyKeyPreparationFailed()
                return nil
            }
            secureRemoveKeyFile(at: keyURL)
        }
        // 3. Fresh generation into the Keychain.
        return generateAndStoreKey(to: keyStore, failureHandler: failureHandler)
    }

    /// P0-1 (2026-07-28 audit): retry prepareKey after a Keychain unlock
    /// event. The previous behavior stranded the user for the whole session
    /// when prepareKey failed with `.interactionLocked` (login + Keychain
    /// locked at launchd start). The retry is idempotent — if the key is
    /// already loaded, it returns the cached key without re-prep work.
    /// Wire from `NSWorkspace.didWakeNotification` (system wake) or login
    /// unlock notifications so the session self-heals without restart.
    @discardableResult
    static func retryPrepareKeyIfLocked(
        keyURL: URL = CryptoService.keyFileURL,
        keyStore: KeyStoring = KeychainKeyStore(),
        failureHandler: (CryptoKeyFailure) -> KeyFailureAction = CryptoService.keyFailureHandler
    ) -> SymmetricKey? {
        // Idempotency check: if the cache already holds a key, this is a
        // no-op. Lets the wake observer fire on every system event without
        // re-running the prep pipeline.
        guard shared.withCachedLoadedKey({ shared.cachedLoadedKey }) == nil else {
            return shared.withCachedLoadedKey { shared.cachedLoadedKey }
        }
        return prepareKey(keyURL: keyURL, keyStore: keyStore, failureHandler: failureHandler)
    }

    /// STOR-1 (2026-07-24 audit): prepareKey's success path must publish the
    /// key to the shared cache + set the latch, otherwise getKey()'s prior
    /// miss (which latched `keyLoadAttempted = true`) would permanently strand
    /// the session keyless. Routes through the same lock as `getKey()`'s own
    /// write (BUG-018) so the invariants live in one place.
    private static func publishToSharedCache(_ key: SymmetricKey) -> SymmetricKey {
        shared.withCachedLoadedKey {
            shared.cachedLoadedKey = key
            shared.keyLoadAttempted = true
        }
        // P0-2 F18: key 重新就绪时清空否定缓存，让陈旧的 dataCorrupted 缓存不压制新解密。
        // keyUnavailable 本来就不入缓存，故无需特殊处理。
        negativeCacheLock.lock()
        negativeCache.removeAll()
        negativeCacheLock.unlock()
        NotificationCenter.default.post(
            name: .cryptoKeyPrepared,
            object: nil,
            userInfo: ["success": true]
        )
        return key
    }

    /// H-2 (2026-07-25 audit): probe used by ClipboardStore.addItem to decide
    /// whether a capture should be deferred because the detached `prepareKey()`
    /// task is still running on first launch.
    static func isKeyLoadAttemptedAndMissing() -> Bool {
        shared.withCachedLoadedKey {
            shared.cachedLoadedKey == nil && shared.keyLoadAttempted
        }
    }

    /// H-2 (2026-07-25 audit): signal that key preparation definitively failed
    /// so any deferred captures can be dropped rather than waiting forever.
    private static func notifyKeyPreparationFailed() {
        NotificationCenter.default.post(
            name: .cryptoKeyPrepared,
            object: nil,
            userInfo: ["success": false]
        )
    }

    private static func generateAndStoreKey(
        to keyStore: KeyStoring,
        failureHandler: (CryptoKeyFailure) -> KeyFailureAction
    ) -> SymmetricKey? {
        var keyData = Data(count: 32)
        // ID-CRYPTO-0004 (2026-07-31 audit): zero the transient raw-key
        // copy on every exit path via the shared helper.
        defer { wipeKeyMaterial(&keyData) }
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            logger.error("Failed to generate random key bytes")
            // A CSPRNG failure cannot be fixed by regenerating; the default
            // handler quits the app after alerting. Never fatalError (H6).
            _ = failureHandler(.secureRandomUnavailable)
            notifyKeyPreparationFailed()
            return nil
        }
        let status = keyStore.store(keyData)
        guard status == errSecSuccess else {
            logger.error("Failed to store encryption key in Keychain: \(status)")
            // Offer regenerate (e.g. keychain was locked) or an informed
            // quit — never crash (H6).
            guard failureHandler(.keyStorageFailed) == .regenerate else {
                notifyKeyPreparationFailed()
                return nil
            }
            return generateAndStoreKey(to: keyStore, failureHandler: failureHandler)
        }
        return publishToSharedCache(SymmetricKey(data: keyData))
    }

    private static func defaultKeyFailureHandler(_ failure: CryptoKeyFailure) -> KeyFailureAction {
        // BUG-017 (2026-07-21): the previous branch used
        // `DispatchQueue.main.sync`, which deadlocks if the calling thread
        // holds a lock that main is waiting for (key failure paths can run
        // while a UI handler is mid-mutation). Replace with an async dispatch
        // + semaphore.wait(timeout:). Caller still blocks until the alert
        // returns, but if main is busy for >5s we surface a forced .quit
        // rather than hang the calling thread indefinitely.
        // HIGH-3 (2026-07-26 review): alert presentation delegates to
        // `keyFailureAlertPresenter` so AppDelegate can own the NSAlert
        // without changing the semaphore/blocking contract.
        let action: KeyFailureAction
        if Thread.isMainThread {
            action = keyFailureAlertPresenter(failure)
        } else {
            var captured: KeyFailureAction?
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                captured = keyFailureAlertPresenter(failure)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            action = captured ?? .quit
        }
        if action == .quit {
            // Graceful, informed exit instead of fatalError.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return action
    }

    /// Must run on the main thread — callers dispatch.
    private static func presentKeyFailureAlert(_ failure: CryptoKeyFailure) -> KeyFailureAction {
        NSApp.setActivationPolicy(.regular) // LSUIElement app: alert must be visible
        defer { NSApp.setActivationPolicy(.accessory) }
        let alert = NSAlert()
        alert.alertStyle = .critical
        switch failure {
        case .corruptExistingKey:
            alert.messageText = L10n.alertKeyCorruptTitle
            alert.informativeText = L10n.alertKeyCorruptMessage
            // Quit is the default button — a Return-key accident must never
            // destroy the user's history.
            alert.addButton(withTitle: L10n.quitApp)
            alert.addButton(withTitle: L10n.alertKeyButtonReset)
        case .secureRandomUnavailable:
            alert.messageText = L10n.alertKeyRandomTitle
            alert.informativeText = L10n.alertKeyRandomMessage
            alert.addButton(withTitle: L10n.quitApp)
        case .keyStorageFailed:
            alert.messageText = L10n.alertKeyStorageTitle
            alert.informativeText = L10n.alertKeyStorageMessage
            alert.addButton(withTitle: L10n.quitApp)
            alert.addButton(withTitle: L10n.alertKeyButtonRetry)
        }
        let response = alert.runModal()
        if failure == .secureRandomUnavailable { return .quit }
        return response == .alertSecondButtonReturn ? .regenerate : .quit
    }

    private func getKey() -> SymmetricKey? {
        if let customKey { return customKey }
        // H-2 (2026-07-24 audit): snapshot cache state under the lock so we
        // can short-circuit on repeated misses without re-querying Keychain.
        // Set on first encounter (customKey bypass — `keyLoadAttempted` does
        // not apply to the custom-key fast path).
        let (cached, attempted) = withCachedLoadedKey {
            (cachedLoadedKey, keyLoadAttempted)
        }
        if let cached { return cached }
        if attempted { return nil }
        // C1: Keychain is canonical; the pre-C1 key file remains a read-only
        // fallback until prepareKey's migration removes it. Under XCTest,
        // read only the file — never prompt for the real Keychain item.
        let loaded: SymmetricKey?
        if !Self.isRunningTests, let data = KeychainKeyStore().load(), data.count == 32 {
            loaded = SymmetricKey(data: data)
        } else if let keyData = Self.readKeyFile(at: Self.keyFileURL, caller: "getKey"), keyData.count == 32 {
            loaded = SymmetricKey(data: keyData)
        } else {
            loaded = nil
        }
        // M-3 (2026-07-25 audit): while we were doing I/O, the detached
        // `prepareKey()` task may have generated/successfully migrated a key
        // and populated the cache. Never overwrite a now-populated cache with
        // our (possibly stale) nil/missing result; only record the miss if the
        // cache is still empty. The latch still flips so repeated calls skip
        // the expensive Keychain/disk round-trip.
        return withCachedLoadedKey {
            if cachedLoadedKey == nil {
                cachedLoadedKey = loaded
            }
            keyLoadAttempted = true
            return cachedLoadedKey
        }
    }

    // MARK: - Public API

    /// Encrypts string using AES-GCM (v2 format). Returns base64 encoded string with "v2" prefix.
    func encrypt(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        return encryptBytes(Array(data)).map { $0.base64EncodedString() }
    }

    /// Encrypts raw Data (for images) using AES-GCM (v2 format).
    func encryptData(_ data: Data) -> Data? {
        return encryptBytes(Array(data))
    }

    /// Decrypts base64 string. Automatically detects format (v2 or legacy).
    func decrypt(_ base64String: String) -> String? {
        guard let combined = Data(base64Encoded: base64String) else {
            return nil
        }
        guard let bytes = decryptBytes(from: combined) else {
            return nil
        }
        guard let result = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        return result
    }

    /// P0-2: 单 chokepoint 分类解密。NR4 否定缓存仅 .dataCorrupted / .internalError 写入，
    /// .keyUnavailable 永不缓存（瞬态）。调用方按 isEncrypted 分支。
    func decryptWithReason(_ base64String: String, itemID: UUID) -> DecryptResult {
        // 1. key 就绪检查
        guard getKey() != nil else { return .keyUnavailable }

        // ID-CRYPTO-0005 (2026-08-01 audit): base64 解码失败路径此前直接
        // return .internalError，不写否定缓存，与 spec NR4（.internalError →
        // 缓存 60s）及其余失败路径不一致。解码失败时 `combined` 不存在，
        // 无法复用 `itemID:sha256(combined)` key —— 该路径改用对原始输入
        // 字符串的哈希作 key，并在解码前先做前置查询（下方第 3 步仍保留
        // combined 哈希 key 的查询，成功路径缓存命中行为不变）。
        let rawCacheKey = "\(itemID):\(Self.sha256Hex(Data(base64String.utf8)))"
        if let cached = Self.cachedNegativeResult(forKey: rawCacheKey) {
            return cached
        }

        // 2. base64 解码
        guard let combined = Data(base64Encoded: base64String) else {
            return Self.cacheAndReturn(.internalError, key: rawCacheKey)
        }

        // 3. 否定缓存检查（读时懒淘汰, F8, P9 NSLock 包裹）
        let cacheKey = "\(itemID):\(Self.sha256Hex(combined))"
        if let cached = Self.cachedNegativeResult(forKey: cacheKey) {
            return cached
        }

        // 4. 实际解密（走现有 decryptBytes 但用 isOldFormat 区分 v2/legacy 分流 reason）
        if isOldFormat(base64String) {
            // ID-DEBUG-display (2026-07-30): log legacy decrypt failure to
            // distinguish HMAC mismatch (wrong key) from other errors.
            // Helps diagnose the "main window text rows blank" issue.
            // NEW-5 (2026-08-03 audit): the previous log call also printed
            // the first 20 chars of the base64 ciphertext with
            // `privacy: .public`, which explicitly opts out of os_log's
            // default redaction. ~15 bytes of ciphertext per line still
            // leaks user data (it's a function of the plaintext). The
            // distinguishing diagnostic only needs the key-availability
            // bit; drop the input prefix entirely.
            guard let bytes = decryptBytes(from: combined) else {
                let key = getKey()
                let keyAvail = key != nil ? "key=OK" : "key=nil"
                Self.logger.error("decryptWithReason legacy: decryptBytes returned nil (\(keyAvail, privacy: .public)), inputLength=\(combined.count, privacy: .public)")
                return Self.cacheAndReturn(.dataCorrupted, key: cacheKey)
            }
            guard let result = String(bytes: bytes, encoding: .utf8) else {
                return Self.cacheAndReturn(.internalError, key: cacheKey)
            }
            return .success(result)
        } else {
            // v2 GCM: 复用 decryptV2 但捕获 throw → 分类 authenticationFailure vs 其他
            do {
                let sealedBoxData = combined.dropFirst(2)  // N1 关键：剥 2 字节 "v2" prefix
                let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
                guard let key = getKey() else { return .keyUnavailable }  // 双重保险
                let decrypted = try AES.GCM.open(sealedBox, using: key)
                guard let result = String(bytes: decrypted, encoding: .utf8) else {
                    return Self.cacheAndReturn(.internalError, key: cacheKey)
                }
                return .success(result)
            } catch CryptoKitError.authenticationFailure {
                return Self.cacheAndReturn(.dataCorrupted, key: cacheKey)
            } catch {
                return Self.cacheAndReturn(.internalError, key: cacheKey)
            }
        }
    }

    /// 否定缓存查询（读时懒淘汰, F8, P9 NSLock 包裹）。命中且未过期返回
    /// 缓存的 reason；未命中或已过期（懒淘汰后）返回 nil。
    /// ID-CRYPTO-0005 (2026-08-01 audit): extracted from decryptWithReason
    /// so the pre-decode raw-input key and the post-decode combined key
    /// share one lookup path.
    private static func cachedNegativeResult(forKey cacheKey: String) -> DecryptResult? {
        negativeCacheLock.lock()
        let cached = negativeCache[cacheKey]
        negativeCacheLock.unlock()
        guard let (cachedReason, cachedAt) = cached else { return nil }
        // NEW-6 (2026-08-03 audit): `_negativeCacheClock` removed — call
        // `Date()` directly. No-op for correctness; reclaims 1 lock/unlock
        // per cache lookup.
        let now = Date()
        if now.timeIntervalSince(cachedAt) < negativeCacheTTL {
            return cachedReason
        }
        // 过期：懒淘汰
        negativeCacheLock.lock()
        negativeCache.removeValue(forKey: cacheKey)
        negativeCacheLock.unlock()
        return nil
    }

    /// 写否定缓存（仅永久失败）+ 返回 result（P9 + N6 NSLock 包裹）
    private static func cacheAndReturn(_ reason: DecryptResult, key: String) -> DecryptResult {
        // NEW-6 (2026-08-03 audit): `_negativeCacheClock` removed — call
        // `Date()` directly. The negative-cache insert below is the only
        // synchronization point left in this function.
        let now = Date()
        negativeCacheLock.lock()
        // ID-PERF-0003: evict the oldest-timestamp entry before insert when
        // at cap. min(by:) is O(n) but the cache is bounded (1000) so this
        // stays under 100 µs even at the cap.
        if negativeCache.count >= negativeCacheMaxSize,
           let oldest = negativeCache.min(by: { $0.value.1 < $1.value.1 }) {
            negativeCache.removeValue(forKey: oldest.key)
        }
        negativeCache[key] = (reason, now)
        negativeCacheLock.unlock()
        return reason
    }

    /// 计算密文 sha256（hex 编码）
    /// N3: 用 CryptoKit.SHA256 与项目现有 HMAC<SHA256> 同源，零额外 import
    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Decrypts raw Data (for images). Automatically detects format.
    func decryptData(_ combined: Data) -> Data? {
        guard let bytes = decryptBytes(from: combined) else {
            return nil
        }
        return Data(bytes)
    }

    /// Computes a deterministic HMAC-SHA256 hex digest of `string` using the
    /// app's symmetric key. Used for content deduplication; replaces the prior
    /// unsalted SHA256 which acted as an offline dictionary oracle for short
    /// secrets stored in UserDefaults alongside the ciphertext.
    func hmacHex(for string: String) -> String? {
        guard let key = getKey(), let data = string.data(using: .utf8) else {
            return nil
        }
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Encryption (v2: AES-GCM)

    private func encryptBytes(_ bytes: [UInt8]) -> Data? {
        guard let key = getKey() else { return nil }

        do {
            let sealedBox = try AES.GCM.seal(bytes, using: key)
            guard let combined = sealedBox.combined else { return nil }

            // Prepend "v2" format marker
            var result = Data("v2".utf8)
            result.append(combined)
            return result
        } catch {
            Self.logger.error("AES-GCM encryption failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Decryption (v2 and legacy)

    /// Returns nil if decryption fails for any reason.
    /// Tries v2 (AES-GCM) first, then legacy (AES-CBC+HMAC).
    private func decryptBytes(from combined: Data) -> [UInt8]? {
        // Detect format by "v2" prefix
        if combined.count >= 2 && combined.prefix(2) == Data("v2".utf8) {
            let sealedBoxData = combined.dropFirst(2)
            return decryptV2(data: Data(sealedBoxData))
        }
        // Legacy format (no prefix)
        return decryptLegacy(from: combined)
    }

    private func decryptV2(data: Data) -> [UInt8]? {
        guard let key = getKey() else { return nil }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            return Array(decrypted)
        } catch CryptoKitError.authenticationFailure {
            // ID-SILENT-0011 (2026-07-31 audit): GCM tag mismatch = wrong key
            // or tampered/corrupt ciphertext — an EXPECTED, already-classified
            // failure (decryptWithReason maps it to .dataCorrupted). Keep it
            // out of the error stream so the loud log below stays a reliable
            // "something is actually wrong" signal.
            Self.logger.debug("decryptV2 authentication failure (wrong key or corrupt ciphertext)")
            return nil
        } catch {
            // ID-SILENT-0011 (2026-07-30/31 audits): anything else — malformed
            // `SealedBox` (truncation / format drift), CryptoKit parameter
            // errors, framework hiccups — is unexpected and must be visible.
            // The error message is privacy-safe (no plaintext content).
            Self.logger.error("decryptV2 unexpected error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Legacy Decryption (AES-CBC+HMAC, pre-v2 format)

    /// Returns true if the given base64 string uses the legacy (pre-v2) format.
    /// C4: strict byte-prefix check only. v2 payloads are self-describing ("v2"
    /// marker); anything without the marker is treated as legacy. Decryption
    /// success is never used as a classifier — that gave a UserDefaults-writing
    /// attacker a v2/legacy oracle for free.
    func isOldFormat(_ base64String: String) -> Bool {
        guard let combined = Data(base64Encoded: base64String) else { return false }
        return !(combined.count >= 2 && combined.prefix(2) == Data("v2".utf8))
    }

    /// Migrates old-format encrypted string to new v2 format.
    /// Returns nil if not old format or migration fails.
    func migrateToV2(_ base64String: String) -> String? {
        guard let combined = Data(base64Encoded: base64String) else { return nil }
        // Already new format
        if combined.count >= 2 && combined.prefix(2) == Data("v2".utf8) { return nil }
        // Try decrypting as old format
        guard let bytes = decryptLegacy(from: combined) else { return nil }
        // Re-encrypt with new format
        return encryptBytes(bytes).map { $0.base64EncodedString() }
    }

    /// Legacy format: 16-byte IV + ciphertext + 32-byte HMAC (minimum 49 bytes).
    /// Returns nil if decryption fails.
    private func decryptLegacy(from combined: Data) -> [UInt8]? {
        guard let key = getKey() else { return nil }

        // L-3 (2026-07-24 audit): the old comment labeled this branch
        // "New format (v2) with HMAC" but we're inside `decryptLegacy` —
        // the IV + ciphertext + 32-byte HMAC layout is the legacy (pre-v2)
        // AES-CBC+HMAC format. CommonCrypto AES-CBC is still in use here
        // for backwards-compatible reads; only the pre-1.2.0 unauthenticated
        // CBC branch (no HMAC) was removed at C4.
        // Legacy AES-CBC+HMAC: minimum 16 (IV) + 1 + 32 (HMAC) = 49 bytes.
        if combined.count >= 49 {
            let hmacSize = 32
            // Wrap slice with Data(...) so constantTimeCompare's 0-based loop
            // works. `combined.suffix(_:)` returns Slice<Data> with
            // startIndex = combined.count - hmacSize, not 0 — passing the raw
            // slice causes out-of-bounds subscript trap.
            let storedHMAC = Data(combined.suffix(hmacSize))

            // Verify HMAC over IV || ciphertext (constant-time to prevent
            // timing side-channel forgery of the auth tag)
            let ivAndCiphertext = combined.dropLast(hmacSize)
            let computedHMAC = computeHMAC(data: Data(ivAndCiphertext), key: key)
            // ID-SILENT-0022 (2026-08-08 audit): distinguish HMAC mismatch
            // from other decrypt failures. Pre-fix, this path returned nil
            // silently and the caller (`decryptWithReason`) logged a generic
            // "decryptBytes returned nil" — operators diagnosing "why can't
            // I read old items" had no signal that the failure was auth vs
            // format corruption. `decryptV2` already distinguishes via
            // CryptoKit's `authenticationFailure` error; this brings the
            // legacy path to parity.
            guard Self.constantTimeCompare(computedHMAC, storedHMAC) else {
                Self.logger.error("HMAC mismatch on legacy decrypt — stored vs computed tag diverge (key? tampered ciphertext? pre-1.2.0 no-HMAC branch?)")
                return nil
            }

            let iv = combined.prefix(16)
            let ciphertext = combined.dropFirst(16).dropLast(hmacSize)
            let keyData = key.withUnsafeBytes { Data($0) }
            return Self.legacyAESDecryptCBC(data: Data(ciphertext), key: keyData, iv: Data(iv)).map { [UInt8]($0) }
        }

        // C4: the pre-1.2.0 branch (16-byte IV + ciphertext, no HMAC) was removed.
        // Unauthenticated CBC let anyone who can write UserDefaults tamper with
        // ciphertext undetected and run a padding-oracle attack to recover
        // plaintext byte-by-byte. Such blobs are now rejected outright.
        return nil
    }

    // MARK: - Helpers

    /// Computes HMAC-SHA256 using raw Data key (for legacy format migration).
    /// Exposed for ImageStorage use.
    static func computeLegacyHMAC(data: Data, key: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress, key.count,
                    dataBytes.baseAddress, data.count,
                    &result
                )
            }
        }
        return Data(result)
    }

    private func computeHMAC(data: Data, key: SymmetricKey) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(authenticationCode)
    }

    /// Constant-time byte comparison. Defends HMAC tag verification against
    /// timing side channels — `Data ==` short-circuits on first mismatch and
    /// leaks information about the stored tag.
    ///
    /// ID-SECURITY-0008 (2026-08-08 audit): the `a.count == b.count` early
    /// return technically leaks tag length via timing. In practice the only
    /// caller is HMAC-SHA256 verification, where the tag is fixed at 32
    /// bytes — so the leak is theoretical, not exploitable. Acceptable for
    /// the legacy decrypt path; the primary AES-GCM v2 path uses CryptoKit's
    /// authenticated decryption, which doesn't rely on this function. If a
    /// future caller passes variable-length secrets, replace the early
    /// return with a length-padded XOR over `max(a.count, b.count)`.
    static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    static func legacyAESDecryptCBC(data: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, 32,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        &decryptedBytes, bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess, numBytesDecrypted > 0 else { return nil }
        return Data(decryptedBytes.prefix(numBytesDecrypted))
    }
}
