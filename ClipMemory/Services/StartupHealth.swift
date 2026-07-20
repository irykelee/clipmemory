import Foundation
import os.log

/// A.2 observability: one-time startup health snapshot.
///
/// Logs version + macOS + Keychain presence + items/trashed/tags counts +
/// images count + last-launch time at `applicationDidFinishLaunching`. Goal:
/// when the next UI bug or crash shows up, Console.app / `log show` has a
/// snapshot of "the moment the app started" so we don't have to reconstruct.
///
/// Caller must be on the main thread — `ClipboardStore.shared` is `@MainActor`
/// bound (via `@Published`). `applicationDidFinishLaunching` runs on main, so
/// `AppDelegate` is the natural call site.
///
/// Tests inject every dependency via parameters so live history stays
/// untouched (per C1 test-never-touch-prod-data rule): `counts` decouples the
/// function from `ClipboardStore.shared.init()`, `keyStore` is a `KeyStoring`
/// fake, `imagesDirectory` is a temp dir, `defaults` is an isolated suite.
enum StartupHealth {
    private static let lastLaunchKey = "lastLaunchTime"
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "Startup")

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
        defaults: UserDefaults = .standard
    ) -> Snapshot {
        let dir = imagesDirectory ?? ImageStorage.shared.imagesDirectoryURL
        let imgCount = (try? fileManager.contentsOfDirectory(atPath: dir.path).count) ?? 0
        return Snapshot(
            version: AppVersion.current,
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            keychainKeyExists: keyStore.load() != nil,
            itemsCount: counts.items,
            trashedCount: counts.trashed,
            tagsCount: counts.tags,
            imagesCount: imgCount,
            lastLaunchTime: defaults.object(forKey: lastLaunchKey) as? Date
        )
    }

    /// Build a snapshot, log it once, and persist `Date()` as the new
    /// `lastLaunchTime` so the *next* launch can report "previous launch was
    /// N seconds ago". Order matters: snapshot reads existing `lastLaunchTime`
    /// BEFORE the write — otherwise every log would claim lastLaunch = now.
    static func logSnapshot(
        counts: Counts = .zero,
        keyStore: any KeyStoring = KeychainKeyStore(),
        imagesDirectory: URL? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        let snap = snapshot(
            counts: counts,
            keyStore: keyStore,
            imagesDirectory: imagesDirectory,
            fileManager: fileManager,
            defaults: defaults
        )
        logger.info("\(snap.description, privacy: .public)")
        defaults.set(Date(), forKey: lastLaunchKey)
    }
}
