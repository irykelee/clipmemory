import XCTest
@testable import ClipMemory

/// H1: the jsDelivr mirror is used only when the primary GitHub feed is
/// unreachable AND the user has explicitly consented AND the mirror is not
/// older than the primary's last known appcast. Never switch silently.
final class UpdateServiceTests: XCTestCase {

    private let primary = URL(string: "https://github.com/irykelee/clipmemory/releases/latest/download/appcast.xml")!

    override func tearDownWithError() throws {
        // Never leak consent/date state written to UserDefaults across tests.
        UpdateService.fallbackFeedConsent = nil
        UpdateService.lastPrimaryItemDate = nil
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
        UserDefaults.standard.removeObject(forKey: "UpdateFallbackFeedConsent")
    }

    // MARK: - Feed resolution

    func testResolvedFeedKeepsPrimaryWhenReachable() {
        for consent in [FeedConsent.granted, .denied, .undecided] {
            let resolved = UpdateService.resolvedFeed(primary: primary, primaryReachable: true, consent: consent)
            XCTAssertEqual(resolved, primary, "reachable primary must be kept regardless of consent")
        }
    }

    func testResolvedFeedUsesMirrorWhenUnreachableAndConsented() {
        let resolved = UpdateService.resolvedFeed(primary: primary, primaryReachable: false, consent: .granted)
        XCTAssertEqual(resolved, UpdateService.fallbackFeedURL)
        XCTAssertNotEqual(resolved, primary)
    }

    func testResolvedFeedKeepsPrimaryWhenConsentDenied() {
        let resolved = UpdateService.resolvedFeed(primary: primary, primaryReachable: false, consent: .denied)
        XCTAssertEqual(resolved, primary, "denied consent must keep the primary feed")
    }

    func testResolvedFeedNeverSwitchesSilentlyWhenUndecided() {
        let resolved = UpdateService.resolvedFeed(primary: primary, primaryReachable: false, consent: .undecided)
        XCTAssertEqual(resolved, primary, "H1: no silent fallback — undecided consent keeps the primary")
    }

    func testResolvedFeedKeepsPrimaryWhenMirrorIsStale() {
        let resolved = UpdateService.resolvedFeed(
            primary: primary,
            primaryReachable: false,
            consent: .granted,
            mirrorStale: true
        )
        XCTAssertEqual(resolved, primary, "a stale mirror must be refused even with consent")
    }

    func testFallbackFeedIsJsDelivrMirrorOfMainBranch() {
        let fallback = UpdateService.fallbackFeedURL.absoluteString
        XCTAssertTrue(fallback.hasPrefix("https://cdn.jsdelivr.net/gh/irykelee/clipmemory@main/"),
                      "fallback must be the jsDelivr mirror of this repo's main branch")
        XCTAssertTrue(fallback.hasSuffix("appcast.xml"))
    }

    // MARK: - Consent persistence

    func testFallbackFeedConsentRoundTripsUserDefaults() {
        UpdateService.fallbackFeedConsent = nil
        XCTAssertNil(UpdateService.fallbackFeedConsent, "unset means never asked")

        UpdateService.fallbackFeedConsent = true
        XCTAssertEqual(UpdateService.fallbackFeedConsent, true)

        UpdateService.fallbackFeedConsent = false
        XCTAssertEqual(UpdateService.fallbackFeedConsent, false)

        UpdateService.fallbackFeedConsent = nil
        XCTAssertNil(UpdateService.fallbackFeedConsent, "setting nil must remove the key")
    }

    // MARK: - Appcast date parsing (staleness guard)

    private let sampleAppcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0"><channel>
    <item><title>2.5.5</title><pubDate>Sat, 18 Jul 2026 03:32:59 +0000</pubDate></item>
    <item><title>2.5.0</title><pubDate>Sat, 18 Jul 2026 00:58:03 +0000</pubDate></item>
    </channel></rss>
    """

    func testLatestItemDateReturnsNewestPubDate() {
        let date = UpdateService.latestItemDate(inAppcastXML: sampleAppcast)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        XCTAssertEqual(date, formatter.date(from: "Sat, 18 Jul 2026 03:32:59 +0000"))
    }

    func testLatestItemDateReturnsNilForGarbage() {
        XCTAssertNil(UpdateService.latestItemDate(inAppcastXML: "not xml at all"))
        XCTAssertNil(UpdateService.latestItemDate(inAppcastXML: "<pubDate>yesterday</pubDate>"))
    }

    // MARK: - Staleness guard

    func testFallbackIsStaleWhenOlderThanLastPrimary() {
        let lastPrimary = Date(timeIntervalSince1970: 1_900_000_000) // 2030, after the sample appcast
        XCTAssertTrue(UpdateService.fallbackIsStale(fallbackXML: sampleAppcast, lastPrimaryItemDate: lastPrimary))
    }

    func testFallbackIsNotStaleWhenNewerOrEqual() {
        let old = Date(timeIntervalSince1970: 1_000_000_000) // 2001
        XCTAssertFalse(UpdateService.fallbackIsStale(fallbackXML: sampleAppcast, lastPrimaryItemDate: old))
    }

    func testFallbackIsNotStaleWhenNoBaselineKnown() {
        XCTAssertFalse(UpdateService.fallbackIsStale(fallbackXML: sampleAppcast, lastPrimaryItemDate: nil),
                       "without a primary baseline there is nothing to compare against")
    }

    func testFallbackIsNotStaleWhenUnparsable() {
        XCTAssertFalse(UpdateService.fallbackIsStale(fallbackXML: "garbage", lastPrimaryItemDate: Date()),
                       "unparsable mirror data must not block the consented fallback")
    }

    // MARK: - Feed policy (UpdateSourceSwitch spec §3.1, §5 tests 1-4)

    func testPolicyMigrationFromTrueConsentYieldsAutomatic() {
        UpdateService.fallbackFeedConsent = true
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
        UpdateService.migrateFeedConsentIfNeeded()
        XCTAssertEqual(UpdateService.feedPolicy, .automatic)
        XCTAssertNil(UserDefaults.standard.object(forKey: "UpdateFallbackFeedConsent"),
                     "old key must be cleared after migration")
    }

    func testPolicyMigrationFromFalseConsentYieldsPrimary() {
        UpdateService.fallbackFeedConsent = false
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
        UpdateService.migrateFeedConsentIfNeeded()
        XCTAssertEqual(UpdateService.feedPolicy, .primary)
        XCTAssertNil(UserDefaults.standard.object(forKey: "UpdateFallbackFeedConsent"))
    }

    func testPolicyDefaultsToAutomaticWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "UpdateFallbackFeedConsent")
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
        UpdateService.migrateFeedConsentIfNeeded()
        XCTAssertEqual(UpdateService.feedPolicy, .automatic,
                       "first-time users default to automatic for safety")
    }

    func testPolicyRoundTripsThroughUserDefaults() {
        for policy in UpdateFeedPolicy.allCases {
            UpdateService.feedPolicy = policy
            XCTAssertEqual(UpdateService.feedPolicy, policy, "round-trip failed for \(policy)")
        }
    }

    // MARK: - Feed probe (spec §5 tests 5-9)

    private let primaryChannel = FeedChannel(
        id: "primary", url: URL(string: "https://example.com/primary.xml")!,
        kind: .primary, labelKey: "x"
    )
    private let fallbackChannel = FeedChannel(
        id: "fallback", url: URL(string: "https://example.com/fallback.xml")!,
        kind: .fallback, labelKey: "x"
    )

    override func setUp() {
        super.setUp()
        MockURLProtocol.stubResponses = [:]
        MockURLProtocol.stubError = nil
    }

    func testProbeAutomaticSelectsPrimaryWhenReachable() async {
        MockURLProtocol.stubResponses[primaryChannel.url] = (200, "<rss><channel></channel></rss>", nil)
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.chosenURL, primaryChannel.url)
        XCTAssertEqual(decision?.reason, .automaticReachable)
    }

    func testProbeAutomaticSelectsFallbackWhenPrimaryTimesOut() async {
        // Primary fails (status 0 = badServerResponse); fallback succeeds.
        // (Brief step 3.2 originally used `stubError = URLError(.timedOut)`
        // globally, which fails BOTH URLs and contradicts the test's clear
        // intent of "primary times out, fallback reached".)
        MockURLProtocol.stubResponses = [
            primaryChannel.url: (0, "", nil),
            fallbackChannel.url: (200, "<rss><channel></channel></rss>", nil)
        ]
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url)
        XCTAssertEqual(decision?.reason, .automaticPrimaryDown)
    }

    func testProbeAutomaticRejectsStaleFallback() async {
        // Primary fails (status 0 = badServerResponse), fallback succeeds with stale pubDate
        MockURLProtocol.stubResponses = [
            primaryChannel.url: (0, "", nil),
            fallbackChannel.url: (200, sampleAppcast, nil) // sampleAppcast pubDate ~2020
        ]
        MockURLProtocol.stubError = nil
        let lastKnown = Date(timeIntervalSince1970: 1_900_000_000) // 2030, after sampleAppcast
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .automatic, lastKnownDate: lastKnown,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.chosenURL, primaryChannel.url,
                       "stale fallback must be rejected; keep primary even when unreachable")
        XCTAssertEqual(decision?.reason, .mirrorStaleRejected)
    }

    func testProbeManualPrimaryForcesPrimaryRegardlessOfNetwork() async {
        MockURLProtocol.stubError = URLError(.notConnectedToInternet)
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .primary, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.chosenURL, primaryChannel.url,
                       "user-forced primary must NOT silently downgrade to fallback")
        XCTAssertEqual(decision?.reason, .userForced)
    }

    func testProbeManualFallbackBypassesStaleGuard() async {
        let lastKnown = Date(timeIntervalSince1970: 1_900_000_000) // 2030
        MockURLProtocol.stubResponses = [
            primaryChannel.url: (0, "", nil), // unreachable
            fallbackChannel.url: (200, sampleAppcast, nil) // stale
        ]
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .fallback, lastKnownDate: lastKnown,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url,
                       "user-forced fallback bypasses stale guard (informed consent)")
        XCTAssertEqual(decision?.reason, .userForcedFallback)
    }
}

// MARK: - MockURLProtocol test helper (file scope, outside UpdateServiceTests class)

/// Test stub: feeds canned responses based on URL → (status, body) map.
/// Tests register an instance via `URLSessionConfiguration.protocolClasses`.
final class MockURLProtocol: URLProtocol {
    static var stubResponses: [URL: (status: Int, body: String, delay: TimeInterval?)] = [:]
    static var stubError: Error?

    override class func canInit(with request: URLRequest) -> Bool {
        stubError != nil || stubResponses.keys.contains(request.url!)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = MockURLProtocol.stubError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url, let stub = MockURLProtocol.stubResponses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let delay = stub.delay {
            Thread.sleep(forTimeInterval: delay)
        }
        if stub.status < 100 {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body.data(using: .utf8) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum MockURLSessionFactory {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
