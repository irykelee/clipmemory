import Foundation

/// Where a feed source sits in the trust hierarchy.
enum ChannelKind: Equatable {
    case primary
    case fallback
}

/// Describes one update-feed endpoint. Adding a new channel = append to
/// `UpdateFeedPolicies.knownChannels`; no probe / UI changes required
/// (spec §1.2 extension point).
struct FeedChannel: Equatable {
    let id: String
    let url: URL
    let kind: ChannelKind
    let labelKey: String
}

/// The user's persisted update-source choice. Single source of truth
/// (spec §1.1 invariant #1).
/// Adding a user-selectable channel = append a `FeedChannel` to
/// `knownChannels` AND add a matching case here + handle it in
/// `FeedProbeEngine.resolve` + the settings `Picker` (Swift switches are
/// exhaustive, the compiler enforces all three).
enum UpdateFeedPolicy: String, Codable, CaseIterable, Equatable {
    case automatic
    case primary
    case fallback
    case gitee
}

enum UpdateFeedPolicies {
    /// Hardcoded v1 channel list. Future channels append here only.
    static let knownChannels: [FeedChannel] = [
        FeedChannel(
            id: "github-release",
            url: requireURL("https://github.com/irykelee/clipmemory/releases/latest/download/appcast.xml"),
            kind: .primary,
            labelKey: "settings.updateSource.option.primary"
        ),
        FeedChannel(
            id: "jsdelivr-mirror",
            url: UpdateService.fallbackFeedURL,
            kind: .fallback,
            labelKey: "settings.updateSource.option.fallback"
        ),
        // GITEE (2026-08-05): China-accessible mirror for users whose
        // network can't reach GitHub reliably. The Gitee repo holds a copy
        // of appcast.xml whose enclosures point at Gitee release assets
        // (GitHub tarball is mirrored there by Scripts/sync_gitee_release.sh
        // at every release). User-selectable via the settings picker; never
        // used by automatic probing (kind .fallback but only reachable via
        // the explicit .gitee policy — resolve() short-circuits for it).
        FeedChannel(
            id: "gitee-mirror",
            url: requireURL("https://gitee.com/irykelee/clipmemory/raw/main/appcast.xml"),
            kind: .fallback,
            labelKey: "settings.updateSource.option.gitee"
        )
    ]

    // L-19 (2026-07-24 review): no bare `URL(string:)!`. A typo'd hardcoded
    // feed URL now traps with the offending string in the message instead of
    // an opaque force-unwrap crash — these URLs are compile-time constants,
    // so a failure here is a programmer error, hence preconditionFailure.
    private static func requireURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("UpdateFeedPolicies: invalid hardcoded feed URL '\(string)'")
        }
        return url
    }
}
