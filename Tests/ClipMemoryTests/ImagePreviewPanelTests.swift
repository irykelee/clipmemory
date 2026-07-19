import XCTest
@testable import ClipMemory

/// Image preview sizing: native size when it fits, native + scroll when the
/// screen can't hold it — never downscale a big screenshot into unreadable
/// text (the old 300 px in-row cap complaint).
final class ImagePreviewPanelTests: XCTestCase {

    private let screen = NSSize(width: 1512, height: 982) // 14" MBP visible frame

    func testSmallImageShowsAtNativeSizeNoScroll() {
        let layout = ImagePreviewPanel.layout(imageSize: NSSize(width: 800, height: 600), screenSize: screen)
        XCTAssertEqual(layout.panelSize, NSSize(width: 800, height: 600))
        XCTAssertEqual(layout.imageSize, NSSize(width: 800, height: 600))
        XCTAssertFalse(layout.scrollable)
    }

    func testImageExactlyAtCapIsNotScrollable() {
        let cap = NSSize(width: floor(screen.width * 0.9), height: floor(screen.height * 0.9))
        let layout = ImagePreviewPanel.layout(imageSize: cap, screenSize: screen)
        XCTAssertFalse(layout.scrollable)
        XCTAssertEqual(layout.panelSize, cap)
    }

    func testWideScreenshotKeepsNativeSizeAndScrolls() {
        // A dual-monitor wide shot: downscaling to the row width is exactly
        // the "看不清" case — must stay native and scroll instead.
        let wide = NSSize(width: 5120, height: 1440)
        let layout = ImagePreviewPanel.layout(imageSize: wide, screenSize: screen)
        XCTAssertTrue(layout.scrollable)
        XCTAssertEqual(layout.imageSize, wide, "image keeps native resolution inside the scroll view")
        XCTAssertEqual(layout.panelSize.width, floor(screen.width * 0.9))
        XCTAssertEqual(layout.panelSize.height, floor(screen.height * 0.9))
    }

    func testTallScreenshotScrollsVertically() {
        let tall = NSSize(width: 1200, height: 4000)
        let layout = ImagePreviewPanel.layout(imageSize: tall, screenSize: screen)
        XCTAssertTrue(layout.scrollable)
        XCTAssertEqual(layout.imageSize, tall)
    }

    func testZeroSizeImageDoesNotProduceZeroPanel() {
        let layout = ImagePreviewPanel.layout(imageSize: .zero, screenSize: screen)
        XCTAssertFalse(layout.scrollable)
        XCTAssertGreaterThan(layout.panelSize.width, 0)
        XCTAssertGreaterThan(layout.panelSize.height, 0)
    }
}
