import XCTest
@testable import ClipMemory

/// Verify the dual-channel feed selection: the jsDelivr mirror is used only
/// when the primary GitHub feed is unreachable.
final class UpdateServiceTests: XCTestCase {

    private let primary = URL(string: "https://github.com/irykelee/clipmemory/releases/latest/download/appcast.xml")!

    func testResolvedFeedKeepsPrimaryWhenReachable() {
        let resolved = UpdateService.resolvedFeedURL(primary: primary, primaryReachable: true)
        XCTAssertEqual(resolved, primary, "reachable primary must be kept")
    }

    func testResolvedFeedFallsBackWhenPrimaryUnreachable() {
        let resolved = UpdateService.resolvedFeedURL(primary: primary, primaryReachable: false)
        XCTAssertEqual(resolved, UpdateService.fallbackFeedURL, "unreachable primary must switch to the mirror")
        XCTAssertNotEqual(resolved, primary)
    }

    func testFallbackFeedIsJsDelivrMirrorOfMainBranch() {
        let fallback = UpdateService.fallbackFeedURL.absoluteString
        XCTAssertTrue(fallback.hasPrefix("https://cdn.jsdelivr.net/gh/irykelee/clipmemory@main/"),
                      "fallback must be the jsDelivr mirror of this repo's main branch")
        XCTAssertTrue(fallback.hasSuffix("appcast.xml"))
    }
}
