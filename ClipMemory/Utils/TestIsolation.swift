import Foundation

/// ID-CRASH-0029 (2026-09-28 code-review P2-23): single source of truth
/// for the test-suite `UserDefaults` seam. The previous layout had three
/// near-identical `nonisolated(unsafe) static var defaults: UserDefaults =
/// .standard` declarations on `WindowManager`, `LanguageManager`, and
/// `UpdateService` — five globals total when counting the two
/// `injectedForTest` mirrors. Tests assigned each independently in `setUp`
/// and restored in `tearDown`; changing the strategy required editing
/// three sites.
///
/// Now all three services read from `TestIsolation.defaults` (and
/// `TestIsolation.setDefaults(_:)` as the canonical setUp entry point).
/// The per-service statics are retained as deprecated forwarders so
/// existing test sites (`LanguageManager.defaults = …`,
/// `UpdateService.defaults = …`, `WindowManager.defaults = …`) continue
/// to compile and run unchanged — removal is its own migration once
/// the Swift 6 actor cleanup commits to the service layer (per
/// `docs/SWIFT6_MIGRATION.md` Phase 3).
///
/// ID-CRASH-0064 (2026-10-23): the SCOPE of that consolidation, stated
/// precisely so the next reader neither over- nor under-estimates it.
///
/// * CONSOLIDATED — the `UserDefaults` seam: ONE storage
///   (`TestIsolation.defaults`) behind three forwarders. Changing the
///   isolation strategy is now a one-site edit.
/// * CONSOLIDATED — the "is this a test process?" probe:
///   `TestIsolation.isRunningTests` (ID-CRASH-0031, three signals). The
///   last local copy — `UpdateService`'s private `XCTestConfigurationFilePath`
///   read — was removed by ID-CRASH-0064.
/// * DELIBERATELY NOT CONSOLIDATED — the two `injectedForTest` seams
///   (`LanguageManager.injectedForTest`, `UpdateService.injectedForTest`).
///   They inject a *fake service instance* of a service-specific type, not
///   a `UserDefaults` suite: the two hold different types, so there is no
///   shared storage to point them at. Merging them would need type erasure
///   (`Any` + a registry), which trades a readable seam for a runtime-cast
///   failure mode. They stay per-service, and their contract (production
///   never sets them; tests reset them in `tearDown`) is unchanged.
///
/// Why an enum (vs struct/class): namespaces for free, no initialiser
/// surface, `static var` lives on the type. Singleton-shaped.
/// `nonisolated(unsafe)` matches the per-service precedent: read from
/// the main thread (`setUp`/`tearDown`), written only from test setup
/// (`XCTestConfigurationFilePath` is set before any test runs).
enum TestIsolation {

    /// The IMMUTABLE baseline the seam starts on.
    ///
    /// ID-CRASH-0066 (2026-10-23): kept separate from `defaults` on
    /// purpose. `defaults` is mutable and every test class that touches
    /// the seam reassigns it — so asserting on `defaults` says something
    /// about WHOSE TEST RAN LAST, not about the baseline. A guard on a
    /// mutable global is therefore order-dependent: the suite could end
    /// with the seam pointing at an isolated suite even if the baseline
    /// were broken. This constant is the thing that can be asserted
    /// deterministically.
    nonisolated static let baselineDefaults: UserDefaults = defaultsFor(isTestProcess: isRunningTests)

    /// ID-REVIEW-1036 (2026-10-26): lock-protected for the same reason as
    /// `ServiceContainer.crypto` (ID-REVIEW-1034) — the read-modify-write of
    /// a class reference without a lock is the exact shape that aborted the
    /// test host in CI run 40186263416.
    ///
    /// The three forwarders (`LanguageManager.defaults` /
    /// `UpdateService.defaults` / `WindowManager.defaults`) are
    /// `nonisolated(unsafe)` — **NOT actor-isolated** — so any of them can
    /// be read from a background thread, while tests write the seam from
    /// `setUp`. Today's call sites happen to be `@MainActor`
    /// (`LanguageManager.shared`, `UpdateService._sharedDefault`), but the
    /// seam itself offers no such guarantee: it is the canonical storage
    /// every service reaches for.
    ///
    /// The lock is NOT held while the caller uses the returned
    /// `UserDefaults` — `UserDefaults` is internally thread-safe.
    ///
    /// ⚠️ Measured 2026-10-26 (independent review + controlled mirror
    /// probe): the over-release IS observable here. The earlier note in
    /// this file claimed the opposite ("Foundation keeps a per-suite cache
    /// alive, so the refcount never reaches zero") — that claim was
    /// **measured false**: `UserDefaults(suiteName: "x") === UserDefaults
    /// (suiteName: "x")` is `false` (no per-name instance cache) and a
    /// `UserDefaults` subclass's `deinit` DOES run.
    ///
    /// What actually decides observability is the **strong-reference
    /// structure of the swap**, not the referenced type: when the writer
    /// hands over a FRESH instance and retains none of the swapped-out
    /// ones, the swapped-out instance's only strong reference is this
    /// storage slot ⇒ the writer's release drops it to zero ⇒ its
    /// `dealloc` runs ⇒ a reader holding a stale pointer faults
    /// (measured 3/3 within 0.5 s: `EXC_BAD_ACCESS` inside
    /// `-[NSUserDefaults objectForKey:]`).
    ///
    /// ⇒ The lock here is a **proven** fix, not insurance. The regression
    /// test `Tests/ClipMemoryTests/Review1036RegressionTests.swift` uses
    /// exactly that shape, so removing the lock makes it fail.
    private static let defaultsLock = NSLock()
    private nonisolated(unsafe) static var defaultsStorage: UserDefaults = baselineDefaults

    /// The single `UserDefaults` instance shared by all services in
    /// production. Tests reassign this in `setUp` and restore in
    /// `tearDown`; reading services pick up the test value transparently.
    ///
    /// ID-CRASH-0066 (2026-10-23): the BASELINE must not be the production
    /// domain while a test process is running.
    ///
    /// The storage used to start as `.standard` — the production
    /// `com.clipmemory.app` domain. Two consequences, both observed in the
    /// wild rather than reasoned about:
    ///
    /// 1. "Forgot to inject a suite" was silently equivalent to "write to
    ///    the user's real settings" (e.g. `UpdateFallbackFeedConsent`
    ///    appearing in the production domain during a test run).
    /// 2. A `tearDown` that reset the seam to `.standard` became a LEAK
    ///    once ID-CRASH-0029 put all three services onto ONE storage:
    ///    resetting one of them reset all three, so the remainder of the
    ///    test process ran with the production domain wired in.
    ///
    /// The baseline now follows the pattern the store's own defaults
    /// already use (ID-STORE-0014, `ClipboardStore.xcTestDefaults`): under
    /// XCTest → an isolated suite; in production → `.standard`.
    ///
    /// The production branch is unchanged and is asserted as such by
    /// `Tests/ClipMemoryTests/SeamBaselineIsolationTests.swift`.
    static var defaults: UserDefaults {
        get {
            defaultsLock.lock()
            defer { defaultsLock.unlock() }
            return defaultsStorage
        }
        set {
            defaultsLock.lock()
            defer { defaultsLock.unlock() }
            defaultsStorage = newValue
        }
    }

    /// The suite name for the XCTest-isolated baseline. Same naming shape
    /// as the suite used by `ClipboardStore.xcTestDefaults`.
    nonisolated static let xcTestIsolationSuiteName = "TestIsolation-XCTest-isolation"

    /// Decides which `UserDefaults` storage the seam starts on.
    ///
    /// ID-CRASH-0066: split out of the `defaults` initializer so the
    /// PRODUCTION branch can be asserted from a test process.
    /// `isRunningTests` is a constant of the running process and cannot be
    /// flipped, but this decision function can be called with either
    /// argument — so "production still gets `.standard`" is a real
    /// assertion rather than an assumption.
    static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        guard isTestProcess else { return .standard }
        // `UserDefaults(suiteName:)` returns nil only for an invalid name;
        // the constant above is valid, so the fallback is unreachable in
        // practice. It mirrors `ClipboardStore.xcTestDefaults`.
        return UserDefaults(suiteName: xcTestIsolationSuiteName) ?? .standard
    }

    /// Tests call this in `setUp`. Existing call sites use the
    /// per-service forwarder (`LanguageManager.defaults = …`); new code
    /// should prefer this entry.
    static func setDefaults(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// ID-CRASH-0031 (2026-10-20 data-loss incident): robust "is this
    /// process a test process?" probe.
    ///
    /// The per-service `xcTestDefaults` helpers used to key off
    /// `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
    /// == nil`.
    ///
    /// MEASURED (2026-10-20): in the app-hosted test process that variable
    /// IS present, with an EMPTY STRING value — and `Optional("") == nil`
    /// is false, so the old single-signal guard did detect the test host.
    /// The first version of the incident record claimed the opposite; it
    /// was corrected in `docs/incidents/2026-10-20-trash-purge.md` §3.
    ///
    /// Widening the probe was still worth doing: it previously rested on
    /// ONE proxy for "am I in a test process?". If that proxy were ever
    /// missing on some launch path, the process would take the PRODUCTION
    /// path and read / write the user's real `com.clipmemory.app` domain.
    /// Three independent signals now cover that:
    /// 1. `XCTestConfigurationFilePath` present with ANY value (an empty
    ///    string still counts).
    /// 2. The `XCTestCase` class is loaded in this process (the XCTest
    ///    framework is injected into the host app).
    /// 3. An `.xctest` bundle is injected into this process.
    ///
    /// NOT a usable signal: the unified log line `Successfully spawned
    /// ClipMemory`. The test host produces exactly the same line, so it
    /// does not distinguish a test launch from a plain one.
    nonisolated static let isRunningTests: Bool = isTestProcess(signals: currentTestProcessSignals())

    /// ID-REVIEW-1045 (2026-10-28): the three signals, **structured**.
    ///
    /// Before this, the whole probe lived inside one `static let`
    /// initialiser closure — a **constant of the running process** that
    /// could not be flipped, and whose decision logic could not be
    /// exercised from a test. That made two halves untestable:
    ///
    /// * "a NON-test process ⇒ probe is false" — the half that decides
    ///   whether the **production** app registers its global hotkey, shows
    ///   its menu-bar item, and writes to the user's real domain. In a
    ///   test host the probe is *always* true, so that half was
    ///   structurally unreachable.
    /// * "the decision logic is correct" — e.g. a signal that is supposed
    ///   to be an OR-term accidentally becoming an AND-term would silently
    ///   disable the whole test-isolation regime.
    ///
    /// The signals are now values, and the decision is a **pure
    /// function** of them: the production half becomes directly
    /// assertable by feeding `false`, and every OR-term gets its own
    /// test.
    ///
    /// ⚠️ The probe's *meaning* is unchanged — same three signals, same
    /// OR semantics, same evaluation timing (first access, `swift_once`).
    /// Production behaviour is byte-identical.
    struct TestProcessSignals: Equatable {
        /// Signal 1 — `XCTestConfigurationFilePath` present with ANY
        /// value (an empty string still counts; measured 2026-10-20).
        var hasXCTestConfigPath: Bool
        /// Signal 2 — the `XCTestCase` class is loaded in this process.
        var xcTestCaseClassLoaded: Bool
        /// Signal 3 — an `.xctest` bundle is injected into this process.
        var xctestBundleInjected: Bool

        /// A process with none of the three signals is NOT a test process.
        static let none = TestProcessSignals(
            hasXCTestConfigPath: false,
            xcTestCaseClassLoaded: false,
            xctestBundleInjected: false
        )
    }

    /// Reads the three signals from the **current** process.
    ///
    /// Split out of `isRunningTests` so the probe can be re-derived on
    /// demand (consistency assertion) instead of being a one-shot
    /// constant. Keeping the *reads* here — and nowhere else — is what
    /// the ID-REVIEW-1044 static guard ⑩ pins (all three anchors
    /// `ProcessInfo.processInfo.environment[` / `NSClassFromString(` /
    /// `Bundle.allBundles` must appear **only** in this file).
    nonisolated static func currentTestProcessSignals() -> TestProcessSignals {
        TestProcessSignals(
            hasXCTestConfigPath:
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            xcTestCaseClassLoaded: NSClassFromString("XCTestCase") != nil,
            xctestBundleInjected:
                Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        )
    }

    /// The **pure** decision function: is this process a test process?
    ///
    /// Three independent signals, OR-ed. "ANY signal ⇒ test process" is
    /// the fail-safe direction: a false negative (a test process judged
    /// to be production) writes into the user's real domain — that is
    /// the ID-CRASH-0031 data-loss shape. A false positive (production
    /// judged to be a test process) is the ID-REVIEW-1045 shape: the
    /// production app silently stops registering its hotkey, shows no
    /// menu-bar item, and keeps its data in an isolated store.
    ///
    /// ⚠️ The false-positive direction is why this function exists as a
    /// **pure** function rather than staying inside the `static let`:
    /// the production half has to be assertable, and it has to be
    /// assertable *without* a production binary (see
    /// `Scripts/production-probe-smoke.sh` for the end-to-end counterpart
    /// that closes the remaining gap — "the probe is false **in the real
    /// production process**").
    nonisolated static func isTestProcess(signals: TestProcessSignals) -> Bool {
        signals.hasXCTestConfigPath
            || signals.xcTestCaseClassLoaded
            || signals.xctestBundleInjected
    }

    /// ID-CRASH-0031: the UserDefaults keys that hold the user's actual
    /// data (history / recycle bin / tags). These are the keys a test
    /// process must never write, and the keys two app processes must
    /// never overwrite with a stale snapshot.
    /// ID-CRASH-0031 (2026-10-20): true when a mutation of the user's
    /// data blobs must be REFUSED — the process runs tests AND the
    /// target defaults addresses the production domain.
    ///
    /// ID-CRASH-0031 follow-up: the check is DOMAIN-level, not instance
    /// identity. `UserDefaults(suiteName: "com.clipmemory.app")` is a
    /// different object that addresses the SAME domain, so an identity
    /// check would let it through. The discriminator is the VALUE of the
    /// production data blob: an instance addressing the same domain
    /// reports the same bytes, an unrelated suite (even one that reuses
    /// a production key NAME) does not.
    ///
    /// A write-then-read-back probe was measured and does NOT work in
    /// either direction — two UserDefaults instances in the same process
    /// do not share their in-memory caches, so neither instance observes
    /// the other's write.
    nonisolated static func mustRefuseProductionDataMutation(_ defaults: UserDefaults) -> Bool {
        isRunningTests && addressesProductionDomain(defaults)
    }

    /// True when `defaults` addresses the same persistent domain as
    /// `UserDefaults.standard` (the app's own `com.clipmemory.app`
    /// suite).
    ///
    /// Measured on this machine:
    /// * `UserDefaults.standard` → always true (identity).
    /// * `UserDefaults(suiteName: "com.clipmemory.app")` → true (it reads
    ///   the app's `ClipboardItems` blob).
    /// * an unrelated suite → false, even when it holds a key with the
    ///   same NAME as a production data key (the VALUES differ).
    nonisolated static func addressesProductionDomain(_ defaults: UserDefaults) -> Bool {
        if defaults === UserDefaults.standard { return true }
        for key in productionDataKeys {
            guard let standardBlob = UserDefaults.standard.data(forKey: key) else {
                continue
            }
            guard let candidateBlob = defaults.data(forKey: key) else {
                continue
            }
            if candidateBlob == standardBlob { return true }
        }
        // The production domain holds no data blob at all (a fresh
        // install, or a domain whose blobs were quarantined). There is no
        // user data in it to overwrite, and an empty domain is
        // indistinguishable from an unrelated empty suite through the
        // public UserDefaults API — so no domain-level discriminator can
        // exist here. The residual gap is therefore bounded: it needs a
        // SECOND instance addressing the production domain, and inside
        // the app / test-host process that instance cannot even be
        // created (`UserDefaults(suiteName: <own bundle id>)` returns
        // nil — measured).
        //
        // Note the common case is unaffected: `UserDefaults.standard`
        // itself is caught by the identity check above, so a test process
        // writing `.standard` is refused whether or not the blobs exist.
        return false
    }

    nonisolated static let productionDataKeys: Set<String> = [
        UserDefaultsKey.clipboardItems.rawValue,
        UserDefaultsKey.trashedItems.rawValue,
        UserDefaultsKey.clipboardTags.rawValue
    ]
}
