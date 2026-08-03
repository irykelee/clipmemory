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
    // P0-1 (2026-07-28 audit): retry CryptoService.prepareKey after
    // unlock-revealing events (system wake, session-become-active,
    // screen unlock). The original code stranded the clipboard for the
    // whole session if Keychain was locked at launchd start.
    // P0-1 follow-up (2026-07-29): added sessionDidBecomeActiveNotification
    // because didWakeNotification alone does not cover fresh-boot + login
    // or screen-lock → unlock without sleep. Both observers also schedule
    // a 3s delayed retry — the notification may arrive before the user
    // enters their password (Keychain still locked).
    private var keychainUnlockObserver: NSObjectProtocol?
    private var sessionBecomeActiveObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    // ID-SECURITY-0001 (2026-07-30 audit): wipe the in-memory root key
    // when the app loses focus / locks / suspends so a memory-dump attack
    // on a suspended process (hibernate image / RAM disk) can't recover
    // raw key bytes. The three registrations cover distinct lock paths:
    // - NSApplication.didResignActiveNotification — app loses focus
    //   (Cmd+Tab away), fires even without FileVault
    // - NSWorkspace.sessionDidResignActiveNotification — screen lock /
    //   fast user switching / logout
    // - NSWorkspace.willSleepNotification — system sleep / hibernate
    // ID-APP-0001 (2026-08-01 audit): ivar names fixed to match the
    // notifications actually registered in setupBackgroundPurgeObservers();
    // they previously referenced namesake notifications that were never
    // observed here.
    private var didResignActiveObserver: NSObjectProtocol?
    private var sessionDidResignActiveObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var lastPrewarmTime: Date = .distantPast
    private var welcomeWindow: NSWindow?
    // ID-LIFE-0020 (2026-07-31 audit): the willClose block observer token
    // used to be discarded, so every welcome-window reopen left a permanent
    // observer whose closure strongly captured the closed NSWindow graph.
    // Stored now; removed on willClose (self-removal) and in deinit.
    // Internal (not private) so the ID-LIFE-0020 regression test can assert
    // the token lifecycle.
    private(set) var welcomeCloseObserver: NSObjectProtocol?
    // Independent settings window (2026-07-25 plan): separate from the main
    // window, opened via menu `⌘,` or the sidebar "Settings" tab. Same
    // `isReleasedWhenClosed = false` pattern as welcomeWindow so SwiftUI
    // @State survives close/reopen.
    private var settingsWindow: NSWindow?
    // ID-LIFE-0021 (2026-07-31 audit): same discarded-token leak as
    // welcomeCloseObserver, for the settings window.
    private(set) var settingsCloseObserver: NSObjectProtocol?
    // CLIP-3 (2026-07-24): debounce .encryptionFailed alerts — see throttler doc.
    private let encryptionAlertThrottler = EncryptionFailedAlertThrottler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // HIGH-3 (2026-07-26 review): own the key-failure alert presentation
        // here instead of in CryptoService so the service layer has no AppKit
        // dependency (NSAlert, NSApp.terminate).
        CryptoService.keyFailureAlertPresenter = { [weak self] failure in
            self?.presentKeyFailureAlert(failure) ?? .quit
        }

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
        // ID-APP-0003 (2026-08-03 audit): logSnapshot writes lastLaunchTime to
        // production .standard BEFORE the AAA suite snapshot, escaping the ZZZ
        // canary (which is structurally blind to writes earlier than its own
        // before-snapshot) AND overwriting the real user's lastLaunchTime on
        // every test run. Skip in test host — same pattern as the test-host
        // guard at :108. StartupHealthTests does not depend on AppDelegate's
        // call path; it invokes logSnapshot directly with an isolated suite.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            StartupHealth.logSnapshot(counts: startupCounts)
        }
        setupHotKey()
        setupLanguageObserver()
        setupKeychainUnlockObserver()
        setupSettingsMenuItem()
        // ID-SECURITY-0001 (2026-07-30 audit): purge in-memory root key
        // when the app loses focus / FileVault locks. See ivar comments.
        setupBackgroundPurgeObservers()
        NSApp.setActivationPolicy(.accessory)
        // ID-MON-0003 (2026-08-03): skip startup side-effects in test host.
        // The test bundle is injected into the real app process, so these
        // calls write to the shared UserDefaults domain used by production —
        // polluting test baseline (UpdateService network probe, BackupService
        // lastBackupDate, etc.). The :469 guard covers setupClipboardMonitor;
        // this guard covers welcome判定 + UpdateService init + backup +
        // OCR backfill. StartupHealth.logSnapshot is now guarded separately
        // at :86 (ID-APP-0003) because it writes lastLaunchTime to the
        // shared .standard domain, not a fresh store. Observer setup above
        // is read-only or test-inert and stays unguarded.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
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
        // ID-LIFE-0007 (2026-07-30 audit): drain in-flight image writes
        // BEFORE ClipboardStore flush, so files already past encrypt complete
        // their disk write before the process exits. Orphan cleanup is
        // handled by cleanupOrphanedImages on next launch.
        ImageStorage.shared.drainPendingWrites()
        hotKeyManager?.unregister()
        clipboardMonitor?.stopMonitoring()
        welcomeWindow?.close()
        settingsWindow?.close()
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
        welcomeWindow = win
        // ID-LIFE-0003 (2026-07-30 audit): register so the main-window-close
        // policy switch keeps the app activated while the welcome window is
        // on screen. Settings window does this (line 317); welcome was the
        // orphan, causing Dock-icon loss on close.
        windowManager?.registerSecondaryWindow(win)
        // ID-LIFE-0004 (2026-07-30 audit): win.isReleasedWhenClosed = false
        // means closing the window doesn't deallocate it; the welcomeWindow
        // ivar + NSHostingView would otherwise leak. Nil the ivar + unregister
        // on willClose so the next reopen starts from a clean slate.
        // ID-LIFE-0020 (2026-07-31 audit): keep the observer token and
        // self-remove inside the handler — a discarded token left a permanent
        // observer (and its strongly-captured window graph) per reopen.
        if let stale = welcomeCloseObserver {
            NotificationCenter.default.removeObserver(stale)
            welcomeCloseObserver = nil
        }
        let welcomeRef = win
        welcomeCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: welcomeRef, queue: .main
        ) { [weak self] _ in
            self?.welcomeWindow = nil
            self?.windowManager?.unregisterSecondaryWindow(welcomeRef)
            if let self, let observer = self.welcomeCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                self.welcomeCloseObserver = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupWindowManager() { windowManager = WindowManager() }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // ID-L10N-0010 (2026-07-30 audit): use L10n.appName for VoiceOver. The
            // tooltip below already does this; consistency across both is
            // the fix. SF Symbol name itself stays English (Apple platform
            // convention).
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: L10n.appName)
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

    /// Inserts the "设置…" (⌘,) menu item into the app menu.
    /// Uses title-based lookup rather than a hardcoded index so the insert
    /// position is stable regardless of system language or future menu changes.
    /// Falls back to `item(at: 1)` if title matching fails.
    private func setupSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first(where: { $0.title == "ClipMemory" })?.submenu
            ?? NSApp.mainMenu?.item(at: 1)?.submenu
        else { return }

        // Insert after the first separator (below About / Preferences area).
        let settingsItem = NSMenuItem(
            title: L10n.settingsWindowTitle,
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self

        // Find the index of the "About" item (or first separator) to insert after.
        if let aboutIndex = appMenu.items.firstIndex(where: { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) }) {
            appMenu.insertItem(NSMenuItem.separator(), at: aboutIndex + 1)
            appMenu.insertItem(settingsItem, at: aboutIndex + 2)
        } else {
            // Fallback: append to the menu.
            appMenu.addItem(NSMenuItem.separator())
            appMenu.addItem(settingsItem)
        }
    }

    private func setupLanguageObserver() {
        languageObserver = NotificationCenter.default.addObserver(forName: Notification.Name("LanguageDidChange"), object: nil, queue: .main) { [weak self] _ in
            self?.statusItem?.button?.toolTip = L10n.appName
        }
        encryptionFailedObserver = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: .main
        ) { [weak self] note in
            // XCTest injects into the real app, so this observer is live
            // during tests — and tests deliberately post .encryptionFailed
            // (OCRTests encrypt-failure fixtures). A modal runModal there
            // blocks the test process forever (2026-07-24 CI hang: Test
            // step stuck >60 min). Same guard as CryptoService.isRunningTests.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            // CLIP-3 (2026-07-24): batch failure paths (OCR backfill, bulk
            // tag encryption) post one notification per item — one modal per
            // notification is an alert storm. Throttle per H-3 source tag;
            // suppressed failures are counted into the next alert's text.
            guard let self else { return }
            let source = EncryptionFailedAlertThrottler.sourceKey(for: note)
            let decision = encryptionAlertThrottler.recordFailure(source: source)
            guard decision.shouldShowAlert else { return }
            let a = NSAlert()
            a.messageText = L10n.error
            a.informativeText = decision.failureCount > 1
                ? L10n.alertEncryptFailedCount(decision.failureCount)
                : L10n.alertEncryptFailed
            a.alertStyle = .warning
            a.addButton(withTitle: L10n.buttonConfirm)
            a.runModal()
        }
    }

    @objc func showMainWindow() {
        // H-1: optional — fail quietly if WindowManager not initialized.
        windowManager?.showMainWindow()
    }

    // P0-1 (2026-07-28 audit): retry CryptoService.prepareKey when the
    // system wakes from sleep or the user session becomes active (login /
    // screen unlock). Both notifications are proxies for "Keychain may
    // now be unlocked"; the retry is idempotent (no-op if the key is
    // already loaded), so it's safe to fire on every event.
    //
    // P0-1 follow-up (2026-07-29): added sessionDidBecomeActiveNotification
    // because didWakeNotification does NOT fire on fresh-boot + first login
    // or screen-lock → unlock without sleep — the two most common "login
    // items launch before first unlock" scenarios. Both observers also
    // schedule a single 3 s delayed retry when the immediate retry returns
    // nil, covering the race where the notification fires before the user
    // enters their password (Keychain still locked at notification time).
    private func setupKeychainUnlockObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        let retry: () -> Void = {
            if CryptoService.retryPrepareKeyIfLocked() == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    CryptoService.retryPrepareKeyIfLocked()
                }
            }
        }
        let prewarmIfNeeded: () -> Void = { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastPrewarmTime) >= 5 else { return }
            self.lastPrewarmTime = now
            MainActor.assumeIsolated {
                ClipboardStore.shared.prewarmDecryptionCache(items: ClipboardStore.shared.items)
            }
        }
        keychainUnlockObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in retry(); prewarmIfNeeded() }
        sessionBecomeActiveObserver = nc.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in retry(); prewarmIfNeeded() }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in prewarmIfNeeded() }
    }

    /// ID-SECURITY-0001 (2026-07-30 audit): register observers that wipe
    /// `CryptoService.cachedLoadedKey` whenever the app loses focus /
    /// the user locks the screen / the system sleeps. The next
    /// foreground operation transparently re-prepares the key from
    /// Keychain (existing `getKey()` flow).
    ///
    /// Notification selection rationale:
    /// - `NSApplication.didResignActiveNotification` — app loses focus
    ///   (Cmd+Tab away, dialog dismissed). Fires even without FileVault.
    /// - `NSWorkspace.sessionDidResignActiveNotification` — user session
    ///   went inactive: screen lock, fast user switching, logout. This
    ///   is the closest AppKit signal to "user stepped away from
    ///   computer"; FileVault lock begins around the same event.
    /// - `NSWorkspace.willSleepNotification` — system sleep / hibernate.
    ///   Memory may be written to disk (RAM-backed hibernation image),
    ///   where raw key bytes would survive. Purge before sleep.
    /// Deinit cleanup uses the `removeObserver(_:)` token pattern that
    /// already handles the other lifecycle observers in this file.
    private func setupBackgroundPurgeObservers() {
        let purge: () -> Void = {
            // Clear the in-memory key. Next foreground will re-prepare.
            CryptoService.shared.clearInMemoryKey()
        }
        didResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in purge() }
        sessionDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main
        ) { _ in purge() }
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in purge() }
    }

    /// Independent settings window (2026-07-25 plan). Replaces the previous
    /// main-window-embedded settings tab. Both the menu `⌘,` entry and the
    /// sidebar "Settings" tab call this method.
    @objc func showSettingsWindow() {
        // Close any existing settings window before opening a new one so
        // repeated invocations don't stack windows and leak the old reference.
        // B-6 (2026-07-27): unregister the old window first so the previous
        // reference is cleared from WindowManager's secondaryWindows table —
        // otherwise the closed-but-not-deallocated NSWindow would still be
        // counted as "visible" and the main-window-close policy would never
        // sink to .accessory.
        if let old = settingsWindow {
            windowManager?.unregisterSecondaryWindow(old)
            old.close()
        }
        settingsWindow = nil

        let rootView = SettingsRootView(
            hotKeyManager: hotKeyManager,
            store: ClipboardStore.shared,
            backupService: BackupService.shared
        )
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = L10n.settingsWindowTitle
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(rootView: rootView)
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
        // B-6 (2026-07-27): register so the main-window-close policy switch
        // keeps the app activated while the settings window is on screen.
        windowManager?.registerSecondaryWindow(win)
        // ID-LIFE-0004 (2026-07-30 audit): same nil-on-close as welcome window.
        // ID-LIFE-0021 (2026-07-31 audit): keep the observer token and
        // self-remove inside the handler — same discarded-token leak as the
        // welcome window (ID-LIFE-0020).
        if let stale = settingsCloseObserver {
            NotificationCenter.default.removeObserver(stale)
            settingsCloseObserver = nil
        }
        let settingsRef = win
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: settingsRef, queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
            self?.windowManager?.unregisterSecondaryWindow(settingsRef)
            if let self, let observer = self.settingsCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                self.settingsCloseObserver = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Menu `⌘,` handler. Delegates to the independent settings window
    /// instead of the previous main-window tab switch.
    @objc private func showSettings() {
        showSettingsWindow()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func sendFeedback() {
        // LOW-7 (2026-07-26 review): guard-let instead of force-unwrap.
        guard let url = URL(string: "https://github.com/irykelee/clipmemory/issues/new") else { return }
        NSWorkspace.shared.open(url)
    }

    // F-1 phase 3 (2026-07-28): method accesses @MainActor-isolated
    // ClipboardStore members (onRecordOwnWrite, onExcludedAppsChanged,
    // parseExcludedBundleIds). Invoked from main-thread
    // applicationDidFinishLaunching (line 37), which is @MainActor per
    // NSApplicationDelegate's Swift protocol isolation.
    @MainActor private func setupClipboardMonitor() {
        // Initialize store first so image migration observer is registered
        _ = ClipboardStore.shared
        // Then trigger ImageStorage migration
        _ = ImageStorage.shared
        // ID-MON-0002 (2026-08-01): under XCTest the test bundle is injected
        // into the real app, so a live monitor here captures REAL pasteboard
        // writes (including writes made by other tests) into the production
        // UserDefaults store — encrypted with the XCTest fixture key, which
        // production then reports as corrupted ("N 条损坏"). Keep the store /
        // ImageStorage first-touch above (tests rely on it for migration
        // coverage); skip only the live monitor. Tests that exercise
        // ClipboardMonitor construct their own instance.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // H-1: optional — guard init result so a partial ClipboardMonitor
        // construction doesn't take the whole app down. We still let the
        // store run; the menu bar QuickBar just won't auto-refresh from
        // system paste events until relaunch.
        let monitor = ClipboardMonitor()
        monitor.delegate = ClipboardStore.shared
        monitor.startMonitoring()
        clipboardMonitor = monitor
        // MED-5 (2026-07-26 review): wire anti-recapture + excluded-apps via
        // closures instead of a bidirectional ClipboardStore.clipboardMonitor ref.
        ClipboardStore.shared.onRecordOwnWrite = { @MainActor [weak monitor] in
            monitor?.recordOwnWrite()
        }
        ClipboardStore.shared.onExcludedAppsChanged = { @MainActor [weak monitor] ids in
            monitor?.excludedBundleIds = ids
        }
        // Apply initial excluded-apps state from stored settings.
        // F-2 sweep (2026-07-28): dropped MainActor.assumeIsolated wrap.
        // setupClipboardMonitor is itself @MainActor (per F-1 phase 3 commit
        // `6a311c8`), so `parseExcludedBundleIds()` (inherited @MainActor from
        // class-level annotation on ClipboardStore) is directly callable
        // without runtime bridge.
        monitor.excludedBundleIds = ClipboardStore.shared.parseExcludedBundleIds()
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
        if let o = keychainUnlockObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = sessionBecomeActiveObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = didBecomeActiveObserver { NotificationCenter.default.removeObserver(o) }
        // ID-SECURITY-0001 (2026-07-30 audit): remove the background-purge
        // observers alongside the other lifecycle observers.
        if let o = didResignActiveObserver { NotificationCenter.default.removeObserver(o) }
        // ID-APP-0002 (2026-08-01 audit): sessionDidResignActiveObserver is
        // registered on NotificationCenter.default (see
        // setupBackgroundPurgeObservers) but was removed from the NSWorkspace
        // center here — a no-op that leaked the observer for the process
        // lifetime. Remove it from the center it was actually registered on.
        if let o = sessionDidResignActiveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = willSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        // ID-LIFE-0020 / ID-LIFE-0021 (2026-07-31 audit): the willClose
        // observers normally self-remove when their window closes; deinit
        // is the safety net for a still-open window at teardown.
        if let o = welcomeCloseObserver { NotificationCenter.default.removeObserver(o) }
        if let o = settingsCloseObserver { NotificationCenter.default.removeObserver(o) }
        // BUG-037 (2026-07-21): deinit was observer-only. Carbon hotkey,
        // clipboard monitor timer, and welcome window are cleaned only
        // in applicationWillTerminate. If AppDelegate is ever deallocated
        // outside the terminate path, those resources leak. Mirror the
        // terminate cleanup here as a safety net.
        hotKeyManager?.unregister()
        clipboardMonitor?.stopMonitoring()
        welcomeWindow?.close()
        settingsWindow?.close()
    }

    // MARK: - Key Failure Alert (moved from CryptoService, HIGH-3)

    /// HIGH-3 (2026-07-26 review): presents the key-failure critical alert.
    /// Previously a `private static` method on CryptoService — moved here so
    /// the service layer has no AppKit dependency (NSAlert, NSApp.terminate).
    /// Must run on the main thread; callers dispatch.
    private func presentKeyFailureAlert(_ failure: CryptoKeyFailure) -> KeyFailureAction {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        let alert = NSAlert()
        alert.alertStyle = .critical
        switch failure {
        case .corruptExistingKey:
            alert.messageText = L10n.alertKeyCorruptTitle
            alert.informativeText = L10n.alertKeyCorruptMessage
            alert.addButton(withTitle: L10n.quitApp)
            alert.addButton(withTitle: L10n.alertKeyButtonReset)
        case .secureRandomUnavailable:
            alert.messageText = L10n.alertKeyRandomTitle
            alert.informativeText = L10n.alertKeyRandomMessage
            alert.addButton(withTitle: L10n.quitApp)
        case .keyStorageFailed:
            alert.messageText = L10n.alertKeyStorageTitle
            alert.informativeText = L10n.alertKeyStorageMessage
            alert.addButton(withTitle: L10n.quitApp)
            alert.addButton(withTitle: L10n.alertKeyButtonRetry)
        }
        let response = alert.runModal()
        if failure == .secureRandomUnavailable { return .quit }
        return response == .alertSecondButtonReturn ? .regenerate : .quit
    }
}
