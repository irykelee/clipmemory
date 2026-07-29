import XCTest
import SwiftUI
@testable import ClipMemory

/// MED-7 (2026-07-26 review): snapshot tests for the four settings-window
/// tabs, replacing the deprecated SettingsViewSnapshotTests.
///
/// Each test uses an isolated ClipboardStore (MemoryStorageBackend) and
/// deterministic snapshot baseline (fontScale=1.0, language=en) so tests
/// are independent of global state from other test files (MED-2).
/// F-1 phase 2 (2026-07-28): @MainActor — ClipboardStore init is @MainActor.
@MainActor
final class SettingsTabSnapshotTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        snapshotTestSetUp()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
    }

    override func tearDown() {
        store = nil
        backend = nil
        snapshotTestTearDown()
        super.tearDown()
    }

    // MARK: - GeneralSettingsView

    func testGeneralSettingsTabDefault() {
        let view = GeneralSettingsView(hotKeyManager: nil)
        let image = renderToImage(view, size: CGSize(width: 640, height: 480))
        assertImageSnapshot(image, className: "SettingsTabSnapshotTests",
                           testName: "testGeneralSettingsTabDefault")
    }

    // MARK: - HistoryCaptureSettingsView

    func testHistoryCaptureTabDefault() {
        let view = HistoryCaptureSettingsView(store: store)
        let image = renderToImage(view, size: CGSize(width: 640, height: 560))
        assertImageSnapshot(image, className: "SettingsTabSnapshotTests",
                           testName: "testHistoryCaptureTabDefault")
    }

    // MARK: - BackupSettingsView

    func testBackupTabDefault() {
        let view = BackupSettingsView(backupService: .shared)
        let image = renderToImage(view, size: CGSize(width: 640, height: 400))
        assertImageSnapshot(image, className: "SettingsTabSnapshotTests",
                           testName: "testBackupTabDefault")
    }

    // MARK: - UpdateAboutSettingsView

    func testUpdateAboutTabDefault() {
        let view = UpdateAboutSettingsView()
        let image = renderToImage(view, size: CGSize(width: 640, height: 520))
        assertImageSnapshot(image, className: "SettingsTabSnapshotTests",
                           testName: "testUpdateAboutTabDefault")
    }

    // MARK: - SettingsRootView

    func testSettingsRootViewGeneralTab() {
        let view = SettingsRootView(hotKeyManager: nil, store: store,
                                    backupService: .shared)
        let image = renderToImage(view, size: CGSize(width: 680, height: 560))
        assertImageSnapshot(image, className: "SettingsTabSnapshotTests",
                           testName: "testSettingsRootViewGeneralTab")
    }
}
