import AppKit
import SwiftUI

/// Singleton window controller for the restore wizard (matches the
/// `AppDelegate.showSettingsWindow()` pattern — one window, reused).
final class RestoreWizardWindowController: NSWindowController {
    static let shared = RestoreWizardWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Restore Wizard"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Open (or focus) the wizard with a fresh view model.
    func present(
        backupService: BackupService,
        imagesDirectory: URL,
        defaults: UserDefaults
    ) {
        let vm = RestoreWizardViewModel(
            backupService: backupService,
            imagesDirectory: imagesDirectory,
            defaults: defaults
        )
        let view = RestoreWizardView(vm: vm) { [weak self] in
            self?.close()
        }
        window?.contentView = NSHostingView(rootView: view)
        // Trigger async list load.
        Task { @MainActor in await vm.loadList() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
