import XCTest
import SwiftUI
import AppKit
@testable import ClipMemory

/// Snapshot test infrastructure for ClipMemory (NEW-7 Phase 1).
///
/// Renders SwiftUI views off-screen to PNG and compares byte-for-byte
/// against a golden file on disk.
///
/// Why not swift-snapshot-testing (pointfreeco)?
/// - v1.19.x requires Swift 6.0 tools-version, producing a swiftmodule with
///   Swift 6 ABI mangling. Our project compiles tests with Swift 5 language
///   mode (`SWIFT_VERSION: "5.9"`), and Swift 5 client cannot import a Swift 6
///   ABI module — `assertSnapshot` is not found at link time.
/// - v1.17.0 (Swift 5.9 tools-version) compiles with our toolchain but its
///   source uses an `Issue.record` signature that the newer Testing module
///   shipped with Xcode 26.6 rejects, breaking the package itself.
/// - Bumping our project to `SWIFT_VERSION: "6.0"` is a project-wide change
///   that risks subtle concurrency errors across the 35 existing test files.
/// - A minimal in-house helper is ~40 lines, has no external coupling, and
///   serves the same visual-regression purpose.
///
/// Why ImageRenderer (not UIGraphicsImageRenderer / CALayer.render):
/// - ImageRenderer is the Apple-blessed macOS 13+ path for offscreen SwiftUI
///   rendering. It correctly handles `@Environment`, `@EnvironmentObject`,
///   and SwiftUI Material backgrounds that hand-rolled Core Graphics paths
///   miss.
/// - 1× scale is required for cross-machine snapshot stability. Retina
///   (2×/3×) snapshots differ across developer machines because the pixel
///   count varies with display configuration.
///
/// Golden files live at
/// `<test-file-dir>/__Snapshots__/<TestClassName>/<testName>.png` and are
/// checked in (P1-AUDIT-2026-09-22 P1-6).

@MainActor
func renderToImage<V: View>(_ view: V, size: CGSize = CGSize(width: 800, height: 600)) -> CGImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1.0
    renderer.proposedSize = .init(width: size.width, height: size.height)
    guard let cgImage = renderer.cgImage else {
        fatalError("ImageRenderer failed for view at size \(size)")
    }
    return cgImage
}

func pngData(from cgImage: CGImage) -> Data {
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    return bitmap.representation(using: .png, properties: [:]) ?? Data()
}

/// Asserts that `image` matches the golden PNG at the conventional path.
///
/// Behavior (P1-AUDIT-2026-09-22 P1-6, strict):
/// - If the golden PNG does not exist, the test FAILS — there is NO record
///   path (silent first-run recording was the previous green-on-CI facade
///   and has been removed, with no replacement).
/// - If the golden exists, the rendered image is compared byte-for-byte
///   against it. Mismatch fails the test and writes `<test>.actual.png`
///   next to the golden for Quick Look diffing.
///
/// Baseline regeneration is NOT currently possible from this helper: no
/// code path here (or anywhere in Tests/) writes goldens — the only
/// `__Snapshots__` write is the `<test>.actual.png` mismatch artifact.
/// Recording is gated on an env-gated record path; see the
/// docs/skips-ledger.md restore checklist.
///
/// `className` is the XCTestCase subclass name (passed by the caller since
/// `assertImageSnapshot` is a free function, not a method).
func assertImageSnapshot(
    _ image: CGImage,
    className: String,
    testName: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    let sourceFileURL = URL(fileURLWithPath: String(describing: file))
        .deletingLastPathComponent()
    let goldenDir = sourceFileURL.appendingPathComponent("__Snapshots__/\(className)")
    let goldenURL = goldenDir.appendingPathComponent("\(testName).png")
    let actualData = pngData(from: image)

    // P1-AUDIT-2026-09-22 (audit finding P1-6): CI was previously treated
    // as a render smoke test only — auto-record + pass — which meant
    // CI never actually compared against the goldens. Strict byte compare
    // every time, in any environment; a missing golden fails fast instead
    // of silently passing.
    // auto-review-20260922-090545:4 / -111346:7 / 20261003-073406 P1: the
    // auto-record branch was removed with no replacement — NO code path in
    // this helper (or anywhere in Tests/) writes goldens, so "delete +
    // re-run to regenerate" is not executable. Recording is gated on an
    // env-gated record path (docs/skips-ledger.md restore checklist);
    // Scripts/regenerate-snapshots.sh is retained only as a
    // destructive-flow tripwire until then.

    guard FileManager.default.fileExists(atPath: goldenURL.path) else {
        XCTFail("""
            Snapshot golden missing at \(goldenURL.path).
            There is no record path: re-running tests cannot re-record the \
            golden. Baseline recording is gated on an env-gated record \
            path — see docs/skips-ledger.md restore checklist.
            """,
            file: file, line: line)
        return
    }

    let goldenData: Data
    do {
        goldenData = try Data(contentsOf: goldenURL)
    } catch {
        XCTFail("Failed to load golden \(goldenURL.path): \(error)",
                file: file, line: line)
        return
    }

    guard actualData == goldenData else {
        // Diff hint: write actual next to golden so developers can
        // eyeball via Quick Look. The artifact lives in the source tree
        // (untracked, gitignored as *.actual.png) — it is NOT attached to
        // the xcresult. ci.yml uploads __Snapshots__/ as a run artifact on
        // test-job failure, which is how a CI-only mismatch's actual
        // render becomes inspectable post-mortem.
        let actualURL = goldenURL.deletingLastPathComponent()
            .appendingPathComponent("\(testName).actual.png")
        try? actualData.write(to: actualURL)
        XCTFail("""
            Snapshot \(testName) mismatch.
              golden: \(goldenURL.path)
              actual: \(actualURL.path)
            If the change is intentional, baseline recording is gated on an \
            env-gated record path (docs/skips-ledger.md restore checklist).
            """,
            file: file, line: line)
        return
    }
}

/// Isolates snapshot tests from global state pollution by other tests in
/// the suite. Without this, prior tests mutating `fontScale`
/// (UserDefaults key read by `@AppStorage("fontScale")`) or
/// `LanguageManager.shared.selectedLanguage` produce different render
/// output under full-suite vs focused test runs.
///
/// Call from `setUp()` of any test class that calls `assertImageSnapshot`.
/// Stores the original values and restores them in `tearDown()`.
@MainActor func snapshotTestSetUp() {
    let defaults = UserDefaults.standard
    // ID-STORE-0007 (2026-08-01): object(forKey:) not double(forKey:) —
    // double() returns 0 for an ABSENT key, which tearDown would then
    // write back as a real 0, polluting production defaults (fontScale=0
    // matches no picker tag and renders the settings row blank).
    snapshotTestSavedFontScale = defaults.object(forKey: "fontScale") as? Double
    // ID-CRASH-0038 (2026-10-02): same missing-aware pattern for the two
    // remaining production-`.standard` `@AppStorage` reads:
    // `SettingsRootView` reads `@AppStorage("settings.selectedTab")`
    // (SettingsRootView.swift:31) and `GeneralSettingsView` reads
    // `@AppStorage("themeAppearance")` (GeneralSettingsView.swift:13).
    // Hygiene only: auto-review-164609's theory that a polluted
    // `settings.selectedTab = update` mis-recorded the root-view golden was
    // falsified locally — byte-compare passes with the key isolated, so the
    // render is invariant to the key and the key cannot explain the CI
    // mismatch (see skips-ledger.md). For the blank-golden family TWO
    // candidate hypotheses remain open (AppKit-backed `Form` rasterization
    // gap vs capture-too-early/settle): the blank region matches the Form
    // subtree and the 4 sibling goldens (single-Form views) are 100% blank,
    // but the picker band is a degenerate render (uniform fill + one glyph
    // cluster, not 4 labels) — that does NOT exclude a settle race. The
    // golden is byte-stable and byte-matches locally, so no
    // environment-independent rendering property explains the CI-only
    // mismatch yet. `themeAppearance` isolation is reasoned-inert, not
    // measured: the only golden it could affect
    // (testSettingsRootViewGeneralTab) is currently skipped. We still remove
    // both keys for the render window so future goldens can never depend on
    // host defaults; tearDown restores the prior value or absence.
    snapshotTestSavedSelectedTab = defaults.object(forKey: "settings.selectedTab") as? String
    snapshotTestSavedThemeAppearance = defaults.object(forKey: "themeAppearance") as? String
    defaults.removeObject(forKey: "settings.selectedTab")
    defaults.removeObject(forKey: "themeAppearance")
    // NEW-4 (2026-08-06 review): missing-aware save for language, mirroring
    // the fontScale pattern. The previous code read
    // `LanguageManager.shared.selectedLanguage` which returned "en" for an
    // ABSENT key (LanguageManager:46 fallback), so tearDown would write
    // "en" back unconditionally — pinning appLanguage to "en" on any host
    // that never had it set.
    // NEW-2 follow-up (2026-08-06): no `appLanguage`/`AppleLanguages`
    // save/restore here. Audit (2026-08-06) confirmed no view reads these
    // directly from `UserDefaults.standard`; they route through
    // `LanguageManager.shared`, which is stubbed below. Saving/restore
    // these would be dead code — and worse, missing-aware restore would
    // pretend the key existed and write back "en" on a host that never
    // had `appLanguage`, pinning the user's prefs. Removed.
    // Force defaults used by our rendered views to a deterministic baseline.
    // Only `fontScale` is read directly via `@AppStorage` by Views
    // (QuickBarView, WelcomeView, NewTagSheet, TagPickerSheet). The
    // language-related keys are routed through `LanguageManager.shared`,
    // which is stubbed below.
    defaults.set(1.0, forKey: "fontScale")
    // NEW-2 follow-up (2026-08-06): install a stub LanguageManager so
    // view bodies that read `LanguageManager.shared.selectedLanguage` see
    // "en" regardless of the host's real preference. Without this, the
    // production `LanguageManager.shared` would initialize from the host
    // defaults (e.g. "zh-Hans" on a Chinese-locale dev machine) and
    // snapshot tests would render the user's preferred language instead
    // of the deterministic baseline, breaking the snapshot comparison.
    //
    // The stub instance uses an isolated testDefaults suite so its
    // `applyLanguage()` write to `AppleLanguages` doesn't escape into the
    // production domain. The `injectedForTest` seam (NEW-2 follow-up)
    // is reset by `snapshotTestTearDown` below.
    let stubDefaults = makeTestDefaults()
    stubDefaults.set("en", forKey: "appLanguage")
    stubDefaults.set(["en"] as [String], forKey: "AppleLanguages")
    let stub = LanguageManager(defaults: stubDefaults)
    LanguageManager.injectedForTest = stub
}

@MainActor func snapshotTestTearDown() {
    let defaults = UserDefaults.standard
    if snapshotTestSavedFontScale != nil {
        defaults.set(snapshotTestSavedFontScale, forKey: "fontScale")
    } else {
        defaults.removeObject(forKey: "fontScale")
    }
    // ID-CRASH-0038 (2026-10-02): missing-aware restore mirrors the setUp
    // save — never pin a key the host never had (same rationale as the
    // fontScale/ID-STORE-0007 note above).
    if snapshotTestSavedSelectedTab != nil {
        defaults.set(snapshotTestSavedSelectedTab, forKey: "settings.selectedTab")
    } else {
        defaults.removeObject(forKey: "settings.selectedTab")
    }
    if snapshotTestSavedThemeAppearance != nil {
        defaults.set(snapshotTestSavedThemeAppearance, forKey: "themeAppearance")
    } else {
        defaults.removeObject(forKey: "themeAppearance")
    }
    // NEW-2 follow-up (2026-08-06): no `appLanguage`/`AppleLanguages`
    // restore here. See the matching note in setUp — language baseline
    // is set, not restored, and the stub instance is the only
    // observation point.
    // NEW-2 follow-up: detach the stub so subsequent tests see the
    // production `LanguageManager.shared` again. The stub's side
    // effects (applyLanguage writes to testDefaults, not the production
    // domain, so this is a clean detach).
    LanguageManager.injectedForTest = nil
}

private var snapshotTestSavedFontScale: Double?
private var snapshotTestSavedSelectedTab: String?
private var snapshotTestSavedThemeAppearance: String?

// MARK: - M13 Test Infrastructure

/// M13: isolated UserDefaults suite factory.
///
/// Tests must never write to `UserDefaults.standard` — the test host shares
/// that domain with the production app, so any write pollutes the user's
/// real preferences and causes local-green / CI-red flakes (ID-MON-0002).
///
/// Usage:
/// ```
/// let defaults = makeTestDefaults()
/// // use defaults in test
/// removeTestDefaults(defaults)
/// ```
private var _testDefaultsSuiteNames: [Int: String] = [:]

func makeTestDefaults() -> UserDefaults {
    let suiteName = "test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    _testDefaultsSuiteNames[ObjectIdentifier(defaults).hashValue] = suiteName
    return defaults
}

func removeTestDefaults(_ defaults: UserDefaults) {
    let key = ObjectIdentifier(defaults).hashValue
    if let suiteName = _testDefaultsSuiteNames[key] {
        defaults.removePersistentDomain(forName: suiteName)
        _testDefaultsSuiteNames[key] = nil
    }
}