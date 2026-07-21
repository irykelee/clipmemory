import Foundation

/// Why a particular channel was chosen. Surfaced in the UI status panel
/// (spec §2 component `UpdateStatus`).
enum ProbeReason: String, Equatable {
    case automaticReachable       // .automatic + primary 200
    case automaticPrimaryDown     // .automatic + primary down + fallback fresh
    case mirrorStaleRejected      // .automatic + primary down + fallback stale → keep primary
    case userForced               // .primary mode (regardless of network)
    case userForcedFallback       // .fallback mode (bypasses stale guard, user informed consent)
}

struct FeedProbeDecision: Equatable {
    let chosenURL: URL
    let usedChannelID: String
    let reason: ProbeReason
}

/// Pure protocol — test stubbing by injecting a deterministic mock that
/// returns fixed decisions (no network) for unit tests.
protocol FeedProbeEngine: Sendable {
    func resolve(
        policy: UpdateFeedPolicy,
        lastKnownDate: Date?,
        channels: [FeedChannel],
        timeout: TimeInterval?
    ) async -> FeedProbeDecision?
}

final class DefaultFeedProbeEngine: FeedProbeEngine {
    private let urlSession: URLSession
    private let probeTimeoutSeconds: TimeInterval
    private let parseLatestDate: (String) -> Date?

    init(
        urlSession: URLSession = .shared,
        probeTimeoutSeconds: TimeInterval = 5,
        parseLatestDate: @escaping (String) -> Date? = UpdateService.latestItemDate(inAppcastXML:)
    ) {
        self.urlSession = urlSession
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.parseLatestDate = parseLatestDate
    }

    func resolve(
        policy: UpdateFeedPolicy,
        lastKnownDate: Date?,
        channels: [FeedChannel],
        timeout: TimeInterval? = nil
    ) async -> FeedProbeDecision? {
        guard let primary = channels.first(where: { $0.kind == .primary }),
              let fallback = channels.first(where: { $0.kind == .fallback }) else {
            return nil
        }
        // Per-call override wins; otherwise use engine-level config from init.
        let effectiveTimeout = timeout ?? probeTimeoutSeconds
        switch policy {
        case .primary:
            return FeedProbeDecision(chosenURL: primary.url, usedChannelID: primary.id, reason: .userForced)
        case .fallback:
            // Bypass stale guard — user informed consent.
            return FeedProbeDecision(chosenURL: fallback.url, usedChannelID: fallback.id, reason: .userForcedFallback)
        case .automatic:
            let primaryXML = await fetchBody(url: primary.url, timeout: effectiveTimeout)
            if primaryXML != nil {
                return FeedProbeDecision(chosenURL: primary.url, usedChannelID: primary.id, reason: .automaticReachable)
            }
            // Primary unreachable — try fallback.
            guard let fallbackXML = await fetchBody(url: fallback.url, timeout: effectiveTimeout) else {
                // Both down — keep primary (no silent failover when fallback also unreachable).
                return FeedProbeDecision(chosenURL: primary.url, usedChannelID: primary.id, reason: .automaticPrimaryDown)
            }
            // Stale guard — applies in .automatic only.
            if let lastKnownDate,
               let fallbackDate = parseLatestDate(fallbackXML),
               fallbackDate < lastKnownDate {
                return FeedProbeDecision(chosenURL: primary.url, usedChannelID: primary.id, reason: .mirrorStaleRejected)
            }
            return FeedProbeDecision(chosenURL: fallback.url, usedChannelID: fallback.id, reason: .automaticPrimaryDown)
        }
    }

    private func fetchBody(url: URL, timeout: TimeInterval) async -> String? {
        do {
            let request = URLRequest(url: url, timeoutInterval: timeout)
            let (data, response) = try await urlSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
