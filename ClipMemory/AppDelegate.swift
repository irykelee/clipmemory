import AppKit
import Darwin
import SwiftUI
import ServiceManagement
import os.log

// swiftlint:disable file_length

class AppDelegate: NSObject, NSApplicationDelegate {
    // H-2 (2026-08-08): shared logger for AppDelegate observers that
    // currently have no dedicated logger (encryptionFailedObserver uses
    // NSAlert which logs via osascript/NSAlert's own pipeline; the new
    // trashLoadFailed observer uses AppKit.log directly so it surfaces
    // in Console.app and `log show --predicate ...`).
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "AppDelegate")

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
    private var clipboardSaveFailedObserver: NSObjectProtocol?
    // ID-CRASH-0007 (2026-09-28 code-review P1-1): mirror observer for
    // `.tagSaveFailed` so tag-save failures route through the same
    // throttler + NSAlert UI as items-save failures (independent
    // sourceKey bucket). Separate observer variable because
    // NotificationCenter has no multi-name API in Foundation.
    private var tagSaveFailedObserver: NSObjectProtocol?
    // ID-CRASH-0012 (2026-09-28 code-review P1-2): mirror observer
    // for `.imageSaveFailed` so image-write failures route through
    // the same throttler + NSAlert UI as items-save + tag-save
    // failures (independent sourceKey bucket "imageSave").
    private var imageSaveFailedObserver: NSObjectProtocol?
    // H-2 (2026-08-08): observer for `.trashLoadFailed` so the user
    // sees a signal when the trash blob was corrupt. Without this
    // observer, the quarantine + sweep-skip happens silently and the
    // user's trash appears empty with no explanation. Mirror of
    // `encryptionFailedObserver` lifecycle (registered in
    // setupObservers, released in deinit).
    private var trashLoadFailedObserver: NSObjectProtocol?
    // ID-CRASH-0022 (2026-10-20): observer for `.trashItemsExpired` —
    // the recycle bin's retention purge removed items, and the user
    // must be told (the purge used to be a silent DELETE). Separate
    // observer variable because NotificationCenter has no multi-name
    // API in Foundation — same pattern as `.tagSaveFailed` / `.imageSaveFailed`.
    private var trashItemsExpiredObserver: NSObjectProtocol?
    /// ID-CRASH-0035 (2026-10-21): observer for `.trashPurgePending` —
    /// the retention purge wants to delete a LOT of entries and is
    /// waiting for the user's confirmation. Its own observer variable for
    /// the same reason as the ones above (NotificationCenter has no
    /// multi-name API).
    private var trashPurgePendingObserver: NSObjectProtocol?
    /// ID-CRASH-0035 (2026-10-21): how many recycle-bin entries are
    /// waiting for the user's confirmation before the retention purge may
    /// delete them. `0` means "nothing pending".
    private var pendingTrashPurgeCount: Int = 0
    /// ID-CRASH-0035: the retention window that produced the pending
    /// purge — shown in the confirmation so the user knows the rule that
    /// is about to apply.
    private var pendingTrashPurgeRetentionDays: Int = 0
    // ID-CRASH-0022 (2026-10-20): observer for `.itemsLoadFailed` — the
    // clipboard history blob was unreadable and was quarantined. The
    // trash side has had a user-visible signal since 2026-08-08 and the
    // tags side has `.tagBackendCorrupted`; the items side — the biggest
    // dataset of the three — had only a log line, so the user saw their
    // history disappear with no explanation. Its own throttler bucket
    // ("itemsLoadFailed").
    private var itemsLoadFailedObserver: NSObjectProtocol?
    // ID-CRASH-0008 (2026-09-28 code-review P1-3): observer for
    // `.tagBackendCorrupted` so the user's tag sidebar emptiness is
    // surfaced via `DiagnosticsBanner.tagsLoadFailed` instead of
    // going silently empty. Was a dead notification per the report's
    // finding (no observer consumed it). Now routes through the
    // same banner that handles `keyUnavailable` and
    // `dataCorruptedCount` — UI side zero new components.
    private var tagBackendCorruptedObserver: NSObjectProtocol?
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
    /// H-1 (2026-08-08 audit): independent throttler for save failures —
    /// keeps disk-full / iCloud sync-conflict / permission-revoked in
    /// their own 60s bucket so one transient cause doesn't suppress
    /// alerts for unrelated ones.
    private let saveAlertThrottler = EncryptionFailedAlertThrottler()
    /// H-1 (2026-08-08 audit): independent throttler for trash load failures
    /// — keeps disk-full / prior-launch-persistent in their own 60s bucket
    /// so save/encryption/trash alerts don't suppress each other.
    private let trashAlertThrottler = EncryptionFailedAlertThrottler()

    /// ID-CRASH-0032: how long a second instance waits for the lock before
    /// it gives up and exits. The lock is released by the kernel when the
    /// owning process exits, so this only has to cover "the other instance
    /// is still shutting down" — a quitting instance drains its pending
    /// writes first, which is bounded by `shouldTerminateTimeout` (5s).
    /// Two seconds covers the common case (the process is gone within a
    /// few milliseconds); a longer drain means the newcomer refuses, and
    /// the user simply starts the app again.
    private static let instanceLockTimeout: TimeInterval = 2.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ID-CRASH-0032 (2026-10-20): single-instance guard. This MUST
        // run before anything touches the user's data.
        //
        // The history and the recycle bin are stored as WHOLE-ARRAY
        // replacements: `ClipboardItems` and `ClipboardTrashedItems` are
        // one JSON blob each, and every write replaces the whole array.
        // Two processes each hold their own snapshot of that blob, so the
        // second writer replaces the first writer's blob with its own
        // stale copy — entries the first deleted come back, entries the
        // first added disappear.
        //
        // The decision is an exclusive `flock` on a lock file
        // (`SingleInstanceLock`): the kernel releases it when the owner
        // exits — even on SIGKILL, so a crashed instance leaves no stale
        // lock — and every copy of the app shares it, because a
        // `/Applications` install and a Debug build in DerivedData have the
        // same bundle id, the same UserDefaults domain and therefore the
        // same data.
        //
        // The check is skipped in a test host (`TestIsolation.isRunningTests`):
        // the test host IS the app and the build tool launches it on every
        // `xcodebuild test`. It is already isolated onto its own
        // UserDefaults suite — so it never contends for the user's data —
        // and it must not lock the user out of their own app while the
        // suite runs. A PLAIN launch obeys the guard, and that is exactly
        // the instance that must not write alongside another one.
        if !TestIsolation.isRunningTests,
           !SingleInstanceLock.shared.acquire(timeout: Self.instanceLockTimeout) {
            refuseToRunAsDuplicateInstance()
        }
        // HIGH-3 (2026-07-26 review): own the key-failure alert presentation
        // here instead of in CryptoService so the service layer has no AppKit
        // dependency (NSAlert, NSApp.terminate).
        CryptoService.keyFailureAlertPresenter = { [weak self] failure in
            self?.presentKeyFailureAlert(failure) ?? .quit
        }
        // ID-CRASH-0034 (2026-09-28 code-review P2-19): CryptoService
        // also posts `.cryptoServiceRequestTerminateApp` (defined in
        // `Services/EncryptionFailureAlert.swift`) instead of calling
        // `NSApp.terminate(nil)` directly. AppDelegate owns the actual
        // NSApp.terminate so the service layer stays AppKit-free.
        NotificationCenter.default.addObserver(
            forName: .cryptoServiceRequestTerminateApp,
            object: nil,
            queue: .main
        ) { _ in
            NSApp.terminate(nil)
        }

        setupWindowManager()
        setupStatusItem()
        setupClipboardMonitor()
        // ID-STORE-0018 (MEDIUM-6 audit fix, 2026-08-15): start the
        // network monitor so offline → online transitions trigger an
        // immediate flush of any queued ClipboardStore / ImageStorage
        // writes, instead of waiting for the next user copy or the
        // 16 s × 16 = 256 s backoff ladder to expire.
        NetworkMonitor.shared.start()
        setupNetworkRecoveryObserver()
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
        if !TestIsolation.isRunningTests {
            StartupHealth.logSnapshot(counts: startupCounts)
        }
        setupHotKey()
        setupLanguageObserver()
        setupKeychainUnlockObserver()
        // ID-PERF-0005 (2026-08-16 audit MEDIUM-13 fix): install memory-warning
        // observer before any work that could prime caches (OCR backfill,
        // prewarm, first render). See `setupMemoryWarningObserver` for the
        // iOS-vs-macOS API rationale.
        setupMemoryWarningObserver()
        // ID-CRASH-0003 (2026-08-16 audit MEDIUM-1 fix): detect whether
        // the previous launch crashed (no sentinel) and enter safe-mode
        // after 3 consecutive crashes. Call BEFORE OCR backfill / backup
        // schedule so a stuck crash loop doesn't repeatedly re-prime
        // expensive work. The banner observer is registered separately
        // by ContentView's banner view; this call only updates the
        // persistent state and posts the change notification.
        SafeModeService.shared.registerPreviousLaunchDidCrash()
        setupSettingsMenuItem()
        // ID-CRASH-0002 (2026-08-16 audit MEDIUM-1 fix): install Help →
        // View Recent Crashes. The lazy window is created on first
        // invocation by `showRecentCrashes`; here we only attach the
        // menu item to the main menu's Help slot.
        setupHelpMenuItem()
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
        guard !TestIsolation.isRunningTests else { return }
        if FirstLaunchManager.isFirstLaunch { showWelcomeWindow() }
        // Start Sparkle: daily background check per SUEnableAutomaticChecks.
        _ = UpdateService.shared
        // Daily local backup (throttled internally to once per 24h).
        BackupService.shared.performBackupIfNeeded()
        // One-time OCR backfill for pre-existing image items.
        // P2-14 round-2 self-review fix [P1-1]: defer backfill until
        // the async first-load lands, otherwise `items == []` here
        // (load decode hasn't yet hit the MainActor hop) and the
        // backfill short-circuits on `candidates.isEmpty` for every
        // launch — every pre-existing image's `ocrAttempted` flag
        // stays false forever, BUG-010's "retry next launch" promise
        // never gets a chance to fire. Test suite stayed green because
        // OCRTests manually call `store.loadItems()` (the now-test-only
        // sync path) before invoking backfill.
        Task { @MainActor in
            await ClipboardStore.shared.waitForFirstLoad()
            ClipboardStore.shared.backfillOCRIfNeeded()
        }
        // C: start HangDetector watchdog last so all prior setup completes
        // before the main-thread heartbeat timer begins ticking.
        HangDetector.start()
    }

    // ID-LIFE-0026 (MEDIUM-2, audit 2026-08-15): graceful-quit gate. AppKit calls this
    // BEFORE `applicationWillTerminate` for normal Cmd+Q quits (NOT for SIGKILL
    // / Force Quit — those bypass us entirely). When writes are in flight
    // (large-image backfill mid-write, OCR backfill mid-write, debounced
    // store flush queued), we return `.terminateLater` and asynchronously drain
    // before calling `replyToApplicationShouldTerminate(true)`. Without this gate,
    // `applicationWillTerminate`'s sync drain could race with the dispatch queue
    // and the last write slips; cleanupOrphanedImages would recover it on next
    // launch, but the user-visible behavior is "I quit and a record vanished".
    //
    // Watchdog: if drain hangs (network-mounted Images/ stuck, etc.) the 5s
    // timer aborts the quit instead of trapping the user. `hasRepliedToTerminate`
    // is a one-shot guard so the drain-completion reply and the watchdog reply
    // race safely (the second call is a no-op per AppKit's documented contract).
    private static let shouldTerminateTimeout: TimeInterval = 5
    private let terminateReplyLock = NSLock()
    private var hasRepliedToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasPending = ClipboardStore.shared.needsSave
            || ImageStorage.shared.hasPendingWrites
        guard hasPending else { return .terminateNow }

        NSLog("[AppDelegate] applicationShouldTerminate: pending writes detected, deferring quit")
        // Reset the replied flag for the next quit cycle.
        terminateReplyLock.lock()
        hasRepliedToTerminate = false
        terminateReplyLock.unlock()

        // Drain on a global queue so main stays free to fire the watchdog.
        // ID-LIFE-0007 ordering preserved (image writes before clipboard saves).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ImageStorage.shared.drainPendingWrites()
            // ID-STORE-0022 (P1-AUDIT-2026-09-22 follow-up 2026-09-25):
            // flushPendingSaves is now called ONLY from main-thread sites
            // (applicationWillTerminate, ContentView trim-confirm, BackupSettings
            // import, RestoreWizard). The drain itself does NOT call it —
            // `applicationWillTerminate` runs synchronously on main after
            // AppKit accepts the .terminateLater reply and is guaranteed to
            // execute before the process exits (CL-Gate / macOS lifecycle),
            // so the durability guarantee moves there. Removes the recursion
            // risk that came from draining flushPendingSaves via
            // DispatchQueue.main.sync inside the bg queue (which nested
            // RunLoop.main.run from bg and triggered libdispatch BUG in
            // GH Actions release runs — see auto-review 20260924-194701 P1).
            // The earlier `DispatchQueue.main.sync { flushPendingSaves }`
            // block here was the source of those test crashes; removing it
            // eliminates the cross-thread flush path entirely.
            DispatchQueue.main.async {
                self?.replyToTermination(allow: true)
            }
        }
        // Watchdog: if the drain doesn't complete in time, abort the quit
        // rather than trap the user with a frozen quit. They'd retry Cmd+Q.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shouldTerminateTimeout) {
            self.replyToTermination(allow: false)
        }
        return .terminateLater
    }

    /// One-shot reply wrapper. The first call wins; subsequent calls are
    /// no-ops. `allow=false` is the watchdog's "drain timed out" path;
    /// `allow=true` is the drain-completed path.
    private func replyToTermination(allow: Bool) {
        terminateReplyLock.lock()
        let alreadyReplied = hasRepliedToTerminate
        if !alreadyReplied {
            hasRepliedToTerminate = true
        }
        terminateReplyLock.unlock()
        guard !alreadyReplied else { return }
        if !allow {
            os_log(.error, log: OSLog(subsystem: "com.clipmemory.app", category: "AppDelegate"),
                   "applicationShouldTerminate: drain timeout (>%ds), aborting quit",
                   Int(Self.shouldTerminateTimeout))
        }
        // ID-LIFE-0026: `NSApp.reply(toApplicationShouldTerminate:)` is the
        // macOS 14+ replacement for the legacy `replyToApplicationShouldTerminate`.
        // Project deployment target is 13.0 (project.yml:21), but the
        // legacy name is treated as a hard "renamed" error by the 14+
        // SDK, so the new name is the only path that compiles here.
        // If 13.x support is required in the future, the pre-14 path
        // needs a runtime ObjC selector dispatch workaround.
        NSApp.reply(toApplicationShouldTerminate: allow)
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
        // ID-CRASH-0003 (2026-08-16 audit MEDIUM-1 fix): clear the
        // safe-mode sentinel on graceful exit. If we crash, the
        // sentinel stays in place and the NEXT launch's
        // registerPreviousLaunchDidCrash() counts this as a crash.
        SafeModeService.shared.clearSentinelOnNormalExit()
    }

    // ID-STORE-0018 (MEDIUM-6 audit fix, 2026-08-15): when the network
    // monitor posts `didBecomeReachable`, drain any writes that piled up
    // during the offline window. Order: image writes first (ID-LIFE-0007
    // pattern), then ClipboardStore flush. The save retry path's
    // exponential backoff would eventually retry on its own, but a 30-min
    // offline window would still delay the queue by up to 256 s of backoff
    // after the link comes back. This observer short-circuits that.
    private func setupNetworkRecoveryObserver() {
        // ID-STORE-0018: register the offline→online observer. The
        // `forName: Notification.Name("NetworkMonitor.didBecomeReachable")`
        // form (Pattern B in NotificationObserverAssertionTests) is used
        // instead of `forName: .didBecomeReachable` (Pattern A) because
        // `addObserver(forName:)` is typed as `NSNotification.Name?`, and
        // member-lookup dot syntax would resolve to NSNotification.Name
        // (which doesn't have `didBecomeReachable`) and fail to compile.
        // The inline-literal form bypasses the member-lookup entirely
        // and the test's regex picks it up correctly.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NetworkMonitor.didBecomeReachable"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSLog("[AppDelegate] NetworkMonitor.didBecomeReachable — draining queued writes")
            ImageStorage.shared.drainPendingWrites()
            ClipboardStore.shared.flushPendingSaves()
            _ = self
        }
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
        let welcome = windowManager?.welcomeViewFactory(hotKey) { [weak self] in
            self?.welcomeWindow?.close()
            onComplete?()
        } ?? WelcomeView(hotKeyManager: hotKey, onComplete: { [weak self] in
            self?.welcomeWindow?.close()
            onComplete?()
        })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 740),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
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

    /// ID-PERF-0005 (2026-08-16 audit MEDIUM-13 fix): install the macOS
    /// memory-warning observer. The corresponding iOS-only API is
    /// `UIApplicationDelegate.applicationDidReceiveMemoryWarning(_:)`;
    /// on macOS the equivalent signal is the system-wide notification
    /// posted by `NSApplication` when the system is under memory
    /// pressure (available since macOS 10.0). We use the raw string
    /// `NSApplicationDidReceiveMemoryWarningNotification` (rather than
    /// a Swift overlay name) because the Swift overlay for AppKit
    /// constants is incomplete — verifying the raw value with the
    /// notification-name test guards against silent no-ops if Apple
    /// ever renames either side of the symbol.
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationDidReceiveMemoryWarningNotification"),
            object: nil,
            queue: .main
        ) { _ in
            MemoryCacheRegistry.flushAll()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // ID-L10N-0010 (2026-07-30 audit): use L10n.appName for VoiceOver. The
            // tooltip below already does this; consistency across both is
            // the fix. SF Symbol name itself stays English (Apple platform
            // convention).
            button.image = Self.defaultStatusImage()
            button.toolTip = L10n.appName
            button.target = self; button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        // H-1: both optional now. setStatusItem accepts non-nil; guard explicitly.
        if let item = statusItem, let wm = windowManager { wm.setStatusItem(item) }
    }

    @MainActor @objc private func statusItemClicked() {
        // ID-CRASH-0035 (2026-10-21): a pending retention purge takes
        // precedence over the QuickBar. The badge is the only affordance
        // for a decision that has to be made before data is deleted, and
        // the user clicked it on purpose — so this is the one place where
        // a modal confirmation is acceptable: it can never pop up on its
        // own.
        if pendingTrashPurgeCount > 0 {
            // ID-REVIEW-1026 (2026-10-24, independent review P1): the
            // badge can be STALE. The user may have restored or deleted
            // those entries themselves, which resolves the pending set in
            // the store while the badge is still up — the live count is
            // then 0 and there is nothing left to ask about. The badge
            // GATES the QuickBar, so a click that ended in "nothing
            // happened" left the user with an app that looked stuck.
            // Falling through to the QuickBar is the answer.
            if presentTrashPurgeConfirmation() { return }
            windowManager?.showQuickBar()
            return
        }
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

    /// ID-CRASH-0002 (2026-08-16 audit MEDIUM-1 fix): install the
    /// "Help → View Recent Crashes" menu item. We add it to the
    /// standard Help menu (created automatically by AppKit's default
    /// main menu, indexed 3 in a typical layout: App / File / Edit /
    /// Help / Window / etc.). macOS only creates the Help menu when
    /// the app's Info.plist sets `CFBundleHelpBookName`, but it
    /// always reserves a slot — we append the item there regardless
    /// so the user can find it from the standard menu bar.
    private func setupHelpMenuItem() {
        // Find an existing Help menu by title, fall back to creating one.
        // AppKit's default main menu does NOT include a Help menu unless
        // the app's Xcode template added one — but the project uses a
        // minimal main menu (see project.yml's `INFOPLIST_KEY_LSUIElement`
        // + accessory activation policy), so we may need to create.
        var helpMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Help" })?.submenu
        if helpMenu == nil {
            let created = NSMenuItem()
            created.title = "Help"
            NSApp.mainMenu?.addItem(created)
            let submenu = NSMenu(title: "Help")
            created.submenu = submenu
            helpMenu = submenu
        }
        guard let helpMenu else { return }

        let crashItem = NSMenuItem(
            title: L10n.crashMenuViewRecent,
            action: #selector(showRecentCrashes),
            keyEquivalent: ""
        )
        crashItem.target = self
        helpMenu.addItem(crashItem)
    }

    /// ID-CRASH-0002: action wired to Help → View Recent Crashes. Lazily
    /// creates the window on first invocation; subsequent invocations
    /// re-focus the existing window. SwiftUI's `.task(id:)` re-runs on
    /// every `.onAppear`, so re-showing the window refreshes the list
    /// (matching macOS convention that re-opening a window reflects
    /// current state).
    @objc func showRecentCrashes() {
        if let existing = recentCrashesWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.crashWindowTitle
        window.contentViewController = NSHostingController(
            rootView: windowManager?.recentCrashesViewFactory() ?? RecentCrashesView()
        )
        window.setFrameAutosaveName("com.clipmemory.app.RecentCrashesWindow")
        window.center()
        recentCrashesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ID-CRASH-0002: window kept alive between Help-menu invocations
    /// so re-opening restores the user's last position (via
    /// `setFrameAutosaveName`) instead of recentering every time.
    private var recentCrashesWindow: NSWindow?

    /// ID-CRASH-0022 (2026-10-20): the two observers for the data-loss
    /// signals of the recycle bin and the clipboard history.
    ///
    /// Split out of `setupLanguageObserver()` — that function is a
    /// grab-bag of observer registrations and had crossed the
    /// SwiftLint `function_body_length` ceiling.
    ///
    /// Both notifications are posted ASYNCHRONOUSLY by their senders
    /// (see `TrashStore.postTrashLoadFailed` and
    /// `ClipboardStore.postItemsLoadFailed`) precisely so that these
    /// observers — registered here, during the launch sequence — are
    /// in place when they fire: the sends happen inside the store's
    /// construction, which is earlier in the same launch.
    private func setupTrashAndItemsObservers() {
        // The recycle bin's retention purge removed items, and the
        // user must be told. Without this, the purge was a silent
        // DELETE: the 2026-10-20 incident emptied 106 items in one
        // launch and said nothing.
        trashItemsExpiredObserver = NotificationCenter.default.addObserver(
            forName: .trashItemsExpired, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleTrashItemsExpired(note)
        }
        // ID-CRASH-0035 (2026-10-21): a retention purge that would remove
        // a LOT of entries waits for the user's confirmation. The badge
        // on the menu bar item carries that pending state — never a
        // modal alert, because the purge also runs on a 60 s timer and a
        // modal could pop up in the middle of a session.
        trashPurgePendingObserver = NotificationCenter.default.addObserver(
            forName: .trashPurgePending, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleTrashPurgePending(note)
        }
        // The items blob was unreadable and got quarantined. Without
        // this, the user sees their clipboard history disappear with no
        // explanation and no hint that a `.corrupt-*` copy exists.
        itemsLoadFailedObserver = NotificationCenter.default.addObserver(
            forName: .itemsLoadFailed, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleItemsLoadFailed(note)
        }
    }

    private func setupLanguageObserver() {
        languageObserver = NotificationCenter.default.addObserver(forName: .languageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.statusItem?.button?.toolTip = L10n.appName
        }
        encryptionFailedObserver = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleEncryptionFailed(note)
        }
        trashLoadFailedObserver = NotificationCenter.default.addObserver(
            forName: .trashLoadFailed, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleTrashLoadFailed(note)
        }
        setupTrashAndItemsObservers()

        // ID-CRASH-0008 (2026-09-28 code-review P1-3): observer for
        // `.tagBackendCorrupted` (posted by `ClipboardStore.loadTags()`
        // catch) so the user's tag sidebar emptiness is surfaced via
        // `DiagnosticsBanner.tagsLoadFailed`. Before this observer,
        // the notification was a dead channel (per the report's
        // finding — no consumer). Sets `store.diagnostics.tagsLoadFailed
        // = true` on main thread (required since `diagnostics` is
        // `@Published` on the main actor). The banner itself
        // (`DiagnosticsBanner.swift`) was extended to show the
        // new message; UI side zero new components.
        tagBackendCorruptedObserver = NotificationCenter.default.addObserver(
            forName: .tagBackendCorrupted, object: nil, queue: .main
        ) { [weak self] _ in
            // Same XCTest guard pattern as the trash / clipboard
            // observers above — tests deliberately post this
            // notification to verify the banner path; banner
            // mutations are main-actor only.
            guard !TestIsolation.isRunningTests else { return }
            // Same strongSelf unwrap pattern as ID-CRASH-0007.
            guard let strongSelf = self else { return }
            ClipboardStore.shared.diagnostics.tagsLoadFailed = true
        }

        // H-1 (2026-08-08 audit): v2.8.1's ID-SILENT-0021 fix posted
        // .clipboardSaveFailed but no production observer consumed it —
        // clipboard captures could silently fail and the user had no
        // signal. Wire the notification to NSAlert via the existing
        // 60s Throttler, bucketed by sourceKey so disk-full vs iCloud
        // sync-conflict don't suppress each other. NSAlert (not
        // DiagnosticsBanner) because DecryptionDiagnostics has no
        // save-failed slot and the user genuinely needs to act now
        // (free disk space, reconnect volume, etc.).
        clipboardSaveFailedObserver = NotificationCenter.default.addObserver(
            forName: .clipboardSaveFailed, object: nil, queue: .main
        ) { [weak self] note in
            // Same XCTest guard: tests deliberately post
            // .clipboardSaveFailed to verify flushSave's failure path;
            // runModal here would hang CI forever.
            guard !TestIsolation.isRunningTests else { return }
            guard let strongSelf = self else { return }
            strongSelf.handleSaveFailureNotification(note)
        }

        // ID-CRASH-0007 (2026-09-28 code-review P1-1): mirror
        // observer for `.tagSaveFailed` so a tag-save failure paths
        // through the same throttler + NSAlert UI as items-save
        // failures. Separate observer (rather than `forNames:`)
        // because NotificationCenter has no multi-name API in
        // Foundation; body delegates to a shared handler so both
        // notification names funnel through one recordFailure call.
        tagSaveFailedObserver = NotificationCenter.default.addObserver(
            forName: .tagSaveFailed, object: nil, queue: .main
        ) { [weak self] note in
            // Same XCTest guard as clipboardSaveFailedObserver above.
            guard !TestIsolation.isRunningTests else { return }
            guard let strongSelf = self else { return }
            strongSelf.handleSaveFailureNotification(note)
        }

        // ID-CRASH-0012 (2026-09-28 code-review P1-2): mirror observer
        // for `.imageSaveFailed` — items + tags + images all funnel
        // through `handleSaveFailureNotification`, which routes via
        // `saveAlertThrottler` with sourceKey buckets. "imageSave"
        // is its own bucket so an image disk-full doesn't suppress
        // an items-save alert (or vice versa).
        imageSaveFailedObserver = NotificationCenter.default.addObserver(
            forName: .imageSaveFailed, object: nil, queue: .main
        ) { [weak self] note in
            // Same XCTest guard as tagSaveFailedObserver above.
            guard !TestIsolation.isRunningTests else { return }
            guard let strongSelf = self else { return }
            strongSelf.handleSaveFailureNotification(note)
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
        closeExistingSettingsWindow()

        let rootView = buildSettingsRootView()
        let win = makeSettingsWindow(rootView: rootView)
        positionSettingsWindow(win, relativeTo: windowManager?.mainWindow)
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
        // B-6 (2026-07-27): register so the main-window-close policy switch
        // keeps the app activated while the settings window is on screen.
        windowManager?.registerSecondaryWindow(win)
        installSettingsCloseObserver(for: win)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close any existing settings window before opening a new one so
    /// repeated invocations don't stack windows and leak the old reference.
    /// B-6 (2026-07-27): unregister the old window first so the previous
    /// reference is cleared from WindowManager's secondaryWindows table —
    /// otherwise the closed-but-not-deallocated NSWindow would still be
    /// counted as "visible" and the main-window-close policy would never
    /// sink to .accessory.
    private func closeExistingSettingsWindow() {
        if let old = settingsWindow {
            windowManager?.unregisterSecondaryWindow(old)
            old.close()
        }
        settingsWindow = nil
    }

    /// ID-CRASH-0032 (2026-09-28 code-review P2-25): route through
    /// `windowManager?.settingsRootViewFactory` so this construction
    /// site stops bypassing the factory indirection (WINDOW-P1-4
    /// exemption's premise失效 — see WindowManager.swift factories).
    private func buildSettingsRootView() -> SettingsRootView {
        windowManager?.settingsRootViewFactory(
            hotKeyManager,
            ClipboardStore.shared,
            BackupService.shared
        ) ?? SettingsRootView(
            hotKeyManager: hotKeyManager,
            store: ClipboardStore.shared,
            backupService: BackupService.shared
        )
    }

    /// Builds the `NSWindow` shell with frame autosave and SwiftUI
    /// hosting view. ID-LIFE-0027 (MEDIUM-3 audit fix, 2026-08-15):
    /// persist the user's resized frame across launches via AppKit's
    /// frame-autosave (matches WINDOW-0001's MainWindow convention).
    private func makeSettingsWindow(rootView: SettingsRootView) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = L10n.settingsWindowTitle
        win.setFrameAutosaveName("com.clipmemory.app.SettingsWindow")
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: rootView)
        return win
    }

    /// Center `win` relative to the main ItemListView window when it's on
    /// screen (the common path: user has the main window open and clicks
    /// the sidebar "Settings" entry, or presses ⌘, while focused on it).
    /// Fall back to `win.center()` (screen-centered) when the main window
    /// isn't visible — typical when the user triggers settings from the
    /// menu bar QuickBar popover, where there is no anchoring window to
    /// relate to. Clamps to the screen's visibleFrame so off-screen or
    /// straddling edge cases don't strand the settings window.
    private func positionSettingsWindow(_ win: NSWindow, relativeTo mainWindow: NSWindow?) {
        guard let main = mainWindow, main.isVisible else {
            win.center()
            return
        }
        let mainFrame = main.frame
        let settingsSize = win.frame.size
        let origin = NSPoint(
            x: mainFrame.midX - settingsSize.width / 2,
            y: mainFrame.midY - settingsSize.height / 2
        )
        win.setFrameOrigin(origin)
        if let screen = main.screen ?? win.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            var clamped = win.frame
            clamped.origin.x = min(max(clamped.origin.x, visible.minX),
                                   visible.maxX - clamped.width)
            clamped.origin.y = min(max(clamped.origin.y, visible.minY),
                                   visible.maxY - clamped.height)
            if clamped != win.frame { win.setFrame(clamped, display: false) }
        }
    }

    /// ID-LIFE-0004 (2026-07-30 audit): same nil-on-close as welcome
    /// window. ID-LIFE-0021 (2026-07-31 audit): keep the observer token
    /// and self-remove inside the handler — same discarded-token leak as
    /// the welcome window (ID-LIFE-0020).
    private func installSettingsCloseObserver(for win: NSWindow) {
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
    }

    /// Menu `⌘,` handler. Delegates to the independent settings window
    /// instead of the previous main-window tab switch.
    func showRestoreWizard() {
        RestoreWizardWindowController.shared.present(
            backupService: .shared,
            imagesDirectory: AppDirectories.applicationSupport.appendingPathComponent("ClipMemory/Images", isDirectory: true),
            defaults: .standard,
            // ID-CRASH-0032 (2026-09-28 code-review P2-25): route
            // through `windowManager?.restoreWizardViewFactory` so this
            // construction site stops bypassing the factory indirection
            // (WINDOW-P1-4 exemption's premise失效 — see
            // WindowManager.swift factories).
            viewFactory: windowManager?.restoreWizardViewFactory
        )
    }

    @objc private func showSettings() {
        showSettingsWindow()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - ID-CRASH-0032 single-instance guard

    /// ID-CRASH-0032: this process could not take the instance lock, so
    /// another live instance already owns the user's data. Bring that
    /// instance forward, record why, and leave WITHOUT touching a byte of
    /// the data.
    ///
    /// `NSApp.terminate` is deliberately NOT used here: it routes through
    /// `applicationShouldTerminate` → `applicationWillTerminate`, and that
    /// path instantiates `ClipboardStore.shared` / `ImageStorage.shared`
    /// and flushes them — the duplicate would write the very blob it is
    /// refusing to touch. `exit()` skips the AppKit termination sequence
    /// entirely, and at this point in the launch there is nothing to clean
    /// up: the guard runs before any window, monitor, hot key or store
    /// exists.
    private func refuseToRunAsDuplicateInstance() {
        let other = Self.otherRunningInstance()
        let message = """
        ID-CRASH-0032: another ClipMemory instance (pid \(other?.processIdentifier ?? -1)) \
        already owns the clipboard history; this instance exits without touching the data
        """
        logger.error("\(message)")
        // `os.Logger` is asynchronous — `NSLog` guarantees the line reaches
        // the unified log even though we are about to exit the process.
        NSLog("%@", message)
        // Best effort: bring the running instance forward so the user sees
        // that the app is already open.
        other?.activate(options: [])
        // ID-CRASH-0032 follow-up (2026-10-24, independent review P1): the
        // silent exit read as "double-clicking does nothing". The app is an
        // accessory (no Dock icon), so `activate` on the incumbent shows no
        // window, and this process vanished without a word. Say it out loud
        // BEFORE leaving — the user gets an answer instead of silence.
        presentAlreadyRunningAlert()
        exit(EXIT_SUCCESS)
    }

    /// Tells the user that ClipMemory is already running.
    ///
    /// The alert touches no data: `NSAlert` is pure AppKit and no store is
    /// instantiated on this path — which is exactly why this function may
    /// run at all (the whole point of the instance lock is that the
    /// duplicate must not touch the blob).
    ///
    /// The activation policy is temporarily raised to `.regular` so the
    /// alert can take focus and be dismissed — the app has no Dock icon of
    /// its own (LSUIElement), and a panel that cannot be focused is a
    /// panel the user never sees. Same pattern as
    /// `presentKeyFailureAlert`.
    private func presentAlreadyRunningAlert() {
        // XCTest guard: the guard itself never fires in a test host (the
        // lock is skipped under tests), but a modal alert in CI would hang
        // the run forever if that ever changed.
        guard !TestIsolation.isRunningTests else { return }
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.alertAlreadyRunningTitle
        alert.informativeText = L10n.alertAlreadyRunningMessage
        alert.addButton(withTitle: L10n.buttonDone)
        alert.runModal()
    }

    /// The other live instance of this app, if any.
    ///
    /// Used for UX only — bringing the incumbent to the front. The
    /// *decision* to refuse running is made by `SingleInstanceLock`, which
    /// is atomic and shared by every copy of the app; this lookup is the
    /// OS's own view of what is running and is best-effort.
    nonisolated static func otherRunningInstance() -> NSRunningApplication? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clipmemory.app"
        let mine = ProcessInfo.processInfo.processIdentifier
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        guard hasOtherLiveInstance(
            candidateProcessIDs: candidates.map(\.processIdentifier),
            myProcessID: mine
        ) else {
            return nil
        }
        return candidates.first { $0.processIdentifier != mine }
    }

    /// The pure decision behind "is somebody else running?", split out so
    /// it can be pinned by a test: given the process ids of the running
    /// instances of this app, is one of them another live instance?
    ///
    /// Terminated instances are filtered by the caller — this function
    /// only answers "is there a process id that is not mine?".
    nonisolated static func hasOtherLiveInstance(
        candidateProcessIDs: [Int32],
        myProcessID: Int32
    ) -> Bool {
        candidateProcessIDs.contains { $0 != myProcessID }
    }
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
        guard !TestIsolation.isRunningTests else { return }
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
        if let o = clipboardSaveFailedObserver { NotificationCenter.default.removeObserver(o) }
        // ID-CRASH-0007 (2026-09-28 code-review P1-1): mirror observer
        // cleanup for `.tagSaveFailed`. Same leak guard as
        // clipboardSaveFailedObserver above.
        if let o = tagSaveFailedObserver { NotificationCenter.default.removeObserver(o) }
        // ID-CRASH-0012 (2026-09-28 code-review P1-2): mirror observer
        // cleanup for `.imageSaveFailed`.
        if let o = imageSaveFailedObserver { NotificationCenter.default.removeObserver(o) }
        // M-2 / round-15 Finding A (2026-08-08): trashLoadFailedObserver
        // was registered in H-2 but never removed in deinit — observer
        // leak across AppDelegate lifetimes. Mirrors the clipboardSaveFailed
        // cleanup pattern above.
        if let o = trashLoadFailedObserver { NotificationCenter.default.removeObserver(o) }
        // ID-CRASH-0022 (2026-10-20): mirror observer cleanup for
        // `.trashItemsExpired`. Same leak guard as trashLoadFailedObserver
        // above.
        if let o = trashItemsExpiredObserver { NotificationCenter.default.removeObserver(o) }
        // ID-CRASH-0035 (2026-10-21): mirror observer cleanup for
        // `.trashPurgePending`. Same leak guard as trashItemsExpiredObserver
        // above.
        if let o = trashPurgePendingObserver { NotificationCenter.default.removeObserver(o) }
        // ID-CRASH-0022 (2026-10-20): mirror observer cleanup for
        // `.itemsLoadFailed`. Same leak guard as trashLoadFailedObserver
        // above.
        if let o = itemsLoadFailedObserver { NotificationCenter.default.removeObserver(o) }
        // ID-CRASH-0008 (2026-09-28 code-review P1-3): mirror observer
        // cleanup for `.tagBackendCorrupted`. Same leak guard as
        // trashLoadFailedObserver above.
        if let o = tagBackendCorruptedObserver { NotificationCenter.default.removeObserver(o) }
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

    // ID-CRASH-0007 (2026-09-28 code-review P1-1): shared handler
    // for both `.clipboardSaveFailed` (items) and `.tagSaveFailed`
    // (tags) observers. Routes through `saveAlertThrottler` with
    // the source key from the notification's `userInfo`, so a tag
    // disk-full doesn't suppress an items alert (and vice versa).
    // Both observers route here to share the alert presentation
    // and the XCTest guard logic. Extracted from the original
    // inline closure (lines 625-651 pre-ID-CRASH-0007) so the
    // `.tagSaveFailed` observer can call the exact same body.
    fileprivate func handleSaveFailureNotification(_ note: Notification) {
        // Same XCTest guard as the original observer: tests
        // deliberately post `.clipboardSaveFailed` to verify
        // `flushSave()`'s failure path; runModal here would hang
        // CI forever.
        guard !TestIsolation.isRunningTests else { return }
        let source = EncryptionFailedAlertThrottler.sourceKey(for: note)
        let decision = saveAlertThrottler.recordFailure(source: source)
        guard decision.shouldShowAlert else { return }
        let a = NSAlert()
        a.messageText = L10n.error
        a.informativeText = decision.failureCount > 1
            ? L10n.alertSaveFailedCount(decision.failureCount)
            : L10n.alertSaveFailed
        a.alertStyle = .warning
        a.addButton(withTitle: L10n.buttonConfirm)
        a.runModal()
    }

    /// Extracted from setupLanguageObserver's inline closure (P1-AUDIT-2026-09-22
    /// cyclomatic-complexity refactor). XCTest guard + throttler alert.
    fileprivate func handleEncryptionFailed(_ note: Notification) {
        // XCTest injects into the real app, so this observer is live
        // during tests — and tests deliberately post .encryptionFailed
        // (OCRTests encrypt-failure fixtures). A modal runModal there
        // blocks the test process forever (2026-07-24 CI hang: Test
        // step stuck >60 min). Same guard as CryptoService.isRunningTests.
        guard !TestIsolation.isRunningTests else { return }
        // CLIP-3 (2026-07-24): batch failure paths (OCR backfill, bulk
        // tag encryption) post one notification per item — one modal per
        // notification is an alert storm. Throttle per H-3 source tag;
        // suppressed failures are counted into the next alert's text.
        let source = EncryptionFailedAlertThrottler.sourceKey(for: note)
        let decision = encryptionAlertThrottler.recordFailure(source: source)
        guard decision.shouldShowAlert else { return }
        // ID-REVIEW-1024 follow-up (2026-10-24, independent review P2):
        // a `recoverable` failure is one where nothing was lost:
        //   - "keychainLoad" (CryptoService.handleKeychainOtherError) —
        //     the keychain was momentarily unreadable, so key preparation
        //     was DEFERRED: the root key was NOT regenerated and nothing
        //     was overwritten;
        //   - "keychainMigration.transient" / ".unknown" — the legacy key
        //     file stays in place and keeps serving the session.
        // Telling the user "encryption failed, item was not saved" for
        // those cases was both wrong and alarming — it sent people
        // looking for data loss that never happened. The recoverable case
        // gets its own wording; the throttler bucket is still the
        // per-source one, so the count semantics are unchanged.
        let isRecoverable = (note.userInfo?["recoverable"] as? Bool) == true
        let a = NSAlert()
        a.messageText = L10n.error
        if isRecoverable {
            a.informativeText = L10n.alertEncryptKeychainRecoverable
        } else {
            a.informativeText = decision.failureCount > 1
                ? L10n.alertEncryptFailedCount(decision.failureCount)
                : L10n.alertEncryptFailed
        }
        a.alertStyle = .warning
        a.addButton(withTitle: L10n.buttonConfirm)
        a.runModal()
    }

    /// Extracted from setupLanguageObserver's inline closure (P1-AUDIT-2026-09-22
    /// cyclomatic-complexity refactor). H-1 (2026-08-08 audit) alert surfacing
    /// for trash load failure with persistent-flag suffix.
    fileprivate func handleTrashLoadFailed(_ note: Notification) {
        // Same XCTest guard as handleEncryptionFailed: tests deliberately
        // post .trashLoadFailed to verify the notification fires; an
        // NSAlert here would hang CI forever.
        guard !TestIsolation.isRunningTests else { return }
        let persistent = (note.userInfo?["persistent"] as? Bool) ?? false
        let suffix = persistent ? " (persisted from prior launch)" : ""
        let underlying = (note.userInfo?["error"] as? String) ?? "unknown"
        let decision = trashAlertThrottler.recordFailure(source: "trashLoadFailed")
        let detail = "Quarantined blob retained under 'ClipboardTrashedItems.corrupt-*'. Underlying error: \(underlying)"
        logger.error("Trash load failed\(suffix). \(detail)")
        guard decision.shouldShowAlert else { return }
        let a = NSAlert()
        a.messageText = L10n.error
        a.informativeText = decision.failureCount > 1
            ? L10n.alertTrashLoadFailedCount(decision.failureCount)
            : L10n.alertTrashLoadFailed
        a.alertStyle = .warning
        a.addButton(withTitle: L10n.buttonConfirm)
        a.runModal()
    }

    /// ID-CRASH-0022 (2026-10-20): the recycle bin's retention purge
    /// removed items. This is the third leg of the data-deletion gate
    /// (报错 / 重试 / 用户可见) — the purge is a delete, so the user
    /// has to learn that it happened, how many items it took, and how
    /// long they were kept.
    ///
    /// ID-CRASH-0035 (2026-10-21): the notice is no longer a MODAL
    /// alert. The purge also runs on a 60 s cleanup timer, so a modal
    /// could pop up in the middle of a session and interrupt whatever
    /// the user was doing. A purge big enough to matter now asks for
    /// confirmation BEFORE it deletes anything (see
    /// `handleTrashPurgePending`); what reaches this handler is either a
    /// routine purge or one the user already confirmed.
    fileprivate func handleTrashItemsExpired(_ note: Notification) {
        let count = (note.userInfo?["count"] as? Int) ?? 0
        let retentionDays = (note.userInfo?["retentionDays"] as? Int) ?? 0
        guard count > 0 else { return }
        logger.error("Recycle bin retention purge removed \(count) item(s) (window: \(retentionDays) days)")
        // The purge is done — nothing is pending any more. The tooltip
        // keeps the outcome, because a small purge is silent by design
        // and this is where the user can find out what happened.
        //
        // ID-REVIEW-1025 (2026-10-24, independent review P2): the
        // `alert.trash.items.expired.title` key ("回收站已清理") was
        // added to all 7 languages but never referenced by anything —
        // dead weight that also documented the intent (a titled message,
        // not a bare count). The tooltip now carries it.
        clearPendingPurgeBadge(
            lastResultText: "\(L10n.alertTrashItemsExpiredTitle)：\(L10n.alertTrashItemsExpired(count, retentionDays: retentionDays))"
        )
    }

    /// ID-CRASH-0035 (2026-10-21): the retention purge wants to remove a
    /// LOT of entries and is waiting for the user's confirmation. The
    /// badge on the menu bar item is the whole UI here: it never
    /// interrupts, and clicking it is what opens the confirmation.
    ///
    /// ID-REVIEW-1025 (2026-10-24, independent review P1): `count == 0`
    /// is the RESOLVED signal — the entries the notice referred to have
    /// left the bin (the user restored them, or deleted them one by
    /// one), so there is nothing left to decide.
    ///
    /// It has to be handled rather than ignored: `pendingTrashPurgeCount`
    /// gates the QuickBar (`statusItemClicked`), so a stale count left
    /// the app unreachable for the rest of the session — every click
    /// opened a confirmation for a batch that no longer existed, and the
    /// badge never went away. The user had to restart the app.
    fileprivate func handleTrashPurgePending(_ note: Notification) {
        let count = (note.userInfo?["count"] as? Int) ?? 0
        let retentionDays = (note.userInfo?["retentionDays"] as? Int) ?? 0
        guard count > 0 else {
            clearPendingPurgeBadge(lastResultText: nil)
            return
        }
        logger.error("Recycle bin retention purge is waiting for confirmation: \(count) item(s) past the \(retentionDays)-day window")
        showPendingPurgeBadge(count: count, retentionDays: retentionDays)
    }

    /// ID-CRASH-0035 (2026-10-21): shows the count badge on the menu bar
    /// item — the user has a decision to make.
    private func showPendingPurgeBadge(count: Int, retentionDays: Int) {
        pendingTrashPurgeCount = count
        pendingTrashPurgeRetentionDays = retentionDays
        guard let button = statusItem?.button else { return }
        // ID-REVIEW-1025 (2026-10-24): the badge is drawn ON TOP of the
        // menu bar symbol, so a `nil` badge must never mean "no icon at
        // all" — the app would become unreachable. Falling back to the
        // plain symbol keeps the icon (and the badge count in the
        // tooltip) visible even if the composite cannot be built.
        button.image = Self.badgedStatusImage(count: count) ?? Self.defaultStatusImage()
        button.toolTip = "\(L10n.appName) — \(L10n.alertTrashPurgePendingBadge(count))"
    }

    /// ID-CRASH-0035 (2026-10-21): clears the badge. `lastResultText` is
    /// what the tooltip shows instead of the plain app name — the outcome
    /// of the purge that just happened.
    private func clearPendingPurgeBadge(lastResultText: String?) {
        pendingTrashPurgeCount = 0
        pendingTrashPurgeRetentionDays = 0
        guard let button = statusItem?.button else { return }
        button.image = Self.defaultStatusImage()
        if let lastResultText {
            button.toolTip = "\(L10n.appName) — \(lastResultText)"
        } else {
            button.toolTip = L10n.appName
        }
    }

    /// ID-CRASH-0035 (2026-10-21): the user clicked the badge — now ask.
    ///
    /// "永久删除" performs the purge; "取消" leaves the entries in the
    /// bin and defers the decision. Nothing is deleted without an
    /// explicit answer.
    ///
    /// ID-REVIEW-1025 (2026-10-24, independent review P2): "取消" used to
    /// keep the badge AND the count, and the count gates the QuickBar
    /// (`statusItemClicked`) — so every later click on the menu bar icon
    /// opened the same modal again and the QuickBar (the app's only
    /// window) could not be reached at all. The user was trapped in a
    /// destructive-or-nothing loop.
    ///
    /// "取消" now DECLINES the batch: the store forgets the pending set
    /// and the badge goes away, so the QuickBar opens normally. The
    /// entries stay in the bin — nothing is deleted — and the 60 s tick
    /// asks again (the batch is still there, so the question comes back
    /// as a fresh badge, not as a trap).
    @MainActor
    @discardableResult
    private func presentTrashPurgeConfirmation() -> Bool {
        // ID-REVIEW-1025 (2026-10-24, independent review P3): the
        // dialog must state the number that will ACTUALLY be deleted.
        // The badge's cached count can be up to one cleanup tick stale
        // (the user may have restored an entry since the notice), so the
        // live value is read from the store.
        let count = ClipboardStore.shared.pendingExpiredPurgeCount
        let retentionDays = pendingTrashPurgeRetentionDays
        guard count > 0 else {
            // ID-REVIEW-1026 (2026-10-24, independent review P1): the
            // badge is stale — the pending set has already been resolved
            // (the user restored or deleted those entries). There is
            // nothing to ask about, so the badge goes away and the caller
            // opens the QuickBar instead of swallowing the click.
            clearPendingPurgeBadge(lastResultText: nil)
            return false
        }
        // The app is a menu bar app: without this the alert can open
        // behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.alertTrashPurgePendingTitle
        alert.informativeText = L10n.alertTrashPurgePending(count, retentionDays: retentionDays)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.alertTrashPurgePendingConfirm)
        alert.addButton(withTitle: L10n.buttonCancel)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            // "取消" — the entries stay, the badge goes away, and the
            // next tick asks again.
            ClipboardStore.shared.declineExpiredPurge()
            return true
        }
        ClipboardStore.shared.confirmExpiredPurge()
        return true
    }

    /// ID-CRASH-0035 (2026-10-21): renders the menu bar icon with a red
    /// count badge, the way Mail shows its unread count.
    ///
    /// The composite image is NOT a template image — a template image is
    /// tinted by the menu bar, and the badge would disappear with it.
    /// The symbol inside is tinted with `labelColor`, so it still adapts
    /// to light and dark menu bars.
    ///
    /// Measured (2026-10-21): a template image drawn into a custom image
    /// comes out BLACK — the current drawing color is ignored. So the
    /// tint has to be applied with a `.sourceAtop` fill, which colors
    /// exactly the pixels the glyph covers (verified: systemRed →
    /// r=255 g=66 b=69, labelColor → r=216 g=216 b=216).
    static func badgedStatusImage(count: Int) -> NSImage? {
        guard count > 0, let symbol = defaultStatusImage() else { return nil }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceAtop)
            // The badge: a red disc with the count on it.
            let text = "\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            let diameter = max(textSize.width, textSize.height) + 4
            let badge = NSRect(
                x: rect.maxX - diameter,
                y: rect.maxY - diameter,
                width: diameter,
                height: diameter
            )
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
            text.draw(
                at: NSPoint(
                    x: badge.midX - textSize.width / 2,
                    y: badge.midY - textSize.height / 2
                ),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The plain menu bar icon.
    static func defaultStatusImage() -> NSImage? {
        NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: L10n.appName)
    }

    /// ID-CRASH-0022 (2026-10-20): the clipboard history blob was
    /// unreadable and was quarantined.
    ///
    /// The items-side twin of `handleTrashLoadFailed`. The history is
    /// the biggest dataset the app owns, and it used to fail SILENTLY:
    /// the user saw an empty library with no explanation and no hint
    /// that the unreadable copy still exists under
    /// `ClipboardItems.corrupt-*`.
    fileprivate func handleItemsLoadFailed(_ note: Notification) {
        // Same XCTest guard as handleTrashLoadFailed: a modal alert
        // would hang CI forever.
        //
        // ID-REVIEW-1025 (2026-10-24): the guard reads the CANONICAL
        // probe (`TestIsolation.isRunningTests`, three signals) instead
        // of the raw `XCTestConfigurationFilePath` lookup. The raw
        // lookup rests on ONE signal: if it is missing on some launch
        // path, the process takes the PRODUCTION path, opens a modal
        // `NSAlert` inside the test host, and the CI job hangs until
        // its timeout. Production behaviour is unchanged — none of the
        // three signals fires in a real launch.
        guard !TestIsolation.isRunningTests else { return }
        let persistent = (note.userInfo?["persistent"] as? Bool) ?? false
        let underlying = (note.userInfo?["error"] as? String) ?? "unknown"
        let decision = trashAlertThrottler.recordFailure(source: "itemsLoadFailed")
        let detail = "Quarantined blob retained under 'ClipboardItems.corrupt-*'. Underlying error: \(underlying)"
        logger.error("Items load failed\(persistent ? " (persisted from prior launch)" : ""). \(detail)")
        guard decision.shouldShowAlert else { return }
        let a = NSAlert()
        a.messageText = L10n.alertItemsLoadFailedTitle
        a.informativeText = decision.failureCount > 1
            ? L10n.alertItemsLoadFailedCount(decision.failureCount)
            : L10n.alertItemsLoadFailed
        a.alertStyle = .warning
        a.addButton(withTitle: L10n.buttonConfirm)
        a.runModal()
    }
}
