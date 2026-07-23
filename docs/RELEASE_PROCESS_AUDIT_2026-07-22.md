# ClipMemory Release Process Audit — 2026-07-22

**Date:** 2026-07-22
**Triggered by:** v2.5.10 release (commit `4a9a9d1`, tag `v2.5.10`)
**Status:** Audit complete; remediation queued for next session (2026-07-23)
**Scope:** End-to-end release process review — code commit → CI/CD → automated tests → build/package → pre-release verify → canary → full rollout → monitoring → rollback

---

## 1. Push Flow Problems Exposed (root cause + impact)

### P0 — Blocking

| # | Problem | Root Cause | Impact |
|---|---|---|---|
| **1** | GH Actions Release workflow failed at step 10 ("Sign tarball and update appcast") | `git pull --rebase origin main` (release.yml:108) assumes main contains tag's ancestors + current content. Fix branch was ahead of main by 17 commits; rebase attempted to apply each commit onto stale file state → 30+ `CONFLICT (add/add)` | Entire release flow blocked; required manual force-push main (user explicit OK + `--force-with-lease`) to resolve |
| **2** | Workflow has no fallback for "tag branch ahead of main" scenario | Workflow design assumes linear history where main always contains everything in the tagged commit | Next release (v2.5.11+) will fail the same way unless fix branch is rebased onto main before tagging |
| **3** | Workflow creates GH Release with auto-stub title "v2.5.10" | `softprops/action-gh-release@v3` + `generate_release_notes: true` defaults title to tag name when no `title:` param passed | Violates `release-push-checklist.md` §D3 bilingual title requirement; required manual `gh release edit --title "..." --notes-file ...` after workflow |
| **4** | Local `Scripts/package.sh` sha256 ≠ CI workflow sha256 | Local macOS SDK + codesign differs from `macos-latest` runner → binary byte-level differs → tarball sha differs | Local Cask is always stale; tap Cask is always from CI; local Cask commit may look correct but actually wrong |

### P1 — Significant friction

| # | Problem | Root Cause | Impact |
|---|---|---|---|
| **5** | `gh release view v2.5.10` intermittently returns "release not found" + exit 1; but `gh release list` and direct API work fine | gh CLI cache/token refresh issue | verify script D3 check unreliable; release was correctly published but script reports "not yet published" |
| **6** | Force-push to main was required to recover from workflow design flaw | Workflow's "pull main + rebase appcast commit" assumption fails without fallback to "push directly to main" | Irreversible operation; violates "minimize force-push to main" GitOps best practices; needs user explicit OK + risk explanation |
| **7** | 7-language native speaker review gate was skipped by user | `release-push-checklist.md` §7 is hard requirement but has no enforcement gate | Controller-supplied draft shipped without native validation; bugs surface only when real users encounter them (v2.5.7 lesson: 5 channels missed) |
| **8** | No automated post-release bilingual title detection | Workflow doesn't self-check if title is bilingual | Each release requires human verify; if verify forgotten, stub leak (as in this release) |
| **9** | Workflow auto-updates appcast.xml via `git config user.name "github-actions[bot]"` + direct push main (release.yml:99-109) | Workflow assumes only appcast.xml changes; but xcodegen may regenerate other files | In v2.5.10 case, step 10 failed → appcast not updated (the CI run's appcast was in `4a9a9d1` commit, never pushed to main) |
| **10** | Cask update uses inline heredoc in workflow (release.yml:136-164) | Doesn't reference source file; relies on hand-maintained string template | When Cask template changes (e.g., adding `livecheck` block), workflow drifts from reality |

### P2 — Tech debt

| # | Problem | Root Cause | Impact |
|---|---|---|---|
| **11** | `pre_push_verify.sh` D3 check uses `gh release view` (unstable subcommand) | verify script hardcodes the unreliable subcommand | D3 flakes forever |
| **12** | Both `package.sh` (local) and workflow write Cask | Two parallel mechanisms | Unclear which is source of truth; local Cask commits get immediately superseded by CI build |
| **13** | `xcodegen generate` runs in both workflow and locally | Same command at two sites | `project.pbxproj` drifts; local may commit old version, CI generates new |
| **14** | verify script doesn't check "local Cask sha256 matches local tarball" | verify assumes local Cask = release Cask | This release's commit `4a9a9d1` has sha `e09f87...` while CI has `d8af1b...` — verify didn't catch |
| **15** | No branch protection on main | No required PR + CI pass + review | Force-push main had no review guardrail |
| **16** | Long-lived feature branches severely drift from main | `fix/v2.5.10-hotfix-batch` accumulated 17 commits in 14 weeks without merge to main | Workflow's rebase assumption fails |
| **17** | No automated "verify GH Release body contains bilingual section" | Workflow creates release but doesn't validate content | Every release depends on manual verify |
| **18** | No `livecheck` block in Cask | Both local and workflow heredoc don't write it | Homebrew users won't auto-detect new versions (only via Sparkle in-app) |
| **19** | No `workflow_dispatch` dry-run mode | workflow only triggers on tag push | Can't test workflow changes without actually releasing |
| **20** | No post-release health check | Release publish ends workflow | Critical bug requires user report to discover |
| **21** | No Slack/email/notification on release publish | Workflow has no notification step | Must actively check GH UI to know release succeeded |
| **22** | No rollback runbook | No documentation exists | Critical bug → search memory / trial-and-error |
| **23** | No SBOM / provenance attestation | No sigstore/cosign integration | Supply chain security compliance gap |
| **24** | No staged rollout / canary | Sparkle feed directly 100% push to all users | Can't control distribution speed |

---

## 2. End-to-End Process Evaluation (8 stages)

### Stage 1: Code Commit
- **Current:** Manual `git add` + `git commit`; each commit runs pre-commit 3-check (file size, sensitive patterns, field names)
- **Weaknesses:**
  - No conventional commits enforcement
  - No changeset / release-please auto-tracking
  - Version bumps are manual `sed project.yml` (this release: 1 line human edit)
- **Improvements:**
  - Add `release-please` or `semantic-release`: auto-generate CHANGELOG + bump version from conventional commits
  - Add `commitlint` to pre-commit hook for conventional commits format

### Stage 2: CI/CD Pipeline (GH Actions)
- **Current:** `ci.yml` + `release.yml` two workflows
- **Weaknesses:**
  - No build matrix (single Xcode/macOS version)
  - `release.yml` only triggers on tag; no preview mode
  - Cask content hardcoded in workflow (line 136-164); Cask template change requires workflow edit
  - No SBOM, provenance, signed commits
- **Improvements:**
  - Add `workflow_dispatch` with `[dry_run=true]` input → test workflow without releasing
  - Externalize Cask template (`Casks/clipmemory.rb.template`) + workflow renders values
  - Add `slsa-framework/slsa-github-generator` for provenance
  - Add build matrix: `macos-14` + `macos-15` parallel

### Stage 3: Automated Tests (XCTest + Snapshot)
- **Current:** 400 tests; snapshot tests for 5 views (WelcomeView / ClipboardItemRow / SettingsView / SidebarView / TrashItemRow)
- **Weaknesses:**
  - QuickBarView snapshot impossible (ImageRenderer can't render `List(.sidebar)`)
  - No runtime warning test (BUG-009 "Modifying state during view update" is runtime warning, not XCTest-assertable)
  - No UI test for BUG-024 alert path
  - Snapshot baseline is PNG (gitignored), auto-record-on-missing works but no PR-time visual diff
- **Improvements:**
  - Add runtime warning capture via XCTObservation + console.log filter → BUG-009-class warnings testable
  - Add XCUITest for BUG-024 import error alert path
  - Publish snapshot baseline to GH Pages / artifact for PR-time visual diff

### Stage 4: Build & Package (xcodebuild + package.sh)
- **Current:** xcodebuild Release + package.sh tarball + sha256 + Cask update
- **Weaknesses:**
  - Local package.sh ≠ CI tarball sha256 (known)
  - package.sh writes sha256 into Cask → conflicts with CI workflow
  - No reproducible build (timestamp in binary)
  - No codesign hardening verification (self-signed is known limit)
- **Improvements:**
  - **Critical:** Move Cask update to CI-only; local package.sh only computes local sha for verify (no Cask write)
  - Use `SOURCE_DATE_EPOCH` for reproducible build
  - Add codesign verify step before package

### Stage 5: Pre-release Verification (pre_push_verify)
- **Current:** Single script checks 5 items (MARKETING_VERSION / README H1 / Cask / gh release / sha)
- **Weaknesses:**
  - D3 uses unstable `gh release view`
  - Doesn't check "local Cask sha == tarball sha"
  - Doesn't check "local branch HEAD == remote tag HEAD"
  - Doesn't check "7 language README changelog contains v$VERSION"
  - Doesn't check "7 .lproj settings.backup.import.result uses all 4 placeholders"
- **Improvements:**
  - D3 → `gh api repos/$OWNER/$REPO/releases/tags/$TAG --jq .name`
  - Add sha256 cross-check: local tarball sha == remote release asset sha == tap Cask sha
  - Add i18n placeholder check (`grep '%1$d.*%2$d.*%3$d.*%4$d' per file`)
  - Add "README changelog 包含 v$VERSION" per language check
  - Add "branch ahead/behind main" pre-check

### Stage 6: Canary / Staged Rollout
- **Current:** ❌ **Nonexistent**
- **Weaknesses:**
  - Sparkle feed directly 100% push to all users
  - No staged rollout (% users receiving new version)
  - No beta channel mechanism
- **Improvements:**
  - Add Sparkle `phased rollout` config (10% → 50% → 100%)
  - Use `sparkle:criticalUpdateSince` metadata for critical bug fixes (skip rollout)
  - Add `<sparkle:phasedRollout>` element in appcast.xml

### Stage 7: Full Release (push tag → GH release → tap update)
- **Current:** Tag push triggers workflow; workflow runs build/package/sign/appcast/release/tap; auto-stub title needs manual fix
- **Weaknesses:**
  - workflow step 10 fails without fallback
  - GH release title is stub → manual `gh release edit` required
  - No post-release automated verification
- **Improvements:**
  - **Critical:** Replace workflow's `git pull --rebase origin main` with "rebase on `origin/$TAG` or open appcast-only PR"
  - Pass `title:` to softprops/action-gh-release with bilingual template
  - Add post-release verification step:
    ```yaml
    - name: Verify release
      run: |
        TITLE=$(gh api repos/$REPO/releases/tags/$TAG --jq .name)
        case "$TITLE" in v*) exit 1 ;; esac  # fail if stub
        BODY=$(gh api .../releases/tags/$TAG --jq .body)
        echo "$BODY" | grep -q "中文" && echo "$BODY" | grep -q "English" || exit 1
    ```

### Stage 8: Monitoring & Alerting
- **Current:** ❌ **Nonexistent** (beyond manual GH Issues watching)
- **Weaknesses:**
  - No Sparkle update telemetry (don't know how many users received v2.5.10)
  - No crash reporting (v2.5.10 crashes only surface via user complaints)
  - No release health check (24h post-release issue spike detection)
- **Improvements:**
  - Connect `os_log` → `OSLogStore` → backend (Sentry or self-hosted)
  - Hook `SUUpdaterDelegate` for download/install events
  - Post-release 24h: auto-generate GH Issue template "v2.5.10 experience feedback"
  - Release health dashboard (GH Actions workflow output + visualization)

### Stage 9: Rollback Mechanism
- **Current:** ❌ **No documentation**
- **Weaknesses:**
  - No procedure to yank a release
  - No procedure to revert Cask tap
  - No procedure to force Sparkle feed back to previous version
  - No emergency hotfix flow defined
- **Improvements:**
  - Write `docs/RELEASE_ROLLBACK.md` runbook
  - Prepare `Scripts/yank_release.sh vX.Y.Z`: hide release + revert tap + force Sparkle to previous
  - Critical hotfix template: `hotfix/vX.Y.Z.N` branch → cherry-pick fix → tag → push
  - Release monitoring: crash spike detection → auto-page on-call

---

## 3. Prioritized Improvement Plan

### P0 — Must-fix (before next release)

| ID | Change | Effort | Risk |
|---|---|---:|---|
| **P0-1** | Fix release.yml step 10: remove `git pull --rebase origin main`; use "push appcast commit via squash/rebase on appcast-only branch" or drop auto appcast update (manual commit) | 2h | Low (doesn't break current happy path) |
| **P0-2** | release.yml softprops action: add `title:` parameter (bilingual template) | 30min | Very low |
| **P0-3** | Add post-release verification step (fail if title is stub or body not bilingual) | 1h | Very low |
| **P0-4** | Modify package.sh: **don't write Cask** (CI only); local only computes sha for verify | 30min | Low |
| **P0-5** | pre_push_verify D3: switch to `gh api` + `--jq .name` (replace unstable `gh release view`) | 15min | Very low |
| **P0-6** | pre_push_verify: add i18n placeholder + README changelog + branch ahead/behind pre-checks | 2h | Very low |
| **P0-7** | Branch protection on main: require CI pass + 1 review | 30min | Medium (affects current workflow) |

### P1 — Important (this quarter)

| ID | Change | Effort | Risk |
|---|---|---:|---|
| **P1-1** | Externalize Cask to template file (`Casks/clipmemory.rb.template`), workflow renders values | 3h | Low |
| **P1-2** | Add `workflow_dispatch` dry-run mode (input: dry_run=true) | 4h | Medium |
| **P1-3** | Add `release-please` for auto CHANGELOG + version bump (switch to conventional commits) | 8h | Medium |
| **P1-4** | Add Sparkle phased rollout (10% → 50% → 100%) | 4h | Low |
| **P1-5** | Write `docs/RELEASE_ROLLBACK.md` + `Scripts/yank_release.sh` | 4h | Very low |
| **P1-6** | Add snapshot runtime warning capture (XCTObservation) for BUG-009-class warnings | 6h | Low |
| **P1-7** | CI build matrix: macos-14 + macos-15 parallel | 2h | Low |

### P2 — Medium-term

| ID | Change | Effort | Risk |
|---|---|---:|---|
| **P2-1** | Connect `os_log` telemetry (self-hosted or Sentry) | 2-3 days | High (data compliance) |
| **P2-2** | Migrate to Developer ID signing (replace self-signed) | 1 day + Apple account | Medium |
| **P2-3** | SBOM + SLSA provenance attestation | 2 days | Low |
| **P2-4** | Post-release health dashboard (24h issue spike detection) | 3 days | Medium |
| **P2-5** | Emergency hotfix flow template (`hotfix/vX.Y.Z.N` + cherry-pick + tag + push) | 1 day | Medium |

---

## 4. Suggested Pre-Release Verification Checklist (pre_push_verify.sh v2)

```bash
# A: Version consistency
✅ A1: project.yml MARKETING == CURRENT_PROJECT == 2.5.10
✅ A1+: branch HEAD == tag commit (no drift)

# B: Documentation
✅ A2: 7 README H1 == v2.5.10
✅ A2+: 7 README changelog section 包含 "v2.5.10" + 3 bullets (no orphan H1)
✅ A2+: 7 README changelog bullets 对应 3 个 work items (grep -c "BUG-024" 等)

# C: i18n
✅ A3: 7 .lproj settings.backup.import.result 包含 4 个 %X$d placeholder
✅ A3+: 7 .lproj placeholder 顺序 %1 → %2 → %3 → %4 (regex)

# D: Cask
✅ A4: Casks/clipmemory.rb version == 2.5.10
✅ A4+: Casks/clipmemory.rb sha256 (if filled) == local Releases/ClipMemory.tar.gz sha256

# E: GH Release (post-push phase)
✅ D3: gh api releases/tags/v2.5.10 --jq .name 包含 zh-Hans + English 字符
✅ D3+: release body 包含 "中文" + "English" section headers
✅ D3+: release asset appcast.xml + ClipMemory.tar.gz 都 attach
✅ D3+: tarball sha256 (release asset) == tap Cask sha256
```

## 5. Suggested PR/Merge Checklist

```markdown
## Pre-merge to main
- [ ] Branch ahead of main (rebase or merge if > 5 commits)
- [ ] CI green (build + test + lint)
- [ ] pre_push_verify.sh green at current version
- [ ] 7-language native speaker review PASS or user waiver recorded
- [ ] Release notes draft ready (zh-Hans + English)
- [ ] Branch protection rules allow this merge
```

---

## 6. Single Point of Failure (SPOF) Assessment

| SPOF | Current Backup | Risk |
|---|---|---|
| GH Actions self-hosted runners | None (use GitHub-provided macos-latest) | Low (GH SLA high) |
| Sparkle EdDSA private key | Only GH Secret | **HIGH** (loss = lose update capability; recommend cold backup + documented recovery) |
| `github-actions[bot]` write permission | Only GH token | Medium |
| `TAP_GITHUB_TOKEN` | Only GH Secret | Medium |
| Self-signed cert 2027-07 expiry | None | **HIGH** (must re-export + re-secrets before expiry; per memory) |
| `~/.claude/projects/-Users-iryke/memory/` | None (local only) | **HIGH** (machine failure = memory loss) |
| Local Cask sha256 | None | Low (CI is source of truth) |

---

## 7. Summary

Core problems exposed by v2.5.10 push:
1. **Release workflow design assumption error** (branch ahead of main not handled) → required path 1 force-push main
2. **Local vs CI build inconsistency** → `package.sh` Cask update is forever stale
3. **7-language native speaker review gate has no enforcement** → easy to bypass without automatic retry

P0 priority fixes (7 items / ~7 hours work):
- Fix workflow (`P0-1`)
- Make verify actually reliable (`P0-5`, `P0-6`)
- Add branch protection (`P0-7`)
- Stop Cask drift (`P0-4`)
- Bilingual title in workflow (`P0-2`, `P0-3`)

**Next session priority:** execute P0 fixes in order, then re-attempt v2.5.11 (or v2.5.10.1 hotfix) release with hardened workflow.

---

## 8. Cross-References

- `docs/RELEASE_PUSH_CHECKLIST.md` — single-page 5-section checklist (existing, unchanged)
- `docs/RELEASE.md` — full 12-step prose form (existing, unchanged)
- `~/.claude/projects/-Users-iryke/memory/feedback/release-push-checklist.md` — memory rule enforcing 5 sections + 7-language native review gate (existing, unchanged)
- `~/.claude/projects/-Users-iryke/memory/clipmemory/sparkle-architecture.md` — Sparkle update feed architecture (existing, unchanged)
- `~/Documents/session-resume/2026-07-22.md` v4 — session log including v2.5.10 release details (updated this session)
