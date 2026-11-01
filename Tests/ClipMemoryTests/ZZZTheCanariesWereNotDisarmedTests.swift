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
/// ## The two flags cover each other
///
/// | 被删的东西 | 谁变红 |
/// |---|---|
/// | observer 里的 `aaaBootstrapRan = true` | **本审计**（基线标志仍在 ⇒ 审计不 skip ⇒ 计数器 ≠ 3 ⇒ 红） |
/// | bootstrap 里的 `didSnapshotProductionDomain = true` | **canary 自己**的 `XCTAssertTrue` |
///
/// ⇒ **任何一个标志都不能被单独删掉** ⇒ 这正是 M5 那条教训的结构性落地。
enum ProductionCanaryGuard {

    /// How many of the three production canaries **executed** their comparison
    /// in this process.
    ///
    /// ⇒ The increment sits **after** the skip guards on purpose: a `defer`
    /// would also run when `XCTSkip` throws ⇒ a **skipped** canary would still
    /// be counted ⇒ the audit could not tell "ran" from "was disarmed".
    private static var executedCount = 0

    /// Records that one production canary actually ran its comparison.
    static func recordExecution() {
        executedCount += 1
    }

    /// The number of production canaries that executed (read-only view).
    static var productionCanariesExecuted: Int { executedCount }

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
static func skipIfAnotherInstanceIsRunning() throws {
    try XCTSkipIf(
        SingleInstanceLock.isHeldByAnotherProcess(),
        "another ClipMemory instance is running (.instance.lock is held) — it "
        + "legitimately rewrites its own production data, which this process "
        + "cannot attribute; skipping the production-domain content "
        + "comparison (on CI no instance runs, so the check still executes)"
    )
}

/// Skip unless the **AAA bootstrap** captured the production baseline.
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
static func skipUnlessProductionBaselineCaptured() throws {
    // ⚠️ ID-REVIEW-1049 (2026-10-28, independent verifier M5): the skip is
    // legitimate ONLY when the AAA bootstrap **never ran** (a narrow
    // `-only-testing:` run).
    //
    // ⇒ The old condition was "the baseline flag is false" — and that flag
    // is set **by** the bootstrap ⇒ **deleting that one line silently
    // disarmed all three production canaries** and the suite stayed green
    // (the verifier's M5 survived).
    //
    // ⇒ The skip is now tied to an **independent** signal ("did the AAA
    // class actually run?") ⇒ the two can no longer be removed together.
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
    // ⚠️ ID-REVIEW-1049 (2026-11-01): the condition was **INVERTED** in the
    // previous round ⇒ `XCTSkipUnless(!bootstrapRan)` skipped exactly when
    // the bootstrap HAD run ⇒ the three production canaries were **always
    // off** in a full run. See `ProductionCanaryGuard` (and ledger §50.7).
    try XCTSkipUnless(
        bootstrapRan,
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
/// ⇒ ⇒ This test asserts the canaries **actually executed** whenever a
/// production baseline exists — i.e. a disarm is now a **red** test.
///
/// ⚠️ The class name must sort **after** `ZZZSuiteTeardownTests` — XCTest
/// enumerates test classes alphabetically — hence the `ZZZThe…` name.
final class ZZZTheCanariesWereNotDisarmedTests: XCTestCase {
    func testTheProductionCanariesWereNotDisarmed() throws {
        // ⚠️ The condition is the **baseline flag**, NOT `aaaBootstrapRan` —
        // deliberately, so the two flags cover each other (see the table in
        // `ProductionCanaryGuard`'s doc comment). If the audit used
        // `aaaBootstrapRan`, deleting the observer's assignment would disarm
        // the canaries AND the audit together ⇒ the mutation would survive.
        try XCTSkipUnless(
            AAASuiteBootstrapTests.didSnapshotProductionDomain,
            "no production baseline was captured in this process (a narrow run "
            + "has no baseline ⇒ there is nothing for the canaries to compare "
            + "against ⇒ the audit does not apply)"
        )
        XCTAssertEqual(
            ProductionCanaryGuard.productionCanariesExecuted, 3,
            "ID-REVIEW-1049: the three production canaries did NOT all execute "
            + "even though a production baseline exists ⇒ the production-domain "
            + "safety net is DISARMED and the suite would still be green. "
            + "(The previous round shipped exactly this: the skip condition was "
            + "inverted ⇒ the canaries were off in every full run.)"
        )
    }
}
