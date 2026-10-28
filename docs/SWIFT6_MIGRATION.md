# Swift 6 Migration Roadmap

> **Audit reference**: ID-STORE-0008 (`docs/superpowers/audits/audit-report-2026-08-15.md` §7.1 / §52.7/.14) — "TSan 未进 CI / Swift 6 迁移计划缺失" (MEDIUM-14 in legacy ledger)
> **Status**: Phase 1 in progress — TSan advisory CI + this document + M-16 annotations

---

## 1. Background

Thread Sanitizer (TSan) is a LLVM-level data-race detector that instruments compiled binaries. It was added to the CI pipeline in this PR to provide continuous runtime verification of memory race safety.

**TSan catches C/ObjC/Swift naked memory races — it does NOT catch Swift actor isolation violations under `minimal` concurrency mode.** The Swift type system in `minimal` mode does not enforce actor isolation; TSan green therefore means "no memory races detected" but is only a lower bound on true concurrency safety. "TSan green ≠ concurrency safe."

Audit finding MEDIUM-14 (`ID-STORE-0008` in ledger) identified that ClipMemory had no TSan infrastructure and no Swift 6 migration plan. Prior to this PR, data-race detection relied entirely on static code review. Six Sendable conformance sites existed across the codebase, and three used `@unchecked Sendable` without explicit thread-safety justification.

---

## 2. Current State

| Setting | Value | Location |
|---------|-------|----------|
| `SWIFT_VERSION` | 5.9 | `project.yml:19` |
| `SWIFT_STRICT_CONCURRENCY` | minimal | `project.yml:20` |
| Sendable conformance sites | 6 | ClipboardItem, Tag, DateFilter, AppVersion, UpdateStatus, BackupItem |
| `@unchecked Sendable` sites | 3 | UpdateService.swift:94, FeedProbeEngine.swift:259, NetworkMonitor.swift:23 |
| Test suite size | `Scripts/test-count.sh` (static estimate) | see ID-TEST-0002 |

The `minimal` mode disables Swift's strict concurrency checking entirely. This keeps the codebase compiling today but shifts all actor-isolation verification to manual review. Swift 6 introduces a new `complete` mode that enforces Sendable checks and actor isolation at compile time.

---

## 3. Migration Phases

### Phase 1 — Foundation (this PR: `fix/m-14-tsan-swift6-foundation`)

TSan advisory CI infrastructure + this roadmap document + `@unchecked Sendable` thread-safety annotations. **No production code behavior changes.** No tests added.

### Phase 2 — Targeted Incremental (Swift 5.x, future)

Per-module opt-in of upcoming Swift concurrency features via `SWIFT_UPCOMING_FEATURE_*` compiler flags:

- `IsolatedDefaultValues` — default argument isolation
- `InferSendableFromCaptures` — smarter Sendable inference
- `StrictConcurrency` — incremental strictness (requires per-module audit)

For external frameworks (Sparkle, AppKit) that predate Swift concurrency, add `@preconcurrency import` to suppress spurious warnings. Begin annotating internal types with `Sendable` / `@Sendable` where straightforward.

**Estimated scope**: ~1–2 days of compiler-flag experimentation + per-module annotations.

### Phase 3 — Swift 6 Mode (future)

Full migration to Swift 6:

1. Bump `SWIFT_VERSION` in `project.yml` from 5.9 to 6.0
2. Change `SWIFT_STRICT_CONCURRENCY` from `minimal` to `complete`
3. Withdraw all `@preconcurrency import` directives
4. Audit all remaining `@unchecked Sendable` sites for proper synchronous isolation
5. Convert `stateLock`-protected mutable state to `actor`-isolated state
6. Address all Swift 6 mode warnings and errors

**Estimated scope**: 3–5 days of full Sendable audit across all modules.

---

## 4. Per-Module Migration Table

| Module | Sendable 现状 | Race 风险 | Phase 2 effort | Phase 3 blocker |
|--------|--------------|-----------|----------------|-----------------|
| `Services/ClipboardStore` | ✓ Sendable (值类型) | Low — NSCache already locked | 1h | NSCache → actor |
| `Services/ClipboardMonitor` | 部分 (@unchecked) | High — `stateLock` already present | 2h | `stateLock` → actor |
| `Services/UpdateService` | @unchecked (NoOpFeedProbeEngine) | Low — no mutable state | 0.5h | URLSession delegate 隔离 |
| `Services/FeedProbeEngine` | @unchecked (CappedFetchDelegate) | Medium — mutable fetch state | 1h | @preconcurrency URLKit |
| `Services/NetworkMonitor` | @unchecked | Medium — NWPath monitor ref | 1h | NWPath 监听器重构 |
| `Services/BackupPackage` | ✓ Sendable (enum) | Low | 0.5h | — |

### Detailed Notes

**ClipboardStore** — All stored items are plain structs. NSCache provides thread-safe storage. Phase 3 work: replace NSCache with a dedicated `actor`-isolated cache type to eliminate the last shared mutable state.

**ClipboardMonitor** — Uses `OSAllocatedUnfairLock` to protect `stateLock` and all mutable clipboards. Phase 3: migrate the monitor to an `actor` for Swift-6-native isolation.

**UpdateService** — `NoOpFeedProbeEngine` (UpdateService.swift:94) is a protocol-conforming no-op with no mutable state. Marked `@unchecked Sendable` with thread-safety justification: type-level no-op (FeedProbeEngine protocol minimum implementation); all methods return static values; compiler-validated zero stored properties.

**FeedProbeEngine** — `CappedFetchDelegate` (FeedProbeEngine.swift:259) uses `@unchecked Sendable` with per-fetch `OSAllocatedUnfairLock` + URLSession serial delegate queue. Phase 2: isolate with `@preconcurrency import URLKit` until Swift 6 enables full annotation.

**NetworkMonitor** — `NetworkMonitor` (NetworkMonitor.swift:23) is `@unchecked Sendable` because it wraps `NWPathMonitor` which is not Sendable. Phase 3: refactor to a dedicated actor with structured concurrency.

**BackupPackage** — `BackupItem` enum is fully Sendable. No migration needed.

---

## 5. Risks and Mitigations

### Sparkle URLSession uninstrumented

Sparkle's `SPKDataSession` uses URLSession internally, but TSan runs with `ignore_noninstrumented_modules=1` to suppress uninstrumented framework warnings. This means Sparkle's internal URLSession races will not be caught by TSan. **Mitigation**: `@preconcurrency import` Sparkle in Phase 2 to isolate its callbacks, and rely on structured concurrency for safe URLSession usage in our own code.

### Cocoa app delegate main-thread assumptions

AppKit's `NSApplicationDelegate` callbacks and `NSAlert` modal runs assume main-thread execution. Swift 6's `complete` mode may flag some background-to-main dispatch patterns. **Mitigation**: audit all `DispatchQueue.main.async` call sites in Phase 3; use `@MainActor` annotations on delegate methods where appropriate.

### NSAlert modal blocking

`NSAlert.runModal()` blocks the calling thread. Under Swift 6 `complete` mode, blocking on a non-`@MainActor` context while holding a lock can cause TSan warnings. **Mitigation**: ensure all `NSAlert` presentations happen on the main actor with no locks held.

---

## 6. Verification Gates

All gates must pass before advancing between phases.

### Gate 1 — TSan advisory CI green

`.github/workflows/tsan.yml` runs on every PR (race-prone subset, see assertion in workflow for current count, 15 min) and nightly (full suite, see `Scripts/test-count.sh`, 60 min). Advisory means `continue-on-error: true` — failures do not block merge but must be addressed before the next release.

### Gate 2 — Swift 6 strict concurrency build

```bash
xcodebuild -scheme ClipMemory SWIFT_STRICT_CONCURRENCY=complete
```

This repo has no `Package.swift` — Sparkle is declared as an SPM dependency in `project.yml:9–12` and is injected into the `.xcodeproj` via XcodeGen. The build must complete with **zero warnings** under `complete` mode before Phase 3 is declared done.

### Gate 3 — Full test suite in TSan mode

All tests must pass under TSan instrumentation (current count: `Scripts/test-count.sh`). Run:

```bash
xcodebuild -scheme ClipMemory -configuration Debug \
  test CODE_SIGN_IDENTITY="-" \
  -enableThreadSanitizer YES \
  ENABLE_THREAD_SANITIZER=YES
```

The full suite must report 0 data races and all tests passing.

---

## 7. Rollback Strategy

### Per-module flag rollback (Phase 2)

If a specific module causes Swift 6 warnings under `complete` mode, it can be individually exempted via `SWIFT_UPCOMING_FEATURE_DISABLE` flags in that module's build settings, without reverting the entire migration.

### Branch revert (any phase)

The `fix/m-14-tsan-swift6-foundation` branch is a standalone feature branch. If Phase 3 reveals systemic issues that cannot be resolved within a reasonable timebox, revert to `main` and defer the full Swift 6 migration to a future release cycle.

### Phase 3 deferral

If TSan infrastructure reveals an unexpectedly high number of races, or if Swift 6 toolchain stability is insufficient, Phase 3 may be deferred indefinitely. Phase 1 and Phase 2 infrastructure remains valuable independently: TSan advisory catches regressions, Phase 2 annotations document thread-safety intent.

---

## 8. `nonisolated(unsafe)` Symbol Roster (ID-CRASH-0030)

> ID-CRASH-0030 (2026-09-28 code-review P2-21): the code-review audit
> counted 17 `nonisolated(unsafe)` declarations across the service
> layer. These must each be either (a) migrated to actor isolation in
> Phase 3, or (b) given a documented isolation contract in Phase 2.
> Per audit recommendation: "把这里的高隔离决策依据记入 SWIFT6_MIGRATION.md".
>
> ID-CRASH-0064 (2026-10-23): **the "17" was stale AND the table was
> internally inconsistent** — the table listed 18 declarations while the
> prose said 17. The arithmetic behind it ("11 production cache/state
> vars + 6 test-seam statics = 17") silently dropped
> `LanguageManager.codeStorage`, a production state var that the very
> same table listed. Every line number had drifted as well.
> Re-measured on 2026-10-27: **19 declarations** — 12 production cache/state vars
> + 7 test-seam statics. The 19th is `AppStorageDefaults.overrideStorage`
> (ID-REVIEW-1039, 2026-10-27): the appearance seam the view tree's `@AppStorage`
> declarations and `sz(_:)` resolve against. It is deliberately NOT folded into
> `TestIsolation.defaults` — see the roster row for the measured reason.
>
> ID-REVIEW-1042 (2026-10-27): **20 declarations**. The 20th is
> `AppPasteboard.overrideBoard` — the pasteboard seam's test override. The app
> binds to a PRIVATE pasteboard in a test process, so the suite can never
> reach the user's real clipboard (ID-REVIEW-1041 measured the damage that
> motivated it). It is deliberately NOT folded into `TestIsolation.defaults`
> either: that seam owns `UserDefaults` STORAGE, this one owns a system
> RESOURCE — and the lock contract is the same shape (the read points are not
> all on the main actor: `ClipboardMonitor` polls from its own timer queue).
> The declaration moved 76 → 81 when ID-REVIEW-1042's follow-up added the
> measured note about `loadFullSizeImageAsync` returning its completion on
> the main thread.
>
> ID-REVIEW-1045 (2026-10-28): **{count} declarations**. The two new ones are the
> menu-bar status item's **creation seam** in `AppDelegate`:
> `statusItemFactory` (`AppDelegate.swift:575`) — the closure that actually
> creates the `NSStatusItem` — and `statusItemCreationCount`
> (`AppDelegate.swift:580`) — the counter that makes the creation **observable**
> (the static guards pinned the RESOURCE and the ARGUMENT, never the ACT of
> creating ⇒ a mutation could create the item without assigning it and every
> guard stayed green while the test host really occupied a slot in the user's
> menu bar). Both are guarded by `statusItemFactoryLock` (`:574`). They are
> deliberately NOT folded into `TestIsolation.defaults`: that seam owns
> `UserDefaults` storage, these own the **creation action** on a system
> resource — the same "one concept, two mechanisms" split as
> `AppPasteboard.overrideBoard`.

> <!-- nonisolated-unsafe-declaration-count: 22 -->

### How this was measured

A **declaration** is a line where the keyword appears with no `//` before
it. A comment that merely MENTIONS the keyword is NOT a declaration and
does not count — the roster is a list of declarations, not of mentions.

Reproduce with (run from the repo root):

```bash
rg -n --no-heading -g '*.swift' '^[^/]*nonisolated\(unsafe\)' ClipMemory/
```

Raw output on 2026-10-28 — 22 lines, i.e. 22 declarations:

```
AppDelegate.swift:590:    nonisolated(unsafe) static var statusItemFactory: (NSStatusBar) -> NSStatusItem = {
AppDelegate.swift:595:    nonisolated(unsafe) static var statusItemCreationCount = 0
Services/LanguageManager.swift:29:    nonisolated(unsafe) static var injectedForTest: LanguageManager?
Services/LanguageManager.swift:74:    nonisolated(unsafe) static var defaults: UserDefaults {
Services/LanguageManager.swift:102:    nonisolated(unsafe) private static var codeStorage: String = "en"
Services/WindowManager.swift:113:    nonisolated(unsafe) static var defaults: UserDefaults {
Services/UpdateService.swift:202:    nonisolated(unsafe) static var defaults: UserDefaults {
Services/UpdateService.swift:235:    nonisolated(unsafe) static var injectedForTest: UpdateService?
Services/ClipboardStore.swift:928:    nonisolated(unsafe) let contentCache: NSCache<NSString, NSString> = {
Services/ClipboardStore.swift:939:    nonisolated(unsafe) private let rtfPlaintextCache: NSCache<NSString, NSString> = {
Services/ClipboardStore.swift:1046:    nonisolated(unsafe) var pendingFailedIDs = Set<UUID>()
Services/ClipboardStore.swift:1047:    nonisolated(unsafe) let pendingFailedIDsLock = NSLock()
Services/ClipboardStore.swift:1055:    nonisolated(unsafe) var pendingDiagnostics: [PendingDiagnostic] = []
Services/ClipboardStore.swift:1056:    nonisolated(unsafe) let pendingDiagnosticsLock = NSLock()
Services/ClipboardStore.swift:2445:    nonisolated(unsafe) let prewarmStateLock = NSLock()
Services/ClipboardStore.swift:2446:    nonisolated(unsafe) var prewarmInFlight = false
Services/ClipboardStore.swift:2447:    nonisolated(unsafe) var prewarmPendingItems: [ClipboardItem]?
Services/ClipboardStore.swift:2448:    nonisolated(unsafe) var prewarmPendingCompletions: [() -> Void] = []
Services/ClipboardStore.swift:2457:    nonisolated(unsafe) var pendingPrewarmWorkItem: DispatchWorkItem?
Utils/AppPasteboard.swift:81:    private nonisolated(unsafe) static var overrideBoard: NSPasteboard?
Utils/AppStorageDefaults.swift:93:    private nonisolated(unsafe) static var overrideStorage: UserDefaults?
Utils/TestIsolation.swift:97:    private nonisolated(unsafe) static var defaultsStorage: UserDefaults = baselineDefaults
```

The COUNT is enforced by a test — see "Drift protection" below. The LINE
numbers are a snapshot too, and since 2026-10-23 they are enforced as
well: the raw output must list exactly the declarations the code carries,
with their current line numbers (a row that points at a line which no
longer holds the declaration sends the next reader to the wrong place —
that is what happened to the `TestIsolation` row when ID-CRASH-0066 moved
the declaration). Refresh the roster in the same commit that moves the
declarations.

### The roster

Isolation contracts below were re-verified against the call sites, not
just copied from the declaration comments.

| File | Line | Symbol | Current isolation (verified) | Phase 3 plan |
|------|------|--------|------------------------------|--------------|
| `AppDelegate.swift` | 590 | `statusItemFactory: (NSStatusBar) -> NSStatusItem` | ID-REVIEW-1045 P1-2: the seam that creates the menu-bar status item. The factory is **read** under `statusItemFactoryLock` (`:574`) inside `makeStatusItem()` (`:592`) and **invoked outside** the lock (the creation itself must not hold the lock). It is deliberately NOT `TestIsolation.defaults`: that seam owns `UserDefaults` storage, this one owns the **creation action** on a system resource | actor-isolate the canonical seam |
| `AppDelegate.swift` | 580 | `statusItemCreationCount: Int` | ID-REVIEW-1045 P1-2: the counter that makes the creation **observable** — every increment and every read is bracketed by `statusItemFactoryLock` (`:574`; reads go through `statusItemCreations` at `:583`). A behavioural guard asserts "the test host created NOTHING" ⇒ aliasing, renaming or moving the creation into a helper cannot hide it | actor-isolate the canonical seam |
| `Services/ClipboardStore.swift` | 928 | `contentCache: NSCache` | `NSCache` is documented thread-safe (per NSCache header); the nonisolated decrypt kernels touch it from prewarm's utility-queue workers | actor-isolated cache |
| `Services/ClipboardStore.swift` | 939 | `rtfPlaintextCache: NSCache` | same NSCache thread-safety contract as `contentCache` | actor-isolated cache |
| `Services/ClipboardStore.swift` | 1046 | `pendingFailedIDs: Set<UUID>` | every access bracketed by `pendingFailedIDsLock` (`:1047`) — `ClipboardStore.swift:2419`, `ClipboardStore+Encryption.swift:59,252,310,322` | actor-isolated state |
| `Services/ClipboardStore.swift` | 1047 | `pendingFailedIDsLock: NSLock` | paired with `:1046` | eliminate with actor |
| `Services/ClipboardStore.swift` | 1055 | `pendingDiagnostics: [PendingDiagnostic]` | every access bracketed by `pendingDiagnosticsLock` (`:1056`) — `ClipboardStore+Encryption.swift:229,262,272` | actor-isolated state |
| `Services/ClipboardStore.swift` | 1056 | `pendingDiagnosticsLock: NSLock` | paired with `:1055` | eliminate with actor |
| `Services/ClipboardStore.swift` | 2445 | `prewarmStateLock: NSLock` | paired with `:2446-2448` | eliminate with actor |
| `Services/ClipboardStore.swift` | 2446 | `prewarmInFlight: Bool` | guarded by `prewarmStateLock` — `ClipboardStore+Prewarm.swift:99-107,157-167` | actor-isolated state |
| `Services/ClipboardStore.swift` | 2447 | `prewarmPendingItems: [ClipboardItem]?` | guarded by `prewarmStateLock` | actor-isolated state |
| `Services/ClipboardStore.swift` | 2448 | `prewarmPendingCompletions: [() -> Void]` | guarded by `prewarmStateLock` | actor-isolated state |
| `Services/ClipboardStore.swift` | 2457 | `pendingPrewarmWorkItem: DispatchWorkItem?` | ⚠ **NOT lock-guarded.** Main-thread-only: the work item is scheduled on `DispatchQueue.main` and its body runs there (`ClipboardStore+Prewarm.swift:59,60,70,74,78` — none of those take `prewarmStateLock`). The previous roster claimed "guarded by prewarmStateLock"; the code does not do that | actor-isolated state |
| `Services/LanguageManager.swift` | 29 | `injectedForTest: LanguageManager?` | test seam — injects a fake *service instance*. Per-service by design (see "Not in this roster") | keep; typed fake-instance seam |
| `Services/LanguageManager.swift` | 74 | `defaults: UserDefaults` | forwarder over `TestIsolation.defaults` (the canonical storage) — no independent state | actor-isolate the canonical seam |
| `Services/LanguageManager.swift` | 102 | `codeStorage: String` | guarded by `codeLock` at every access (`LanguageManager.swift:99`, `currentLanguageCode` at `:103`). The previous roster cited ":86", which is the computed property, not the lock | eliminate with actor |
| `Services/UpdateService.swift` | 202 | `defaults: UserDefaults` | forwarder over `TestIsolation.defaults` (the canonical storage) — no independent state | actor-isolate the canonical seam |
| `Services/UpdateService.swift` | 235 | `injectedForTest: UpdateService?` | test seam — injects a fake *service instance*. Per-service by design (see "Not in this roster") | keep; typed fake-instance seam |
| `Services/WindowManager.swift` | 113 | `defaults: UserDefaults` | forwarder over `TestIsolation.defaults` (the canonical storage). Dormant since WINDOW-0001 — frame persistence moved to AppKit's `setFrameAutosaveName` | actor-isolate the canonical seam |
| `Utils/TestIsolation.swift` | 97 | `defaultsStorage: UserDefaults` | **canonical** storage for the whole test seam (ID-CRASH-0029). ID-REVIEW-1036 (2026-10-26): the declaration moved from `defaults` to `defaultsStorage` because `defaults` became a lock-guarded computed accessor (`defaultsLock`) — the read-modify-write of a class reference without a lock is the shape that aborted the test host in CI run 40186263416. The storage is `private` so the lock cannot be bypassed by writing the slot directly. The three service forwarders read it through the accessor, so they inherit the lock. ID-CRASH-0066 changed its INITIALIZER from `.standard` to the immutable `baselineDefaults` (an isolated suite under XCTest, `.standard` in production) | migrate to actor in Phase 3 |
| `Utils/AppPasteboard.swift` | 81 | `overrideBoard: NSPasteboard?` | test seam — the pasteboard the app reads from and writes to. ID-REVIEW-1042 (2026-10-27): in a test process the app binds to a PRIVATE pasteboard, so the suite can neither read nor write the user's real clipboard (ID-REVIEW-1041 measured the damage: the suite's fixtures were captured by a separately running ClipMemory app into the user's real history, and the final `clearContents()` emptied the clipboard). Deliberately NOT `TestIsolation.defaults` — that seam owns `UserDefaults` storage, this one owns a system resource. Guarded by `AppPasteboard.lock`; the read points are NOT all on the main actor (`ClipboardMonitor` polls from its own timer queue), so a bare `static var` would be a data race — the same shape that aborted the test host in CI run 40186263416 | actor-isolate the canonical seam |
| `Utils/AppStorageDefaults.swift` | 93 | `overrideStorage: UserDefaults?` | test seam — the appearance store the view tree's `@AppStorage` declarations and `sz(_:)` resolve against. ID-REVIEW-1039 (2026-10-27): deliberately NOT `TestIsolation.defaults`, and it owns its own suite in a test process. Reason (measured): swapping the canonical service seam invalidates `LanguageManager.shared`'s **instance-identity** cache (`_sharedDefaultDefaults === defaults`), so the next read of `shared` re-creates the manager and binds it to whatever the service seam holds at that moment — and the next `selectedLanguage` assignment writes `appLanguage` + `AppleLanguages` into THAT store. When that store is the baseline suite, the ZZZ canary goes red naming four unrelated test classes. (`LanguageManager.init` itself writes nothing — `didSet` does not fire during `init`.) Guarded by `AppStorageDefaults.lock` (`:90`) | actor-isolate the canonical seam |

**22 declarations** = 14 production cache/state vars (11 in
`ClipboardStore` + `LanguageManager.codeStorage` + the 2 `AppDelegate`
status-item creation seam vars) + 8 test-seam statics
(3 service forwarders + 2 `injectedForTest` + 1 canonical storage
+ 1 appearance-seam override + 1 pasteboard-seam override).

### Not in this roster (but adjacent)

* **3 concurrent accessors** of the state above are declared `nonisolated`
  WITHOUT `(unsafe)`, so they are not declarations of this kind and are
  not counted: `ClipboardStore+Encryption.swift:191`
  (`getDecryptedContent`), `ClipboardStore.swift:2503`
  (`getRTFPlaintext`), `ClipboardStore+OCR.swift:186`
  (`getDecryptedOcrText`). They are the reason the lock contracts above
  matter: they read/write the same state from prewarm's utility queue.
* **Test code** carries 2 further declarations
  (`Tests/ClipMemoryTests/ImagePreviewPanelTests.swift:175-176`). They
  are outside this roster's scope (production code under `ClipMemory/`),
  but they are named here so "18" is not mistaken for a repo-wide total.

### Drift protection

The count above is enforced, not just documented:
`Tests/ClipMemoryTests/IsolationSeamConsolidationTests.swift`
(`testDocumentedRosterCountMatchesTheMeasuredDeclarationCount`) re-counts
the declarations under `ClipMemory/` with the same rule and compares them
against the `<!-- nonisolated-unsafe-declaration-count: N -->` marker
above. Add or remove a declaration → update the marker in the same
commit, or the suite goes red. A stale count in this file is exactly the
failure mode ID-CRASH-0030 was raised for, so it is now a build-time
failure instead of a reading-time surprise.

Since 2026-10-23 the raw output's LINE NUMBERS are enforced too
(`testDocumentedRosterLineNumbersStillPointAtTheirDeclarations`): the
documented `(file, line)` pairs must equal the measured ones. A file that
moves its declarations therefore needs the roster refreshed in the same
commit — the alternative is a row that points at the wrong line.

---

*Last updated: 2026-10-28 (ID-REVIEW-1045: §8 refreshed — the menu-bar status item's creation seam contributes 2 new `nonisolated(unsafe)` declarations (`AppDelegate.swift:575` `statusItemFactory`, `:580` `statusItemCreationCount`); the COUNT moves 20 → **22**, and the roster rows + raw-output block are refreshed in the same commit, as the drift-protection test demands). Previous: 2026-10-27 (ID-REVIEW-1042: §8 refreshed — the new `AppPasteboard` pasteboard seam contributes the 20th `nonisolated(unsafe)` declaration (`Utils/AppPasteboard.swift:76`, `overrideBoard`); the COUNT moves 19 → **20**, and the roster row + raw-output block are refreshed in the same commit, as the drift-protection test demands). Previous: 2026-10-26 (ID-REVIEW-1036: §8's `LanguageManager` / `UpdateService` / `TestIsolation` rows refreshed — the ID-REVIEW-1036 seam hardening moved `TestIsolation.defaults` from a stored property to a lock-guarded computed accessor over `defaultsStorage` (declaration now at :97), which shifted the `LanguageManager` rows (20→29, 65→74, 93→102) and `UpdateService.injectedForTest` (226→235); the COUNT is unchanged at 18). Previous: 2026-10-24 (ID-REVIEW-1026: §8's `ClipboardStore` rows refreshed again — the ID-REVIEW-1026 sentinel rework moved the declarations to 928–2457; the COUNT is unchanged at 18). Previous: 2026-10-24 (ID-REVIEW-1025: §8's `ClipboardStore` rows refreshed twice — the declarations moved from 2329–2341 to 2347–2359 (the `pendingKeyItems` overflow notification) and then to 2397–2409 (the items-load-failed sentinel check); the COUNT is unchanged). Previous: 2026-10-23 (ID-REVIEW-1024 review: §8's `TestIsolation` row refreshed — the declaration moved from line 50 to line 84 in ID-CRASH-0066 — and the line numbers are now enforced by a test, like the count). Previous: 2026-10-23 (ID-CRASH-0064: §8 re-measured — 17 → **18** declarations, line numbers and two isolation contracts corrected, count now enforced by a test). Previous: 2026-09-29 (ID-CRASH-0030 P2-21 roster appended). Related: `.github/workflows/tsan.yml`, `audit-report-2026-08-15.md` (MEDIUM-14 / ID-STORE-0008).*
