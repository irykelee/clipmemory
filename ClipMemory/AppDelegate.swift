import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var clipboardMonitor: ClipboardMonitor!
    private(set) var hotKeyManager: HotKeyManager!
    private(set) var windowManager: WindowManager!
    private var languageObserver: NSObjectProtocol?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindowManager()
        setupStatusItem()
        setupClipboardMonitor()
        setupHotKey()
        setupLanguageObserver()
        NSApp.setActivationPolicy(.accessory)
        if FirstLaunchManager.isFirstLaunch { showWelcomeWindow() }
    }

    private func showWelcomeWindow() {
        let welcome = WelcomeView(hotKeyManager: hotKeyManager) { [weak self] in self?.welcomeWindow?.close() }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        NotificationCenter.default.addObserver(forName: .encryptionFailed, object: nil, queue: .main) { _ in
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
        clipboardMonitor = ClipboardMonitor(); clipboardMonitor.delegate = ClipboardStore.shared
        clipboardMonitor.startMonitoring(); ClipboardStore.shared.clipboardMonitor = clipboardMonitor
        ClipboardStore.shared.updateExcludedAppsOnMonitor()
    }

    private func setupHotKey() {
        hotKeyManager = HotKeyManager()
        hotKeyManager.setShowWindowHandler { [weak self] in DispatchQueue.main.async { self?.windowManager.showQuickBar() } }
        hotKeyManager.register()
    }

    deinit { if let o = languageObserver { NotificationCenter.default.removeObserver(o) } }
}
