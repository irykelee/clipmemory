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
        defaults: UserDefaults,
        // ID-CRASH-0032 (2026-09-28 code-review P2-25): optional view
        // factory routed via `WindowManager.restoreWizardViewFactory`.
        // The factory matches the inline construction shape
        // (`vm` + onClose closure) so a no-op nil-fallback keeps the
        // previous behaviour for non-WindowManager-managed paths.
        viewFactory: ((RestoreWizardViewModel, @escaping () -> Void) -> RestoreWizardView)? = nil
    ) {
        let vm = RestoreWizardViewModel(
            backupService: backupService,
            imagesDirectory: imagesDirectory,
            defaults: defaults
        )
        let view = (viewFactory ?? { vmInstance, onCloseInstance in
            RestoreWizardView(vm: vmInstance) { [weak self] in
                self?.close()
                onCloseInstance()
            }
        })(vm) { [weak self] in
            self?.close()
        }
        window?.contentView = NSHostingView(rootView: view)
        // Trigger async list load.
        Task { @MainActor in await vm.loadList() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
