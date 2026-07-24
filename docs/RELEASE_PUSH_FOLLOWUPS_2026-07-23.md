# Release / Push 流程后续优化 — 2026-07-23 Ship Review

> **目的**: 落地 2026-07-23 v2.5.11 ship review 中识别出的剩余 push 流程优化项。
> **状态**: 实施完成（D2 待 permission），未 commit / 未 push。
> **触发上下文**: v2.5.10 + v2.5.11 两次 ship 都耗时 20-25 min + 出问题（README 重复、release.yml race、local main divergence、auto-stub title）。本次针对每个具体痛点加解决方案。

---

## 实施记录（已落地，未 commit）

### A1. 6 lang README 重复 v2.5.11 块清理 + sync_readme.py dedupe re-apply

**痛点**：sync_readme.py 之前只 `insert_section()`，不查重。每次 release 跑两次 → 6 lang README 各有 2 个 v2.5.11 块（v2.5.10 + v2.5.11 都中招）。

**修复**：
- `Scripts/sync_readme.py`：新增 `remove_existing_section(text, version)` + `section_version(section)` helper；`insert_section()` 加 precondition assert（重复 version 抛 ValueError，不再静默 append）；main loop 在 insert 前调 `remove_existing_section`
- `docs/lang/README_{EN,JA,KO,ES,PT,ZH-HANT}.md`：删每个文件 line 95 的重复 `### v2.5.11` 块，保留 line 51 的版本（verify: `grep -c "^### v2.5.11" README.md docs/lang/README_*.md` 全部 =1）

### B1+B2+C1+C2+C3+C4+D1. release.yml 综合优化（7 项）

| ID | 变更 | 预期收益 |
|----|------|----------|
| B1 | `actions/cache@v4` 缓存 `~/Library/Caches/Homebrew` + `/tmp/sparkle{-dl,}` + `~/Library/Developer/Xcode/DerivedData`，key on `hashFiles('project.yml','project.pbxproj','ClipMemory/Package.resolved')` + sparkle version | 省 60-180s/release |
| B2 | 新增 `Run tests` step（`xcodebuild test`）在 `Build Release` 之前 | 测试失败 → 不打包不 publish（fail-fast） |
| C1 | 新增 `Pre-release verify` step 在 `Create GitHub Release` 之前：检查 `docs/release-notes/vX.Y.Z.md` 有 `## 中文` + `## English` + `project.yml` MARKETING_VERSION 一致 + 7 lang README 无重复 | release **未发布** 就 catch 问题（vs 当前 P0-3 是 publish 后才 catch） |
| C2 | `on.pull_request.paths: '.github/workflows/release.yml'` + publish 步骤加 `if: github.event_name == 'push'` 守卫 | 改 release.yml 有 CI 验证（dry-run） |
| C3 | Sparkle tools `gh release download --tag 2.9.4`（pin 到 project.yml 一致的版本） | 防止 Sparkle latest 静默破坏 CI |
| C4 | xcodegen install step 加 `if which xcodegen` 短路 | cache hit 时省 brew install |
| D1 | job-level `concurrency: group: release-${{ github.ref }}, cancel-in-progress: false` | 防多 tag race appcast push |

### B4. safe_push.sh wrapper（绕过 core.hooksPath global）

**痛点**：core.hooksPath 是 `/Users/iryke/bin/git-hooks`（global，含 3-check pre-commit），阻塞 repo-local pre-push hook 接 `pre_push_main_sync.sh`。

**修复**：新增 `Scripts/safe_push.sh` wrapper — run `pre_push_main_sync.sh` 然后 `exec git push "$@"`。

**使用方式**（任选其一）：
```bash
# 直接用
bash Scripts/safe_push.sh origin main
bash Scripts/safe_push.sh origin v2.5.12

# 或配置 git alias（一次性，本机）
git config alias.push '!f() { bash Scripts/safe_push.sh "$@"; }; f'
# 然后 git push origin main 自动跑预检
```

### D3. sync_readme.py 单测（25 cases，全过）

**新文件** `Scripts/test_sync_readme.py`，stdlib only（无 pytest 依赖）：

- `remove_existing_section` 单匹配 / 多匹配 / 零匹配 3 case
- `section_version` plain / 带日期 / 带前缀空白 / 非法 header 4 case
- `insert_section` precondition assert 抛 ValueError + happy path 3 case
- `bump_title` 替换正确 + body 不动 2 case
- **end-to-end dedupe**：模拟 re-run 同 version，验证 `remove_existing_section` + `insert_section` 流程后 README 仍只有 1 个 `### v2.5.11` 块 + 跳过 `remove_existing_section` 会抛异常（防止 bug 静默回归）5 case
- `first_section_offset` 1 case

跑法：`python3 Scripts/test_sync_readme.py` → ✅ all tests passed。

### D4. Scripts/package.sh self-check

**新增** `verify_package(app, tarball, cask, expected_version)` 函数，main body 末尾调用，失败 exit 1。

检查项：
1. `.app` bundle 存在
2. `Info.plist` 的 `CFBundleShortVersionString` == `MARKETING_VERSION`
3. tarball 存在且非空
4. Cask `sha256` == tarball sha256（reference-only Cask，提前 catch stale 模板）
5. Cask `version` == `MARKETING_VERSION`

---

## 建议 commit 拆分（3 PRs + squash-merge to main）

### PR #A: README + script dedupe fix（紧急 bug 修复）
```
fix(scripts): sync_readme.py dedupe re-apply + 6 lang README cleanup (v2.5.11 ship review)
```
- `Scripts/sync_readme.py` (+37)
- `docs/lang/README_{EN,JA,KO,ES,PT,ZH-HANT}.md` (-44 each)

### PR #B: release.yml 综合优化（7 项 ship-review）
```
ci(release): cache + test + pre-verify + PR trigger + concurrency (v2.5.11 ship review)
```
- `.github/workflows/release.yml` (+126/-4)

### PR #C: scripts 加固（3 项）
```
feat(scripts): safe_push wrapper + sync_readme tests + package.sh self-check (v2.5.11 ship review)
```
- `Scripts/safe_push.sh` (new, +33)
- `Scripts/test_sync_readme.py` (new, +170)
- `Scripts/package.sh` (+99)

每个 PR 走 `feature branch → PR → squash-merge → main` 流程（per `feedback/clipmemory-monorepo-boundary` + branch protection）。

---

## 待办 / 未完成

### D2: Homebrew tap repo CI（**需 explicit permission**）

**内容**：在 `irykelee/homebrew-clipmemory` repo 加 `.github/workflows/cask-validate.yml`：
- 验证 `Casks/clipmemory.rb` Ruby 语法（`ruby -c`）
- 验证 sha256 / version 与最新 GitHub Release asset 匹配
- PR-trigger only（不自动 push）

**为什么 pending**：`feedback/no-github-without-permission` 白名单只含 ClipMemory + Feidi，tap repo 不在内。需要 user 明确授权才能开 PR 推到 tap repo。

**风险/取舍**：
- ✓ 优势：提前 catch Cask 错误，避免用户 `brew install` 失败
- ✗ 风险：tap repo 是公开项目（Cask 公开），CI 失败可见但不影响发布主流程；当前 release workflow 已经把正确 sha 推到 tap，所以 CI 主要是 fail-fast 价值
- **建议**：低优先级，可选 — 当前 P0-4 已经把 tap push 自动化，单条 release 失败可手动 `gh release edit`

### Push 策略（用户决策）

3 PR 提交后，squash-merge 到 main 即可。**不**需要新 release（本次仅是 ship-review 改进，不是新功能 release）。下一个 release（v2.5.12 / v2.6.x）会自然用上这些改进。

---

## 验证清单（commit 前必须跑）

```bash
# A1 dedupe fix
python3 Scripts/test_sync_readme.py   # → ✅ 25/25 pass
grep -c "^### v2.5.11" README.md docs/lang/README_*.md   # → 全部 =1

# B 系列 release.yml
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"   # → OK

# D4 package.sh
bash -n Scripts/package.sh && echo OK

# 全部
git diff --stat
```

---

## 引用

- v2.5.11 release notes: `docs/release-notes/v2.5.11.md`
- v2.5.11 ship audit: `docs/RELEASE_PROCESS_AUDIT_2026-07-22.md`（P0-1/2/3 已落地）
- Release checklist: `docs/RELEASE_PUSH_CHECKLIST.md`
- Memory: `feedback/release-push-checklist`、`feedback/release-memory-closeout`