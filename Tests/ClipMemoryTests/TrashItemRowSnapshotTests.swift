import XCTest
import SwiftUI
@testable import ClipMemory

/// Snapshot baseline for TrashItemRow in the image-rendering state.
///
/// Phase 1 of NEW-7: exercises the image-type rendering path so that any
/// future change to the trash row image layout surfaces immediately in
/// the snapshot diff.
///
/// Note: this baseline captures the initial render before the .task kicks
/// in. The `imageLoadFailed` state requires the async `.task` to complete
/// and populate `loadedImage` / `imageLoadFailed`. At t=0 in the snapshot,
/// neither has been set, so the row shows the `ProgressView()` loading
/// state. Capturing the post-load error state requires a test seam and is
/// deferred to Phase 2 (alongside the ContentView split).
final class TrashItemRowSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        snapshotTestSetUp()
    }

    override func tearDown() {
        snapshotTestTearDown()
        super.tearDown()
    }

    /// Renders an image-type item in its initial loading state.
    @MainActor
    func testRendersImageInitialState() {
        let item = ClipboardItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            content: "missing-image-abc.png",
            type: .image,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: false,
            isSensitive: false,
            deletedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let row = TrashItemRow(
            item: item,
            onRestore: {},
            onDeletePermanently: {}
        )
        let image = renderToImage(row, size: CGSize(width: 600, height: 80))
        assertImageSnapshot(
            image,
            className: "TrashItemRowSnapshotTests",
            testName: "testRendersImageInitialState"
        )
    }
}