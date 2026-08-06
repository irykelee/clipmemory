import Foundation
@testable import ClipMemory

/// NEW-2 (2026-08-06 review): deterministic stub for `FeedProbeEngine` that
/// returns nil for every call. Used by snapshot tests that previously
/// triggered the real `UpdateService.shared` init, which kicked off a
/// Sparkle `SPUStandardUpdaterController` and a real appcast network probe
/// (NEW-3). With this stub + `autoStart: false`, the production side
/// effects never run and the test session writes zero production keys.
///
/// Returning nil (not a fixed decision) matches the "no probe" semantics:
/// any caller that *needs* probe behavior in a snapshot test is asking
/// the wrong question — snapshot tests should not depend on feed state.
final class StubFeedProbeEngine: FeedProbeEngine, @unchecked Sendable {
    func resolve(
        policy: UpdateFeedPolicy,
        lastKnownDate: Date?,
        channels: [FeedChannel],
        timeout: TimeInterval?
    ) async -> FeedProbeDecision? {
        return nil
    }
}
