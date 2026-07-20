import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var clipboardMonitor: ClipboardMonitor!
    private(set) var hotKeyManager: HotKeyManager!
    private(set) var windowManager: WindowManager!
    private var languageObserver: NSObjectProtocol?
    private var encryptionFailedObserver: NSObjectProtocol?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindowManager()
        setupStatusItem()
        setupClipboardMonitor()
        // A.2: log startup health snapshot BEFORE long-running ops (backup,
        // OCR backfill, Sparkle) so it appears first in `log show` output
        // and is the first thing we look at on the next bug.
        let startupCounts = StartupHealth.Counts(
            items: ClipboardStore.shared.items.count,
            trashed: ClipboardStore.shared.trashedItems.count,
            tags: ClipboardStore.shared.tags.count
        )
        StartupHealth.logSnapshot(counts: startupCounts)
        setupHotKey()
        setupLanguageObserver()
        NSApp.setActivationPolicy(.accessory)
        if FirstLaunchManager.isFirstLaunch { showWelcomeWindow() }
        // Start Sparkle: daily background check per SUEnableAutomaticChecks.
        _ = UpdateService.shared
        // Daily local backup (throttled internally to once per 24h).
        BackupService.shared.performBackupIfNeeded()
        // One-time OCR backfill for pre-existing image items.
        ClipboardStore.shared.backfillOCRIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardStore.shared.flushPendingSaves()
    }

    @objc func disableFindMenuShortcut() {
        let findSel = Selector(("performFindPanelAction:"))
        for menu in NSApp.mainMenu?.items ?? [] {
            walkMenu(menu.submenu) { item in
                if item.action == findSel {
                    item.target = self
                    item.action = #selector(handleFindAction)
                    item.keyEquivalent = ""  // Remove Cmd+F keyboard shortcut
                }
            }
        }
    }

    private func walkMenu(_ menu: NSMenu?, visit: (NSMenuItem) -> Void) {
        guard let menu else { return }
        for item in menu.items {
            visit(item)
            walkMenu(item.submenu, visit: visit)
        }
    }

    @objc private func handleFindAction() {
        NotificationCenter.default.post(name: .cmdFFindAction, object: nil)
    }

    private func showWelcomeWindow() {
        showWelcomeView { FirstLaunchManager.markLaunched() }
    }

    @objc func showWelcomeView(onComplete: (() -> Void)? = nil) {
        // Close any existing welcome window before opening a new one so repeated
        // "view welcome" actions don't stack windows and leak the old reference.
        welcomeWindow?.close()
        welcomeWindow = nil

        let welcome = WelcomeView(hotKeyManager: hotKeyManager) { [weak self] in
            self?.welcomeWindow?.close()
            onComplete?()
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L10n.appName; win.isReleasedWhenClosed = false; win.center()
        win.contentView = NSHostingView(rootView: welcome); win.makeKeyAndOrderFront(nil)
        welcomeWindow = win; NSApp.activate(ignoringOtherApps: true)
    }

    private func setupWindowManager() { windowManager = WindowManager() }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipMemory")
            button.toolTip = L10n.appName
            button.target = self; button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        windowManager.setStatusItem(statusItem)
    }

    @objc private func statusItemClicked() { windowManager.showQuickBar() }

    private func setupLanguageObserver() {
        languageObserver = NotificationCenter.default.addObserver(forName: Notification.Name("LanguageDidChange"), object: nil, queue: .main) { [weak self] _ in
            self?.statusItem.button?.toolTip = L10n.appName
        }
        encryptionFailedObserver = NotificationCenter.default.addObserver(forName: .encryptionFailed, object: nil, queue: .main) { _ in
            let a = NSAlert(); a.messageText = L10n.error; a.informativeText = L10n.alertEncryptFailed; a.alertStyle = .warning; a.addButton(withTitle: L10n.buttonConfirm); a.runModal()
        }
    }

    @objc func showMainWindow() { windowManager.showMainWindow() }

    @objc private func showSettings() {
        windowManager.showMainWindow()
        NotificationCenter.default.post(name: .showSettingsTab, object: nil)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func sendFeedback() { NSWorkspace.shared.open(URL(string: "https://github.com/irykelee/clipmemory/issues/new")!) }

    private func setupClipboardMonitor() {
        // Initialize store first so image migration observer is registered
        _ = ClipboardStore.shared
        // Then trigger ImageStorage migration
        _ = ImageStorage.shared
        clipboardMonitor = ClipboardMonitor()
        clipboardMonitor.delegate = ClipboardStore.shared
        clipboardMonitor.startMonitoring()
        ClipboardStore.shared.clipboardMonitor = clipboardMonitor
        ClipboardStore.shared.updateExcludedAppsOnMonitor()
    }

    private func setupHotKey() {
        hotKeyManager = HotKeyManager()
        hotKeyManager.setShowWindowHandler { [weak self] in DispatchQueue.main.async { self?.windowManager.showMainWindow() } }
        hotKeyManager.register()
    }

    deinit { if let o = languageObserver { NotificationCenter.default.removeObserver(o) }; if let o = encryptionFailedObserver { NotificationCenter.default.removeObserver(o) } }
}
