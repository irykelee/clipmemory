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
///
/// NEW-2 (2026-08-06 review): also injects `UpdateService` (NEW-2) and
/// `UpdateService.defaults` so snapshot rendering of UpdateAboutSettingsView
/// does NOT trigger the production singleton — which previously fired
/// `migrateFeedConsentIfNeeded` (writing `UpdateFeedPolicy = automatic`),
/// the Sparkle `SPUStandardUpdaterController` (`SUHasLaunchedBefore`,
/// `SULastCheckTime`, `SUUpdateGroupIdentifier`), and the appcast probe
/// (`LastPrimaryAppcastItemDate`). Five of the six production keys
/// caught by the ZZZ canary came from this class.
@MainActor
final class SettingsTabSnapshotTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var testDefaults: UserDefaults!
    private var savedUpdateDefaults: UserDefaults!
    private var stubUpdateService: UpdateService!

    override func setUp() {
        super.setUp()
        snapshotTestSetUp()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
        // NEW-2: isolate UpdateService into the test's defaults suite plus
        // a stub probe engine. `autoStart: false` skips the production
        // init's Task that starts the Sparkle updater.
        testDefaults = makeTestDefaults()
        savedUpdateDefaults = UpdateService.defaults
        UpdateService.defaults = testDefaults
        stubUpdateService = UpdateService(
            probeEngine: StubFeedProbeEngine(),
            autoStart: false
        )
        UpdateService.injectedForTest = stubUpdateService
    }

    override func tearDown() {
        UpdateService.injectedForTest = nil
        stubUpdateService = nil
        UpdateService.defaults = savedUpdateDefaults
        removeTestDefaults(testDefaults)
        testDefaults = nil
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
