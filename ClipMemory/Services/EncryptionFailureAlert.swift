import AppKit

/// ID-CRASH-0034 (2026-09-28 code-review P2-19): AppKit-coupled
/// alert UI extracted from `CryptoService.swift`. The previous inline
/// `presentKeyFailureAlert` + `NSApp.terminate(nil)` callsites together
/// pulled `AppKit` (NSAlert / NSApp) into the crypto kernel, which:
///   - defeated the `file_length` lint ceiling (forced `// swiftlint:disable file_length`
///     because the file grew past 1249 with the 30-line alert body);
///   - made the crypto kernel untestable in any environment without a
///     real NSApplication (per CLAUDE.md P2-19 + ID-CRYPTO-0004);
///   - violated the project invariant "crypto / Keychain is AppKit-free
///     so it can be exercised under isolated test runners" (BackupPackage
///     follows this rule; CryptoService didn't).
///
/// Now `CryptoService.swift` declares the contract via a closure
/// (`keyFailureAlertPresenter`, `appTerminator`) and a notification
/// (`NSNotification.Name.cryptoServiceRequestTerminateApp`). AppDelegate
/// owns the `NSAlert` / `NSApp.terminate(nil)` call sites; tests can
/// inject mock closures. The contract is identical to the previous
/// behaviour — default present path uses `presentKeyFailureAlert` here,
/// default terminate path posts the notification (AppDelegate listener
/// calls `NSApp.terminate(nil)`).

/// Default alert presentation for `CryptoKeyFailure`. Extracted verbatim
/// from `CryptoService.swift:711-737`. Must run on the main thread —
/// callers dispatch.
func presentKeyFailureAlert(_ failure: CryptoKeyFailure) -> KeyFailureAction {
    NSApp.setActivationPolicy(.regular) // LSUIElement app: alert must be visible
    defer { NSApp.setActivationPolicy(.accessory) }
    let alert = NSAlert()
    alert.alertStyle = .critical
    switch failure {
    case .corruptExistingKey:
        alert.messageText = L10n.alertKeyCorruptTitle
        alert.informativeText = L10n.alertKeyCorruptMessage
        // Quit is the default button — a Return-key accident must never
        // destroy the user's history.
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

/// Default terminate-app behaviour. AppDelegate subscribes to the
/// `NSNotification.Name.cryptoServiceRequestTerminateApp` notification
/// and calls `NSApp.terminate(nil)`. Tests can override
/// `CryptoService.appTerminator` with a no-op spy.
func postRequestTerminateAppNotification() {
    NotificationCenter.default.post(
        name: .cryptoServiceRequestTerminateApp,
        object: nil
    )
}

extension Notification.Name {
    /// ID-CRASH-0034: posted by `CryptoService.appTerminator` when the
    /// default terminate-app path is selected (alert 264
    /// returned `.quit`, or `keyFailureHandler` chose quit). AppDelegate
    /// observes and calls `NSApp.terminate(nil)`. Lets CryptoService stay
    /// AppKit-free.
    static let cryptoServiceRequestTerminateApp = Notification.Name("CryptoService.requestTerminateApp")
}
