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
        // ID-TEST-1024 (2026-10-24): failure used to `fatalError` — killing
        // the whole test host, indistinguishable from the ID-CRASH-class
        // restarts that ID-CRASH-0057 spent 16 .ips files hunting. Fail the
        // current test via XCTFail instead and return a 1×1 opaque red
        // sentinel so the golden comparison below fails deterministically
        // (and the harness keeps running the remaining suites).
        XCTFail("ImageRenderer failed for view at size \(size)")
        return opaqueRedSentinelImage()
    }
    return cgImage
}

/// A 1×1 opaque red image used as the render-failure sentinel. Built
/// through `CGContext`, whose constant arguments here cannot fail.
private func opaqueRedSentinelImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    return context.makeImage()!
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
        // the xcresult. ci.yml (build-and-test job) uploads *.actual.png
        // when a test step in that job fails, which is how a CI-only
        // mismatch's actual render becomes inspectable post-mortem.
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
/// (the UserDefaults key read by
/// `@AppStorage("fontScale", store: AppStorageDefaults.shared)`) or
/// `LanguageManager.shared.selectedLanguage` produce different render
/// output under full-suite vs focused test runs.
///
/// Call from `setUp()` of any test class that calls `assertImageSnapshot`.
/// Points the **appearance** seam (`AppStorageDefaults`) at an isolated
/// per-test suite and restores it in `tearDown()`.
@MainActor func snapshotTestSetUp() {
    // ID-REVIEW-1039 (2026-10-27): the appearance preferences the views
    // read (`fontScale` / `settings.selectedTab` / `themeAppearance`) now
    // resolve against `AppStorageDefaults.shared` — the dedicated appearance
    // seam — because every `@AppStorage` declaration in the view tree carries
    // `store: AppStorageDefaults.shared` (17 sites across 14 view files) and
    // `sz(_:)` reads the same seam.
    //
    // Why the change was needed: the test bundle is injected INTO the app
    // binary (`TEST_HOST`), so `UserDefaults.standard` inside a test
    // process IS the user's real `com.clipmemory.app` domain. The old code
    // therefore had to plant a baseline there (`fontScale = 1.0`) and REMOVE
    // two keys, restoring all three in tearDown — and a restore does not
    // survive a host abort (ID-REVIEW-1038 measured `fontScale = 3.7` left
    // in the user's plist after a trap). On this machine the user's real
    // `settings.selectedTab` was one of the keys the old code deleted around
    // every snapshot test.
    //
    // Now the seam points at a per-test suite, which is EMPTY by
    // construction ⇒ the three keys are absent ⇒ the render is
    // deterministic with **no write at all** — not to the production
    // domain, not to a shared suite. (An absent `fontScale` makes
    // `double(forKey:)` return 0, which the clamp in `sz(_:)` turns back
    // into the base size — the same pixels the old 1.0 baseline produced.)
    let snapshotDefaults = makeTestDefaults()
    snapshotTestDefaults = snapshotDefaults
    AppStorageDefaults.setShared(snapshotDefaults)

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
    //
    // NEW-4 (2026-08-06 review) + NEW-2 follow-up (2026-08-06): the stub
    // needs NO save/restore of `appLanguage` / `AppleLanguages` in the
    // production domain. The previous code read
    // `LanguageManager.shared.selectedLanguage`, which returned "en" for an
    // ABSENT key (LanguageManager:46 fallback), so tearDown wrote "en"
    // back unconditionally — pinning appLanguage to "en" on any host that
    // never had it set. Audit (2026-08-06) confirmed no view reads these
    // keys directly; they route through `LanguageManager.shared`, which is
    // stubbed here.
    let stubDefaults = makeTestDefaults()
    snapshotStubDefaults = stubDefaults
    stubDefaults.set("en", forKey: "appLanguage")
    stubDefaults.set(["en"] as [String], forKey: "AppleLanguages")
    let stub = LanguageManager(defaults: stubDefaults)
    LanguageManager.injectedForTest = stub
}

@MainActor func snapshotTestTearDown() {
    // ID-REVIEW-1039 (2026-10-27): there is nothing to restore in the
    // production domain any more — the snapshot baseline never left the
    // per-test suite (see `snapshotTestSetUp`). What is restored is the
    // seam itself, so the rest of the test process sees the canonical
    // baseline again.
    AppStorageDefaults.setShared(nil)
    if let snapshotDefaults = snapshotTestDefaults {
        removeTestDefaults(snapshotDefaults)
    }
    snapshotTestDefaults = nil

    // ID-REVIEW-1040 (2026-10-27): the stub's suite was created here and
    // was never destroyed — it leaked one plist file per snapshot test.
    // The process-end sweep would have caught it, but a per-test cleanup
    // keeps the footprint bounded even if the sweep never runs.
    if let stubDefaults = snapshotStubDefaults {
        removeTestDefaults(stubDefaults)
    }
    snapshotStubDefaults = nil

    // NEW-2 follow-up (2026-08-06): detach the stub so subsequent tests see
    // the production `LanguageManager.shared` again. The stub's side
    // effects (applyLanguage writes to its own test suite, not the
    // production domain, so this is a clean detach).
    LanguageManager.injectedForTest = nil
}

/// The per-test suite the snapshot baseline lives in, if a snapshot test is
/// running. `nil` outside a snapshot test.
private var snapshotTestDefaults: UserDefaults?

/// The per-test suite the `LanguageManager` stub is bound to, if a snapshot
/// test is running. `nil` outside a snapshot test.
private var snapshotStubDefaults: UserDefaults?

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
/// M13: isolated UserDefaults suite factory.
///
/// ID-REVIEW-1040 (2026-10-27): the suite is created through
/// `TestSuiteCleanup` so that it is **REGISTERED** — and destroying it
/// removes the plist **FILE**, not just its values.
///
/// The old code called `removePersistentDomain` only, which leaves an empty
/// shell file behind on every single call — AND leaves a pending write that
/// cfprefsd later flushes back to disk (measured: the shell comes back in
/// ~1 of 8 runs).
///
/// Census on the developer's machine (2026-10-27, the day this was fixed):
/// **199 804** leftover `*.plist` files in `~/Library/Preferences`,
/// **820 MB** of 4 KB blocks (the bytes themselves are only **21.8 MB**),
/// and **+339 per full test run** before the fix.
/// ⚠️ The earlier figure of "137 997 files / 539 MB" was measured before the
/// census was taken over the WHOLE directory — it counted only the
/// `test-`-prefixed subset. The number above is the whole directory.
func makeTestDefaults() -> UserDefaults {
    TestSuiteCleanup.makeSuite(named: "test-\(UUID().uuidString)")
}

/// Destroys a suite created by `makeTestDefaults()`.
///
/// ID-REVIEW-1040: the domain AND its file go away — see
/// `TestSuiteCleanup` for the measured reason and the load-bearing order.
func removeTestDefaults(_ defaults: UserDefaults) {
    _ = TestSuiteCleanup.destroy(defaults)
}
