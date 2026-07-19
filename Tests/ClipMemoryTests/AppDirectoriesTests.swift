import XCTest
@testable import ClipMemory

/// H7: Application Support resolution must never force-unwrap — an empty
/// system lookup falls back to `~/Library/Application Support`.
final class AppDirectoriesTests: XCTestCase {

    func testResolvePrefersFirstSystemCandidate() {
        let candidate = URL(fileURLWithPath: "/System/Candidate", isDirectory: true)
        let home = URL(fileURLWithPath: "/tmp/fakehome", isDirectory: true)
        let resolved = AppDirectories.resolve(candidates: [candidate], home: home)
        XCTAssertEqual(resolved, candidate)
    }

    func testResolveFallsBackToHomeLibraryWhenNoCandidates() {
        let home = URL(fileURLWithPath: "/tmp/fakehome", isDirectory: true)
        let resolved = AppDirectories.resolve(candidates: [], home: home)
        XCTAssertEqual(resolved.path, "/tmp/fakehome/Library/Application Support")
    }

    func testApplicationSupportMatchesSystemLookupOnThisMachine() {
        let system = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        XCTAssertNotNil(system, "test machine should have an Application Support directory")
        XCTAssertEqual(AppDirectories.applicationSupport, system)
    }
}
