import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var clipboardMonitor: ClipboardMonitor!
    private(set) var hotKeyManager: HotKeyManager!
    private(set) var windowManager: WindowManager!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var languageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupWindowManager()
        setupClipboardMonitor()
        setupHotKey()
        setupLanguageObserver()
        NSApp.setActivationPolicy(.accessory)
    }

    private func setupWindowManager() {
        windowManager = WindowManager()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipMemory")
        }
        statusItem.menu = createMenu()
    }

    private func setupLanguageObserver() {
        languageObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("LanguageDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildMenu()
        }

        NotificationCenter.default.addObserver(
            forName: .encryptionFailed,
            object: nil,
            queue: .main
        ) { _ in
            let alert = NSAlert()
            alert.messageText = L10n.error
            alert.informativeText = L10n.alertEncryptFailed
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.buttonConfirm)
            alert.runModal()
        }
    }

    private func rebuildMenu() {
        statusItem.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.headerShowAll, action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.headerShowPinned, action: #selector(showPinned), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        launchAtLoginMenuItem = NSMenuItem(title: launchAtLoginTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.buttonSettings, action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.sendFeedback, action: #selector(sendFeedback), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.quitApp, action: #selector(quitApp), keyEquivalent: "q"))
        return menu
    }

    @objc private func showHistory() {
        showMainWindow()
    }

    @objc private func showPinned() {
        showMainWindow(pinnedOnly: true)
    }

    @objc private func showSettings() {
        showMainWindow(settingsOnly: true)
    }

    private func launchAtLoginTitle() -> String {
        let enabled = SMAppService.mainApp.status == .enabled
        return enabled ? "✓ \(L10n.launchAtLogin)" : "  \(L10n.launchAtLogin)"
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                showNotification(title: L10n.launchAtLoginDisabled, body: L10n.launchAtLoginDisabledBody)
            } else {
                try service.register()
                showNotification(title: L10n.launchAtLoginEnabled, body: L10n.launchAtLoginEnabledBody)
            }
            launchAtLoginMenuItem.title = launchAtLoginTitle()
        } catch {
            showNotification(title: L10n.error, body: error.localizedDescription)
        }
    }

    private func showNotification(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.buttonConfirm)
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func sendFeedback() {
        let url = URL(string: "https://github.com/irykelee/clipmemory/issues/new")!
        NSWorkspace.shared.open(url)
    }

    private func setupClipboardMonitor() {
        clipboardMonitor = ClipboardMonitor()
        clipboardMonitor.delegate = ClipboardStore.shared
        clipboardMonitor.startMonitoring()
        ClipboardStore.shared.clipboardMonitor = clipboardMonitor
        ClipboardStore.shared.updateExcludedAppsOnMonitor()
    }

    private func setupHotKey() {
        hotKeyManager = HotKeyManager()
        hotKeyManager.setShowWindowHandler { [weak self] in
            DispatchQueue.main.async {
                self?.windowManager?.showWindow()
            }
        }
        hotKeyManager.register()
    }

    func showMainWindow(pinnedOnly: Bool = false, settingsOnly: Bool = false) {
        windowManager?.showWindow(pinnedOnly: pinnedOnly, settingsOnly: settingsOnly)
    }

    deinit {
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
