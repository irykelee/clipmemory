import XCTest
@testable import ClipMemory

/// ID-REVIEW-1049 (2026-11-01): the **production canary's preconditions** and
/// the **audit** that proves the canaries actually ran.
///
/// ## Why this file exists
///
/// The three production canaries (`testNoProductionPollution` /
/// `testProductionDataBlobsAreUnchanged` /
/// `testFirstLaunchFlagIsNeverChangedDuringTheSuite`) are the **only** thing
/// that catches "a test wrote the user's production domain".
///
/// ⇒ A canary that is **skipped** is not a **failure** ⇒ the suite stays
/// green while the safety net is off. That is the worst possible state for a
/// safety net: **it looks armed**.
///
/// ⇒ The previous round shipped exactly that: the skip condition was
/// **inverted** (`XCTSkipUnless(!bootstrapRan)`) ⇒ the canaries were off in
/// **every** full run — the only place they protect anything — and the suite
/// was green. Caught by the full-suite `skipped` count (4 → 7).
///
/// ⇒ ⇒ *「跳过」不是「失败」* ⇒ every safety check that can be skipped needs
/// an **independent** proof that it **executed**.
/// ⇒ ⇒ *ID-REVIEW-1042 的「验证工具本身不能成为它要消灭的那种伤害源」，
/// 在「跳过」这一侧的对偶命题是：「验证工具必须能发现**它自己没跑**」。*
///
/// ## The three signals — and why **two** flags are not enough
///
/// | 信号 | 性质 | 谁能删掉它 |
/// |---|---|---|
/// | `aaaBootstrapRan` | **声明**：观察者看到 AAA 类跑完 | 删 observer 里那一行 |
/// | `didSnapshotProductionDomain` | **声明**：引导类说自己拍过基线 | 删引导类里那一行 |
/// | `productionPersistentDomainBefore` | **证据**：快照本身 | 得删掉整个快照 |
///
/// ⚠️ **独立核验员 P2-2**：两个**声明**一起删 ⇒ 三个 canary 跳过 ⇒ 审计也跳过
/// ⇒ 套件全绿，而安全网是关的（核验员自测 V4 = SURVIVED）。
/// ⇒ ⇒ **两个能一起删的标志 = 一个标志**。
///
/// ⇒ 修法（两条一起上）：
/// ① **canary 的武装条件改看「证据」**（快照非空）而不是看「声明」⇒
///    删掉声明**关不掉** canary；
/// ② **审计做三方交叉核对** ⇒ 「有证据却没人声明」判成红。
enum ProductionCanaryGuard {

    /// Why a production canary did **not** execute its comparison.
    ///
    /// ⇒ 每一个跳过都必须**带理由**上报 ⇒ 否则「合法跳过」与「被解除武装」
    /// 在报告里长得一模一样（这正是本族要消灭的形状）。
    enum SkipReason: String, Equatable {
        /// 另一个 ClipMemory 实例在跑 ⇒ 生产域的「前后对比」无法归因。
        case anotherInstanceRunning
        /// 这个进程里**没有**基线（窄跑没带 AAA 引导）⇒ 无从对比。
        case baselineNotCaptured
    }

    /// How many of the three production canaries **started** in this process.
    ///
    /// ⇒ Counted **before** any skip decision: a "started but skipped" canary
    /// and a "never reached" canary are different states, and the audit has to
    /// tell them apart.
    private static var startedCount = 0

    /// How many of the three production canaries **executed** their comparison
    /// in this process.
    ///
    /// ⇒ The increment sits **after** the skip guards on purpose: a `defer`
    /// would also run when `XCTSkip` throws ⇒ a **skipped** canary would still
    /// be counted ⇒ the audit could not tell "ran" from "was disarmed".
    private static var executedCount = 0

    /// Why each production canary skipped — one entry per skipped canary.
    private static var skipReasons: [SkipReason] = []

    /// Records that one production canary started (before any skip decision).
    static func recordStart() {
        startedCount += 1
    }

    /// Records that one production canary actually ran its comparison.
    static func recordExecution() {
        executedCount += 1
    }

    /// Records that one production canary skipped because of `reason`.
    ///
    /// ⚠️ **Only** called from inside the branch guarded by the **same live
    /// condition** that causes the skip ⇒ ⇒ if somebody inverts the skip
    /// condition, the canary skips **without** a reason ⇒ the audit's
    /// accounting fails (red) instead of the net going quietly quiet.
    static func recordSkip(_ reason: SkipReason) {
        skipReasons.append(reason)
    }

    /// The number of production canaries that started (read-only view).
    static var productionCanariesStarted: Int { startedCount }

    /// The number of production canaries that executed (read-only view).
    static var productionCanariesExecuted: Int { executedCount }

    /// The reasons the production canaries skipped (read-only view).
    static var productionCanarySkipReasons: [SkipReason] { skipReasons }

    /// Skip when **another** ClipMemory instance is running.
    ///
    /// ID-REVIEW-1030 (2026-10-25): the production-domain **content** comparison
    /// can only be trusted when no other ClipMemory instance is running.
    ///
    /// The comparison is "before vs after the whole suite" — it sees *that* the
    /// production domain changed, never *who* changed it. When the real app is
    /// running it rewrites its own `ClipboardItems` blob on every save, and
    /// because AES-GCM uses a fresh nonce per save, even an identical-item
    /// re-save changes the bytes while keeping the length. The guard then
    /// reports "the production data blob was rewritten" for a test run that
    /// never touched production.
    ///
    /// Measured 2026-10-25 on this machine: the real app's CoreSpotlight
    /// re-index bursts line up exactly with the blob's byte change during the
    /// suite; the suite is green on CI (no app runs there) and green locally
    /// while the app is closed.
    ///
    /// The test host deliberately never takes the single-instance lock (see
    /// `SingleInstanceLock`), so a held lock means a real instance is running
    /// ⇒ the comparison is unattributable ⇒ skip it **visibly** instead of
    /// failing on somebody else's write. The seam guards
    /// (`TestIsolation.mustRefuseProductionDataMutation`) and the byte-level
    /// comparison still apply whenever the lock is free — which is the case
    /// on CI.
    ///
    /// ⚠️ ID-REVIEW-1049 (independent verifier P2-1): the skip must **report
    /// its reason** ⇒ otherwise "legitimately skipped" and "disarmed" look the
    /// same in the report — which is the exact shape this file exists to kill.
    static func skipIfAnotherInstanceIsRunning() throws {
        guard SingleInstanceLock.isHeldByAnotherProcess() else { return }
        ProductionCanaryGuard.recordSkip(.anotherInstanceRunning)
        // ⚠️ `throw XCTSkip(…)` — **not** `try XCTSkip(…)`: in Swift, `XCTSkip(…)`
        // is the **overlay's `Error` struct initializer**
        // (`public struct XCTSkip: Swift::Error`) ⇒ it **constructs a value** and
        // **throws nothing** ⇒ `try XCTSkip(…)` is a discarded value ⇒ the
        // canary carries on and *passes* after "skipping" (measured
        // 2026-11-01: the lock probe made the canaries record a skip AND
        // execute ⇒ 3 + 3 = 6). ⇒ **only** `throw XCTSkip(…)` really skips.
        throw XCTSkip(
            "another ClipMemory instance is running (.instance.lock is held) — it "
            + "legitimately rewrites its own production data, which this process "
            + "cannot attribute; skipping the production-domain content "
            + "comparison (on CI no instance runs, so the check still executes)"
        )
    }

    /// Skip unless the **production baseline** was captured.
    ///
    /// ⚠️ ID-REVIEW-1047 (2026-10-28, independent verifier): the production
    /// comparison is only meaningful when the "before" snapshot EXISTS.
    ///
    /// ⇒ `AAASuiteBootstrapTests` takes that snapshot. In a **narrow run**
    /// (`-only-testing:`) that class never runs ⇒ `before` is EMPTY ⇒
    /// **every** production key looks "ADDED" ⇒ the two data blobs
    /// (deliberately NOT in any allowlist since ID-REVIEW-1038) make the
    /// canary **fail unconditionally**.
    ///
    /// ⇒ That artifact is not harmless: it was observed as a **false
    /// catch** — a mutation harness that ran only the canary class reported
    /// "the canary caught it" while the canary was in fact failing on
    /// *every* key, including keys the mutation never touched ⇒ a mutation
    /// was credited to the canary that the canary would have flagged anyway.
    ///
    /// ⇒ Skip explicitly (visible in the report) rather than fail red.
    ///
    /// ⚠️ One helper for all three canaries (ID-REVIEW-1047 round 2) — the
    /// third copy used to be inlined and pushed `testNoProductionPollution`'s
    /// body past SwiftLint's `function_body_length` (54 > 50) ⇒ a **new**
    /// lint warning, i.e. a regression this round introduced.
    ///
    /// ⚠️ ID-REVIEW-1049 (independent verifier M5 + P2-2): the skip is tied to
    /// the **evidence** (`hasProductionBaseline`), NOT to a claim — deleting
    /// the claims must not disarm the canaries.
    static func skipUnlessProductionBaselineCaptured() throws {
        // ⚠️ ID-REVIEW-1049 (independent verifier M5): the skip is legitimate
        // ONLY when the AAA bootstrap **never ran** (a narrow `-only-testing:`
        // run) — and "the AAA class ran" is an **independent** signal.
        let bootstrapRan = XCTestIsolationSuiteBootstrap.aaaBootstrapRan
        if bootstrapRan {
            XCTAssertTrue(
                AAASuiteBootstrapTests.didSnapshotProductionDomain,
                "ID-REVIEW-1049: the AAA bootstrap RAN but did not capture the "
                + "production baseline — that is a **BUG in the bootstrap**, not a "
                + "narrow run. (Independent verifier M5: deleting the one line "
                + "that sets the flag silently disarmed all three production "
                + "canaries.)"
            )
        }
        // ⚠️ ID-REVIEW-1049 (independent verifier P2-2): the arming condition
        // reads the **evidence** (the snapshot itself), not a claim ⇒ deleting
        // both claims (the verifier's V4) can no longer disarm the canaries.
        guard !AAASuiteBootstrapTests.hasProductionBaseline else { return }
        ProductionCanaryGuard.recordSkip(.baselineNotCaptured)
        // ⚠️ `throw XCTSkip(…)`, not `try XCTSkip(…)` — see the note in
        // `skipIfAnotherInstanceIsRunning`.
        throw XCTSkip(
            "production baseline not captured — the AAA suite bootstrap did not run "
            + "in this process (a narrow `-only-testing:` run has no baseline ⇒ "
            + "every production key would look ADDED ⇒ the comparison is meaningless)"
        )
    }
}

/// ID-REVIEW-1049 (2026-11-01): the **audit** of the three production canaries.
///
/// ⇒ A canary that is **skipped** is not a **failure** ⇒ the suite stays green
/// while the production-domain safety net is off.
/// ⇒ ⇒ This test asserts the canaries are all **accounted for**: each one
/// either executed its comparison, or skipped for a reason that is
/// **independently verifiable right now**.
///
/// ⚠️ The class name must sort **after** `ZZZSuiteTeardownTests` — XCTest
/// enumerates test classes alphabetically — hence the `ZZZThe…` name.
final class ZZZTheCanariesWereNotDisarmedTests: XCTestCase {

    /// The three independent signals about the production baseline.
    private struct BaselineSignals {
        /// **声明 ①**：the observer saw the AAA class finish.
        let bootstrapClassRan: Bool
        /// **声明 ②**：the bootstrap says it captured a baseline.
        let baselineClaimed: Bool
        /// **证据**：the snapshot dictionary itself is not empty.
        let evidenceExists: Bool
    }

    /// Reads the three signals (no flag of its own — read-only).
    private static func baselineSignals() -> BaselineSignals {
        BaselineSignals(
            bootstrapClassRan: XCTestIsolationSuiteBootstrap.aaaBootstrapRan,
            baselineClaimed: AAASuiteBootstrapTests.didSnapshotProductionDomain,
            evidenceExists: !AAASuiteBootstrapTests.productionPersistentDomainBefore.isEmpty
        )
    }

    func testTheProductionCanariesWereNotDisarmed() throws {
        let started = ProductionCanaryGuard.productionCanariesStarted
        let executed = ProductionCanaryGuard.productionCanariesExecuted
        let skips = ProductionCanaryGuard.productionCanarySkipReasons

        // ⚠️ Nothing happened at all ⇒ the canary class did not run in this
        // process (a narrow `-only-testing:` run that does not include it)
        // ⇒ there is nothing to audit ⇒ skip **visibly**.
        if started == 0 && executed == 0 && skips.isEmpty {
            // ⚠️ `throw XCTSkip(…)`, not `try XCTSkip(…)` — see the note in
            // `ProductionCanaryGuard.skipIfAnotherInstanceIsRunning`.
            throw XCTSkip(
                "the production canary class did not run in this process "
                + "(a narrow `-only-testing:` run that does not include "
                + "`ZZZSuiteTeardownTests` has no canaries to audit)"
            )
        }

        assertBaselineSignalsAgree()
        assertEveryCanaryIsAccountedFor(started: started, executed: executed, skipped: skips.count)
        assertEverySkipReasonIsVerifiableNow(skips)
    }

    /// ⚠️ ID-REVIEW-1049 (independent verifier P2-2): the three signals must
    /// **agree**.
    ///
    /// ⇒ V4 deleted both claims in one step ⇒ the canaries skipped, the audit
    /// skipped, the suite stayed green ⇒ two flags that can be deleted
    /// together are **one** flag.
    ///
    /// ⇒ The cross-check that kills it: the **evidence** (the snapshot) is
    /// still there while **nobody** claims it ⇒ the canaries would skip for a
    /// reason that is not true ⇒ red.
    private func assertBaselineSignalsAgree() {
        let signals = Self.baselineSignals()
        XCTAssertFalse(
            signals.bootstrapClassRan && !signals.baselineClaimed,
            "ID-REVIEW-1049: the observer saw `AAASuiteBootstrapTests` run, but the "
            + "bootstrap says it captured NO baseline ⇒ that is a **BUG in the "
            + "bootstrap**, not a narrow run."
        )
        XCTAssertFalse(
            !signals.bootstrapClassRan && signals.baselineClaimed,
            "ID-REVIEW-1049: the bootstrap captured a baseline, but the observer "
            + "never recorded that the AAA class ran ⇒ the two independent signals "
            + "disagree ⇒ one of them was tampered with."
        )
        XCTAssertFalse(
            !signals.bootstrapClassRan && !signals.baselineClaimed && signals.evidenceExists,
            "ID-REVIEW-1049: the production baseline **snapshot exists** (the "
            + "evidence) but **neither** signal claims it ⇒ the canaries would skip "
            + "and this audit would skip ⇒ the safety net would be off while the "
            + "suite stayed green. (Independent verifier P2-2: deleting both flags "
            + "in one step kept the suite green.)"
        )
    }

    /// Every canary must be **accounted for**: started, and either executed or
    /// skipped **with a recorded reason**.
    private func assertEveryCanaryIsAccountedFor(
        started: Int, executed: Int, skipped: Int
    ) {
        XCTAssertEqual(
            started, 3,
            "ID-REVIEW-1049: expected 3 production canaries to START, got \(started) "
            + "⇒ at least one canary body was removed or never reached its bookkeeping."
        )
        XCTAssertEqual(
            executed + skipped, 3,
            "ID-REVIEW-1049: the three production canaries are not all accounted for: "
            + "\(executed) executed + \(skipped) skipped ≠ 3 ⇒ a canary was silently "
            + "disarmed (a skip WITHOUT a recorded reason does not count)."
        )
    }

    /// Every recorded skip reason must be **independently verifiable now**.
    ///
    /// ⇒ A reason that is not true ⇒ the canary was silenced ⇒ red.
    ///
    /// ⚠️ The lock check re-reads the live lock: if the user's app quits in
    /// the millisecond between the canaries and this audit, this turns red
    /// (a visible, re-runnable failure — the documented cost of not trusting
    /// a reason it cannot re-check).
    private func assertEverySkipReasonIsVerifiableNow(
        _ skips: [ProductionCanaryGuard.SkipReason]
    ) {
        for reason in skips {
            switch reason {
            case .anotherInstanceRunning:
                XCTAssertTrue(
                    SingleInstanceLock.isHeldByAnotherProcess(),
                    "ID-REVIEW-1049: a canary claimed it skipped because another "
                    + "ClipMemory instance is running — but no instance holds the lock "
                    + "NOW ⇒ the reason is not true ⇒ the canary was silently disarmed."
                )
            case .baselineNotCaptured:
                // ⚠️ ID-REVIEW-1049 第三轮 (2026-11-01, independent verifier P2-1):
                // this re-check used to read `hasProductionBaseline` — **the
                // same expression** as the skip gate ⇒ **tautological** ⇒
                // neutering that one helper would make the canaries skip
                // AND the re-check agree ⇒ the net goes off silently.
                //
                // ⇒ ⇒ Verify against the **raw facts** instead: the bootstrap's
                // claim, and the snapshot itself. (The coordinated 3-line
                // deletion — capture + both claims — still cannot be caught
                // from inside the tree ⇒ that is what the **out-of-band**
                // check `Scripts/verify-production-canaries.py` is for.)
                XCTAssertFalse(
                    AAASuiteBootstrapTests.didSnapshotProductionDomain,
                    "ID-REVIEW-1049 第三轮: a canary claimed it skipped because no production "
                    + "baseline exists — but the bootstrap says it DID capture one ⇒ "
                    + "the reason is not true ⇒ the canary was silently disarmed."
                )
                XCTAssertTrue(
                    AAASuiteBootstrapTests.productionPersistentDomainBefore.isEmpty,
                    "ID-REVIEW-1049 第三轮: a canary claimed it skipped because no production "
                    + "baseline exists — but the production snapshot EXISTS ⇒ "
                    + "the reason is not true ⇒ the canary was silently disarmed."
                )
            }
        }
    }
}
