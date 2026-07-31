import Foundation
import os

/// Why a particular channel was chosen. Surfaced in the UI status panel
/// (spec §2 component `UpdateStatus`).
enum ProbeReason: String, Equatable {
    case automaticReachable       // .automatic + primary 200
    case automaticPrimaryDown     // .automatic + primary down + fallback fresh
    // BUG-035 (2026-07-21): distinguished from automaticPrimaryDown which
    // semantically implies fallback took over. bothDownKeepPrimary covers
    // the "primary down AND fallback down" case where we keep the primary
    // URL (no better choice).
    case bothDownKeepPrimary     // .automatic + primary down + fallback also down
    case mirrorStaleRejected      // .automatic + primary down + fallback stale → keep primary
    case userForced               // .primary mode (regardless of network)
    case userForcedFallback       // .fallback mode (bypasses stale guard, user informed consent)

    /// UPD-3 (2026-07-24 review): L10n key for the settings status panel.
    /// The raw enum rawValue used to be interpolated straight into
    /// user-visible text; the view now resolves this key via L10n instead.
    var labelKey: String { "settings.updateSource.reason.\(rawValue)" }
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
    // H-20 (2026-07-24 audit): logger for size-cap refusals.
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "FeedProbe")
    private let urlSession: URLSession
    // ID-LIFE-0010 (2026-07-30 audit): tracks whether the URLSession was
    // self-created (default branch below) vs caller-injected. Only the
    // self-created one should be invalidated in deinit — test-injected
    // sessions are owned by their tests and must not be invalidated.
    private let selfCreated: Bool
    private let probeTimeoutSeconds: TimeInterval
    private let parseLatestDate: (String) -> Date?

    init(
        urlSession: URLSession? = nil,
        probeTimeoutSeconds: TimeInterval = 5,
        parseLatestDate: @escaping (String) -> Date? = UpdateService.latestItemDate(inAppcastXML:)
    ) {
        // BUG-036 (2026-07-21): URLSession.shared has a default
        // `timeoutIntervalForRequest` of 60s that some macOS versions honor
        // over the per-request `timeoutInterval` for `data(for:)`. Force
        // an ephemeral session with explicit 5s request timeout so the
        // probe's 5s budget is actually enforced. Tests inject their own
        // URLSession via the parameter; the default ephemeral one has no
        // shared cookie/cache state so probes don't pollute each other.
        if let urlSession {
            self.urlSession = urlSession
            self.selfCreated = false
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = probeTimeoutSeconds
            config.timeoutIntervalForResource = probeTimeoutSeconds
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.urlSession = URLSession(configuration: config)
            self.selfCreated = true
        }
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.parseLatestDate = parseLatestDate
    }

    deinit {
        // ID-LIFE-0010: invalidate only if we own the URLSession. The
        // production singleton never deinits, so this is defensive for
        // future test/refactor paths that construct transient engines.
        if selfCreated { urlSession.invalidateAndCancel() }
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
            return await resolvePrimary(primary: primary, timeout: effectiveTimeout)
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
            return await resolveAutomatic(
                primary: primary,
                fallback: fallback,
                lastKnownDate: lastKnownDate,
                timeout: effectiveTimeout
            )
        }
    }

    /// `.primary` mode: user explicitly chose primary — fetch it so caller can
    /// update baseline date without a second URLSession call. Failure leaves
    /// baseline unchanged.
    private func resolvePrimary(primary: FeedChannel, timeout: TimeInterval) async -> FeedProbeDecision {
        let primaryXML = await fetchBody(url: primary.url, timeout: timeout)
        return FeedProbeDecision(
            chosenURL: primary.url,
            usedChannelID: primary.id,
            reason: .userForced,
            primaryAppcastXML: primaryXML,
            primaryLatestDate: primaryXML.flatMap(parseLatestDate)
        )
    }

    /// `.automatic` mode: try primary first; if down, try fallback unless stale.
    /// Both down → keep primary (no silent failover). Stale guard applies only here.
    private func resolveAutomatic(
        primary: FeedChannel,
        fallback: FeedChannel,
        lastKnownDate: Date?,
        timeout: TimeInterval
    ) async -> FeedProbeDecision {
        let primaryXML = await fetchBody(url: primary.url, timeout: timeout)
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
        guard let fallbackXML = await fetchBody(url: fallback.url, timeout: timeout) else {
            // BUG-035 (2026-07-21): both down — distinct reason so the UI
            // can show "both feeds unreachable" instead of misleadingly
            // suggesting fallback took over.
            return FeedProbeDecision(
                chosenURL: primary.url,
                usedChannelID: primary.id,
                reason: .bothDownKeepPrimary,
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

    /// ID-UPDATE-0002 (2026-07-31 audit): streams the H-20 size cap through
    /// a URLSessionDataDelegate so `fetchBody` can collect the body with ONE
    /// continuation-resume instead of iterating `bytes(for:)` one byte at a
    /// time (tens of thousands of async suspensions on a near-1 MB feed could
    /// burn the 5s probe budget and misdiagnose a healthy feed as
    /// unreachable). The cap is still enforced before/while bytes arrive —
    /// never after a full in-memory buffer (UPD-2 invariant):
    /// - `didReceive response` refuses a declared Content-Length over the cap
    ///   before a single body byte is consumed
    /// - `didReceive data` cancels the task the moment the running total
    ///   crosses the cap (Content-Length absent / chunked)
    ///
    /// Why not `data(for:delegate:)`: the async convenience APIs (with or
    /// without a per-task delegate) do NOT deliver the data/response delegate
    /// callbacks — verified 2026-07-31 against a URLProtocol stub AND with a
    /// session-bound delegate; only the classic no-completion-handler
    /// `dataTask(with:)` drives them. So this delegate is bound to a
    /// per-fetch URLSession and the task's completion is bridged back via
    /// `didCompleteWithError` + a checked continuation.
    private final class CappedFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        /// Why the fetch was refused; nil while the response is still legal.
        enum Refusal {
            case declaredContentLength(Int64)
            case streamExceeded
        }
        let maxBytes: Int
        private(set) var refusal: Refusal?
        private var receivedBytes = 0
        private var body = Data()
        private var response: URLResponse?
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        /// Runs a single data task whose streaming callbacks land on this
        /// delegate. Resumes exactly once — URLSession guarantees one
        /// `didCompleteWithError` per task, including after our own cancel.
        func fetch(session: URLSession, request: URLRequest) async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { cont in
                continuation = cont
                session.dataTask(with: request).resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            if response.expectedContentLength > Int64(maxBytes) {
                refusal = .declaredContentLength(response.expectedContentLength)
                completionHandler(.cancel)
            } else {
                self.response = response
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            receivedBytes += data.count
            if receivedBytes > maxBytes {
                refusal = .streamExceeded
                dataTask.cancel()
            } else {
                body.append(data)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error {
                continuation.resume(throwing: error)
            } else if let response {
                continuation.resume(returning: (body, response))
            } else {
                continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
    }

    private func fetchBody(url: URL, timeout: TimeInterval) async -> String? {
        let request = URLRequest(url: url, timeoutInterval: timeout)
        // ID-UPDATE-0002: one-shot body collection with the cap enforced by
        // the delegate (see CappedFetchDelegate doc). Replaces the byte-at-a-
        // time `bytes(for:)` loop (per-byte async suspension). A per-fetch
        // session is required because the streaming delegate can only be
        // bound at session-creation time; reusing the engine session's
        // configuration preserves its protocolClasses (tests) and timeouts.
        let delegate = CappedFetchDelegate(maxBytes: Self.maxResponseBytes)
        let session = URLSession(configuration: urlSession.configuration, delegate: delegate, delegateQueue: nil)
        // The task is already complete at this defer — invalidate only
        // releases the delegate/session resources.
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await delegate.fetch(session: session, request: request)
        } catch {
            if let refusal = delegate.refusal {
                switch refusal {
                case .declaredContentLength(let declared):
                    DefaultFeedProbeEngine.logger.warning("Feed Content-Length \(declared) exceeds \(Self.maxResponseBytes) bytes — refusing before download")
                case .streamExceeded:
                    DefaultFeedProbeEngine.logger.warning("Feed body exceeded \(Self.maxResponseBytes) bytes mid-stream — cancelling")
                }
                return nil
            }
            if let urlError = error as? URLError {
                // L-20: separate timeout (often transient, keep .automatic
                // patience) from other transport errors (DNS, refused, etc.)
                // so a brief outage doesn't look like a hard failure.
                switch urlError.code {
                case .timedOut:
                    DefaultFeedProbeEngine.logger.notice("Feed probe timed out after \(timeout, privacy: .public)s url=\(url.absoluteString, privacy: .public)")
                case .cancelled:
                    // Probe was cancelled by a newer probe winning the race —
                    // expected behavior, don't surface to operators.
                    break
                default:
                    DefaultFeedProbeEngine.logger.error("Feed probe URLError code=\(urlError.code.rawValue, privacy: .public) desc=\(urlError.localizedDescription, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                }
            } else {
                DefaultFeedProbeEngine.logger.error("Feed probe non-URL error: \(String(describing: error), privacy: .public) url=\(url.absoluteString, privacy: .public)")
            }
            return nil
        }
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }
        // L-20 (2026-07-24 audit): log parse failures distinctly from
        // transport errors so an operator can tell "feed returned 200 but
        // body wasn't valid UTF-8" (a CDN corruption signal) from
        // "connection refused" (a network signal). Both still surface
        // as nil upstream; the split is for triage only.
        guard let body = String(data: data, encoding: .utf8) else {
            DefaultFeedProbeEngine.logger.error("Feed body returned 200 but failed UTF-8 decode (bytes=\(data.count))")
            return nil
        }
        return body
    }

    /// H-20 (2026-07-24 audit): 1 MB cap on feed body size. appcast.xml feeds
    /// are typically <50 KB; 1 MB leaves 20x headroom while preventing the
    /// OOM path from a malicious CDN response. UPD-2 + ID-UPDATE-0002:
    /// enforced by `CappedFetchDelegate` during streaming (Content-Length
    /// precheck + running-total cancel), never after a full in-memory buffer.
    static let maxResponseBytes = 1_000_000
}
