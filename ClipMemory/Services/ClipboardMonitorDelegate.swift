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

// L-2 (2026-07-24 audit): the previous default-implementation extension
// silently no-op'd `monitorDidCaptureItem` / `monitorDidRecognizeText` /
// `ocrEnabledForMonitor`, hiding the absence of a real delegate behind
// a successful compile — a partial conformer would capture items and
// then drop them on the floor. All current conformers (ClipboardStore)
// already provide full implementations; making every method required
// surfaces that requirement at the type level.
