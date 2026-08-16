import Foundation

/// ID-PERF-0005 (2026-08-16 audit MEDIUM-13 fix): central registry of
/// NSCache instances that should be explicitly flushed when the system
/// signals memory pressure via
/// `NSApplication.didReceiveMemoryWarningNotification`.
///
/// `applicationDidReceiveMemoryWarning(_:)` is **iOS-only** — see
/// AppDelegate's observer comment for the cross-reference and a link
/// to the Apple documentation that confirms it. The macOS-equivalent
/// signal is the notification posted by `NSApplication` when the
/// system is under memory pressure (available since macOS 10.0).
///
/// NSCache auto-evicts under pressure via its `countLimit` /
/// `totalCostLimit`, but pre-flushing when the system asks lets the
/// next render skip the rebuild cost entirely (caches stay cold until
/// items are re-accessed). Without this, the rebuild cost lands on
/// the next search keystroke or list scroll — exactly when the user
/// is already struggling with a slow machine.
///
/// Add a new line here whenever a new NSCache is introduced that
/// holds non-trivial memory and rebuilds cheaply from its source.
/// Don't add caches that hold config objects (regex patterns, locale
/// tables) where the rebuild cost is higher than the holding cost —
/// for those, leave them to NSCache's built-in eviction.
enum MemoryCacheRegistry {
    static func flushAll() {
        // ClipboardStore caches the decrypted content (AES-GCM output)
        // and parsed RTF plaintext — by far the largest single memory
        // consumer in the app, bounded only by 500 entries × 10MB cost
        // limit. A memory warning is exactly the moment to drop both.
        ClipboardStore.shared.flushMemoryCaches()

        // FuzzySearchMatcher caches the pinyin transliteration and
        // latin-folded form of every distinct content string. Both
        // rebuild from `CFStringTransform` + ICU folding on the next
        // search keystroke — cheap per call, expensive across the
        // 16_384-entry ceiling.
        FuzzySearchMatcher.flushMemoryCaches()

        // ClipboardItemRow caches three NSAttributedString highlight
        // outputs — the heaviest per-row allocations in the UI layer.
        ClipboardItemRowCaches.flushMemoryCaches()

        // DateHelpers caches locale-bound formatters. Cheap to hold
        // individually, but a fresh formatter build is the dominant
        // cost on the first render after a warning, and stale
        // pre-language-switch instances linger otherwise.
        DateHelpersCache.flushMemoryCaches()
    }
}