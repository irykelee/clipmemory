# ClipMemory v2.2.4 发布前审计与修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 对当前 `main` 做完整发布前审计，修复所有有证据的真实问题，统一到 `v2.2.4`，并在所有本地验证通过后发布可安装的 GitHub Release。

**Architecture:** 先建立可复现的基线，再沿剪贴板数据流审计核心功能、安全、并发和发布链路。确认问题后采用“回归测试 → 最小修复 → 相关测试 → 全量测试”的闭环；最后把 `project.yml` 作为 App 版本来源，同步 Cask、7 个 README、roadmap 和安装包。

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, CryptoKit, CommonCrypto legacy compatibility, XcodeGen, Xcodebuild, XCTest, SwiftLint, Homebrew Cask, GitHub CLI.

## Global Constraints

- Minimum deployment target remains macOS 13.0.
- Preserve the existing `v2.2.3` tag; never move, delete, or rewrite it.
- The new release target is `v2.2.4`.
- Do not add third-party dependencies.
- Do not implement OCR, SQLite migration, a new DI framework, or unrelated architecture refactors.
- Every confirmed issue gets a regression test before its minimal implementation fix.
- Treat only reproducible or tool-proven defects as issues; do not expand style preferences into bugs.
- The release gate requires all real Blocker, High, Medium, and Low issues to be fixed or explicitly excluded with evidence.
- GitHub push and Release creation happen only after the local release checklist passes and the release action is confirmed at the final gate.

---

### Task 1: Establish the audit baseline

**Files:**
- Create directory: `/Users/iryke/Projects/ClipMemory/docs/superpowers/audits/`
- Create: `/Users/iryke/Projects/ClipMemory/docs/superpowers/audits/2026-07-16-v2.2.4-audit.md`
- Read: `/Users/iryke/Projects/ClipMemory/project.yml`
- Read: `/Users/iryke/Projects/ClipMemory/Casks/clipmemory.rb`
- Read: `/Users/iryke/Projects/ClipMemory/Scripts/package.sh`
- Read: `/Users/iryke/Projects/ClipMemory/README.md`
- Read: `/Users/iryke/Projects/ClipMemory/docs/roadmap.md`

**Interfaces:**
- Consumes: current repository state, current GitHub read-only metadata, existing test and lint commands.
- Produces: an audit report containing observed versions, test/lint/build results, open GitHub work, and a numbered finding list. Later tasks use the finding IDs as their traceability anchors.

- [ ] **Step 0: Create the audit directory**

Run:

```bash
mkdir -p /Users/iryke/Projects/ClipMemory/docs/superpowers/audits
```

Expected: the directory exists and is ready for the audit report.

- [ ] **Step 1: Confirm repository and remote state**

Run from `/Users/iryke/Projects/ClipMemory`:

```bash
git status --short --branch
git remote -v
git log --oneline --decorate -20
git tag --sort=-creatordate | head -12
```

Expected baseline facts to record, not assume:

- whether `main` is clean and synchronized with `origin/main`
- the commit pointed to by `v2.2.3`
- whether current `HEAD` differs from that tag
- the configured GitHub remote URL

- [ ] **Step 2: Capture version and release drift**

Run:

```bash
grep -RInE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION|version "|ClipMemory v2[.]2|2[.]0[.]0' \
  project.yml ClipMemory.xcodeproj/project.pbxproj Casks/clipmemory.rb \
  Scripts/package.sh README.md docs/lang docs/roadmap.md

gh release list --limit 15
gh release view v2.2.3 --json tagName,name,publishedAt,assets,url
gh issue list --state open --limit 30
gh pr list --state open --limit 30
```

Record each mismatch in the audit report with the exact file and line. The report must explicitly record whether `v2.2.3` has an asset and whether any open Issue or PR exists.

- [ ] **Step 3: Run baseline tests, lint, and Release build**

Run:

```bash
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -configuration Debug \
  test \
  -destination 'platform=macOS'

swiftlint lint --quiet

xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -configuration Release \
  build
```

Record the exact test count, failures, SwiftLint warnings, and build result. Do not label environment-only messages such as unavailable macOS services as product bugs without a reproducible app failure.

- [ ] **Step 4: Write the baseline report**

The report must contain these sections with actual values:

```markdown
# ClipMemory v2.2.4 Audit Report

## Baseline
## Release and version drift
## Confirmed findings
## Environment-only diagnostics
## Verification log
## Release blockers remaining
```

A clean category must say `No confirmed finding`, while an unresolved category must list the exact command and evidence still needed. Do not write a generic “looks good” conclusion.

- [ ] **Step 5: Verify the report is self-contained**

Run:

```bash
grep -nE 'TBD|TODO|FIXME|待补|以后再' \
  docs/superpowers/audits/2026-07-16-v2.2.4-audit.md
```

Expected: no output. Every finding has a severity, file path, line, reproduction evidence, and intended regression-test location.

---

### Task 2: Audit the data, security, and persistence path

**Files:**
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/CryptoService.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/ImageStorage.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/ClipboardStore.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/StorageBackend.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Models/ClipboardItem.swift`
- Read: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/CryptoServiceTests.swift`
- Read: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/ImageStorageTests.swift`
- Read: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/IntegrationTests.swift`
- Modify only if a finding is confirmed: the exact source and test files named in the audit report.

**Interfaces:**
- Consumes: the baseline report from Task 1 and the existing `CryptoService`, `ImageStorage`, `ClipboardStore`, and `StorageBackend` APIs.
- Produces: confirmed or rejected findings with a complete source-to-consumer trace and a named regression test for every confirmed finding.

- [ ] **Step 1: Trace text encryption end to end**

Verify the actual path:

```text
ClipboardStore.addItem
  → CryptoService.encrypt
  → StorageBackend write
  → ClipboardStore load
  → CryptoService.decrypt
  → ClipboardStore cache / UI consumer
```

Check that:

- v2 encryption produces the documented prefix and authenticated ciphertext
- failed encryption cannot persist plaintext
- v2 decryption rejects modified data
- legacy AES-CBC + HMAC data remains readable
- the key file is created with the documented permissions and is not replaced through a TOCTOU path
- constant-time HMAC comparison handles equal, unequal, empty, and different-length values

Run the focused suites:

```bash
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -only-testing:ClipMemoryTests/CryptoServiceTests \
  -only-testing:ClipMemoryTests/IntegrationTests \
  test -destination 'platform=macOS'
```

- [ ] **Step 2: Trace image storage end to end**

Verify the actual path:

```text
ClipboardMonitor image capture
  → ImageStorage.saveImage
  → encrypted file path
  → ClipboardItem.imagePath
  → ImageStorage.loadImage/loadImageObject
  → ClipboardStore cleanup/delete
```

Check PNG and TIFF round trips, corrupted/empty files, encrypted-at-rest bytes, UUID/path traversal rejection, cache behavior, delete behavior, bulk deletion, and orphan cleanup. Run:

```bash
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ImageStorageTests \
  test -destination 'platform=macOS'
```

- [ ] **Step 3: Trace ClipboardStore state transitions**

Check add, deduplication, persistence, restart recovery, trim-to-limit, pin preservation, group clearing, sensitive clearing, decryption failure flags, and cache invalidation. Compare each mutating operation with its corresponding read path; a cache test is not sufficient unless the affected item is subsequently read through the production accessor.

Run:

```bash
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -only-testing:ClipMemoryTests/IntegrationTests \
  test -destination 'platform=macOS'
```

- [ ] **Step 4: Record security findings with evidence**

For each confirmed issue, append a row to `docs/superpowers/audits/2026-07-16-v2.2.4-audit.md`:

```markdown
| ID | Severity | File:line | Input/state | Wrong behavior | Reproduction | Regression test |
|----|----------|-----------|-------------|----------------|--------------|-----------------|
```

For each rejected suspicion, record the source path and the existing test or code invariant that disproves it. Do not silently discard a suspected security issue.

---

### Task 3: Audit capture, concurrency, UI state, and lifecycle paths

**Files:**
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/ClipboardMonitor.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/HotKeyManager.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/LanguageManager.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Services/WindowManager.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/AppDelegate.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Views/ContentView.swift`
- Read: `/Users/iryke/Projects/ClipMemory/ClipMemory/Views/QuickBarView.swift`
- Read: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/ClipboardMonitorTests.swift`
- Read: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/ConcurrencyTests.swift`
- Read: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/HotKeyManagerTests.swift`
- Modify only if a finding is confirmed: the exact source and test files named in the audit report.

**Interfaces:**
- Consumes: the baseline report and the data/security audit findings.
- Produces: confirmed or rejected capture, concurrency, UI-state, lifecycle, and localization findings with reproduction steps.

- [ ] **Step 1: Trace clipboard capture and sensitive detection**

Verify that the monitor:

- ignores its own writes exactly once
- respects excluded bundle IDs
- captures text, links, images, and RTF according to settings
- does not mark images sensitive only because of byte size
- uses the compiled sensitive-pattern cache safely across reads
- forwards the correct metadata to `ClipboardStore`

Run:

```bash
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ClipboardMonitorTests \
  -only-testing:ClipMemoryTests/SensitiveDetectorTests \
  -only-testing:ClipMemoryTests/ConcurrencyTests \
  test -destination 'platform=macOS'
```

- [ ] **Step 2: Audit lock and main-thread boundaries**

For every `ClipboardMonitor` state variable, verify reads and writes use the existing lock. For every `@Published` mutation, verify the mutation occurs on the main thread. For every background task or debounce work item, verify cancellation and lifetime behavior do not publish stale results.

Record any violation with the exact property, caller, queue, and observable failure. Do not replace the current lock strategy with an actor as part of this release.

- [ ] **Step 3: Audit hotkey and window lifecycle**

Verify default configuration loading, partial UserDefaults state, register/update/unregister/re-register behavior, window rebuild behavior, Quick Bar opening, and application termination. The existing `HotKeyManagerTests` and `IntegrationTests` are the regression baseline; add a test only for a confirmed missing behavior.

- [ ] **Step 4: Run a deterministic manual smoke journey**

After a successful Debug build, launch the app from the generated product and verify in order:

1. App launches and the menu-bar item appears.
2. `Cmd+Ctrl+V` opens Quick Bar.
3. Copying ordinary text records one item and copying the same text updates it instead of duplicating it.
4. Search finds the item and copying it back does not immediately re-record the app's own write.
5. A sensitive-looking value is masked and obeys the configured cleanup mode.
6. An image and an RTF item appear in their respective filters and can be copied back.
7. Pin, group clear, unpin, and delete preserve the documented pinned-item behavior.

Record only reproducible failures in the audit report. A launch service warning without a failed user journey is environment-only evidence.

---

### Task 4: Fix the two confirmed SwiftLint warnings

**Files:**
- Modify: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/ClipboardItemTests.swift:230`
- Modify: `/Users/iryke/Projects/ClipMemory/ClipMemory/Views/ContentView.swift:318`
- Test: `/Users/iryke/Projects/ClipMemory/Tests/ClipMemoryTests/ClipboardItemTests.swift`

**Interfaces:**
- Consumes: the existing test and toolbar code; no public API changes.
- Produces: identical runtime behavior with zero SwiftLint warnings for these two findings.

- [ ] **Step 1: Remove the non-optional String-to-Data conversion warning**

Replace the current line:

```swift
let rtfData = try XCTUnwrap("{\\rtf1\\ansi Hello \\b World\\b0}".data(using: .utf8))
```

with:

```swift
let rtfData = Data("{\\rtf1\\ansi Hello \\b World\\b0}".utf8)
```

Keep the surrounding `XCTUnwrap` for `NSAttributedString` unchanged.

- [ ] **Step 2: Remove the unused SwiftLint disable command**

Delete only this line from `ContentView.swift`:

```swift
// swiftlint:disable identifier_name
```

Do not change the `ToolbarItem(id: "search")` implementation.

- [ ] **Step 3: Run the focused checks**

Run:

```bash
swiftlint lint --quiet
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ClipboardItemTests \
  test -destination 'platform=macOS'
```

Expected: SwiftLint prints no warnings; all `ClipboardItemTests` pass.

---

### Task 5: Resolve every confirmed audit finding

**Files:**
- Modify: the exact source files named by confirmed finding IDs in `/Users/iryke/Projects/ClipMemory/docs/superpowers/audits/2026-07-16-v2.2.4-audit.md`
- Test: the exact corresponding XCTest file for each finding
- Modify: the audit report to record the final verification result

**Interfaces:**
- Consumes: confirmed finding IDs from Tasks 1–3.
- Produces: one regression test and one minimal fix per confirmed finding, with no unresolved release blocker.

- [ ] **Step 1: Freeze the finding list before editing behavior**

The audit report must contain a finite list. For each entry, verify all fields are present:

```markdown
ID, severity, file:line, input/state, observed behavior,
reproduction command or manual steps, regression-test name,
planned fix, verification command, final status
```

If Tasks 1–3 produced no confirmed behavior or security findings, record `No confirmed finding` and proceed to Step 4 without inventing a code change.

- [ ] **Step 2: Add each regression test first**

For each finding, add a named XCTest in the closest existing test file. The test must assert the externally observable failure, not an implementation detail. Run the focused test and record the expected failure before changing production code.

- [ ] **Step 3: Apply the smallest production fix**

Change only the code path proven by the source-to-consumer trace. Preserve existing public APIs, macOS 13 support, encryption formats, localization keys, and lock boundaries unless the finding specifically requires otherwise.

- [ ] **Step 4: Run focused then full verification**

For every finding, run its focused test first, then:

```bash
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -configuration Debug \
  test -destination 'platform=macOS'

swiftlint lint --quiet
```

Update the audit report with the actual result. A finding remains open if the regression test is flaky, only passes by changing the assertion, or the full suite fails.

- [ ] **Step 5: Perform the required quality review**

After all behavior changes, review the diff for security, silent failures, unnecessary complexity, and missing tests. If the code change exceeds 30 lines in a single task, run the repository quality gates `verify-change` and `verify-quality` before moving to release metadata.

---

### Task 6: Synchronize `v2.2.4` version metadata and documentation

**Files:**
- Modify: `/Users/iryke/Projects/ClipMemory/project.yml:11-13`
- Modify: `/Users/iryke/Projects/ClipMemory/Scripts/package.sh:1-12`
- Modify: `/Users/iryke/Projects/ClipMemory/README.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/lang/README_EN.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/lang/README_ES.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/lang/README_JA.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/lang/README_KO.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/lang/README_PT.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/lang/README_ZH-HANS.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/lang/README_ZH-HANT.md`
- Modify: `/Users/iryke/Projects/ClipMemory/docs/roadmap.md`
- Generated: `/Users/iryke/Projects/ClipMemory/ClipMemory.xcodeproj/project.pbxproj`
- Modify later with the real package hash: `/Users/iryke/Projects/ClipMemory/Casks/clipmemory.rb`

**Interfaces:**
- Consumes: the completed audit report and the final list of actual fixes.
- Produces: one canonical App version (`2.2.4`), one canonical package version, synchronized documentation, and a Cask entry whose hash is calculated from the final package rather than guessed.

- [ ] **Step 1: Set the canonical XcodeGen version**

Change `project.yml` to:

```yaml
MARKETING_VERSION: "2.2.4"
CURRENT_PROJECT_VERSION: "2.2.4"
```

Do not edit `ClipMemory.xcodeproj/project.pbxproj` manually.

- [ ] **Step 2: Make the packaging default read the canonical version**

Replace the first four lines of `Scripts/package.sh` with:

```bash
#!/bin/bash
# ClipMemory packaging script
APP_NAME="ClipMemory"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=${1:-$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "${PROJECT_DIR}/project.yml")}
OUTPUT_DIR="${PROJECT_DIR}/Releases"
```

Keep the existing argument override so `./Scripts/package.sh 2.2.4` remains valid. Add this guard immediately after `OUTPUT_DIR`:

```bash
if [ -z "${VERSION}" ]; then
    echo "Error: MARKETING_VERSION not found in project.yml" >&2
    exit 1
fi
```

- [ ] **Step 3: Regenerate and verify the project file**

Run:

```bash
xcodegen generate
grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' \
  ClipMemory.xcodeproj/project.pbxproj
```

Expected: every generated app/test configuration reports `2.2.4`.

- [ ] **Step 4: Synchronize README headings and release notes**

Change the title version in all seven README files to `v2.2.4`. Add one `v2.2.4` changelog section whose bullet list is copied from the final confirmed-finding list and the actual release metadata fixes. Keep the seven language files semantically equivalent; do not add a claim not supported by the audit report or git diff.

- [ ] **Step 5: Reconcile roadmap status**

Update `docs/roadmap.md` so its header describes the current state, v2.3 test work reflects the actual tests present in the repository, and v2.4 OCR remains explicitly future work. Remove the duplicate `OSAllocatedUnfairLock → Actor` row while preserving the documented decision to defer it. Set the total estimate to match the remaining roadmap rather than the stale `v2.2 + v2.3` count.

- [ ] **Step 6: Check all metadata references**

Run:

```bash
grep -RInE '2[.]0[.]0|2[.]2[.]0|2[.]2[.]1|2[.]2[.]2|2[.]2[.]3|v2[.]2[.]0|v2[.]2[.]1|v2[.]2[.]2|v2[.]2[.]3' \
  project.yml ClipMemory.xcodeproj Casks Scripts README.md docs/lang docs/roadmap.md
```

Expected: no stale current-version reference remains. Historical changelog entries may retain old versions only where they describe past releases.

---

### Task 7: Build, package, and verify the release candidate locally

**Files:**
- Read/modify only if needed: `/Users/iryke/Projects/ClipMemory/Scripts/package.sh`
- Generated output: `/Users/iryke/Projects/ClipMemory/Releases/ClipMemory.tar.gz`
- Generated copy: `/Users/iryke/Projects/ClipMemory/Homebrew/ClipMemory.tar.gz`
- Modify: `/Users/iryke/Projects/ClipMemory/Casks/clipmemory.rb`

**Interfaces:**
- Consumes: audited and fixed source, generated Xcode project, synchronized `2.2.4` metadata.
- Produces: a locally verified `ClipMemory.tar.gz`, its SHA256, and a Cask entry pointing at the exact future `v2.2.4` asset.

- [ ] **Step 1: Run all automated local gates**

Run:

```bash
swiftlint lint --quiet
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -configuration Debug \
  test -destination 'platform=macOS'
xcodebuild -project ClipMemory.xcodeproj \
  -scheme ClipMemory \
  -configuration Release \
  build
```

Expected: SwiftLint emits no warnings, all tests pass, and the Release build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Package exactly `2.2.4`**

Run:

```bash
cd /Users/iryke/Projects/ClipMemory
./Scripts/package.sh 2.2.4
```

Expected files:

```text
/Users/iryke/Projects/ClipMemory/Releases/ClipMemory.tar.gz
/Users/iryke/Projects/ClipMemory/Homebrew/ClipMemory.tar.gz
```

- [ ] **Step 3: Verify package contents and embedded version**

Run:

```bash
tar -tzf Releases/ClipMemory.tar.gz | grep -E '^ClipMemory.app/Contents/(Info.plist|MacOS/ClipMemory)$'
APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData/ClipMemory-"*/Build/Products/Release -name ClipMemory.app -print -quit)"
defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString
defaults read "${APP_PATH}/Contents/Info.plist" CFBundleVersion
```

Expected: the archive contains the app executable and `Info.plist`, and both version values are `2.2.4`.

- [ ] **Step 4: Update the Cask from the actual artifact**

Run:

```bash
SHA256="$(shasum -a 256 Releases/ClipMemory.tar.gz | cut -d ' ' -f 1)"
printf '%s\n' "${SHA256}"
```

Set `Casks/clipmemory.rb` to version `2.2.4` and the printed SHA256. Verify the URL is exactly:

```text
https://github.com/irykelee/clipmemory/releases/download/v2.2.4/ClipMemory.tar.gz
```

Do not fabricate or reuse the old `v2.2.0` hash.

- [ ] **Step 5: Run repository checks before staging**

Run:

```bash
git diff --check
git status --short
brew audit --cask Casks/clipmemory.rb
```

Expected: no whitespace errors, only intended files/artifacts are changed, and Homebrew audit reports no Cask syntax error. Do not install the cask into the production machine as a test.

---

### Task 8: Final release gate and v2.2.4 publication

**Files:**
- Create directory: `/Users/iryke/Projects/ClipMemory/docs/superpowers/release-notes/`
- Create: `/Users/iryke/Projects/ClipMemory/docs/superpowers/release-notes/2026-07-16-v2.2.4.md`
- Publish: `/Users/iryke/Projects/ClipMemory/Releases/ClipMemory.tar.gz`
- Publish: existing `v2.2.4` source state and Cask metadata

**Interfaces:**
- Consumes: the completed audit report, passing local release candidate, package SHA256, and final diff.
- Produces: a GitHub `v2.2.4` release with a downloadable `ClipMemory.tar.gz`, while leaving `v2.2.3` unchanged.

- [ ] **Step 0: Create the release-notes directory**

Run:

```bash
mkdir -p /Users/iryke/Projects/ClipMemory/docs/superpowers/release-notes
```

Expected: the directory exists and is ready for the factual release notes.

- [ ] **Step 1: Write factual release notes**

Create `/Users/iryke/Projects/ClipMemory/docs/superpowers/release-notes/2026-07-16-v2.2.4.md` from the final audit report. Include only confirmed changes and these exact sections:

```markdown
# ClipMemory v2.2.4

## 修复

## 发布与兼容性

## 验证
```

The `修复` section must name each confirmed issue and affected behavior. The `发布与兼容性` section must state that `v2.2.3` was preserved and that the package is for macOS 13+. The `验证` section must contain the observed test count, SwiftLint result, Release build result, and final SHA256.

- [ ] **Step 2: Produce the final release checklist**

Run:

```bash
git status --short --branch
git diff --check
git diff --stat
grep -RInE '2[.]0[.]0|2[.]2[.]0|2[.]2[.]1|2[.]2[.]2|2[.]2[.]3|v2[.]2[.]0|v2[.]2[.]1|v2[.]2[.]2|v2[.]2[.]3' \
  project.yml ClipMemory.xcodeproj Casks Scripts README.md docs/lang docs/roadmap.md
```

The checklist must explicitly show:

- no confirmed audit finding remains open
- SwiftLint is clean
- full tests pass
- Release build and package version are `2.2.4`
- Cask SHA256 matches `Releases/ClipMemory.tar.gz`
- `v2.2.3` remains unchanged
- the new Release will contain the package asset

- [ ] **Step 3: Confirm the external release action**

Before `git push` or `gh release create`, show the user the final checklist and the exact package path:

```text
/Users/iryke/Projects/ClipMemory/Releases/ClipMemory.tar.gz
```

Do not publish if any local gate is red or if the user has not confirmed the final release action.

- [ ] **Step 4: Create the release commit and tag from the verified state**

After final confirmation, stage only the intended source, test, documentation, Cask, generated project, audit, plan/spec, and release-notes files. Run the repository pre-commit hook, then create a conventional commit whose body lists the confirmed fixes and verification commands. Create the annotated tag with `git tag -a v2.2.4 -m "Release v2.2.4"` from that commit without changing `v2.2.3`.

- [ ] **Step 5: Push and create the GitHub Release**

After the commit and tag are locally verified:

```bash
git push origin main
git push origin v2.2.4
gh release create v2.2.4 \
  Releases/ClipMemory.tar.gz \
  --title '剪忆 ClipMemory v2.2.4' \
  --notes-file /Users/iryke/Projects/ClipMemory/docs/superpowers/release-notes/2026-07-16-v2.2.4.md
```

The notes must contain only confirmed changes from the audit report.

---

### Task 9: Verify the published release and close the audit

**Files:**
- Modify: `/Users/iryke/Projects/ClipMemory/docs/superpowers/audits/2026-07-16-v2.2.4-audit.md`
- Read: `/Users/iryke/Projects/ClipMemory/Casks/clipmemory.rb`
- Read: published GitHub `v2.2.4` metadata

**Interfaces:**
- Consumes: the published tag, release asset, package hash, and final repository state.
- Produces: a closed audit report with evidence that the published asset, source version, Cask, and docs agree.

- [ ] **Step 1: Verify GitHub Release metadata and asset**

Run:

```bash
gh release view v2.2.4 --json tagName,name,publishedAt,assets,url
```

Expected: tag `v2.2.4` exists and `assets` contains `ClipMemory.tar.gz`.

- [ ] **Step 2: Download and hash-check the published asset in a temporary directory**

Run:

```bash
TMP_DIR="$(mktemp -d)"
gh release download v2.2.4 --pattern 'ClipMemory.tar.gz' --dir "${TMP_DIR}"
shasum -a 256 "${TMP_DIR}/ClipMemory.tar.gz"
shasum -a 256 Releases/ClipMemory.tar.gz
rm -rf "${TMP_DIR}"
```

Expected: the two SHA256 values are identical. Do not use the production application-data directory for this check.

- [ ] **Step 3: Verify the old tag was not rewritten**

Run:

```bash
git fetch origin --tags
git rev-parse v2.2.3
git show-ref --tags v2.2.3 v2.2.4
```

Expected: `v2.2.3` still resolves to its pre-existing commit and `v2.2.4` resolves to the verified release commit.

- [ ] **Step 4: Close the audit report**

Append this section using the exact values printed by the completed commands:

```markdown
## Final result

- Audit findings: use the confirmed-finding count from the audit report
- Tests: use the exact xcodebuild test count followed by `passed`
- SwiftLint: clean
- Release build: succeeded
- Package SHA256: use the final hash printed from `Releases/ClipMemory.tar.gz`
- GitHub asset: verified
- v2.2.3 history: preserved
- v2.2.4 status: published
```

Before marking the task complete, replace the three instructional values with their observed values in the report. Then run:

```bash
git status --short --branch
git log --oneline --decorate -3
```

The repository must be clean except for intentionally retained local build artifacts that are ignored by Git.

---

## Plan self-review

- **Spec coverage:** Tasks 1–3 cover baseline, complete data/security flow, capture/concurrency/UI/lifecycle paths; Task 4 covers the two known lint warnings; Task 5 covers confirmed audit findings; Task 6 covers version/docs/Cask sources; Tasks 7–9 cover build, package, release, and post-release verification.
- **Scope:** OCR, SQLite, DI redesign, and unrelated refactoring are explicitly excluded.
- **Version consistency:** `project.yml` is the canonical source; XcodeGen regenerates `project.pbxproj`; packaging reads the canonical version; Cask uses the actual final artifact hash.
- **History safety:** the plan never moves or deletes `v2.2.3`.
- **Placeholder scan:** runtime-generated values are explicitly produced before use and replaced with observed values in the audit report and release notes; no unresolved implementation step remains.
