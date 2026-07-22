# Release / Push Checklist (Single-Page)

> **Why this exists**: Today (2026-07-20) the AI pushed 13 commits + tag v2.5.7 and declared "all done". The user then had to ping **4 separate times** to surface: release page auto-stub, Casks file stale, README changelog missing, Chinese section had English titles, 5 lang READMEs missing entries. Total: 5 missed channels. The 12-step `docs/RELEASE.md` flow is correct but hidden — Claude can't eyeball-check 12 paragraphs. This file is the **single-page, all-checkboxes-at-once, executable** version.
>
> **Rule**: Before `git push origin vX.Y.Z`, run through every checkbox below. After tag push, run all post-push verifies. Mark each `[x]` in real-time; missing = bug.
>
> **Automation**: `Scripts/pre_push_verify.sh` automates the local checks below. Even if it returns green, **do not skip the manual sections** (release page content, GH Actions verify, tap repo) — those need eyes.

---

## A. Local preparation (BEFORE commit)

### A1. Version + project config

- [ ] `project.yml` `MARKETING_VERSION` bumped to new version
- [ ] `project.yml` `CURRENT_PROJECT_VERSION` bumped (same value as MARKETING_VERSION)
- [ ] `xcodegen generate` re-run (only after project.yml change)

### A2. 8 README files (per `docs/RELEASE.md` B1.2)

For each of: `README.md`, `docs/lang/README_{EN,ZH-HANS,ZH-HANT,JA,KO,ES,PT}.md` (8 total):

- [ ] H1 title line `# <name> vX.Y.Z` updated
- [ ] Changelog section (e.g. `## 📋 更新日志` / `## 📋 Changelog`) has a new `### vX.Y.Z (date) — <title>` entry
- [ ] Entry has 3-5 user-perspective bullets, in **the file's primary language** (don't put English titles in 中文 section)
- [ ] Style matches existing v2.5.6 / v2.5.5 entries (same emoji conventions, same depth, same level of detail)

### A3. Release notes (per `docs/RELEASE.md` B1.2 + `docs/release-notes-template.md`)

- [ ] `docs/release-notes/vX.Y.Z.md` exists (new file)
- [ ] H1 is bilingual: `剪忆 ClipMemory vX.Y.Z — <English title> / <中文标题>` (per template)
- [ ] 中文 section: titles in Chinese, descriptions in Chinese
- [ ] English section: titles in English, descriptions in English
- [ ] Both sections mirror each other in scope (3 highlights, 4 fixes, 1 upgrade note)
- [ ] Install / Install note section present
- [ ] Technical section: commits list + full-changelog URL

### A4. Cask (per `docs/RELEASE.md` B4.11)

- [ ] Live Cask check: `curl -s https://raw.githubusercontent.com/irykelee/homebrew-clipmemory/main/Casks/clipmemory.rb | grep version` shows new version (this is the source of truth)
- [ ] Tap Cask sha256 == release tarball sha256 (cross-check via `gh release download vX.Y.Z` → `shasum -a 256`)
- [ ] Local `Casks/clipmemory.rb` (reference template only): Ruby 语法有效即可（`ruby -c Casks/clipmemory.rb`）；版本/sha 不再要求本地同步（per P0-4 in `docs/RELEASE_PROCESS_AUDIT_2026-07-22.md`）

### A5. Pre-flight (per `docs/RELEASE.md` B1.3)

- [ ] `Scripts/preflight.sh --tests` runs all-green
- [ ] `xcodebuild -scheme ClipMemory -configuration Release build` succeeds
- [ ] `codesign -dv` on built .app shows correct Authority (e.g. `Apple Development (Personal Team, Team ID ...)`)

---

## B. Commit (atomic where possible)

- [ ] Single commit for project.yml + release-notes file (if any)
- [ ] Single commit for 8 README sync
- [ ] Single commit for Casks file (with `git commit --amend` if the sha changed mid-process)
- [ ] Pre-commit hook (file-size / sensitive-pattern / field-name) passes — never `--no-verify`

---

## C. Push + Tag (per `docs/RELEASE.md` B2.5-6)

- [ ] `git fetch origin` to check for new remote commits
- [ ] `git pull --rebase origin main` if needed (resolves any conflicts in `appcast.xml` from GH Actions pipeline)
- [ ] `git push origin main` — user explicit confirmation required
- [ ] `git tag vX.Y.Z` (lightweight; or `git tag -a` if project uses annotated — check `docs/RELEASE.md` B2.6)
- [ ] `git push origin vX.Y.Z`

---

## D. GitHub Release + GH Actions (per `docs/RELEASE.md` B3.7-9 + B4.10)

- [ ] `gh run list --workflow=Release` — must show "completed success" for new commit
- [ ] `gh release view vX.Y.Z`:
  - [ ] Title is **bilingual** (`剪忆 ClipMemory vX.Y.Z — <English> / <中文>`), NOT auto-generated `vX.Y.Z` stub
  - [ ] Body has Highlights / Fixes / Upgrade Note sections in both languages
  - [ ] Assets: `appcast.xml` + `ClipMemory.tar.gz` both present
- [ ] `gh release edit vX.Y.Z --notes-file docs/release-notes/vX.Y.Z.md --title "剪忆 ClipMemory vX.Y.Z — ..."`
- [ ] Verify `appcast.xml` has new `<item>` with `edSignature` (in main branch)
- [ ] Verify external tap repo `irykelee/homebrew-clipmemory` updated (per B3.9) — `curl -s https://raw.githubusercontent.com/irykelee/homebrew-clipmemory/main/Casks/clipmemory.rb | grep version`

---

## E. Local cleanup (per `docs/RELEASE.md` B4.12)

- [ ] `STATUS.md` updated with new version status
- [ ] Session-resume `~/Documents/session-resume/YYYY-MM-DD.md` updated (Round N appended)
- [ ] `~/Documents/session-resume/` cumulative memory updated
- [ ] `~/.claude/projects/-Users-iryke/memory/MEMORY.md` index updated (if new memory rules added)

---

## Anti-patterns (lessons from 2026-07-20)

| Mistake | What it cost | Avoid by |
|---|---|---|
| Declared "all done" after 13 commits without release page check | User had to ping 4 times | **Verify all D1-D6 channels BEFORE declaring done** |
| Mixed English in 中文 section of release notes | Visual / branding broken | **Each language section is monolingual** — per `docs/release-notes-template.md` |
| Bumped README header but skipped changelog section | User ping 2 | **A2 is 2-checkboxes per file**: line + changelog entry, not just one |
| Skipped 5 non-source language READMEs as "follow-up" | User ping 3 | **8 README updates in one batch** — one commit, all languages |
| Cask file was stale at v2.5.6 after push | User ping 1 | **A4 (Cask) is part of pre-push verify**, not post-push |
| Left `gh release view` title as auto-stub "v2.5.7" | Visible in public release | **D3 explicit check**: title must be bilingual, not stub |

---

## Auto-verify script

`Scripts/pre_push_verify.sh` automates: project.yml version check, 8 README H1 sync, Cask version sync, `gh release view` title content. **Run before tagging**. Even when green, **manual sections A2-changelog / A3-translation / D5-tap** still need human eyes (the script doesn't read Chinese nuances).
