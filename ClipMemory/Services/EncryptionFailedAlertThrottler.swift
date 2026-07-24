import Foundation

/// CLIP-3 (2026-07-24): debounce for `.encryptionFailed` alert storms.
///
/// Before this, the AppDelegate observer ran `NSAlert.runModal()` for EVERY
/// `.encryptionFailed` notification. Batch failure paths (OCR backfill over a
/// large image library with a broken crypto layer, tag-name encryption during
/// a bulk import, HMAC failures on rapid clipboard captures) post one
/// notification per item — dozens of stacked modal alerts the user has to
/// dismiss one by one.
///
/// Policy: within a 60-second window, at most ONE alert per failure source
/// (H-3 tags notifications with `userInfo["source"]`; untagged posts group
/// under "unknown"). Failures suppressed inside the window are counted; the
/// next alert that does show reports the coalesced count in its
/// informativeText so no failure goes unaccounted for.
///
/// Pure decision logic — no AppKit, no UserDefaults — so the window/bucket
/// behavior is unit-testable with an injected clock. Expected to be driven
/// from the main thread (the AppDelegate observer is bound to `queue: .main`).
final class EncryptionFailedAlertThrottler {

    struct Decision: Equatable {
        /// Whether the caller should surface an alert for this failure.
        let shouldShowAlert: Bool
        /// Failures coalesced into this alert: the current one plus any
        /// suppressed since the previous alert for the same source.
        /// Meaningful only when `shouldShowAlert` is true (always >= 1).
        let failureCount: Int
    }

    /// Window during which repeat alerts for the same source are suppressed.
    private let window: TimeInterval
    /// Injectable clock so tests control time without sleeping.
    private let now: () -> Date

    private var lastShownAt: [String: Date] = [:]
    private var suppressedSinceLastAlert: [String: Int] = [:]

    init(window: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.window = window
        self.now = now
    }

    /// Bucketing key for a notification. H-3 (2026-07-24 audit) tagged the
    /// addItem encrypt-failure post with `userInfo["source"]`; older posting
    /// sites (OCR, ImageStorage, tag encryption, HMAC) carry no userInfo and
    /// share the "unknown" bucket — still throttled, just not split apart.
    static func sourceKey(for notification: Notification) -> String {
        (notification.userInfo?["source"] as? String) ?? "unknown"
    }

    /// Records one `.encryptionFailed` failure for `source` and decides
    /// whether an alert should be shown now.
    func recordFailure(source: String) -> Decision {
        let timestamp = now()
        if let last = lastShownAt[source], timestamp.timeIntervalSince(last) < window {
            suppressedSinceLastAlert[source, default: 0] += 1
            return Decision(shouldShowAlert: false, failureCount: 0)
        }
        let count = (suppressedSinceLastAlert[source] ?? 0) + 1
        lastShownAt[source] = timestamp
        suppressedSinceLastAlert[source] = 0
        return Decision(shouldShowAlert: true, failureCount: count)
    }
}
