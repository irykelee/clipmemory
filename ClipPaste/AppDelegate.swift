import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var clipboardMonitor: ClipboardMonitor!
    var hotKeyManager: HotKeyManager!
    private var lastPinnedOnly = false
    private var lastSettingsOnly = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupClipboardMonitor()
        setupHotKey()
        NSApp.setActivationPolicy(.accessory)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipPaste")
        }
        statusItem.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示历史", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "固定片段", action: #selector(showPinned), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "设置", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 ClipPaste", action: #selector(quitApp), keyEquivalent: "q"))
        return menu
    }

    @objc private func showHistory() {
        ClipboardStore.shared.loadItems()
        showMainWindow()
    }

    @objc private func showPinned() {
        showMainWindow(pinnedOnly: true)
    }

    @objc private func showSettings() {
        showMainWindow(settingsOnly: true)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                showNotification(title: "已关闭开机自启", body: "ClipPaste 将不会在登录时启动")
            } else {
                try service.register()
                showNotification(title: "已开启开机自启", body: "ClipPaste 将会在登录时自动启动")
            }
        } catch {
            showNotification(title: "设置失败", body: error.localizedDescription)
        }
    }

    private func showNotification(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setupClipboardMonitor() {
        clipboardMonitor = ClipboardMonitor()
        clipboardMonitor.startMonitoring()
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

    // MARK: - Window Frame Persistence

    private let windowFrameKey = "WindowFrame"

    private var savedWindowFrame: NSRect {
        get {
            guard let data = UserDefaults.standard.data(forKey: windowFrameKey),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                  let x = dict["x"], let y = dict["y"],
                  let w = dict["w"], let h = dict["h"] else {
                return NSRect(x: 0, y: 0, width: 400, height: 500)
            }
            return NSRect(x: x, y: y, width: w, height: h)
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
        lastPinnedOnly = pinnedOnly
        lastSettingsOnly = settingsOnly
        if window == nil {
            let contentView = ContentView(pinnedOnly: pinnedOnly, settingsOnly: settingsOnly)
            window = NSWindow(
                contentRect: savedWindowFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClipPaste"
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
}
