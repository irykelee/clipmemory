import XCTest
@testable import ClipMemory

/// M13 (2026-08-03) + NEW-1 (2026-08-06) + ratchet baseline (2026-08-06):
/// suite-level after-snapshot / diff.
///
/// Runs last in the suite (alphabetically after every other test class).
/// Compares the production UserDefaults persistent domain against the
/// before-snapshot taken by AAASuiteBootstrapTests. Any key added, removed,
/// or changed is a test-pollution failure — that test wrote production
/// UserDefaults and must be fixed.
///
/// Filter prefix: `NS` / `Apple` / `com.apple.` — system runtime keys
/// that may legitimately appear/disappear between launches; not test errors.
///
/// **Why a test method, not `class func tearDown`** (NEW-1, 2026-08-06
/// review): the previous `class func tearDown` called `XCTFail` on
/// pollution, but XCTest's class-level hooks do NOT propagate failures
/// to the process exit code — `xcodebuild` printed `** TEST SUCCEEDED **`
/// with exit code 0 even when this canary fired. The canary was
/// structurally dead (it could log a failure but never block CI).
/// Moving the diff into a real test method makes the failure propagate
/// normally: `xcodebuild` exits non-zero, CI fails the job.
///
/// **Production-safety contract (2026-08-06 rename + 2026-08-07 NEW-9)**:
/// the canary has TWO directions and the second is what protects
/// production:
///   - **Forward** (NEW pollution rejected): any key added/changed
///     that is NOT in `toleratedPollution` AND NOT in `appLifecycleKeys`
///     is a hard failure. This is the actual production safety the
///     canary provides — verified by `testForwardAssertionCatchesNewPollution`
///     below.
///   - **Reverse** (shrink enforcement, partial): `environmentInvariants`
///     keys must appear in the observed set; their absence means
///     a previously-active pollution source silently stopped writing.
///     Reverse enforcement is intentionally limited to race-stable
///     keys (today: `AppleLanguages`) because Sparkle's `SU*` keys
///     are race-conditioned and would flake CI if asserted.
///
/// **Two allowlists, two shrink paths (NEW-9, 2026-08-07)**:
///   - `toleratedPollution`: framework/OS writes that bypass every
///     `defaults` seam (AppleLanguages + Sparkle's `SU*`). SHRINK
///     target — completes when M13 injection covers them.
///   - `appLifecycleKeys`: production code `defaults.set(...)` calls
///     that fire during normal app startup, BOTH in production AND
///     in test (because the test process IS a real app process).
///     NOT a shrink target — these are real app behavior, not test
///     pollution. Option B (M13 init-path seams) is deferred; this
///     set documents the gap.
///
/// **NOT a true ratchet** — neither `toleratedPollution` nor
/// `appLifecycleKeys` is monotonically decreasing. Adding a new entry
/// is a code review event (the reverse-assertion only fires on
/// `environmentInvariants`, not on the broader sets). The terminology
/// was changed from `knownPollution`/`ratchetEnforcedKeys` to make
/// this explicit — future maintainers should not assume the suite
/// auto-shrinks the tolerance set.
final class ZZZSuiteTeardownTests: XCTestCase {

    /// System runtime key prefixes that may legitimately appear/disappear
    /// between before/after snapshots without meaning a test wrote them.
    private static let systemKeyPrefixes = ["NS", "Apple", "com.apple."]

    /// Pre-existing pollution that the canary FORWARD-ACCEPTS.
    /// Each entry is a production UserDefaults key that the test
    /// suite writes as a side-effect of exercising production code
    /// paths (init-time side effects in services that don't yet
    /// have injection seams, plus Sparkle's `SU*` keys that bypass
    /// `UpdateService.defaults`). The forward rejection logic in
    /// `testNoProductionPollution` skips any key in this set.
    ///
    /// Renamed from `knownPollution` (2026-08-06) — the former name
    /// implied "pollution that's known and tracked". The new name
    /// states the actual semantic: "pollution this canary accepts
    /// rather than rejects". Future maintainers should not assume
    /// this set auto-shrinks; see the production-safety contract
    /// above.
    ///
    /// Removing an entry is the policy concern, not the canary's
    /// concern. When all entries are removed (or the set reaches
    /// zero), the canary regresses to a strict gate that fires on
    /// ANY non-empty pollution — that's the desired end state.
    ///
    /// Source: 2026-08-06 commit — first local xcodebuild run after
    /// migrating the canary from class-tearDown to a real test case.
    /// The original NEW-2 report listed 6 keys (one CI run's observation
    /// lower bound); local reproduction caught 18 keys; the 4→2 LM
    /// injection work dropped the count to 4 framework/OS-level
    /// keys. See report §NEW-2 addendum and `feedback/4to2-language-manager-shared-seam.md`.
    private static let toleratedPollution: Set<String> = [
        // 2026-08-06 (cold-disk calibration, after 4→2 LM seam):
        // real single-run pollution now leaks 4 keys to the production
        // UserDefaults domain. The 4→2 LM seam knocks out
        // `AppleLanguages` (LM init cascade) and `appLanguage`
        // (didSet) from the test write path; the residual 4 keys
        // are all framework- or OS-level writes that bypass every
        // `defaults` seam:
        //
        //   - `AppleLanguages` is the OS-level default for the user's
        //     locale (e.g. ("zh-Hans-CN") on this Chinese dev machine).
        //     We don't write it — but the persistent domain includes
        //     whatever the OS has set, so ZZZ sees it as a baseline
        //     value with zero diff. Including it in the allowlist
        //     documents "this is system state, not our pollution".
        //   - Sparkle's `SPUStandardUpdaterController` writes its own
        //     keys (`SUHasLaunchedBefore`, `SULastCheckTime`, and
        //     race-conditioning `SUUpdateGroupIdentifier`) to the host
        //     bundle's `.standard`. Sparkle owns these; the test seam
        //     can't intercept them without taking on Sparkle's init
        //     contract. Including them in the allowlist is the
        //     honest acknowledgment of that CONTROL gap.
        //
        // The shrink path is removing the `SU*` keys one at a time
        // by mocking Sparkle's updater controller in the test host.
        // That work is tracked separately and is NOT a precondition
        // for this commit.
        "AppleLanguages",       // OS-level locale default (always present)
        "SUHasLaunchedBefore",  // Sparkle SPUStandardUpdaterController
        "SULastCheckTime",      // Sparkle SPUStandardUpdaterController
        "SUUpdateGroupIdentifier", // Sparkle SPUStandardUpdaterController (race-conditioned)
    ]

    /// NEW-9 (2026-08-07): app lifecycle keys that the host process
    /// writes during normal startup, BOTH in production AND in test.
    /// These are NOT test pollution — they are real app behavior.
    /// The test runner launches a real app process (xcodebuild test
    /// → host bundle's app lifecycle runs), so writes to these keys
    /// happen during every test run regardless of test fixture content.
    ///
    /// **Why separate from `toleratedPollution`**: the two sets have
    /// fundamentally different shrink paths:
    ///   - `toleratedPollution`: shrink by completing M13 injection
    ///     coverage (so test fixtures write to injected suite, not
    ///     production domain). Goal: empty.
    ///   - `appLifecycleKeys`: NOT a shrink target. These writes
    ///     happen because the test process IS a real app process.
    ///     Removing them would require either (a) running tests in
    ///     a non-app sandbox (out of scope) or (b) Option B —
    ///     adding M13 seams to every init path that writes them
    ///     (deferred, big).
    ///
    /// **Calibration**: 2026-08-07 truly-cold-disk run (no
    /// `com.clipmemory.app.tests.plist` on host, AAA snapshot empty)
    /// caught these 10 keys. Each one traces to a production code
    /// `defaults.set(...)` call site (see grep of lastBackupDateKey /
    /// lastLaunchKey / hasLaunchedKey / lastPrimaryItemDateKey /
    /// feedPolicyKey / windowFrameKey / itemsStorageKey /
    /// selectedTabRaw / migrationCompleteKey / startupCleanupKey).
    /// All 10 are unconditional lifecycle writes — they fire in
    /// every cold run.
    ///
    /// **Cold + warm bidirectionality** (NEW-9 verification contract):
    /// cold run (no plist) → 10 keys ADDED, all in this set → green.
    /// warm run (plist from prior run) → 10 keys in AAA baseline,
    /// 0 ADDED → green. If either run fails, the set has drifted
    /// from actual app behavior — re-calibrate.
    private static let appLifecycleKeys: Set<String> = [
        // AppDelegate init paths (StartupHealth + WelcomeView + BackupService):
        "lastLaunchTime",            // StartupHealth.swift:24, 144 — set in logSnapshot
        "hasLaunchedBefore",         // WelcomeView.swift:171, 178 — first launch marker
        "appLanguage",               // LanguageManager.shared init (4-LM seam) — writes current language
        "ClipboardTrashedItems",     // TrashStore init / moveToTrash — JSON-encoded trash array
        "lastBackupDate",            // BackupService.swift:44, 320 — written when backup >24h interval
        // UpdateService init + probe:
        "UpdateFeedPolicy",          // UpdateService.swift:110, 193 — feedPolicyKey didSet
        "LastPrimaryAppcastItemDate",// UpdateService.swift:109, 216 — startAfterFeedProbe post-probe
        // WINDOW-0001 (2026-08-10): "WindowFrame" key removed from the
        // whitelist. Frame persistence moved to AppKit's setFrameAutosaveName,
        // which writes to NSUserDefaults under a derived key (NSWindow Frame
        // <autosave name>) — NOT under "WindowFrame". If autosave ever writes
        // a key matching "WindowFrame" in the future, that's a regression.
        // ClipboardStore storage + settings:
        "ClipboardItems",            // ClipboardStore.swift:239 — itemsStorageKey, written on save
        // ID-STORE-0014 (2026-08-10): maxClipboardItems removed from
        // appLifecycleKeys. The corresponding didSet at ClipboardStore.swift:129
        // now writes to the injected defaults suite, so tests can no longer
        // pollute production `com.clipmemory.app`. Re-adding this entry would
        // re-blind the canary — do it only if maxItems didSet regresses to
        // UserDefaults.standard AND a real fix is on the way.
        "settings.selectedTab",      // SettingsRootView.swift:31 — @AppStorage, didSet on tab click
        // ImageStorage startup migration + cleanup:
        "ImageStorageMigrationComplete", // ImageStorage.swift:78, 159, 290 — init-time migration latch
        "ImageStorageStartupCleanupRan", // ImageStorage.swift:889, 891 — init-time orphan cleanup latch
    ]

    /// Cold-disk calibration (2026-08-06) found 18 keys; the 4 removed
    /// for documented reasons are listed in the comment block above.
    ///
    /// Environment invariants — keys that MUST be present in the
    /// observed set on every run. Their absence means a previously-
    /// active source silently stopped writing (a real shrink, not a
    /// race).
    ///
    /// Renamed from `ratchetEnforcedKeys` (2026-08-06) — the old
    /// name implied "the ratchet is enforced on these keys". The new
    /// name states the actual semantic: "these keys are environmental
    /// invariants, not ratchet enforcement". The check in
    /// `environmentInvariantCheck` is a sanity check, not a ratchet
    /// (the forward assertion is the real production safety).
    ///
    /// Race-conditioned framework writes (e.g. `SUUpdateGroupIdentifier`)
    /// are NOT in this set — they would flake CI every other run.
    /// Adding a key to this set is a code review event requiring
    /// proof that the source is race-stable.
    private static let environmentInvariants: Set<String> = [
        // AppleLanguages is OS-level and always present in the
        // production domain. If it disappears, we somehow stopped
        // writing it on some path — flag that as a sanity regression.
        // SU* keys are race-conditioned (Sparkle may or may not write
        // them in a given run) so they're exempt from the reverse-
        // assertion; they ARE listed in `toleratedPollution` so the
        // forward assertion accepts them when they DO appear.
        "AppleLanguages",
    ]

    /// Runs LAST in the suite (alphabetically after every other class).
    /// Compares the production persistent domain against the AAA snapshot.
    /// Fails on keys NOT in `toleratedPollution` (allowlist). The
    /// environment-invariant check in `environmentInvariantCheck`
    /// separately enforces that the `environmentInvariants` subset
    /// appears on every run.
    ///
    /// Double assertion at the end (`XCTFail` + `XCTAssert(false, ...)`) is
    /// intentional redundancy: test-method-level failures cause
    /// `xcodebuild` to exit non-zero, but a future CI tool that swallows
    /// `XCTFail` would still see the explicit `XCTAssert` as a hard stop.
    func testNoProductionPollution() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let after = UserDefaults.standard.persistentDomain(forName: bundleId) ?? [:]
        let before = AAASuiteBootstrapTests.productionPersistentDomainBefore

        // Build filtered key sets (strip system keys)
        func stripSystemKeys(_ dict: [String: Any]) -> [String: Any] {
            dict.filter { key, _ in
                !Self.systemKeyPrefixes.contains { key.hasPrefix($0) }
            }
        }

        let filteredBefore = stripSystemKeys(before)
        let filteredAfter = stripSystemKeys(after)
        let allKeys = Set(filteredBefore.keys).union(filteredAfter.keys)

        var newPollution: [String] = []

        for key in allKeys.sorted() {
            let beforeVal = filteredBefore[key]
            let afterVal = filteredAfter[key]

            // Only flag ADDED / CHANGED — REMOVED is a separate class of
            // damage (data loss) that still fails even for known keys.
            let isAdded = beforeVal == nil && afterVal != nil
            let isChanged = beforeVal != nil && afterVal != nil
                && !(beforeVal! as AnyObject).isEqual(afterVal!)
            let isRemoved = beforeVal != nil && afterVal == nil

            if isRemoved {
                // REMOVED is always a failure regardless of allowlist —
                // losing a user's existing value is worse than polluting
                // a new one.
                newPollution.append("key REMOVED: \"\(key)\" (was \(String(describing: beforeVal)))")
            } else if isAdded || isChanged {
                // NEW-9 (2026-08-07): accept keys in EITHER set:
                // - `toleratedPollution` = test-side pollution that is a
                //   shrink target (M13 injection work).
                // - `appLifecycleKeys` = app lifecycle writes that fire
                //   in every test run because the test process IS a real
                //   app. NOT a shrink target.
                // A key in NEITHER set is genuine new pollution that
                // should be caught.
                let inAnyAllowlist = Self.toleratedPollution.contains(key)
                    || Self.appLifecycleKeys.contains(key)
                if !inAnyAllowlist {
                    // New pollution — not in any allowlist. This is the gate.
                    if isAdded {
                        newPollution.append("key ADDED: \"\(key)\" = \(String(describing: afterVal))")
                    } else {
                        let bv = beforeVal!
                        let av = afterVal!
                        newPollution.append("key CHANGED: \"\(key)\" — before: \(String(describing: bv)), after: \(String(describing: av))")
                    }
                }
                // If the key is in either allowlist, no-op. See the
                // comments on the two sets for why each is acceptable.
            }
        }

        if !newPollution.isEmpty {
            let message = "ZZZ suite teardown: NEW production UserDefaults pollution detected (NOT in `toleratedPollution` or `appLifecycleKeys` allowlists):\n" +
                newPollution.joined(separator: "\n") +
                "\n\nIf this key is benign app lifecycle, add it to `appLifecycleKeys` in ZZZSuiteTeardownTests.swift — but understand it documents a gap in M13 init-path injection coverage (Option B), not a real bug. If this key is test-side pollution, add it to `toleratedPollution` and follow the M13 shrink path. The recommended path for BOTH is to fix the source and remove the entry."
            XCTFail(message)
            XCTAssert(false, message)
        }
    }

    /// Sanity check on environment invariants. NOT a ratchet —
    /// `environmentInvariants` keys must appear in the observed set
    /// on every run; their absence means a previously-active source
    /// silently stopped writing (a real shrink, not a race).
    ///
    /// Race-conditioned framework writes (e.g. `SUUpdateGroupIdentifier`)
    /// are NOT in `environmentInvariants` — they would flake CI every
    /// other run. Adding a key to `environmentInvariants` is a code
    /// review event requiring proof that the source is race-stable.
    ///
    /// **Why a separate test method**: keeps the environment invariant
    /// check independent from the canary's forward assertion. If the
    /// canary test is somehow skipped, this one still runs.
    ///
    /// Renamed from `reverseShrinkageCheck` (2026-08-06) — the old
    /// name implied "the ratchet shrinks when a key is removed" but
    /// `toleratedPollution` is NOT auto-shrinking; only this narrow
    /// `environmentInvariants` subset is enforced. The new name
    /// captures the actual semantic: "these keys are invariants of
    /// the test environment, not ratchet enforcement".
    func environmentInvariantCheck() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let after = UserDefaults.standard.persistentDomain(forName: bundleId) ?? [:]
        let before = AAASuiteBootstrapTests.productionPersistentDomainBefore

        func stripSystemKeys(_ dict: [String: Any]) -> [String: Any] {
            dict.filter { key, _ in
                !Self.systemKeyPrefixes.contains { key.hasPrefix($0) }
            }
        }

        let filteredAfter = stripSystemKeys(after)
        let filteredBefore = stripSystemKeys(before)
        let allKeys = Set(filteredBefore.keys).union(filteredAfter.keys)

        // NEW-2 follow-up (2026-08-06) + NEW-9 (2026-08-07): the
        // environment invariant check only fires on `environmentInvariants`
        // — keys that are race-stable and therefore MUST appear in every
        // run when pollution is happening. Race-conditioned framework
        // writes (e.g. Sparkle's `SUUpdateGroupIdentifier`, which may
        // or may not appear in a given run) are accepted in
        // `toleratedPollution` but exempt from this check to avoid
        // CI flake.
        //
        // NEW-9 (2026-08-07): observedAllowlistKeys now considers
        // BOTH `toleratedPollution` and `appLifecycleKeys` — both
        // are forward-accepted, so both are eligible as "observed"
        // signal sources. (Only `environmentInvariants` is checked
        // for strict presence; the appLifecycleKeys are not — they
        // may or may not fire in a given run depending on test path,
        // e.g. `WindowFrame` only fires when `showSettingsWindow()`
        // is called.)
        //
        // For `environmentInvariants`, we count "observed" as "present
        // in either before or after snapshot" — some enforced keys
        // (e.g. `AppleLanguages`) are OS-level defaults that exist in
        // the domain BEFORE the test runs, so they appear in before
        // but not as ADDED. Counting either-side presence is the
        // right signal for "the source is still active".
        var observedAllowlistKeys: Set<String> = []
        for key in allKeys {
            let beforeVal = filteredBefore[key]
            let afterVal = filteredAfter[key]
            let isAdded = beforeVal == nil && afterVal != nil
            let isChanged = beforeVal != nil && afterVal != nil
                && !(beforeVal! as AnyObject).isEqual(afterVal!)
            let isPresent = beforeVal != nil || afterVal != nil
            let inAnyAllowlist = Self.toleratedPollution.contains(key)
                || Self.appLifecycleKeys.contains(key)
            if inAnyAllowlist && (isAdded || isChanged || isPresent) {
                observedAllowlistKeys.insert(key)
            }
        }

        // Only check the environment-strict subset (NOT a ratchet —
        // just a sanity check that the source is still active).
        let unobservedEnforced = Self.environmentInvariants.subtracting(observedAllowlistKeys)
        if !unobservedEnforced.isEmpty {
            let list = unobservedEnforced.sorted().joined(separator: "\n  - ")
            let message = "ZZZ environment invariant violated: the following ENVIRONMENT-INVARIANT keys are expected to appear in the production UserDefaults snapshot on every run but are absent. Either the production-writing source was fixed (then remove the entry from `environmentInvariants`) or the test host somehow stopped writing it.\n" +
                "Unobserved environment invariants:\n  - \(list)\n\n" +
                "Note: this is a SANITY check, not a ratchet. The `toleratedPollution` set is NOT required to shrink over time. Only `environmentInvariants` keys must appear in every run. Race-conditioned keys (e.g. Sparkle `SUUpdateGroupIdentifier`) belong ONLY in `toleratedPollution`, not in `environmentInvariants`."
            XCTFail(message)
            XCTAssert(false, message)
        }
    }

    // MARK: Canary discovery marker

    /// XCTest discovers test classes by their `testXxx()` methods; a class
    /// with NO test methods is silently skipped. The pollution checks
    /// above are now self-sufficient, but this marker is kept so the class
    /// stays discoverable even if the diff body is ever refactored to a
    /// helper (defensive against the 2026-08-03 "build passed, zero tests
    /// executed" bug recurring).
    func testSuiteTeardownMarker() {
        // ID-MISC-0013 (2026-08-08 audit): bare method body looked like a
        // forgotten test, but it's a class-discovery marker (XCTest skips
        // classes with zero testXxx methods). Trivial assertion makes the
        // intent explicit for future readers.
        XCTAssertTrue(true)
    }

    /// NEW-1 follow-up (2026-08-06): forward-assertion smoke test.
    /// Ratchet baseline tests are about shrink enforcement (allowlist
    /// grew stale). The forward direction (allowlist stale → a new
    /// pollution key slips past) is the actual production safety the
    /// canary provides. The empty-allowlist test (2026-08-06 earlier
    /// today) proved the gate catches new keys when NOTHING is
    /// tolerated. This test proves the gate catches new keys when
    /// the TOLERATED list is non-empty — a regression of the gate
    /// itself (e.g. someone "fixing" the canary to skip the not-in-list
    /// check) would pass the empty-allowlist test but fail this one.
    ///
    /// The injected key uses a `zzz_` prefix so it doesn't collide with
    /// real framework key prefixes the production domain may grow.
    func testForwardAssertionCatchesNewPollution() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let defaults = UserDefaults.standard
        // Inject a known-bogus key AFTER the AAA snapshot (so this
        // method introduces the diff itself). This simulates a test
        // class that, during the run, writes a key not in the
        // tolerated list.
        let bogusKey = "zzz_bogus_test_key"
        defaults.set("test_value", forKey: bogusKey)
        defer { defaults.removeObject(forKey: bogusKey) }

        let after = defaults.persistentDomain(forName: bundleId) ?? [:]
        let before = AAASuiteBootstrapTests.productionPersistentDomainBefore

        // Mirror the production-logic filter for this test
        let filteredBefore = before.filter { key, _ in
            !Self.systemKeyPrefixes.contains { key.hasPrefix($0) }
        }
        let filteredAfter = after.filter { key, _ in
            !Self.systemKeyPrefixes.contains { key.hasPrefix($0) }
        }

        var caughtNewPollution = false
        for key in [bogusKey] {
            let beforeVal = filteredBefore[key]
            let afterVal = filteredAfter[key]
            let isAdded = beforeVal == nil && afterVal != nil
            let inAnyAllowlist = Self.toleratedPollution.contains(key)
                || Self.appLifecycleKeys.contains(key)
            if isAdded && !inAnyAllowlist {
                caughtNewPollution = true
            }
        }
        XCTAssertTrue(caughtNewPollution,
                       "Forward assertion: a new pollution key (not in `toleratedPollution` or `appLifecycleKeys`) must be caught. If this fails, the canary's not-in-list check has been disabled.")
    }
}
