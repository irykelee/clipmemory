import Foundation
import os.log

/// A.2 observability: one-time startup health snapshot.
///
/// Logs version + macOS + Keychain presence + items/trashed/tags counts +
/// images count + last-launch time at `applicationDidFinishLaunching`. Goal:
/// when the next UI bug or crash shows up, Console.app / `log show` has a
/// snapshot of "the moment the app started" so we don't have to reconstruct.
///
/// Caller must be on the main thread — `ClipboardStore.shared` exposes
/// `@Published` properties which SwiftUI requires be mutated on the main
/// thread. ID-CRASH-0042 (2026-09-28 code-review P3): the 2026-07-27
/// Apple conformance audit's F-1 flag (`store NOT yet annotated
/// @MainActor`) has since been resolved — `ClipboardStore` is now
/// `@MainActor` at the class scope (`ClipboardStore.swift:122`), so
/// every property read/write and method call is already main-thread by
/// the compiler. The "we rely on the convention" hedge below is
/// kept only for Swift 5 mode (`SWIFT_STRICT_CONCURRENCY: minimal` —
/// `@MainActor` is enforced, but only for non-`Sendable` cross-thread
/// hops; intra-thread reads remain valid). AppDelegate remains the
/// natural call site.
///
/// Tests inject every dependency via parameters so live history stays
/// untouched (per C1 test-never-touch-prod-data rule): `counts` decouples the
/// function from `ClipboardStore.shared.init()`, `keyStore` is a `KeyStoring`
/// fake, `imagesDirectory` is a temp dir, `defaults` is an isolated suite.
///
/// ⚠️ ID-REVIEW-1048 (2026-10-28): the paragraph above was a **comment-only
/// invariant** — the very shape ID-REVIEW-1043 flagged in `CryptoService` and
/// ID-REVIEW-1047 flagged in `FirstLaunchService` ("写在注释里的、没有被强制
/// 的不变量"). It was **false as a general rule**: the `keyStore` and
/// `defaults` **default parameters were the PRODUCTION identities** ⇒ a caller
/// that omitted them got the user's real Keychain item and the user's real
/// `com.clipmemory.app` domain.
/// ⇒ The invariant is now **enforced**, not just stated:
/// * `defaults` resolves through `defaultsFor(isTestProcess:)` ⇒ a test
///   process writes `lastLaunchTime` into an isolated suite, never into the
///   user's domain (and `lastLaunchTime` is **allowlisted** by the ZZZ canary,
///   so that write would have been **invisible**);
/// * the Keychain read goes through `mayReadKeyStore(isRunningTests:keyStore:)`
///   ⇒ a store that reports the **production** service is refused in a test
///   process (the production item was created by a differently signed process
///   ⇒ macOS raises an ACL modal and the test host **blocks** on it).
enum StartupHealth {
    // P1-AUDIT-2026-09-22 (P2-9): central `UserDefaultsKey` rawValue.
    private static var lastLaunchKey: String { UserDefaultsKey.lastLaunchTime.rawValue }
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "Startup")

    /// ID-REVIEW-1048: the **isolated suite** a test process resolves to.
    ///
    /// A **fixed** name (not a UUID) so a guard can address it and so the
    /// suite does not create a new preferences plist on every test process.
    /// Same shape as `ClipboardStore-XCTest-isolation` /
    /// `SafeModeService-XCTest-isolation` / `BackupService-XCTest-isolation`.
    nonisolated static let xcTestIsolationSuiteName = "StartupHealth-XCTest-isolation"

    /// ID-REVIEW-1048: the **pure** resolver — which domain does the
    /// `defaults` default parameter resolve to?
    ///
    /// * **Production** ⇒ the **same** `UserDefaults.standard` ⇒ byte-identical
    ///   behaviour (the app's `lastLaunchTime` is still read from and written
    ///   to the real domain).
    /// * **A test process** ⇒ an isolated suite ⇒ `logSnapshot`'s
    ///   `defaults.set(Date(), forKey: lastLaunchTime)` can never reach the
    ///   user's real domain.
    ///
    /// Split out as a **pure function** so both halves are assertable from a
    /// test (inside a test host `TestIsolation.isRunningTests` is always true
    /// ⇒ "production ⇒ the real domain" would otherwise be structurally
    /// unreachable — the ID-REVIEW-1045 shape).
    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        guard isTestProcess else { return .standard }
        return UserDefaults(suiteName: xcTestIsolationSuiteName) ?? .standard
    }

    /// ID-REVIEW-1048: may this process **read** this key store?
    ///
    /// The production Keychain item `com.clipmemory.app` / `root-encryption-key`
    /// holds the user's REAL root encryption key. In a test host the item was
    /// created by a **differently signed** process ⇒ macOS raises an **ACL
    /// authorization modal** and the host **blocks** on it (measured in
    /// ID-REVIEW-1042 / ID-REVIEW-1043: tens of seconds, and a `SecurityAgent`
    /// process is left behind) ⇒ reading it from a test is not "harmless", it
    /// is a **user-visible hang**.
    ///
    /// ⇒ The judgement is **by identity**, not by type: any `KeyStoring`
    /// conformer that reports the production service is refused — including a
    /// decorator that wraps the production store.
    ///
    /// ⇒ It **reuses** `CryptoService`'s convergence-point judgement
    /// (ID-REVIEW-1043) instead of inventing a second one ⇒ the two paths
    /// cannot drift apart.
    ///
    /// * **Production** ⇒ always allowed ⇒ byte-identical behaviour.
    nonisolated static func mayReadKeyStore(
        isRunningTests: Bool,
        keyStore: KeyStoring
    ) -> Bool {
        !CryptoService.shouldRefuseKeychainStore(
            isRunningTests: isRunningTests,
            keyStore: keyStore
        )
    }

    /// Items/trashed/tags counts lifted out of `ClipboardStore.shared` so the
    /// production call site can supply them once (main thread, after the store
    /// has finished `loadItems`) without re-touching the singleton on every
    /// snapshot call.
    struct Counts {
        let items: Int
        let trashed: Int
        let tags: Int

        static let zero = Counts(items: 0, trashed: 0, tags: 0)
    }

    struct Snapshot: CustomStringConvertible {
        let version: String
        let macosVersion: String
        let keychainKeyExists: Bool
        let itemsCount: Int
        let trashedCount: Int
        let tagsCount: Int
        let imagesCount: Int
        let lastLaunchTime: Date?

        var description: String {
            let lastLaunch = lastLaunchTime.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "never"
            return """
            version=\(version) macos=\(macosVersion) \
            keychain=\(keychainKeyExists) \
            items=\(itemsCount) trashed=\(trashedCount) tags=\(tagsCount) \
            images=\(imagesCount) lastLaunch=\(lastLaunch)
            """
        }
    }

    /// Pure snapshot builder. `counts` defaults to `.zero` so callers that
    /// don't care about store-derived counts (tests, ad-hoc scripts) can
    /// skip the singleton entirely. Production should pass `Counts` built
    /// from `ClipboardStore.shared` once at startup.
    static func snapshot(
        counts: Counts = .zero,
        keyStore: any KeyStoring = KeychainKeyStore(),
        imagesDirectory: URL? = nil,
        fileManager: FileManager = .default,
        // ID-REVIEW-1048: the default domain is resolved through the seam ⇒ a
        // test process never reads the user's real `lastLaunchTime`.
        defaults: UserDefaults = StartupHealth.defaultsFor(isTestProcess: TestIsolation.isRunningTests)
    ) -> Snapshot {
        let dir = imagesDirectory ?? ImageStorage.shared.imagesDirectoryURL
        let imageCount = Self.imageCountSync(directory: dir, fileManager: fileManager)
        return Snapshot(
            version: AppVersion.current,
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            // ID-REVIEW-1048: the production Keychain identity is refused in a
            // test process ⇒ `load()` is not even called on it.
            keychainKeyExists: Self.mayReadKeyStore(
                isRunningTests: TestIsolation.isRunningTests,
                keyStore: keyStore
            ) && keyStore.load() != nil,
            itemsCount: counts.items,
            trashedCount: counts.trashed,
            tagsCount: counts.tags,
            imagesCount: imageCount,
            lastLaunchTime: defaults.object(forKey: lastLaunchKey) as? Date
        )
    }

    /// Enumerate image files away from the main thread, then invoke the
    /// completion on the main thread with the result. Startup callers that
    /// need a non-blocking health log can use this overload.
    static func imageCount(
        directory: URL,
        fileManager: FileManager = .default,
        completion: @escaping (Int) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let count = Self.imageCountSync(directory: directory, fileManager: fileManager)
            DispatchQueue.main.async {
                completion(count)
            }
        }
    }

    private static func imageCountSync(directory: URL, fileManager: FileManager) -> Int {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "gif", "webp", "heic"]
        return (try? fileManager
            .contentsOfDirectory(atPath: directory.path)
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .count) ?? 0
    }

    /// Emit the startup-health log line(s) without ever calling
    /// `snapshot(...)` from the main thread. Post-audit scan caught that
    /// `snapshot` itself calls `imageCountSync` (which calls
    /// `contentsOfDirectory` synchronously) — so the previous
    /// `logSnapshot` re-introduced the very main-thread block the M-21
    /// audit fix tried to remove. This version builds a partial Snapshot
    /// inline (imagesCount = 0) for the first log line, kicks off the
    /// async image count, and emits a corrected second line when the
    /// dispatch returns. AppDelegate no longer blocks on image-dir
    /// enumeration at launch.
    static func logSnapshot(
        counts: Counts = .zero,
        keyStore: any KeyStoring = KeychainKeyStore(),
        imagesDirectory: URL? = nil,
        fileManager: FileManager = .default,
        // ID-REVIEW-1048: the default domain is resolved through the seam ⇒ the
        // `lastLaunchTime` write below lands in an isolated suite in a test
        // process, never in the user's real domain.
        defaults: UserDefaults = StartupHealth.defaultsFor(isTestProcess: TestIsolation.isRunningTests)
    ) {
        let dir = imagesDirectory ?? ImageStorage.shared.imagesDirectoryURL
        // First log line: all fields except imagesCount, which lands async.
        // `lastLaunchTime` read BEFORE the write so the next launch's log
        // shows this launch correctly as "previous launch was N seconds ago".
        let lastLaunch = defaults.object(forKey: lastLaunchKey) as? Date
        let partial = Snapshot(
            version: AppVersion.current,
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            // ID-REVIEW-1048: the production Keychain identity is refused in a
            // test process ⇒ `load()` is not even called on it.
            keychainKeyExists: Self.mayReadKeyStore(
                isRunningTests: TestIsolation.isRunningTests,
                keyStore: keyStore
            ) && keyStore.load() != nil,
            itemsCount: counts.items,
            trashedCount: counts.trashed,
            tagsCount: counts.tags,
            imagesCount: 0,
            lastLaunchTime: lastLaunch
        )
        logger.info("\(partial.description, privacy: .public) imagesCount=pending")
        defaults.set(Date(), forKey: lastLaunchKey)
        imageCount(directory: dir, fileManager: fileManager) { count in
            let resolved = Snapshot(
                version: partial.version,
                macosVersion: partial.macosVersion,
                keychainKeyExists: partial.keychainKeyExists,
                itemsCount: partial.itemsCount,
                trashedCount: partial.trashedCount,
                tagsCount: partial.tagsCount,
                imagesCount: count,
                lastLaunchTime: partial.lastLaunchTime
            )
            logger.info("\(resolved.description, privacy: .public)")
        }
    }

}
