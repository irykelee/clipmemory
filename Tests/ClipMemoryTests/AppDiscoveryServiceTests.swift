import XCTest
@testable import ClipMemory

final class AppDiscoveryServiceTests: XCTestCase {
    var tempDir: URL!
    var fakeAppPaths: [URL]!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDiscoveryTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create fake .app bundles: real bundleIdentifier requires Info.plist.
        fakeAppPaths = []
        for name in ["TestApp1", "TestApp2"] {
            let appPath = tempDir.appendingPathComponent("\(name).app")
            try? FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
            let infoPlist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                    <key>CFBundleIdentifier</key>
                    <string>com.test.\(name)</string>
                </dict></plist>
                """
            try? infoPlist.data(using: .utf8)!.write(to: appPath.appendingPathComponent("Info.plist"))
            fakeAppPaths.append(appPath)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// P1-AUDIT-2026-09-22 (P1-5): service returns apps from any directory
    /// passed in, with .app filter, bundle id parse, and self-exclusion.
    func testDiscoverReturnsAppsExcludingSelf() throws {
        let svc = AppDiscoveryService(searchDirectories: [tempDir.path], excludedBundleIds: ["com.test.TestApp1"])
        let exp = expectation(description: "discover")
        var found: [AppPickerItem] = []
        svc.discoverInstalledApps { items in
            found = items
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(found.count, 1, "self-exclusion + filter")
        XCTAssertEqual(found.first?.bundleId, "com.test.TestApp2")
    }

    /// P1-AUDIT-2026-09-22: in-process cache returns previously-discovered
    /// result without re-scanning the filesystem.
    func testCacheAvoidsRepeatedScan() throws {
        let svc = AppDiscoveryService(searchDirectories: [tempDir.path], excludedBundleIds: [])
        let exp1 = expectation(description: "first")
        var first: [AppPickerItem] = []
        svc.discoverInstalledApps { items in
            first = items
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 5.0)

        // Remove the app from disk; second discover must NOT re-scan
        // (cache hit) — verify first.count stays > 0 even after delete.
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("TestApp1.app"))
        let exp2 = expectation(description: "second")
        var second: [AppPickerItem] = []
        svc.discoverInstalledApps { items in
            second = items
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 5.0)
        XCTAssertEqual(second.count, first.count, "cache should avoid re-scan")
    }

    /// P1-AUDIT-2026-09-22 (post-broad-review fix): clearCache() forces a fresh
    /// scan, so apps installed/uninstalled between calls are picked up. This
    /// guards against re-introducing the ID-VIEW-0006 regression that the
    /// in-process cache caused when no caller invalidated it.
    func testClearCacheForcesFreshScan() throws {
        let svc = AppDiscoveryService(searchDirectories: [tempDir.path], excludedBundleIds: [])
        let exp1 = expectation(description: "first")
        var first: [AppPickerItem] = []
        svc.discoverInstalledApps { items in
            first = items
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 5.0)
        XCTAssertEqual(first.count, 2, "both fake apps on disk")

        // Remove one app from disk and invalidate the cache.
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("TestApp1.app"))
        svc.clearCache()

        let exp2 = expectation(description: "second")
        var second: [AppPickerItem] = []
        svc.discoverInstalledApps { items in
            second = items
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 5.0)
        XCTAssertEqual(second.count, 1, "fresh scan after clearCache() picks up the removal")
        XCTAssertEqual(second.first?.bundleId, "com.test.TestApp2")
    }
}
