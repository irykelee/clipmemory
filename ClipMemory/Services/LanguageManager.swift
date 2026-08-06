import Foundation
import SwiftUI

@MainActor
class LanguageManager: ObservableObject {
    /// NEW-2 follow-up (2026-08-06): test seam for swapped singleton.
    /// Mirrors `UpdateService.injectedForTest` — when non-nil, `shared`
    /// returns the injected instance instead of the production default.
    /// Production code must never set this; tests reset it to nil in
    /// `tearDown`. `nonisolated(unsafe)` follows the
    /// `UpdateService.injectedForTest` rationale (Swift 6 cleanup batch).
    nonisolated(unsafe) static var injectedForTest: LanguageManager?

    /// NEW-2 follow-up: return `injectedForTest` when set so tests
    /// can render views (e.g. the settings tab) without firing the
    /// production init's side effects (`applyLanguage` writes
    /// `AppleLanguages`, didSet writes `appLanguage`). The injected
    /// instance is always a test-only construction with
    /// `defaults: testDefaults`.
    @MainActor
    static var shared: LanguageManager {
        if let injected = injectedForTest { return injected }
        // NEW-2 follow-up: cache the singleton, but invalidate when
        // `defaults` is reassigned. The original `static let` capture
        // froze the production `.standard` at first read; tests
        // reassigning `defaults` after that first read got ignored
        // and writes leaked to the production domain.
        if let cached = _sharedDefault, _sharedDefaultDefaults === defaults {
            return cached
        }
        let new = LanguageManager(defaults: defaults)
        _sharedDefault = new
        _sharedDefaultDefaults = defaults
        return new
    }

    /// NEW-2 follow-up (2026-08-06): test seam for the SHARED
    /// default-singleton's underlying UserDefaults. Mirrors
    /// `UpdateService.defaults` (M13 injection rollout). When tests
    /// set this to an isolated suite, the next read of `shared`
    /// lazily creates a new singleton bound to that suite,
    /// keeping the init cascade (`applyLanguage` writes
    /// `AppleLanguages`, didSet writes `appLanguage`) out of the
    /// production domain.
    ///
    /// `nonisolated(unsafe)` follows the same justification as the
    /// `defaults` field in `UpdateService` (read from main, written
    /// only from test `setUp`).
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// NEW-2 follow-up: the cached singleton and the `defaults` it
    /// was bound to. `_sharedDefaultDefaults` is the key that
    /// triggers invalidation when `defaults` is reassigned.
    @MainActor
    private static var _sharedDefault: LanguageManager?
    @MainActor
    private static var _sharedDefaultDefaults: UserDefaults?

    /// Nonisolated mirror of `selectedLanguage` for off-main readers
    /// (e.g. `LocalizationService.currentBundle` running inside a
    /// `Task.detached` `CryptoService.prepareKey` failure handler).
    /// Written from `didSet` on the main actor; reads are best-effort and
    /// tolerate one-tick staleness across thread boundaries.
    ///
    /// ID-SYNC-0002 (2026-07-31 audit): was `nonisolated(unsafe)` storage —
    /// an unsynchronized cross-thread String read/write (main writes in
    /// `didSet`, background L10n lookups read), a theoretical torn-read
    /// race. Now backed by NSLock-guarded storage. NSLock rather than
    /// OSAllocatedUnfairLock because the deployment target is macOS 13 and
    /// C-1 (2026-07-24 audit) flagged OSAllocatedUnfairLock as macOS 14+.
    nonisolated private static let codeLock = NSLock()
    // Guarded by `codeLock` at every access (see the computed property
    // below); `unsafe` only because Swift cannot verify the lock discipline.
    nonisolated(unsafe) private static var codeStorage: String = "en"
    nonisolated static var currentLanguageCode: String {
        get { codeLock.withLock { codeStorage } }
        set { codeLock.withLock { codeStorage = newValue } }
    }

    /// NEW-4 (2026-08-06 review): replaceable UserDefaults instance so
    /// tests can use an isolated suite instead of the production
    /// `com.clipmemory.app` domain. `LanguageManager` was the LAST
    /// service-layer singleton that hard-coded `UserDefaults.standard`,
    /// so this is the closing entry in the M13 injection rollout.
    /// Production path falls back to `.standard`.
    private let defaults: UserDefaults

    @Published var selectedLanguage: String {
        didSet {
            // @MainActor guarantees didSet runs on main; publish to the
            // off-main cache before the notification so any listener that
            // reads `currentLanguageCode` in response sees the new value.
            Self.currentLanguageCode = selectedLanguage
            defaults.set(selectedLanguage, forKey: "appLanguage")
            applyLanguage()
            NotificationCenter.default.post(name: Notification.Name("LanguageDidChange"), object: nil)
        }
    }

    // NEW-2 follow-up (2026-08-06): `internal` (not `private`) so
    // `@testable import ClipMemory` test code can construct a stub
    // instance with its own defaults suite. Production callers
    // (`LanguageManager.shared` only) cannot bypass the singleton.
    init(defaults: UserDefaults = .standard) {
        // NEW-4: accept optional defaults injection. Production
        // `LanguageManager.shared` continues to use `.standard` because
        // the explicit-default fallback matches the previous behavior.
        self.defaults = defaults
        // BUG-050 (2026-07-21): simplify init — nil/non-nil branch split
        // wrote to UserDefaults inconsistently (only the nil branch).
        // Both branches now converge: derive the language, assign; didSet
        // handles persistence and application. Init runs on main in production.
        let lang = defaults.string(forKey: "appLanguage") ?? Self.getSystemLanguage()
        self.selectedLanguage = lang
        // didSet observers do NOT fire during Swift init, so currentLanguageCode
        // (the nonisolated mirror added in pilot commit 153d25d) must be seeded
        // explicitly here. Without this, off-main readers of LocalizationService
        // observe the default "en" instead of the user's saved language until the
        // first post-init language change. Same applies to any future cache fields
        // initialized from selectedLanguage.
        Self.currentLanguageCode = lang
    }

    static func getSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh-Hant") {
            return "zh-Hant"
        }
        if preferred.hasPrefix("zh") {
            return "zh-Hans"
        }
        if preferred.hasPrefix("ja") {
            return "ja"
        }
        if preferred.hasPrefix("ko") {
            return "ko"
        }
        if preferred.hasPrefix("es") {
            return "es"
        }
        if preferred.hasPrefix("pt") {
            return "pt"
        }
        return "en"
    }

    func applyLanguage() {
        // NEW-4: use the injected defaults, not `.standard`. Production
        // path (no injection) is unchanged.
        // L8: Prepend selectedLanguage to existing AppleLanguages chain instead of
        // replacing it entirely, preserving system language fallback behavior.
        var languages = defaults.stringArray(forKey: "AppleLanguages") ?? ["en"]
        if let existingIndex = languages.firstIndex(of: selectedLanguage) {
            languages.remove(at: existingIndex)
        }
        languages.insert(selectedLanguage, at: 0)
        defaults.set(languages, forKey: "AppleLanguages")
    }

    var availableLanguages: [(code: String, name: String)] {
        [
            ("zh-Hans", "简体中文"),
            ("zh-Hant", "繁體中文"),
            ("en", "English"),
            ("ja", "日本語"),
            ("ko", "한국어"),
            ("es", "Español"),
            ("pt", "Português")
        ]
    }

    var currentLanguageName: String {
        availableLanguages.first { $0.code == selectedLanguage }?.name ?? "English"
    }
}

struct SensitiveClearOption {
    let hours: Int

    init(hours: Int) {
        self.hours = hours
    }

    var label: String {
        switch hours {
        case 1: return L10n.sensitive1Hour
        case 24: return L10n.sensitive24Hours
        case 48: return L10n.sensitive48Hours
        case 168: return L10n.sensitive7Days
        case 0: return L10n.sensitiveNever
        default: return "\(hours) hours"
        }
    }

    static var options: [SensitiveClearOption] {
        [
            SensitiveClearOption(hours: 1),
            SensitiveClearOption(hours: 24),
            SensitiveClearOption(hours: 48),
            SensitiveClearOption(hours: 168),
            SensitiveClearOption(hours: 0)
        ]
    }
}
