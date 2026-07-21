import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    // H-1 (2026-07-20 audit): IUO `!` forces an implicit — and unguarded —
    // unwrap at every read site. If the relevant `setup*` step fails partway,
    // the very next read crashes here instead of producing a clear log line.
    // `Optional + guard/bind` makes the failure mode explicit and lets the
    // app keep running (showing "QuickBar unavailable" is better than
    // hard-crashing from the menu bar click).
    var statusItem: NSStatusItem?
    var clipboardMonitor: ClipboardMonitor?
    private(set) var hotKeyManager: HotKeyManager?
    private(set) var windowManager: WindowManager?
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
        // C: start HangDetector watchdog last so all prior setup completes
        // before the main-thread heartbeat timer begins ticking.
        HangDetector.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // M-6 fix (2026-07-20 audit): the previous terminate hook only
        // flushed the store and stopped the watchdog. Graceful quit is the
        // happy path on macOS, but `applicationWillTerminate` is **not**
        // guaranteed for SIGKILL, Force Quit, or logout — those still leak
        // Carbon hotkey registration, pasteboard poll timers, and NSPanel
        // refs (we can't defend against SIGKILL from userspace). For the
        // graceful path we now also unregister the Carbon hotkey, stop
        // clipboard polling, and close the welcome window eagerly — same
        // cleanup the deinit path would do.
        ClipboardStore.shared.flushPendingSaves()
        hotKeyManager?.unregister()
        clipboardMonitor?.stopMonitoring()
        welcomeWindow?.close()
        HangDetector.stop()
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

        // H-1: hotKeyManager is now Optional. If setupHotKey() failed earlier
        // we still want the welcome view to render — pass an unbinding here
        // would crash on the first instruction row that reads `hotKeyRef`.
        // Fall back to a fresh-but-unregistered instance so the welcome can
        // still describe the default Cmd+Shift+V bound at app start.
        let hotKey = hotKeyManager ?? HotKeyManager()
        let welcome = WelcomeView(hotKeyManager: hotKey) { [weak self] in
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
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipMemory")
            button.toolTip = L10n.appName
            button.target = self; button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        // H-1: both optional now. setStatusItem accepts non-nil; guard explicitly.
        if let item = statusItem, let wm = windowManager { wm.setStatusItem(item) }
    }

    @objc private func statusItemClicked() {
        // H-1: windowManager is optional — quietly fail if setup didn't complete
        // rather than crashing. QuickBar is a nice-to-have; the app stays usable.
        windowManager?.showQuickBar()
    }

    private func setupLanguageObserver() {
        languageObserver = NotificationCenter.default.addObserver(forName: Notification.Name("LanguageDidChange"), object: nil, queue: .main) { [weak self] _ in
            self?.statusItem?.button?.toolTip = L10n.appName
        }
        encryptionFailedObserver = NotificationCenter.default.addObserver(forName: .encryptionFailed, object: nil, queue: .main) { _ in
            let a = NSAlert(); a.messageText = L10n.error; a.informativeText = L10n.alertEncryptFailed; a.alertStyle = .warning; a.addButton(withTitle: L10n.buttonConfirm); a.runModal()
        }
    }

    @objc func showMainWindow() {
        // H-1: optional — fail quietly if WindowManager not initialized.
        windowManager?.showMainWindow()
    }

    @objc private func showSettings() {
        windowManager?.showMainWindow()
        NotificationCenter.default.post(name: .showSettingsTab, object: nil)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func sendFeedback() { NSWorkspace.shared.open(URL(string: "https://github.com/irykelee/clipmemory/issues/new")!) }

    private func setupClipboardMonitor() {
        // Initialize store first so image migration observer is registered
        _ = ClipboardStore.shared
        // Then trigger ImageStorage migration
        _ = ImageStorage.shared
        // H-1: optional — guard init result so a partial ClipboardMonitor
        // construction doesn't take the whole app down. We still let the
        // store run; the menu bar QuickBar just won't auto-refresh from
        // system paste events until relaunch.
        let monitor = ClipboardMonitor()
        monitor.delegate = ClipboardStore.shared
        monitor.startMonitoring()
        clipboardMonitor = monitor
        ClipboardStore.shared.clipboardMonitor = monitor
        ClipboardStore.shared.updateExcludedAppsOnMonitor()
    }

    private func setupHotKey() {
        // H-1: optional — same idea. Carbon hotkey registration is best-effort;
        // a failure here must not prevent the rest of the app from launching.
        let hotKey = HotKeyManager()
        hotKey.setShowWindowHandler { [weak self] in
            DispatchQueue.main.async { self?.windowManager?.showMainWindow() }
        }
        hotKey.register()
        hotKeyManager = hotKey
    }

    deinit {
        if let o = languageObserver { NotificationCenter.default.removeObserver(o) }
        if let o = encryptionFailedObserver { NotificationCenter.default.removeObserver(o) }
        // BUG-037 (2026-07-21): deinit was observer-only. Carbon hotkey,
        // clipboard monitor timer, and welcome window are cleaned only
        // in applicationWillTerminate. If AppDelegate is ever deallocated
        // outside the terminate path, those resources leak. Mirror the
        // terminate cleanup here as a safety net.
        hotKeyManager?.unregister()
        clipboardMonitor?.stopMonitoring()
        welcomeWindow?.close()
    }
}
