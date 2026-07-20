import Foundation
import Combine

/// Protocol for receiving clipboard monitoring events and providing configuration.
/// H-13 (2026-07-20 audit): extended the surface so `ClipboardMonitor` does not
/// have to reach into the `ClipboardStore.shared` singleton directly. Each
/// method below used to be a `ClipboardStore.shared.<thing>` access inside the
/// monitor — now the monitor asks its delegate and the concrete `ClipboardStore`
/// satisfies the protocol via an extension. The store stays the only writer,
/// but the monitor stops knowing the concrete singleton.
protocol ClipboardMonitorDelegate: AnyObject {
    /// Configured sensitive-clear hours (0 = never auto-clear).
    func sensitiveClearHoursForMonitor() -> Int

    /// Snapshot of the user's "capture rich text" preference. Called from the
    /// main thread before the poll timer fires; safe to read without locks.
    func captureRichTextSettingForMonitor() -> Bool

    /// Live publisher for the same preference. The monitor subscribes once on
    /// the main queue and updates its cached value when the user toggles it.
    /// Returning `Publishers.Empty` is fine when no UI ever toggles the
    /// setting after launch.
    var captureRichTextPublisher: AnyPublisher<Bool, Never> { get }

    /// Hand a newly captured `ClipboardItem` to the store for persistence.
    /// The monitor used to call `ClipboardStore.shared.addItem(item)` —
    /// now the store decides whether/how to dedupe, persist, fire
    /// `objectWillChange`, etc.
    func monitorDidCaptureItem(_ item: ClipboardItem)

    /// OCR-pipeline availability check (user toggle, defaults-based).
    func ocrEnabledForMonitor() -> Bool

    /// Attach OCR-recognized plaintext to an already-persisted image item.
    /// The store hops back to main thread internally and re-encrypts the
    /// `ocrText` ciphertext at rest.
    func monitorDidRecognizeText(_ text: String, forImageItemId id: UUID)
}

// Default implementations let `ClipboardMonitorDelegate` stay optional —
// callers that only care about sensitivity don't have to implement the
// new methods. Both defaults match the previous "off" behavior so a
// partial delegate won't crash.
extension ClipboardMonitorDelegate {
    func captureRichTextSettingForMonitor() -> Bool { true }
    var captureRichTextPublisher: AnyPublisher<Bool, Never> {
        Just(true).eraseToAnyPublisher()
    }
    func monitorDidCaptureItem(_ item: ClipboardItem) {}
    func ocrEnabledForMonitor() -> Bool { false }
    func monitorDidRecognizeText(_ text: String, forImageItemId id: UUID) {}
}
