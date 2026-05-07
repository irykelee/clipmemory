import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var clipboardMonitor: ClipboardMonitor!
    var hotKeyManager: HotKeyManager!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var languageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupClipboardMonitor()
        setupHotKey()
        setupLanguageObserver()
        NSApp.setActivationPolicy(.accessory)
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
        clipboardMonitor.startMonitoring()
        ClipboardStore.shared.clipboardMonitor = clipboardMonitor
    }

    private func setupHotKey() {
        hotKeyManager = HotKeyManager()
        hotKeyManager.setShowWindowHandler { [weak self] in
            DispatchQueue.main.async {
                self?.showMainWindow()
            }
        }
        hotKeyManager.register()
    }

    private let windowFrameKey = "WindowFrame"

    private var savedWindowFrame: NSRect {
        get {
            let defaultFrame = NSRect(x: 0, y: 0, width: 400, height: 500)
            guard let data = UserDefaults.standard.data(forKey: windowFrameKey),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                  let x = dict["x"], let y = dict["y"],
                  let w = dict["w"], let h = dict["h"] else {
                return defaultFrame
            }
            let savedFrame = NSRect(x: x, y: y, width: w, height: h)
            let anyScreenIntersects = NSScreen.screens.contains { $0.visibleFrame.intersects(savedFrame) }
            if !anyScreenIntersects {
                let visible = NSScreen.main?.visibleFrame ?? defaultFrame
                return NSRect(x: visible.midX - 200, y: visible.midY - 250, width: 400, height: 500)
            }
            return savedFrame
        }
        set {
            let dict: [String: CGFloat] = [
                "x": newValue.origin.x,
                "y": newValue.origin.y,
                "w": newValue.size.width,
                "h": newValue.size.height
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict) {
                UserDefaults.standard.set(data, forKey: windowFrameKey)
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        if let w = window {
            savedWindowFrame = w.frame
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = window {
            savedWindowFrame = w.frame
        }
    }

    func showMainWindow(pinnedOnly: Bool = false, settingsOnly: Bool = false) {
        if window == nil {
            let contentView = ContentView(pinnedOnly: pinnedOnly, settingsOnly: settingsOnly)
            window = NSWindow(
                contentRect: savedWindowFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.appName
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            window.contentView = NSHostingView(rootView: contentView)
        } else {
            window.contentView = NSHostingView(rootView: ContentView(pinnedOnly: pinnedOnly, settingsOnly: settingsOnly))
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
