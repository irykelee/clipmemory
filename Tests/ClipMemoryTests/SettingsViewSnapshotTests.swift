import XCTest
import SwiftUI
@testable import ClipMemory

/// Snapshot baselines for the extracted SettingsView (NEW-7 Phase 2).
///
/// Locks in the visual regression surface for the settings page so that
/// subsequent refactors of either ContentView or SettingsView (e.g.,
/// future Phase 3 sidebar split) catch accidental layout drift.
///
/// Note: rendering SettingsView requires constructing a `Form` with many
/// `@Binding` parameters and several singleton-backed callbacks. The test
/// builds the simplest valid invocation (a fresh `ClipboardStore`,
/// no-op callbacks, default values for `@Binding` parameters) and lets the
/// snapshots catch any unintended structural change.
final class SettingsViewSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        snapshotTestSetUp()
    }

    override func tearDown() {
        snapshotTestTearDown()
        super.tearDown()
    }

    /// Renders SettingsView at a fixed size with the simplest valid state
    /// (no excluded apps, default fonts, default theme, no recording).
    /// Captures the default settings page layout.
    @MainActor
    func testRendersSettingsDefaultState() {
        // Use the shared singleton store; read-only access for rendering
        // is safe and matches what ContentView passes in production.
        let store = ClipboardStore.shared
        let view = SettingsView(
            languageManager: LanguageManager.shared,
            themeAppearance: .constant("system"),
            isRecordingHotKey: .constant(false),
            showingAppPicker: .constant(false),
            showingTips: .constant(false),
            pendingMaxItemsReduction: .constant(nil),
            hotKeyManager: nil,
            store: store,
            backupService: BackupService.shared,
            onApplyAppearance: {},
            onExportBackup: {},
            onImportBackup: {},
            onShowBackupError: {},
            onShowLaunchAtLoginError: {},
            onShowWelcomeGuide: {},
            onStartHotKeyRecording: {}
        )
        let image = renderToImage(view, size: CGSize(width: 720, height: 1200))
        assertImageSnapshot(
            image,
            className: "SettingsViewSnapshotTests",
            testName: "testRendersSettingsDefaultState"
        )
    }
}