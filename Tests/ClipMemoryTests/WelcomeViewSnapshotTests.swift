import XCTest
import SwiftUI
@testable import ClipMemory

/// Snapshot baseline for the WelcomeView shown on first launch.
///
/// Phase 1 of NEW-7: this test establishes the snapshot pipeline (helper
/// module, golden record) so subsequent ContentView split work has visual
/// regression coverage. WelcomeView is the easiest valid target — small,
/// only requires a `HotKeyManager` (fresh instance avoids the `.shared`
/// Carbon registration side effects) and a no-op `onComplete`.
///
/// Note: `WelcomeView.onAppear` calls `checkHotKeyConflict()`, which reads
/// `hotKeyManager.hotKeyRef` / `registerAttempted`. With a fresh
/// `HotKeyManager()` both default to nil/false, so `onAppear` does not
/// change visible state. ImageRenderer does not invoke `.onAppear` during
/// offscreen rendering, so the snapshot captures the un-conflicted state
/// deterministically.
@MainActor
final class WelcomeViewSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        snapshotTestSetUp()
    }

    override func tearDown() {
        snapshotTestTearDown()
        super.tearDown()
    }

    func testRendersWelcome() throws {
        // ID-REVIEW-1039 (2026-10-27): hermeticity IS fixed — the view's
        // `@AppStorage` now names the app's appearance seam, so the render
        // no longer reads the production domain. And the test is NOT stable
        // locally: measured with `-test-iterations 10` it passes **2 of 10**
        // when run on its own, and **0 of 10** when run in the same batch as
        // the ClipboardItemRow class — on HEAD (`bad7bc9`) as well as on this
        // branch (0 of 10 in the batch).
        //
        // The earlier note in this file claimed "6 of 6 pass, so the CI
        // failure must be a different mechanism". That was **sample noise** —
        // one 6-iteration run happened to pass. Only the repeated measurement
        // separates the two, and it says the test is flaky here too.
        //
        // Mechanism (same as the ClipboardItemRow pair):
        // `assertImageSnapshot` compares PNG **BYTES**
        // (`SnapshotTestHelpers.swift:137`); golden vs render differ by
        // **13 pixels out of 345 600** with a maximum channel delta of
        // **1** — anti-aliasing noise on a text edge, not a content
        // difference.
        //
        // Recovery condition: the comparator must tolerate rasterization
        // noise (compare pixels with a tolerance instead of PNG bytes). See
        // docs/skips-ledger.md.
        throw XCTSkip("ID-CRASH-0038 skip: PNG byte-compare vs non-deterministic anti-aliasing (2/10 solo pass, 2026-10-27); see skips-ledger.md")
        let view = WelcomeView(
            hotKeyManager: HotKeyManager(),
            onComplete: {}
        )
        let image = renderToImage(view, size: CGSize(width: 720, height: 480))

        assertImageSnapshot(
            image,
            className: "WelcomeViewSnapshotTests",
            testName: "testRendersWelcome"
        )
    }
}
