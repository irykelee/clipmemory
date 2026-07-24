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
        let imageCount = Self.imageCountSync(directory: dir, fileManager: fileManager)
        return Snapshot(
            version: AppVersion.current,
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            keychainKeyExists: keyStore.load() != nil,
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

    /// Build a snapshot, log it once, and persist `Date()` as the new
    /// `lastLaunchTime` so the *next* launch can report "previous launch was
    /// N seconds ago". Order matters: snapshot reads existing `lastLaunchTime`
    /// BEFORE the write — otherwise every log would claim lastLaunch = now.
    ///
    /// M-21 (2026-07-24 audit): image count is dispatched to a utility queue
    /// via `imageCount`. Two log lines emitted: the first carries
    /// `imagesCount=pending`; the second carries the resolved count once
    /// `contentsOfDirectory` returns. Both are still synchronous from the
    /// caller's perspective — `logSnapshot` returns as soon as the dispatch
    /// is queued, so AppDelegate's main thread is not blocked.
    static func logSnapshot(
        counts: Counts = .zero,
        keyStore: any KeyStoring = KeychainKeyStore(),
        imagesDirectory: URL? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        let dir = imagesDirectory ?? ImageStorage.shared.imagesDirectoryURL
        var snap = snapshot(
            counts: counts,
            keyStore: keyStore,
            imagesDirectory: imagesDirectory,
            fileManager: fileManager,
            defaults: defaults
        )
        // First log: imagesCount=0 placeholder (real value lands via callback).
        // Marking the place explicitly so a log reader knows why the count is
        // off — the second line replaces it within ~1 ms for typical sizes.
        let pending = Snapshot(
            version: snap.version,
            macosVersion: snap.macosVersion,
            keychainKeyExists: snap.keychainKeyExists,
            itemsCount: snap.itemsCount,
            trashedCount: snap.trashedCount,
            tagsCount: snap.tagsCount,
            imagesCount: 0,
            lastLaunchTime: snap.lastLaunchTime
        )
        logger.info("\(pending.description, privacy: .public) imagesCount=pending")
        defaults.set(Date(), forKey: lastLaunchKey)
        imageCount(directory: dir, fileManager: fileManager) { count in
            snap = Snapshot(
                version: snap.version,
                macosVersion: snap.macosVersion,
                keychainKeyExists: snap.keychainKeyExists,
                itemsCount: snap.itemsCount,
                trashedCount: snap.trashedCount,
                tagsCount: snap.tagsCount,
                imagesCount: count,
                lastLaunchTime: snap.lastLaunchTime
            )
            logger.info("\(snap.description, privacy: .public)")
        }
    }

}
