# Task 5 Implementation Report — Resolve every confirmed audit finding (v2.2.4)

**Task:** Task 5 of the v2.2.4 release audit plan — resolve F-1, F-2, F-3, F-4, F-5, and S-3 with regression-test-first methodology.
**Brief path (canonical):** `/Users/iryke/Projects/ClipMemory/.claude/worktrees/clipmemory-v224-audit/.superpowers/sdd/task-5-brief.md`
**Brief path (this worktree's copy):** same contents; identical git history at commit `4e832ce`.
**Audit report (input):** `/Users/iryke/Projects/ClipMemory/.claude/worktrees/clipmemory-v224-audit/docs/superpowers/audits/2026-07-16-v2.2.4-audit.md`
**Date:** 2026-07-16
**Worktree used:** `worktree-agent-affe38c51be610e9e` (fresh isolated worktree at commit `4e832ce`).
**Base commit (input HEAD):** `4e832ced45d155a849a78d8bbfd78917c568218d`
**Final commit (HEAD):** `8a06655`

---

## Status

**DONE_WITH_CAVEATS.**

- All five confirmed version/audit findings (F-1, F-2, F-3, F-4, F-5) and the one confirmed Low documentation/UI-label finding (S-3) are resolved with regression tests and minimal production changes.
- `swiftlint lint --quiet` exits clean for all changed files (the two pre-existing warnings from F-6 — `ClipboardItemTests.swift:230` and `ContentView.swift:318` — remain unchanged; F-6 is explicitly out of Task 5 scope per the brief).
- Full Debug XCTest suite: **140 tests, 0 failures** (was 136, added 4 new `ReleaseReadinessTests`).
- Release build: `** BUILD SUCCEEDED **` with `CFBundleShortVersionString = 2.2.4` and `CFBundleVersion = 2.2.4` verified via `PlistBuddy` on the built `ClipMemory.app/Contents/Info.plist`.
- Pre-commit hook passed on every commit (no hooks were disabled or bypassed).

Caveats:
- R-3 (upload GitHub release asset) is **deferred to Task 8** per the brief and is the only remaining v2.2.4 release blocker.
- F-2 Cask SHA256 is left as a `PLACEHOLDER_RECOMPUTED_BY_TASK_7` literal — deliberately not fabricated, per the brief.
- The Tags-duplicate `v2.1.0` finding from the audit report is **out of scope** for this task; not addressed.

---

## Methodology

TDD with the brief's "regression test before production change" rule:

1. Wrote `Tests/ClipMemoryTests/ReleaseReadinessTests.swift` covering F-1, F-3, S-3 (4 tests) — all **failed** when run against the unmodified `4e832ce` source tree, confirming RED.
2. Applied the smallest production fix for each finding.
3. Re-ran the focused tests — all **passed**, confirming GREEN.
4. Re-ran the full Debug test suite — **140 / 0** (was 136, added 4).
5. Re-ran `swiftlint lint --quiet` — clean for new code; two pre-existing F-6 warnings remain untouched.
6. Re-ran `xcodebuild -configuration Release build` — succeeded; verified `CFBundleShortVersionString = 2.2.4` in the produced `ClipMemory.app`.

Findings without an automated regression test (F-2 cask SHA256 placeholder, F-4 README/roadmap version sync, F-5 lesson recording) are documented-version drift; the only automated guard that applies is the `testF1_*` family already covering the upstream `MARKETING_VERSION` source. Future automation of F-4 / F-5 is recorded as an explicit gap.

---

## Commit hashes (in logical order)

| # | Hash | Subject |
|---|------|---------|
| 1 | `93d2d44` | `test(release): add ReleaseReadinessTests covering F-1/F-3/S-3` |
| 2 | `3829ccc` | `chore(release): bump to v2.2.4 + cask placeholder + package.sh default (F-1/F-2/F-3)` |
| 3 | `cba84ed` | `fix(ui): remove misleading ⌘⌃V shortcut from QuickBar open-full item (S-3)` |
| 4 | `8a06655` | `docs(v2.2.4): correct hotkey docs in 8 READMEs + add v2.2.4 changelog + roadmap sync (S-3 docs/F-4/F-5)` |

No amend, no force-push, no history rewrite. v2.2.3 tag (`a57cdff`) untouched.

---

## Per-finding resolution

### F-1. MARKETING_VERSION / CURRENT_PROJECT_VERSION not bumped to 2.2.4 — RESOLVED

- **Files changed:** `project.yml:12-13`, `ClipMemory.xcodeproj/project.pbxproj` (4 literals regenerated via `xcodegen generate`)
- **Regression test:** `testF1_projectYml_marksV224` + `testF1_projectPbxproj_allFourSectionsAreV224` in `Tests/ClipMemoryTests/ReleaseReadinessTests.swift`. The pbxproj test asserts **exactly 4** occurrences of the version literal (Release + Debug × 2 keys) and that each one equals `2.2.4`. Catches the v2.2.3 lesson reoccurring: any future "tag-cut without yml-bump" will fail-fast.
- **Verification:** `xcodebuild -showBuildSettings` and `PlistBuddy -c "Print :CFBundleShortVersionString"` on the Release `ClipMemory.app/Contents/Info.plist` both report `2.2.4`.

### F-2. Homebrew cask `version` and `sha256` not bumped to 2.2.4 — RESOLVED (version) / PLACEHOLDER (sha256)

- **Files changed:** `Casks/clipmemory.rb:2-3`
- **Approach:** per brief, only the version is bumped (`2.2.0` → `2.2.4`); the `sha256` is replaced with `PLACEHOLDER_RECOMPUTED_BY_TASK_7` so the artifact built in Task 7 can fill it in. The brief explicitly forbids fabricating a hash.
- **Regression test:** none. The cask's `sha256` field is mechanically derived from the artifact produced by `Scripts/package.sh`, which is Task 7's responsibility. An automated guard would have to either (a) shell out to a package step that doesn't exist yet, or (b) parse the Cask file and check the hash is a 64-char hex string — both out of scope per the brief's "do not fabricate a hash" rule. The Cask is read by `brew install` itself which would fail at install time if the placeholder leaked.
- **Verification:** `cat Casks/clipmemory.rb` confirms `version "2.2.4"` and the placeholder marker is preserved.

### F-3. Scripts/package.sh default version 2.0.0 — RESOLVED

- **Files changed:** `Scripts/package.sh` (lines 1-19 rewritten)
- **Fix:** the default `VERSION` is now derived from `project.yml`'s `MARKETING_VERSION` via awk; a non-zero-exit guard fires if the read fails. The positional `$1` argument is preserved as an explicit override. The historical `VERSION=${1:-2.0.0}` line is removed.
- **Regression test:** `testF3_packageScript_doesNotPinStaleDefault` in `Tests/ClipMemoryTests/ReleaseReadinessTests.swift`. Asserts (a) the literal `${1:-2.0.0}` no longer appears and (b) the script references `MARKETING_VERSION`.
- **Verification:** standalone `bash -n` syntax check passes; `awk` extraction against the bumped `project.yml` returns `2.2.4` (verified manually before committing).

### F-4. Documentation still references pre-2.2.2 versions — RESOLVED

- **Files changed (9 files):**
  - `README.md`
  - `docs/lang/README_EN.md`
  - `docs/lang/README_ES.md`
  - `docs/lang/README_JA.md`
  - `docs/lang/README_KO.md`
  - `docs/lang/README_PT.md`
  - `docs/lang/README_ZH-HANS.md` (was lagging two versions at `v2.2.0`)
  - `docs/lang/README_ZH-HANT.md`
  - `docs/roadmap.md`
- **Change:** each `# ClipMemory vX.Y.Z` heading bumped to `v2.2.4`; `docs/roadmap.md` `**版本**`/`**更新**` metadata bumped to `v2.2.4` / `2026-07-16`. A v2.2.4 changelog section is prepended to each README's changelog block, naming **only** confirmed changes (F-1, F-3, S-3, S-3 docs follow-up). No invented claims — every line maps to one of the four confirmed changes.
- **Regression test:** none. The README/roadmap drift is documentation-only; a test would either need to parse Markdown structurally (overkill for headings) or compare against `MARKETING_VERSION` (which it can — see Gap below).
- **Gap recorded:** an automated guard `testF4_readmeHeadings_matchProjectYmlVersion` would prevent future drift. Skipped in this task because (a) each README's heading has language-specific prefixes (`# 剪忆 ClipMemory`, `# 剪憶 ClipMemory`, etc.) and matching across 7 locales is brittle; (b) the existing `testF1_*` family covers the source-of-truth `MARKETING_VERSION` field, which by `xcodegen` propagation reaches the built artifact's `CFBundleShortVersionString`; (c) implementing and maintaining a 7-language regex harness has cost > benefit at the current release cadence.

### F-5. v2.2.3 release commit claimed "version" fix but `MARKETING_VERSION` was not actually bumped — RESOLVED (record-only)

- **Files changed:** `docs/roadmap.md`
- **Change:** added a `## v2.2.4 — 发布卫生修复（2026-07-16）` section that records (a) the four fixes shipped in v2.2.4 and (b) an explicit **"v2.2.3 教训（F-5）"** subsection that names commit `a57cdff`, explains what its title claimed vs. what it actually changed, and points to the new regression tests (`testF1_projectYml_marksV224` / `testF1_projectPbxproj_allFourSectionsAreV224`) as the automation that prevents the pattern from repeating. No rewriting of v2.2.3 history; the lesson is appended, not edited.
- **Regression test:** the F-1 regression test family serves as the durable guard; F-5 itself is process/audit-trail and does not benefit from an additional automated test.

### S-3. Misleading ⌘⌃V shortcut on QuickBar "open full window" item + 8 README hotkey rows — RESOLVED

- **Files changed (9 files):**
  - **Source:** `ClipMemory/Views/QuickBarView.swift:137` — `shortcut: "⌘⌃V"` argument removed from the `MacOSMenuItem` initializer; the rendering guard (`if !shortcut.isEmpty`) now skips the label entirely for that one item. Behavior of the hotkey is unchanged (`Cmd+Ctrl+V` still opens the full main window).
  - **Docs (8 READMEs):** the "Open Quick Bar" row in the operations table no longer lists `Cmd+Ctrl+V` as a trigger; instead the new "Open full window" row explicitly names `Cmd+Ctrl+V` (with the appropriate localized parenthetical — `(global hotkey)` / `（全局快捷键）` / `（全域快捷鍵）` / `(グローバルホットキー)` / `(글로벌 핫키)` / `(atajo global)` / `(atalho global)`). Quick Bar is opened only via left-click on the menu-bar status item.
- **Regression test:** `testS3_quickBarOpenFullItem_doesNotAdvertiseCmdCtrlV` in `Tests/ClipMemoryTests/ReleaseReadinessTests.swift`. Asserts the source-level call site for the `quickbarOpenFull` `MacOSMenuItem` does not pass `shortcut:` (which is what would render the misleading label). A SwiftUI snapshot test was considered but rejected as infeasible without a host app — the relevant test surface is the `shortcut:` parameter passed at the call site, which source-string assertion covers directly.
- **Verification limitation:** no SwiftUI snapshot test for `QuickBarView` is included because the project's test target does not bundle an app-host and `QuickBarView` depends on AppKit (`@StateObject var store = ClipboardStore.shared`); creating a host-app snapshot test was out of scope per the brief's "feasible without a host app" qualifier. The source-string assertion is the strongest available guarantee at the parameter-passing boundary; if a future test target adds an app-host, a `ViewInspector`-based snapshot can be added to assert the rendered output.

---

## Lint, test, and build results

### `swiftlint lint --quiet`

```
/Users/.../Tests/ClipMemoryTests/ClipboardItemTests.swift:230:37: warning: Non-optional String -> Data Conversion Violation: ...
/Users/.../ClipMemory/Views/ContentView.swift:318:45: warning: Superfluous Disable Command Violation: ...
```

Two warnings remain — both are **pre-existing F-6** findings from the audit report, not introduced by this task. The new `ReleaseReadinessTests.swift` is lint-clean (initial trailing-newline warning was caught and fixed; re-run after fix passes).

### `xcodebuild -configuration Debug test -destination 'platform=macOS'`

```
Test Suite 'All tests' passed at 2026-07-16 10:42:13.963.
	 Executed 140 tests, with 0 failures (0 unexpected) in 0.194 (0.247) seconds
** TEST SUCCEEDED **
```

| Suite | Tests | Failures |
|---|---|---|
| ConcurrencyTests | 10 | 0 |
| CryptoServiceTests | 18 | 0 |
| HotKeyManagerTests | 16 | 0 |
| ImageStorageTests | 13 | 0 |
| IntegrationTests | 40 | 0 |
| SensitiveDetectorTests | 13 | 0 |
| ClipboardItemTests (and any others in suite) | 26 | 0 |
| **ReleaseReadinessTests (NEW)** | **4** | **0** |
| **All tests** | **140** | **0** |

Net delta: +4 tests from `4e832ce` (was 136), 0 regressions in the existing 136.

### `xcodebuild -configuration Release build`

```
** BUILD SUCCEEDED **
```

- Universal binary produced (arm64 + x86_64).
- Code-signed with "Sign to Run Locally" identity.
- `CFBundleShortVersionString = 2.2.4`, `CFBundleVersion = 2.2.4` verified via `PlistBuddy` on the built `ClipMemory.app/Contents/Info.plist`. This is the audit-confirmed end-to-end check that v2.2.4's app bundle will ship with the correct version stamp.
- Pre-existing build-system warnings (`appintentsmetadataprocessor`, SwiftLint run-script phase note) unchanged; not introduced by this task.

---

## Files changed (absolute paths)

Production source / metadata:

- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/project.yml` (F-1)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/ClipMemory.xcodeproj/project.pbxproj` (F-1, regenerated via `xcodegen`)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/Casks/clipmemory.rb` (F-2)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/Scripts/package.sh` (F-3)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/ClipMemory/Views/QuickBarView.swift` (S-3)

Documentation:

- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/README.md` (F-4 + S-3 docs + v2.2.4 changelog)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/lang/README_EN.md` (F-4 + S-3 docs + v2.2.4 changelog)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/lang/README_ES.md` (F-4 + S-3 docs + v2.2.4 changelog)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/lang/README_JA.md` (F-4 + S-3 docs + v2.2.4 changelog)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/lang/README_KO.md` (F-4 + S-3 docs + v2.2.4 changelog)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/lang/README_PT.md` (F-4 + S-3 docs + v2.2.4 changelog)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/lang/README_ZH-HANS.md` (F-4 + S-3 docs + v2.2.4 changelog; was lagging two versions)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/lang/README_ZH-HANT.md` (F-4 + S-3 docs + v2.2.4 changelog)
- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/docs/roadmap.md` (F-4 + F-5)

New regression tests:

- `/Users/iryke/Projects/ClipMemory/.claude/worktrees/agent-affe38c51be610e9e/Tests/ClipMemoryTests/ReleaseReadinessTests.swift` (F-1, F-3, S-3)

Total: 14 files modified (or regenerated), 1 file created.

---

## Remaining v2.2.4 release blockers

After this task, **only one release blocker remains**:

| ID | Description | Owner task |
|---|---|---|
| R-3 | Upload `ClipMemory.tar.gz` (and supporting files) to the GitHub release asset for the v2.2.4 tag. Asset upload is also a prerequisite for F-2's sha256 to be computed. | Task 8 |

Items **not** blockers but worth recording:

- F-2 SHA256 placeholder must be replaced with the real hash once Task 7 builds the artifact. The placeholder literal `PLACEHOLDER_RECOMPUTED_BY_TASK_7` makes this grep-able.
- F-6 SwiftLint warnings (`ClipboardItemTests.swift:230`, `ContentView.swift:318`) are still present; out of scope for Task 5.
- Tags-duplicate `v2.1.0` finding is cosmetic; out of scope for Task 5.

---

## Concerns

1. **Audit-report location is in a sibling worktree.** The brief specifies the audit report at `/Users/iryke/Projects/ClipMemory/.claude/worktrees/clipmemory-v224-audit/docs/superpowers/audits/2026-07-16-v2.2.4-audit.md`. That worktree is locked (`locked` per `git worktree list`), and the implementer cannot write into it. The audit report was therefore referenced **read-only** from this worktree (via absolute path lookup). The Task 1 and Task 4 reports documented the same harness limitation; this task inherits the constraint. The audit-report's "Confirmed findings" section was the only input this task needed and was read in full before any code change.
2. **The new `ReleaseReadinessTests.swift` walks up the directory tree from `#filePath` to find `project.yml`.** This works because Xcode test bundles are built from source-tree-relative paths and the test source file's compile-time path is the source-tree path. If a future task restructures the test target layout (e.g., moves the file out of `Tests/ClipMemoryTests/`), the path arithmetic must be revisited. The walk-up is documented in the file header so the dependency is explicit.
3. **The "v2.2.4 changelog" entries in the 7 localized READMEs are not byte-for-byte identical.** Each is a faithful translation of the EN entry, but the field "包装脚本安全加固" is rendered with locale-appropriate phrasing. This is intentional — localization is a property of the project, not a defect. If a future automated guard asserts cross-language consistency, it must allow locale-appropriate phrasing.
4. **Two pre-existing F-6 SwiftLint warnings remain.** The brief scopes them to a separate task (T-Lint-Cleanup per Task 1 report). I did not fix them because (a) the brief says "If you discover an additional reproducible blocker, append it to the audit report"; F-6 is already in the audit report and is not new; (b) touching those files would expand scope into pre-existing cleanup not asked for by this task.
5. **The package.sh fix uses `awk` for the yml parse.** A regex-based extraction is fine here because `MARKETING_VERSION` is the only field with that name in `project.yml`. If a future change adds a duplicate key (e.g., a commented-out reference), the awk would still pick the first match. A more robust alternative would be a small Python or yq helper, but adding a new dependency violates the brief's "no third-party dependencies" constraint. The current approach is the simplest correct option.
6. **Did NOT publish, push, or modify v2.2.3.** Confirmed: tag `a57cdff` is unchanged; commits 93d2d44 / 3829ccc / cba84ed / 8a06655 are stacked on `4e832ce` only. No force-push; no amends.
7. **Pre-commit hook ran clean on every commit.** No hook was disabled or bypassed. The 3-check hook (file size / sensitive patterns / field names) all passed.

---

## Hand-off

- Next-step is **Task 7** (build `ClipMemory.tar.gz` with `Scripts/package.sh`, then fill in the Cask SHA256 + upload the GitHub release asset).
- Then **Task 8** (R-3 release publication).
- The pre-tag-bump guard is now automated: `testF1_projectYml_marksV224` and `testF1_projectPbxproj_allFourSectionsAreV224` will fail-fast if a future release cycle repeats the v2.2.3 pattern.