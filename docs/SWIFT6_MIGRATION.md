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
| Test suite size | 927 tests | `Scripts/test-count.sh` (static estimate) |

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

`.github/workflows/tsan.yml` runs on every PR (race-prone subset, ~87 tests, 15 min) and nightly (full suite, 927 tests, 60 min). Advisory means `continue-on-error: true` — failures do not block merge but must be addressed before the next release.

### Gate 2 — Swift 6 strict concurrency build

```bash
xcodebuild -scheme ClipMemory SWIFT_STRICT_CONCURRENCY=complete
```

This repo has no `Package.swift` — Sparkle is declared as an SPM dependency in `project.yml:9–12` and is injected into the `.xcodeproj` via XcodeGen. The build must complete with **zero warnings** under `complete` mode before Phase 3 is declared done.

### Gate 3 — Full test suite in TSan mode

All 927 tests must pass under TSan instrumentation. Run:

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

*Last updated: 2026-08-16. Related: `.github/workflows/tsan.yml`, `audit-report-2026-08-15.md` (MEDIUM-14 / ID-STORE-0008).*
