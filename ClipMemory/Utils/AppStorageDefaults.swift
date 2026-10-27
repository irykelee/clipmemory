import Foundation

/// The `UserDefaults` store that the view tree's `@AppStorage` declarations
/// and `sz(_:)` resolve against.
///
/// ## Why this seam exists
///
/// ID-REVIEW-1039 (2026-10-27): the test bundle is injected into the APP
/// binary (`TEST_HOST`), so `UserDefaults.standard` inside a test process
/// IS the user's real `com.clipmemory.app` domain. Every `@AppStorage`
/// declaration in the view tree (17 sites across 14 view files) read that
/// domain implicitly — `@AppStorage` without a `store:` argument resolves
/// to `UserDefaults.standard` — and `sz(_:)` read it explicitly.
///
/// The snapshot tests therefore had to plant their baseline into the
/// PRODUCTION domain to make the render deterministic, and a `tearDown`
/// restore does not survive a host abort (ID-REVIEW-1038 measured
/// `fontScale = 3.7` left in the user's plist after a trap).
///
/// ## Why it is NOT the app's service seam (`TestIsolation.defaults`)
///
/// The obvious move — reuse the app's canonical service seam — was tried
/// and does not work.
///
/// MEASURED 2026-10-27 (and re-measured by the independent verifier the
/// same day — the first version of this note stated the mechanism wrongly;
/// see below):
///
/// 1. `LanguageManager.shared` caches its singleton and invalidates that
///    cache when the service seam's **instance identity** changes
///    (`_sharedDefaultDefaults === defaults`, `LanguageManager.swift:45`).
///    `UserDefaults(suiteName:)` returns a NEW instance on every call
///    (measured: `===` is `false`), so any swap of the service seam
///    invalidates the cache, and the NEXT read of `shared` re-creates the
///    manager and **binds it to whatever the service seam holds at that
///    moment** (`LanguageManager.swift:48`).
/// 2. `LanguageManager.init` writes **nothing** — `didSet` observers do not
///    fire during `init` (measured: a freshly created manager leaves the
///    suite's owned-key list empty). The first version of this note claimed
///    the opposite ("the initialiser calls `applyLanguage()`"); that was
///    measured false.
/// 3. The two keys are written LATER, by `selectedLanguage`'s `didSet`
///    (`LanguageManager.swift:124` persists `appLanguage`; `applyLanguage()`
///    at `:191` persists `AppleLanguages`) — and they land in **the store
///    the manager was bound at creation**, NOT in whatever the service seam
///    holds at write time (measured). The first version of this note said
///    "whichever store is current"; that was measured false too.
///
/// ⇒ Consequence: a manager that was bound to the BASELINE suite
/// (`TestIsolation-XCTest-isolation`) writes BOTH keys INTO the baseline
/// suite on the next `selectedLanguage` assignment — from any later test,
/// in any class. Those are exactly the two keys the ZZZ canary
/// (`testNoTestWroteIntoTheSharedIsolationSuite`) watches, so it went red
/// and named four unrelated test classes as offenders.
///
/// ⇒ The appearance reads must not DEPEND on the service seam, and must not
/// BE the service seam. This seam owns its own storage: swapping it cannot
/// re-bind `LanguageManager`, and it can never hand out the baseline suite
/// the canary watches.
///
/// ⚠️ The underlying root cause — `LanguageManager.shared`'s cache
/// invalidating on **instance identity** rather than on the seam's
/// **domain** — is still there; this seam routes around it instead of
/// fixing it. Recorded as a known, unfixed hazard in
/// `docs/skips-ledger.md` §39.11.
///
/// ## Resolution
///
/// * **Production** → `UserDefaults.standard`: byte-identical to the
///   pre-ID-REVIEW-1039 behaviour, where every `@AppStorage` without a
///   `store:` argument resolved to `.standard`.
/// * **Test process** → this seam's OWN suite (never the service seam,
///   never the baseline suite), so the app's LIVE views in a test host stay
///   off the production domain and off the canary's baseline.
/// * **A test that needs a specific appearance baseline** overrides it with
///   `setShared(_:)`.
enum AppStorageDefaults {

    /// The lock.
    ///
    /// ID-REVIEW-1036 (2026-10-26): the service seam needed one because any
    /// thread can read it. The same reasoning applies here — `sz(_:)` is
    /// called from view bodies (main thread today) but the seam offers no
    /// such guarantee, and a read-modify-write of a class reference without
    /// a lock is the exact shape that aborted the test host in CI run
    /// 40186263416.
    ///
    /// The lock is NOT held while the caller uses the returned
    /// `UserDefaults` — `UserDefaults` is internally thread-safe.
    private static let lock = NSLock()

    /// The test override, if any.
    private nonisolated(unsafe) static var overrideStorage: UserDefaults?

    /// The suite name for the XCTest-isolated appearance store.
    ///
    /// Deliberately NOT `TestIsolation.xcTestIsolationSuiteName`: that suite
    /// is the BASELINE the ZZZ canary watches for stray writes, and the
    /// appearance seam must never be able to hand it out.
    nonisolated static let xcTestAppearanceSuiteName = "AppStorageDefaults-XCTest-isolation"

    /// This seam's own store in a test process.
    ///
    /// `nil` in production (where `.standard` is used instead), so the
    /// suite is never created outside XCTest.
    private nonisolated static let xcTestAppearanceDefaults: UserDefaults? = {
        guard TestIsolation.isRunningTests else { return nil }
        return UserDefaults(suiteName: xcTestAppearanceSuiteName)
    }()

    /// The store the appearance reads resolve against.
    static var shared: UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        if let override = overrideStorage { return override }
        if let testStore = xcTestAppearanceDefaults { return testStore }
        return .standard
    }

    /// Points the appearance reads at `store`.
    ///
    /// Pass `nil` to go back to the default resolution. Tests call this in
    /// `setUp` and restore it in `tearDown`; production never calls it.
    static func setShared(_ store: UserDefaults?) {
        lock.lock()
        defer { lock.unlock() }
        overrideStorage = store
    }
}
