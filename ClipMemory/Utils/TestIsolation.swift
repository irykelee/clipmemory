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
}
