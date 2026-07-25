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
enum UpdateFeedPolicy: String, Codable, CaseIterable, Equatable {
    case automatic
    case primary
    case fallback
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
            url: requireURL("https://cdn.jsdelivr.net/gh/irykelee/clipmemory@main/appcast.xml"),
            kind: .fallback,
            labelKey: "settings.updateSource.option.fallback"
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
