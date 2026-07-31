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

    // MARK: - Service orchestration (spec §5 tests 10-11)

    @MainActor
    func testSetPolicyTriggersProbeAndStatusUpdate() async {
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
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
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
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
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
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
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
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
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
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
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
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
        UserDefaults.standard.removeObject(forKey: "UpdateFeedPolicy")
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

    override static func canInit(with request: URLRequest) -> Bool {
        stubError != nil || stubResponses.keys.contains(request.url!)
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
