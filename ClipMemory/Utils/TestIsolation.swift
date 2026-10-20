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
/// Why an enum (vs struct/class): namespaces for free, no initialiser
/// surface, `static var` lives on the type. Singleton-shaped.
/// `nonisolated(unsafe)` matches the per-service precedent: read from
/// the main thread (`setUp`/`tearDown`), written only from test setup
/// (`XCTestConfigurationFilePath` is set before any test runs).
enum TestIsolation {

    /// The single `UserDefaults` instance shared by all services in
    /// production. Tests reassign this in `setUp` and restore in
    /// `tearDown`; reading services pick up the test value transparently.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

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
    /// == nil`. That variable is present in the XCTest **runner**, but a
    /// plain launch of the app binary has no such variable — and
    /// `xcodebuild test` launches the app binary through LaunchServices
    /// (confirmed in the unified log: `Successfully spawned ClipMemory`).
    /// A plain launch therefore took the PRODUCTION path and read /
    /// wrote the user's real `com.clipmemory.app` domain.
    ///
    /// Three independent signals, any of which is sufficient:
    /// 1. `XCTestConfigurationFilePath` present with ANY value (an empty
    ///    string still counts — `Optional("") == nil` is false).
    /// 2. The `XCTestCase` class is loaded in this process (the XCTest
    ///    framework is injected into the host app).
    /// 3. An `.xctest` bundle is injected into this process.
    ///
    /// Signals 2 and 3 matter because they survive the app-host launch
    /// path, where signal 1 may be absent.
    nonisolated static let isRunningTests: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

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
