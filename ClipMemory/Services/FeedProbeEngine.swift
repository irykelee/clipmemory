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

    /// Observed primary appcast body (nil when primary did not return 200, or
    /// when the chosen channel was not primary). Lets UpdateService update
    /// its `lastPrimaryItemDate` baseline without a second URLSession fetch.
    let primaryAppcastXML: String?

    /// Most recent `<pubDate>` extracted from `primaryAppcastXML`. nil when
    /// the body is nil or contained no parseable dates.
    let primaryLatestDate: Date?
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
            // Force-fetch the primary even in .primary mode so we can update
            // its baseline date without a second URLSession call from the
            // caller. Failure here just leaves the baseline unchanged.
            let primaryXML = await fetchBody(url: primary.url, timeout: effectiveTimeout)
            return FeedProbeDecision(
                chosenURL: primary.url,
                usedChannelID: primary.id,
                reason: .userForced,
                primaryAppcastXML: primaryXML,
                primaryLatestDate: primaryXML.flatMap(parseLatestDate)
            )
        case .fallback:
            // Bypass stale guard — user informed consent. Don't re-fetch primary.
            return FeedProbeDecision(
                chosenURL: fallback.url,
                usedChannelID: fallback.id,
                reason: .userForcedFallback,
                primaryAppcastXML: nil,
                primaryLatestDate: nil
            )
        case .automatic:
            let primaryXML = await fetchBody(url: primary.url, timeout: effectiveTimeout)
            if let primaryXML {
                return FeedProbeDecision(
                    chosenURL: primary.url,
                    usedChannelID: primary.id,
                    reason: .automaticReachable,
                    primaryAppcastXML: primaryXML,
                    primaryLatestDate: parseLatestDate(primaryXML)
                )
            }
            // Primary unreachable — try fallback.
            guard let fallbackXML = await fetchBody(url: fallback.url, timeout: effectiveTimeout) else {
                // Both down — keep primary (no silent failover when fallback also unreachable).
                return FeedProbeDecision(
                    chosenURL: primary.url,
                    usedChannelID: primary.id,
                    reason: .automaticPrimaryDown,
                    primaryAppcastXML: nil,
                    primaryLatestDate: nil
                )
            }
            // Stale guard — applies in .automatic only.
            if let lastKnownDate,
               let fallbackDate = parseLatestDate(fallbackXML),
               fallbackDate < lastKnownDate {
                return FeedProbeDecision(
                    chosenURL: primary.url,
                    usedChannelID: primary.id,
                    reason: .mirrorStaleRejected,
                    primaryAppcastXML: nil,
                    primaryLatestDate: nil
                )
            }
            return FeedProbeDecision(
                chosenURL: fallback.url,
                usedChannelID: fallback.id,
                reason: .automaticPrimaryDown,
                primaryAppcastXML: nil,
                primaryLatestDate: nil
            )
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
