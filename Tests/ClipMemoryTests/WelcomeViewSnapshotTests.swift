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
final class WelcomeViewSnapshotTests: XCTestCase {

    @MainActor
    func testRendersWelcome() {
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