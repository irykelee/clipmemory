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
            url: URL(string: "https://github.com/irykelee/clipmemory/releases/latest/download/appcast.xml")!,
            kind: .primary,
            labelKey: "settings.updateSource.option.primary"
        ),
        FeedChannel(
            id: "jsdelivr-mirror",
            url: URL(string: "https://cdn.jsdelivr.net/gh/irykelee/clipmemory@main/appcast.xml")!,
            kind: .fallback,
            labelKey: "settings.updateSource.option.fallback"
        )
    ]
}
