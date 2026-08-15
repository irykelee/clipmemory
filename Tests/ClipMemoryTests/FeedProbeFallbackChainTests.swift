import XCTest
@testable import ClipMemory

/// L26 Path F (2026-08-15): exception paths in `DefaultFeedProbeEngine.resolve`
/// not yet covered by `FeedProbeSizeCapTests` or `UpdateServiceTests`.
///
/// Hypothesis (per `feedback/l26-live-drill-beats-static-audit`): static review
/// found `fetchBody` returns nil on (a) size-cap refusal, (b) URLError, (c)
/// non-200 HTTP, (d) UTF-8 decode failure — but the *decision* layer in
/// `resolveAutomatic` treats every nil identically. Real-drill question: does
/// the engine distinguish "primary CDN moved appcast (404)" from "primary CDN
/// rate-limited (503)" from "primary CDN body corrupt (200 + bad UTF-8)"? And
/// does an empty-but-200 body reach Sparkle as an empty channel?
///
/// All tests use the same URLProtocol stub shape as `FeedProbeSizeCapTests`
/// (file-scope `FallbackChainURLProtocol`). Tests inject `lastKnownDate` only
/// where the stale-guard in `resolveAutomatic` matters.
final class FeedProbeFallbackChainTests: XCTestCase {

    private let primaryChannel = FeedChannel(
        id: "github-release", url: URL(string: "https://example.com/fc-primary.xml")!,
        kind: .primary, labelKey: "x"
    )
    private let fallbackChannel = FeedChannel(
        id: "jsdelivr-mirror", url: URL(string: "https://example.com/fc-fallback.xml")!,
        kind: .fallback, labelKey: "x"
    )

    override func setUp() {
        super.setUp()
        FallbackChainURLProtocol.stubs = [:]
        FallbackChainURLProtocol.errors = [:]
        FallbackChainURLProtocol.hangs = [:]
        FallbackChainURLProtocol.debugLogging = false
    }

    override func tearDown() {
        FallbackChainURLProtocol.stubs = [:]
        FallbackChainURLProtocol.errors = [:]
        FallbackChainURLProtocol.hangs = [:]
        FallbackChainURLProtocol.debugLogging = false
        super.tearDown()
    }

    private func makeEngine(timeout: TimeInterval = 5) -> DefaultFeedProbeEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FallbackChainURLProtocol.self]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return DefaultFeedProbeEngine(urlSession: URLSession(configuration: config),
                                      probeTimeoutSeconds: timeout)
    }

    // MARK: - Empty / corrupt body scenarios

    /// Primary returns 200 with an empty body. **ID-UPDATE-0004 (2026-08-15, L26
    /// Path F)**: an empty body is no longer treated as a zero-item
    /// "reachable" feed — `fetchBody` returns nil so the caller falls back
    /// to `.bothDownKeepPrimary`. This eliminates the silent "Sparkle says
    /// you're up to date when the CDN silently emptied the appcast" mode.
    func testAutomaticEmptyPrimaryBodyNowTreatedAsDown() async {
        FallbackChainURLProtocol.stubs[primaryChannel.url] = (200, Data(), nil)
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.reason, .bothDownKeepPrimary,
            "EMPTY primary body must be treated as primary-down — no zero-item feed reaches Sparkle")
        XCTAssertEqual(decision?.chosenURL, primaryChannel.url,
            "no better choice exists; primary URL kept so Sparkle can retry on next probe")
        XCTAssertNil(decision?.primaryAppcastXML,
            "empty body must NOT round-trip; nil signals 'treat as down' to the caller")
    }

    /// Primary returns 200 but the body is non-UTF-8 bytes. `fetchBody` (line
    /// 359) logs `Feed body returned 200 but failed UTF-8 decode` and returns
    /// nil → `.bothDownKeepPrimary` (primary "down" for decision purposes).
    /// Reasonable. But the test verifies the "down" decision is correct AND
    /// captures the decision shape so a future refactor that changes nil-vs-
    /// empty semantics will be flagged.
    func testAutomaticNonUTF8PrimaryBodyTreatedAsPrimaryDown() async {
        // 0xFF 0xFE 0xFD is invalid UTF-8 start-byte.
        let badBytes = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        FallbackChainURLProtocol.stubs[primaryChannel.url] = (200, badBytes, nil)
        FallbackChainURLProtocol.stubs[fallbackChannel.url] = (
            200, Data("<rss><channel><item><pubDate>Wed, 01 Jan 2026 00:00:00 +0000</pubDate></item></channel></rss>".utf8), nil
        )
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.reason, .automaticPrimaryDown,
            "non-UTF8 primary must be treated as primary-down, not as healthy")
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url,
            "fallback must take over; the user gets a feed either way")
    }

    /// Primary 503 (rate-limited, transient). Returns nil → "primary down" →
    /// fallback. Correct behavior, but the test exists to PROVE that the
    /// error path for transient primary failure does NOT silently keep the
    /// broken primary URL when fallback is healthy.
    func testAutomaticTransientPrimaryFailureFallsBackWhenFallbackFresh() async {
        FallbackChainURLProtocol.stubs[primaryChannel.url] = (503, Data("rate limited".utf8), nil)
        FallbackChainURLProtocol.stubs[fallbackChannel.url] = (
            200, Data("<rss><channel><item><pubDate>Wed, 01 Jan 2026 00:00:00 +0000</pubDate></item></channel></rss>".utf8), nil
        )
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.reason, .automaticPrimaryDown)
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url)
    }

    /// **ID-UPDATE-0004 (2026-08-15, L26 Path F)**: an empty fallback body is
    /// no longer treated as a zero-item "fallback reached" — `fetchBody`
    /// returns nil for both empty AND non-UTF-8 bodies, so the engine sees
    /// the fallback as down and falls back to `.bothDownKeepPrimary`. This
    /// eliminates the previous silent failure where `parseLatestDate("")`
    /// returning nil bypassed the mirror-stale guard and let the empty
    /// fallback win over a healthy primary.
    func testAutomaticEmptyFallbackNowTreatedAsDown() async {
        // Primary: 503 → forces engine to probe fallback.
        FallbackChainURLProtocol.stubs[primaryChannel.url] = (
            503, Data("rate limited".utf8), nil
        )
        // Fallback: empty body — fetchBody now returns nil, same as non-UTF-8.
        FallbackChainURLProtocol.stubs[fallbackChannel.url] = (200, Data(), nil)
        let lastKnown = Date(timeIntervalSinceNow: 86_400)
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: lastKnown,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.reason, .bothDownKeepPrimary,
            "EMPTY fallback body must be treated as fallback-down — no zero-item feed reaches Sparkle")
        XCTAssertEqual(decision?.chosenURL, primaryChannel.url,
            "no better choice exists; primary URL kept so Sparkle can retry on next probe")
    }

    // MARK: - Both-down scenarios

    /// Both feeds unreachable (timeout-like 0-status response from our stub
    /// mapped to `.cannotConnectToHost`). Engine must keep the primary URL
    /// — `.bothDownKeepPrimary` reason — and Sparkle will simply fail to
    /// find an update. The test verifies the reason field is set so the
    /// UI status panel can show a distinct message ("both feeds
    /// unreachable" vs. "primary down, fallback took over").
    func testAutomaticBothDownKeepsPrimaryWithDistinctReason() async {
        FallbackChainURLProtocol.errors[primaryChannel.url] = URLError(.cannotConnectToHost)
        FallbackChainURLProtocol.errors[fallbackChannel.url] = URLError(.cannotConnectToHost)
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.reason, .bothDownKeepPrimary,
            "BUG-035: 'both down' must be a distinct reason so UI can differentiate")
        XCTAssertEqual(decision?.chosenURL, primaryChannel.url,
            "no better choice exists; keep primary URL so Sparkle at least tries the canonical endpoint")
        XCTAssertNil(decision?.primaryAppcastXML)
        XCTAssertNil(decision?.primaryLatestDate)
    }

    /// Primary timeout (5s) + fallback healthy → fallback wins with
    /// `.automaticPrimaryDown`. The primary timeout emits a `notice`-level
    /// log (transient-tolerant per L-20); the engine must not lose this
    /// information.
    func testAutomaticPrimaryTimeoutThenFallbackWins() async {
        FallbackChainURLProtocol.errors[primaryChannel.url] = URLError(.timedOut)
        FallbackChainURLProtocol.stubs[fallbackChannel.url] = (
            200, Data("<rss><channel><item><pubDate>Wed, 01 Jan 2026 00:00:00 +0000</pubDate></item></channel></rss>".utf8), nil
        )
        let decision = await makeEngine(timeout: 1).resolve(  // 1s timeout keeps test fast
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.reason, .automaticPrimaryDown)
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url)
    }
}

// MARK: - URLProtocol stub

/// File-scope URLProtocol stub for FeedProbeFallbackChainTests. Unlike
/// SizeCapURLProtocol, this one can also synthesize URLErrors per-URL so the
/// test can exercise the timeout / cannot-connect branch.
final class FallbackChainURLProtocol: URLProtocol {
    static var stubs: [URL: (status: Int, body: Data, headers: [String: String]?)] = [:]
    static var errors: [URL: URLError] = [:]
    static var hangs: [URL: Bool] = [:]  // unused for now; reserved for future "feed never responds" tests
    static var debugLogging = false  // flip on if a regression recurs

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        if FallbackChainURLProtocol.debugLogging {
            print("[FCStub.canInit] \(url) -> stubs=\(FallbackChainURLProtocol.stubs.keys.contains(url)) errors=\(FallbackChainURLProtocol.errors.keys.contains(url))")
        }
        return FallbackChainURLProtocol.stubs.keys.contains(url) || FallbackChainURLProtocol.errors.keys.contains(url)
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if FallbackChainURLProtocol.debugLogging {
            print("[FCStub.start] \(url) status=\(String(describing: FallbackChainURLProtocol.stubs[url]?.status)) errCode=\(String(describing: FallbackChainURLProtocol.errors[url]?.code.rawValue))")
        }
        if let error = FallbackChainURLProtocol.errors[url] {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let stub = FallbackChainURLProtocol.stubs[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}