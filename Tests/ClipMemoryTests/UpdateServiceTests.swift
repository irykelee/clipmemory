import XCTest
@testable import ClipMemory

/// H1: the jsDelivr mirror is used only when the primary GitHub feed is
/// unreachable AND the user has explicitly consented AND the mirror is not
/// older than the primary's last known appcast. Never switch silently.
final class UpdateServiceTests: XCTestCase {

    private let primary = URL(string: "https://github.com/irykelee/clipmemory/releases/latest/download/appcast.xml")!

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // M13 (2026-08-03): UpdateService static accessors now use an injectable
        // defaults suite. Redirect to an isolated test suite.
        testDefaults = makeTestDefaults()
        UpdateService.defaults = testDefaults
        MockURLProtocol.stubResponses = [:]
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestCount = 0
    }

    override func tearDownWithError() throws {
        // M13: reset to production defaults.
        UpdateService.defaults = .standard
        removeTestDefaults(testDefaults)
        testDefaults = nil
    }

    // ID-MISC-0002 (2026-07-31 audit): the "Feed resolution" tests for
    // UpdateService.resolvedFeed and the "Staleness guard" tests for
    // fallbackIsStale were deleted together with that dead code (no
    // production callers; the live decision path is FeedProbeEngine).

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

    /// UPD-4 (2026-07-24 review): RFC 822 also permits NAMED timezones. A
    /// pubDate like "... GMT" must parse via the `zzz` fallback formatter —
    /// before the fix it returned nil and the H1 stale guard failed open.
    func testLatestItemDateParsesNamedTimezone() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0"><channel>
        <item><title>2.5.6</title><pubDate>Sat, 18 Jul 2026 03:32:59 GMT</pubDate></item>
        </channel></rss>
        """
        let date = UpdateService.latestItemDate(inAppcastXML: xml)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        XCTAssertEqual(date, formatter.date(from: "Sat, 18 Jul 2026 03:32:59 +0000"))
    }

    // MARK: - Appcast version parsing (C2: Update tab version display)

    private let sampleAppcastWithVersions = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
    <item>
    <title>ClipMemory 2.7.9</title>
    <sparkle:shortVersionString>2.7.9</sparkle:shortVersionString>
    <pubDate>Wed, 05 Aug 2026 15:00:00 +0000</pubDate>
    </item>
    <item>
    <title>ClipMemory 2.7.8</title>
    <sparkle:shortVersionString>2.7.8</sparkle:shortVersionString>
    <pubDate>Tue, 04 Aug 2026 15:00:00 +0000</pubDate>
    </item>
    <item>
    <title>ClipMemory 2.7.7</title>
    <sparkle:shortVersionString>2.7.7</sparkle:shortVersionString>
    <pubDate>Sun, 02 Aug 2026 15:00:00 +0000</pubDate>
    </item>
    </channel>
    </rss>
    """

    /// Sparkle convention: newest item appears first in appcast. C2 uses
    /// "first item" as the source of truth for "latest available version" —
    /// the UI just needs `==` comparison to current, so semver sorting is
    /// not needed and the missing defensive code is deliberate.
    func testLatestVersionStringReturnsFirstShortVersionString() {
        XCTAssertEqual(UpdateService.latestVersionString(inAppcastXML: sampleAppcastWithVersions),
                       "2.7.9")
    }

    /// Single-item feed (initial release or pre-update build) still resolves.
    func testLatestVersionStringReturnsValueForSingleItem() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
        <item>
        <title>ClipMemory 2.5.0</title>
        <sparkle:shortVersionString>2.5.0</sparkle:shortVersionString>
        <pubDate>Fri, 18 Jul 2026 00:58:03 +0000</pubDate>
        </item>
        </channel>
        </rss>
        """
        XCTAssertEqual(UpdateService.latestVersionString(inAppcastXML: xml), "2.5.0")
    }

    /// Boundary: missing tag, garbage, empty tag — all nil. The UI shows
    /// only the current version (中性态) in these cases, never claims
    /// "up to date" without evidence.
    func testLatestVersionStringReturnsNilForEmptyOrMissing() {
        XCTAssertNil(UpdateService.latestVersionString(inAppcastXML: "not xml at all"))
        XCTAssertNil(UpdateService.latestVersionString(inAppcastXML: ""))
        XCTAssertNil(UpdateService.latestVersionString(inAppcastXML: "<pubDate>Wed, 05 Aug 2026</pubDate>"))
        XCTAssertNil(UpdateService.latestVersionString(inAppcastXML: "<sparkle:shortVersionString></sparkle:shortVersionString>"))
        XCTAssertNil(UpdateService.latestVersionString(inAppcastXML: "<sparkle:shortVersionString>   </sparkle:shortVersionString>"))
    }

    /// The Sparkle-namespaced shortVersionString is what the binary uses
    /// for `==` against `CFBundleShortVersionString`. A bare `<version>`
    /// tag (or any other namespace) must NOT be picked up — otherwise a
    /// future change to the bare `<version>` tag would silently corrupt
    /// the displayed "latest" version.
    func testLatestVersionStringIgnoresNonSparkleVersion() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
        <item>
        <title>Misleading</title>
        <version>99.99.99</version>
        <sparkle:shortVersionString>2.7.8</sparkle:shortVersionString>
        </item>
        </channel>
        </rss>
        """
        XCTAssertEqual(UpdateService.latestVersionString(inAppcastXML: xml), "2.7.8",
                       "Must match the Sparkle-namespaced tag, not a bare <version>")
    }

    // MARK: - ID-UPDATE-0001 (2026-07-31 Round 5): updater must start after probe


    /// ID-UPDATE-0001: `startAfterFeedProbe` captured `probeGeneration`
    /// BEFORE `triggerProbe()` — but `triggerProbe()` always increments it
    /// first thing, so the post-await guard `myGeneration == probeGeneration`
    /// could never pass and `startUpdater()` was dead code. Production
    /// (SUFeedURL always present) always took this path, so Sparkle never
    /// started: no automatic checks, manual checks silently no-op'd.
    /// All pre-existing tests use `autoStart: false`, so the path had zero
    /// coverage. This test drives the probe-then-start path directly and
    /// asserts the start is reached exactly once.
    @MainActor
    func testStartAfterFeedProbeStartsUpdater() async {
        let stub = StubProbeEngine()
        await stub.setNextDecision(FeedProbeDecision(
            chosenURL: primary,
            usedChannelID: "primary",
            reason: .automaticReachable,
            primaryAppcastXML: nil,
            primaryLatestDate: nil
        ))
        let service = UpdateService(probeEngine: stub, autoStart: false)
        service.hasFeedURL = { true } // test runner bundle has no SUFeedURL
        var startCount = 0
        service.startUpdaterHook = { startCount += 1 }

        await service.startAfterFeedProbe()

        XCTAssertEqual(startCount, 1,
                       "ID-UPDATE-0001: startUpdater() must be reached after our own probe finishes")
    }

    /// The generation guard must still block the start when a NEWER probe
    /// ran while we were awaiting (e.g. the user switched the update-source
    /// policy mid-probe). Simulated with a delayed stub decision plus an
    /// extra triggerProbe fired during the delay.
    @MainActor
    func testStartAfterFeedProbeSkipsStartWhenNewerProbeRan() async {
        let stub = StubProbeEngine()
        await stub.enqueueDecision(FeedProbeDecision(
            chosenURL: primary,
            usedChannelID: "primary",
            reason: .automaticReachable,
            primaryAppcastXML: nil,
            primaryLatestDate: nil
        ), delaySeconds: 0.3)
        let service = UpdateService(probeEngine: stub, autoStart: false)
        service.hasFeedURL = { true }
        var startCount = 0
        service.startUpdaterHook = { startCount += 1 }

        async let firstProbe: Void = service.startAfterFeedProbe()
        // Let the first probe get in flight, then run a newer probe
        // (setPolicy does exactly this in production). The stub's queue is
        // empty for it → nil decision → only the generation bump matters.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await service.triggerProbe()
        await firstProbe

        XCTAssertEqual(startCount, 0,
                       "a newer in-flight probe must suppress the stale path's startUpdater()")
    }

    // MARK: - Feed policy (UpdateSourceSwitch spec §3.1, §5 tests 1-4)

    func testPolicyMigrationFromTrueConsentYieldsAutomatic() {
        UpdateService.fallbackFeedConsent = true
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        UpdateService.migrateFeedConsentIfNeeded()
        XCTAssertEqual(UpdateService.feedPolicy, .automatic)
        XCTAssertNil(testDefaults.object(forKey: "UpdateFallbackFeedConsent"),
                     "old key must be cleared after migration")
    }

    func testPolicyMigrationFromFalseConsentYieldsPrimary() {
        UpdateService.fallbackFeedConsent = false
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        UpdateService.migrateFeedConsentIfNeeded()
        XCTAssertEqual(UpdateService.feedPolicy, .primary)
        XCTAssertNil(testDefaults.object(forKey: "UpdateFallbackFeedConsent"))
    }

    func testPolicyDefaultsToAutomaticWhenUnset() {
        testDefaults.removeObject(forKey: "UpdateFallbackFeedConsent")
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
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

    // NEW-7 (2026-08-06): fixtures use the production-shaped ids
    // ("github-release" / "jsdelivr-mirror") so they exercise the same id
    // binding the real engine uses. The old "primary"/"fallback" ids made
    // the engine's kind-based binding look correct in tests while hiding
    // a class of order-dependent bugs.
    private let primaryChannel = FeedChannel(
        id: "github-release", url: URL(string: "https://example.com/primary.xml")!,
        kind: .primary, labelKey: "x"
    )
    private let fallbackChannel = FeedChannel(
        id: "jsdelivr-mirror", url: URL(string: "https://example.com/fallback.xml")!,
        kind: .fallback, labelKey: "x"
    )

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

    // MARK: - Gitee channel (added 2026-08-06)

    private let giteeChannel = FeedChannel(
        id: "gitee-mirror", url: URL(string: "https://gitee.com/irykelee/clipmemory/raw/main/appcast.xml")!,
        kind: .fallback, labelKey: "settings.updateSource.option.gitee"
    )

    /// Gitee is user-forced: short-circuit, don't probe primary or check
    /// staleness. Identical "forced" semantics as the `.fallback` case
    /// but uses the gitee channel (resolved by id since its `kind` is
    /// `.fallback` to keep the kind taxonomy 2-valued).
    func testProbeManualGiteeShortCircuits() async {
        // If the engine probed, this stubError would cause a crash; if it
        // doesn't probe (correct), the stub is irrelevant. The requestCount
        // assertion below turns that implicit signal into an explicit fail.
        MockURLProtocol.stubError = URLError(.notConnectedToInternet)
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .gitee, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel, giteeChannel]
        )
        XCTAssertEqual(MockURLProtocol.requestCount, 0,
                       "user-forced Gitee must NOT touch the network")
        XCTAssertEqual(decision?.chosenURL, giteeChannel.url,
                       "user-forced Gitee must NOT probe primary")
        XCTAssertEqual(decision?.usedChannelID, "gitee-mirror",
                       "channel id must be the known Gitee id")
        XCTAssertEqual(decision?.reason, .userForcedFallback,
                       "Gitee path reuses userForcedFallback reason (matches .fallback)")
        XCTAssertNil(decision?.primaryAppcastXML,
                     "Gitee path must NOT fetch primary — no baseline update")
        XCTAssertNil(decision?.primaryLatestDate)
    }

    /// Same probe bypass even when the stale-guard would otherwise kick in.
    /// Gitee users in China explicitly opt in; we trust their choice.
    func testProbeManualGiteeBypassesStaleGuard() async {
        let lastKnown = Date(timeIntervalSince1970: 1_900_000_000) // 2030
        // Stubs would matter only if probe ran — verify it doesn't by
        // configuring them to fail and confirming the decision still picks
        // Gitee cleanly.
        MockURLProtocol.stubError = URLError(.notConnectedToInternet)
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .gitee, lastKnownDate: lastKnown,
            channels: [primaryChannel, fallbackChannel, giteeChannel]
        )
        XCTAssertEqual(MockURLProtocol.requestCount, 0,
                       "user-forced Gitee must NOT touch the network, even with stale lastKnown")
        XCTAssertEqual(decision?.chosenURL, giteeChannel.url)
        XCTAssertEqual(decision?.reason, .userForcedFallback)
    }

    /// Negative case: if the channel list doesn't include the Gitee channel
    /// (e.g. some future build disables it), the .gitee policy must return
    /// nil rather than silently fall back to GitHub. The UI then shows an
    /// error rather than misleadingly reporting "up to date" via primary.
    func testProbeManualGiteeReturnsNilIfChannelMissing() async {
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .gitee, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertNil(decision, "missing gitee channel must return nil, not silently pick another")
    }

    /// Sanity: the Gitee channel is registered in knownChannels so the
    /// .gitee policy actually has something to resolve. Guards against
    /// accidental removal when refactoring the channel list.
    func testGiteeChannelRegisteredInKnownChannels() {
        let gitee = UpdateFeedPolicies.knownChannels.first { $0.id == "gitee-mirror" }
        XCTAssertNotNil(gitee, "gitee-mirror channel must be registered in UpdateFeedPolicies.knownChannels")
        XCTAssertEqual(gitee?.kind, .fallback,
                       "Gitee channel uses kind .fallback — its policy routing lives in FeedProbeEngine.resolve, not in ChannelKind")
        XCTAssertEqual(gitee?.labelKey, "settings.updateSource.option.gitee")
    }

    // MARK: - Service orchestration (spec §5 tests 10-11)

    @MainActor
    func testSetPolicyTriggersProbeAndStatusUpdate() async {
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        MockURLProtocol.stubResponses = [:]
        MockURLProtocol.stubError = nil
        // Deterministic stub — no network dependency (Important #4 fix).
        let stub = StubProbeEngine()
        await stub.setNextDecision(automaticPrimaryDecision)
        let service = UpdateService(probeEngine: stub, autoStart: false)

        // AutoStart off — no probe runs from init (Important #4 seam).
        let initCalls = await stub.callCount
        XCTAssertEqual(initCalls, 0,
                       "autoStart:false must NOT trigger an init probe")

        let probeDone = expectation(description: "setPolicy probe completes")
        await stub.setOnResolve { _ in probeDone.fulfill() }
        service.setPolicy(.automatic)
        await fulfillment(of: [probeDone], timeout: 2)

        let afterCalls = await stub.callCount
        XCTAssertEqual(afterCalls, 1, "setPolicy must trigger exactly one probe")
        XCTAssertEqual(service.status.currentSource, "github-release",
                       "stub decision reflects in status immediately")
        XCTAssertEqual(UpdateService.feedPolicy, .automatic,
                       "policy must be persisted to UserDefaults")
    }

    @MainActor
    func testSetFallbackPolicyActivatesMirrorWithoutFetch() async {
        // SPUUpdater.resetUpdateCycleAfterShortDelay() does not throw on
        // macOS in Sparkle 2.9.4, so the do/try/catch path is unreachable
        // in unit tests — but the .fallback → jsdelivr-mirror activation
        // path is exercised here. Sparkle reset failures are covered by
        // e2e manual (Task 9).
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        MockURLProtocol.stubResponses = [:]
        let stub = StubProbeEngine()
        await stub.setNextDecision(forcedFallbackDecision)
        let service = UpdateService(probeEngine: stub, autoStart: false)
        let probeDone = expectation(description: "fallback probe completes")
        await stub.setOnResolve { _ in probeDone.fulfill() }
        service.setPolicy(.fallback)
        await fulfillment(of: [probeDone], timeout: 2)
        XCTAssertEqual(service.status.currentSource, "jsdelivr-mirror",
                       ".fallback mode → jsDelivr mirror immediately, no fetch")
        XCTAssertEqual(UpdateService.feedPolicy, .fallback)
    }

    // MARK: - UPD-1 (2026-07-24 audit): triggerProbe must not cancel itself

    /// UPD-1: triggerProbe() cancels `currentProbeTask?.cancel()` on the very
    /// Task that's running it. Both production call paths (init's startAfterFeedProbe
    /// and setPolicy) run triggerProbe INSIDE the Task stored in `currentProbeTask`,
    /// so the cancellation flag is set before the `await probeEngine.resolve(...)`
    /// at line 279 — meaning every URLSession fetch in production aborts with
    /// URLError(.cancelled) before it even goes out. The H1 mirror-fallback feature
    /// has been silently dead at runtime.
    ///
    /// This test reproduces the production call path through setPolicy and asserts
    /// that the stub sees an uncancelled Task at resolve time. Before the fix,
    /// the bug cancels the surrounding Task between line 275 and the await, so
    /// `Task.isCancelled` is true inside the resolve callback. After the fix, the
    /// Task is alive until completion.
    ///
    /// The StubProbeEngine itself doesn't simulate URLSession cooperative
    /// cancellation (resolve returns its queued decision regardless), but it CAN
    /// observe the surrounding Task's cancellation flag — that's the
    /// production-realistic surface this test pins.
    @MainActor
    func testTriggerProbeDoesNotCancelItself() async {
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        MockURLProtocol.stubResponses = [:]
        let stub = StubProbeEngine()
        await stub.setNextDecision(automaticPrimaryDecision)
        let service = UpdateService(probeEngine: stub, autoStart: false)

        let probeReached = expectation(description: "stub.resolve was reached")
        // Inverted: we EXPECT this NOT to be fulfilled — the surrounding Task
        // must still be alive when resolve is called.
        let sawSurroundingTaskCancelled = expectation(description: "Task was cancelled at resolve time")
        sawSurroundingTaskCancelled.isInverted = true

        await stub.setOnResolve { _ in
            probeReached.fulfill()
            if Task.isCancelled {
                sawSurroundingTaskCancelled.fulfill()
            }
        }
        service.setPolicy(.automatic)

        await fulfillment(of: [probeReached], timeout: 2)
        await fulfillment(of: [sawSurroundingTaskCancelled], timeout: 0.5)
    }

    // MARK: - Concurrency (Important #1 race)

    /// A slow startup probe must NOT overwrite a faster post-setPolicy probe.
    /// This regression test pins the generation-token + post-await check by
    /// making the first (slow) probe return a fallback decision AFTER the
    /// second (fast) probe has already written a primary decision.
    @MainActor
    func testSlowStartupProbeDoesNotOverwriteFasterUserChoice() async {
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        UpdateService.lastPrimaryItemDate = nil
        MockURLProtocol.stubResponses = [:]
        MockURLProtocol.stubError = nil
        let stub = StubProbeEngine()
        let primaryDecision = automaticPrimaryDecision
        let fallbackDecision = forcedFallbackDecision
        let service = UpdateService(probeEngine: stub, autoStart: false)

        // First probe: slow, returns fallback.
        await stub.enqueueDecision(fallbackDecision, delaySeconds: 0.5)
        // Second probe: fast, returns primary (user just chose primary).
        await stub.enqueueDecision(primaryDecision, delaySeconds: 0.0)

        // Simulate the startup probe firing alongside a fast user-driven
        // probe. We kick them off in order; the second awaits zero delay and
        // finishes first, then the first resumes and would normally clobber.
        async let firstProbe: Void = service.triggerProbe()
        try? await Task.sleep(nanoseconds: 50_000_000)
        async let secondProbe: Void = service.triggerProbe()
        _ = await (firstProbe, secondProbe)

        let calls = await stub.callCount
        XCTAssertEqual(calls, 2, "both probes must have completed")
        XCTAssertEqual(service.status.currentSource, "github-release",
                       "fast probe result (primary) must win; slow stale probe must be dropped")
    }

    // MARK: - Baseline monotonicity (Important #2)

    @MainActor
    func testBaselineWrittenFromPrimaryObservationOnly() async {
        // Important #2: probe returns primary metadata inline. A single
        // successful primary fetch must update the baseline, even though
        // no second URLSession fetch happens.
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        UpdateService.lastPrimaryItemDate = nil
        let stub = StubProbeEngine()
        let decisionWithPrimaryDate = FeedProbeDecision(
            chosenURL: URL(string: "https://example.com/primary.xml")!,
            usedChannelID: "primary",
            reason: .automaticReachable,
            primaryAppcastXML: sampleAppcast,
            primaryLatestDate: dateFromPubDateString("Sat, 18 Jul 2026 03:32:59 +0000")
        )
        await stub.setNextDecision(decisionWithPrimaryDate)
        let service = UpdateService(probeEngine: stub, autoStart: false)
        await service.triggerProbe()

        XCTAssertEqual(UpdateService.lastPrimaryItemDate,
                       decisionWithPrimaryDate.primaryLatestDate,
                       "baseline written from a single primary fetch — no second URLSession needed")
    }

    @MainActor
    func testBaselineMonotonicDoesNotRollBackOnOlderObservation() async {
        // Important #2: max(old, new) so an out-of-order response can never
        // lower the baseline.
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        let newer = dateFromPubDateString("Sat, 18 Jul 2026 12:00:00 +0000")
        let older = dateFromPubDateString("Sat, 18 Jul 2026 03:32:59 +0000")
        UpdateService.lastPrimaryItemDate = newer
        let stub = StubProbeEngine()
        let olderDecision = FeedProbeDecision(
            chosenURL: URL(string: "https://example.com/primary.xml")!,
            usedChannelID: "primary",
            reason: .automaticReachable,
            primaryAppcastXML: sampleAppcast,
            primaryLatestDate: older
        )
        await stub.setNextDecision(olderDecision)
        let service = UpdateService(probeEngine: stub, autoStart: false)
        await service.triggerProbe()

        XCTAssertEqual(UpdateService.lastPrimaryItemDate, newer,
                       "baseline must be max(old, new); older observation must not roll back")
    }

    // MARK: - UPD-3 (2026-07-24 review): switch recorded only on real channel changes

    /// UPD-3: every probe used to unconditionally overwrite
    /// lastSwitchReason/lastSwitchAt, so the status panel's "Last switch"
    /// showed the latest PROBE rather than the latest channel change. The
    /// reason + timestamp must be written only when `usedChannelID` differs
    /// from the current source.
    @MainActor
    func testSwitchReasonRecordedOnlyWhenChannelChanges() async {
        testDefaults.removeObject(forKey: "UpdateFeedPolicy")
        let stub = StubProbeEngine()
        let service = UpdateService(probeEngine: stub, autoStart: false)

        // Probe 1 keeps the initial channel (github-release) → not a switch.
        await stub.setNextDecision(automaticPrimaryDecision)
        await service.triggerProbe()
        XCTAssertEqual(service.status.currentSource, "github-release")
        XCTAssertNil(service.status.lastSwitchReason,
                     "re-probing the same channel must not record a switch")
        XCTAssertNil(service.status.lastSwitchAt)

        // Probe 2 changes the channel → recorded.
        await stub.setNextDecision(forcedFallbackDecision)
        await service.triggerProbe()
        XCTAssertEqual(service.status.currentSource, "jsdelivr-mirror")
        XCTAssertEqual(service.status.lastSwitchReason, ProbeReason.userForcedFallback.rawValue)
        let firstSwitchAt = service.status.lastSwitchAt
        XCTAssertNotNil(firstSwitchAt)

        // Probe 3 stays on the mirror with a different reason → NOT overwritten.
        let mirrorAgain = FeedProbeDecision(
            chosenURL: URL(string: "https://example.com/fallback.xml")!,
            usedChannelID: "jsdelivr-mirror",
            reason: .automaticPrimaryDown,
            primaryAppcastXML: nil,
            primaryLatestDate: nil
        )
        await stub.setNextDecision(mirrorAgain)
        try? await Task.sleep(nanoseconds: 20_000_000) // make a timestamp bump observable
        await service.triggerProbe()
        XCTAssertEqual(service.status.lastSwitchReason, ProbeReason.userForcedFallback.rawValue,
                       "same-channel probe must not overwrite the original switch reason")
        XCTAssertEqual(service.status.lastSwitchAt, firstSwitchAt,
                       "same-channel probe must not bump the switch timestamp")
    }

    // MARK: - UPD-3: status panel label mapping

    func testStatusPanelSourceLabelMapsKnownChannels() {
        XCTAssertEqual(UpdateStatusPanelView.sourceLabel("github-release"),
                       L10n.string("settings.updateSource.option.primary"))
        XCTAssertEqual(UpdateStatusPanelView.sourceLabel("jsdelivr-mirror"),
                       L10n.string("settings.updateSource.option.fallback"))
        XCTAssertEqual(UpdateStatusPanelView.sourceLabel("future-channel"), "future-channel",
                       "unknown channel ids fall back to the raw id")
    }

    func testStatusPanelReasonLabelLocalizesAllProbeReasons() {
        let allReasons: [ProbeReason] = [
            .automaticReachable, .automaticPrimaryDown, .bothDownKeepPrimary,
            .mirrorStaleRejected, .userForced, .userForcedFallback
        ]
        for reason in allReasons {
            let label = UpdateStatusPanelView.reasonLabel(reason.rawValue)
            XCTAssertNotEqual(label, reason.rawValue,
                              "\(reason) must render localized text, not the raw enum value")
            XCTAssertFalse(label.hasPrefix("settings.updateSource.reason."),
                           "\(reason)'s labelKey must resolve to translated text in the bundle")
        }
        XCTAssertEqual(UpdateStatusPanelView.reasonLabel(nil), "—")
        XCTAssertEqual(UpdateStatusPanelView.reasonLabel("bogus"), "—",
                       "unpersistable/garbage rawValues render the placeholder")
    }

    // MARK: - NEW-5 (2026-08-06 review): latestVersionString order-independence

    /// NEW-5: previously took the first `<sparkle:shortVersionString>`
    /// which assumed Sparkle's newest-first convention. The repo's
    /// `appcast.xml` is built ascending, so the first item was the
    /// OLDEST version (2.4.0) — v2.7.9's "Update" tab would show
    /// "latest: 2.4.0" instead of 2.7.9. The fix selects by max pubDate,
    /// which is order-independent.
    ///
    /// Right answer regardless of order: items at index 0 (oldest) and
    /// last (newest) differ. The function must return the version of the
    /// item with the latest pubDate.
    func testLatestVersionStringTakesItemWithLatestPubDate_ascendingOrder() {
        let xml = """
        <rss><channel>
            <item>
                <title>Version 2.4.0</title>
                <sparkle:shortVersionString>2.4.0</sparkle:shortVersionString>
                <pubDate>Sat, 01 Jul 2026 10:00:00 +0000</pubDate>
            </item>
            <item>
                <title>Version 2.7.9</title>
                <sparkle:shortVersionString>2.7.9</sparkle:shortVersionString>
                <pubDate>Wed, 05 Aug 2026 11:51:20 +0000</pubDate>
            </item>
            <item>
                <title>Version 2.5.0</title>
                <sparkle:shortVersionString>2.5.0</sparkle:shortVersionString>
                <pubDate>Mon, 15 Jul 2026 12:00:00 +0000</pubDate>
            </item>
        </channel></rss>
        """
        XCTAssertEqual(UpdateService.latestVersionString(inAppcastXML: xml), "2.7.9",
                       "NEW-5: ascending order with mid-list newer item must still match by pubDate")
    }

    /// NEW-5: same input re-ordered to newest-first (Sparkle's documented
    /// convention). Both orderings must produce the same answer — the
    /// function reads by pubDate, not by position.
    func testLatestVersionStringTakesItemWithLatestPubDate_descendingOrder() {
        let xml = """
        <rss><channel>
            <item>
                <title>Version 2.7.9</title>
                <sparkle:shortVersionString>2.7.9</sparkle:shortVersionString>
                <pubDate>Wed, 05 Aug 2026 11:51:20 +0000</pubDate>
            </item>
            <item>
                <title>Version 2.5.0</title>
                <sparkle:shortVersionString>2.5.0</sparkle:shortVersionString>
                <pubDate>Mon, 15 Jul 2026 12:00:00 +0000</pubDate>
            </item>
            <item>
                <title>Version 2.4.0</title>
                <sparkle:shortVersionString>2.4.0</sparkle:shortVersionString>
                <pubDate>Sat, 01 Jul 2026 10:00:00 +0000</pubDate>
            </item>
        </channel></rss>
        """
        XCTAssertEqual(UpdateService.latestVersionString(inAppcastXML: xml), "2.7.9")
    }

    /// NEW-5: regression — feed the actual on-disk appcast.xml and confirm
    /// we get 2.7.9 (the current tag). If this ever regresses to "2.4.0",
    /// the View tab will again show the wrong "latest".
    func testLatestVersionStringMatchesActualAppcast() {
        guard let url = Bundle(for: UpdateServiceTests.self).url(forResource: "appcast", withExtension: "xml"),
              let xml = try? String(contentsOf: url, encoding: .utf8) else {
            // appcast not bundled (test-only fixture); skip silently. The
            // two synthesized tests above still cover the order-independence
            // contract.
            return
        }
        XCTAssertEqual(UpdateService.latestVersionString(inAppcastXML: xml), "2.7.9",
                       "NEW-5: the live appcast.xml must report 2.7.9 as the latest version")
    }

    // MARK: - NEW-7 (2026-08-06 review): fallback binding is order-independent

    /// NEW-7: with the standard channel layout (primary, jsDelivr, Gitee),
    /// `resolve(.fallback)` must pick jsDelivr — explicit id binding, not
    /// array index. The previous kind-based binding would also pick jsDelivr
    /// only because of where it sat in the array.
    func testFallbackResolutionPicksJsdelivrNotGitee() async {
        let engine = DefaultFeedProbeEngine()
        let decision = await engine.resolve(
            policy: .fallback, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel, giteeChannel]
        )
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url,
                       "NEW-7: .fallback must resolve to the jsDelivr channel by id")
        XCTAssertEqual(decision?.usedChannelID, "jsdelivr-mirror")
    }

    /// NEW-7: the .automatic policy picks jsDelivr when primary is
    /// unreachable. If anyone reorders the jsDelivr channel to last,
    /// automatic fallback must STILL pick jsDelivr by id (not by kind+order).
    /// We stub primary to fail and stub jsDelivr to succeed; the engine
    /// must surface the jsDelivr decision, not `bothDownKeepPrimary`.
    func testAutomaticFallbackPicksJsdelivrWhenPrimaryDown() async {
        MockURLProtocol.stubError = nil
        // Only stub a known URL to fail; the fallback URL succeeds.
        MockURLProtocol.stubResponses[primaryChannel.url] = (503, "", nil)
        MockURLProtocol.stubResponses[fallbackChannel.url] = (200, "<rss><channel></channel></rss>", nil)
        let engine = DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
        let decision = await engine.resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel, giteeChannel]
        )
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url,
                       "NEW-7: when primary is down, .automatic must fall back to jsDelivr by id")
        XCTAssertEqual(decision?.usedChannelID, "jsdelivr-mirror")
    }

    /// NEW-7: simulate the order-reversed layout that the OLD kind-based
    /// binding would have silently broken. The new id-based binding
    /// survives.
    func testFallbackResolutionOrderIndependent() async {
        // Channels in REVERSE order: Gitee first, jsDelivr second.
        let channels = [giteeChannel, fallbackChannel, primaryChannel]
        let engine = DefaultFeedProbeEngine()
        let decision = await engine.resolve(
            policy: .fallback, lastKnownDate: nil,
            channels: channels
        )
        XCTAssertEqual(decision?.chosenURL, fallbackChannel.url,
                       "NEW-7: .fallback must still resolve to jsDelivr even with channels reordered")
    }
}

// MARK: - StubProbeEngine (file scope; outside UpdateServiceTests class)

/// Deterministic `FeedProbeEngine` for UpdateService orchestration tests.
/// Records each call, supports configurable decisions + delays, and fires
/// an onResolve callback so XCTest expectations can await completion without
/// wall-clock sleeps.
actor StubProbeEngine: FeedProbeEngine {
    private struct PendingDecision {
        let decision: FeedProbeDecision
        let delaySeconds: TimeInterval
    }
    private var queue: [PendingDecision] = []
    private(set) var callCount: Int = 0
    private var onResolve: ((UpdateFeedPolicy) -> Void)?

    func setNextDecision(_ decision: FeedProbeDecision) {
        queue.append(PendingDecision(decision: decision, delaySeconds: 0))
    }

    func enqueueDecision(_ decision: FeedProbeDecision, delaySeconds: TimeInterval) {
        queue.append(PendingDecision(decision: decision, delaySeconds: delaySeconds))
    }

    func setOnResolve(_ callback: ((UpdateFeedPolicy) -> Void)?) {
        onResolve = callback
    }

    func resolve(
        policy: UpdateFeedPolicy,
        lastKnownDate: Date?,
        channels: [FeedChannel],
        timeout: TimeInterval?
    ) async -> FeedProbeDecision? {
        callCount += 1
        let next = queue.isEmpty ? nil : queue.removeFirst()
        if let next {
            if next.delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(next.delaySeconds * 1_000_000_000))
            }
            onResolve?(policy)
            return next.decision
        }
        onResolve?(policy)
        return nil
    }
}

// MARK: - Decision fixtures + helpers (file scope)

let automaticPrimaryDecision = FeedProbeDecision(
    chosenURL: URL(string: "https://example.com/primary.xml")!,
    usedChannelID: "github-release",
    reason: .automaticReachable,
    primaryAppcastXML: nil,
    primaryLatestDate: nil
)

let forcedFallbackDecision = FeedProbeDecision(
    chosenURL: URL(string: "https://example.com/fallback.xml")!,
    usedChannelID: "jsdelivr-mirror",
    reason: .userForcedFallback,
    primaryAppcastXML: nil,
    primaryLatestDate: nil
)

func dateFromPubDateString(_ raw: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return formatter.date(from: raw)!
}

// MARK: - MockURLProtocol test helper (file scope, outside UpdateServiceTests class)

/// Test stub: feeds canned responses based on URL → (status, body) map.
/// Tests register an instance via `URLSessionConfiguration.protocolClasses`.
final class MockURLProtocol: URLProtocol {
    static var stubResponses: [URL: (status: Int, body: String, delay: TimeInterval?)] = [:]
    static var stubError: Error?
    /// Number of requests that reached `startLoading`. Tests that expect
    /// the engine to short-circuit (e.g. user-forced Gitee) assert this
    /// stays at 0; otherwise a stray probe would crash via `stubError`
    /// rather than fail the test with a clear message.
    static var requestCount: Int = 0

    override static func canInit(with request: URLRequest) -> Bool {
        stubError != nil || stubResponses.keys.contains(request.url!)
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requestCount += 1
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
