import Foundation
import Combine

/// Protocol for receiving clipboard monitoring events and providing configuration.
/// H-13 (2026-07-20 audit): extended the surface so `ClipboardMonitor` does not
/// have to reach into the `ClipboardStore.shared` singleton directly. Each
/// method below used to be a `ClipboardStore.shared.<thing>` access inside the
/// monitor — now the monitor asks its delegate and the concrete `ClipboardStore`
/// satisfies the protocol via an extension. The store stays the only writer,
/// but the monitor stops knowing the concrete singleton.
// ID-CRASH-0058 (code-review-2026-10-01 v2.9.7 TSan cleanup):
// `@preconcurrency` is the canonical Swift 6 migration way to suppress
// actor-isolation conformance warnings. The protocol declares no
// isolation requirement; the concrete conformance `extension
// ClipboardStore: ClipboardMonitorDelegate` is in `ClipboardStore.swift`
// where the `@MainActor` class crosses into non-isolated protocol
// dispatch. Without `@preconcurrency`, TSan reports the crossing
// as a runtime data-race risk (warnings at
// `ClipboardStore.swift:98` ×2 in v2.9.5/v2.9.6 builds).
//
// Per Apple docs (`@preconcurrency`):
//   "An attribute that suppresses strict-concurrency warnings from
//    interfaces that haven't been updated for the current Swift
//    concurrency model."
// All protocol methods are themselves synchronous and safe to call
// from the protocol's non-isolated context; the runtime guarantees
// come from the dispatchers we already use (Carbon event thread for
// hotkey, Carbon event thread for clipboard polling — both dispatch
// back to main via DispatchQueue.main.async). The conformance is
// correct as-is; only the type-system warning was wrong.
@preconcurrency
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
    ///
    /// ID-OCR-0004 (2026-07-30 audit): pass `contentHash` so the store can
    /// recover when the original `id` was deduped away between the
    /// monitor's `processImageData` allocation and the OCR completion.
    /// Without this, the OCR result for the new UUID is silently dropped
    /// and the existing item's `ocrText` is never refreshed.
    func monitorDidRecognizeText(_ text: String, forImageItemId id: UUID, contentHash: String?)
}

// L-2 (2026-07-24 audit): the previous default-implementation extension
// silently no-op'd `monitorDidCaptureItem` / `monitorDidRecognizeText` /
// `ocrEnabledForMonitor`, hiding the absence of a real delegate behind
// a successful compile — a partial conformer would capture items and
// then drop them on the floor. All current conformers (ClipboardStore)
// already provide full implementations; making every method required
// surfaces that requirement at the type level.
