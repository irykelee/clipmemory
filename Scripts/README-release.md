# release.sh — ClipMemory 一键发布工具

> 本机专用工具，**不入库、不上 GitHub**（已通过 `.git/info/exclude` 本地排除）。
> 串联现有发布流程（`docs/RELEASE.md` B1–B3），只编排、不重复实现：
> 构建/签名/打包/发布仍由 GitHub Actions `release.yml` 完成。

## 功能一览

```
Scripts/release.sh vX.Y.Z [--yes] [--skip-tests] [--dry-run]
```

| Phase | 内容 | 对应 RELEASE.md |
|---|---|---|
| 0 前置校验 | semver 格式校验、版本必须大于最新 tag、工具链（git/gh/python3/xcodegen/xcodebuild）+ `gh auth`、工作树干净、必须在 main、tag 冲突检查 | 新增（原流程靠人肉） |
| 1 版本与文档 | bump `project.yml` 双版本号 → `xcodegen` → 从 git log 生成双语 release notes 草稿 → **人工编辑 gate** → 提取 README changelog 段 → `sync_readme.py` 同步 7 语种 → 内联 preflight（含 `--tests`） | B1 |
| 2 提交与推送 | `chore(release)` commit → push 确认 gate → 内联 main 同步守卫 + push main → 校验 main == origin/main → 内联 pre-push verify → 打 annotated tag → 推 tag | B2 |
| 3 监控与验证 | `gh run watch` 盯 release.yml → 发布后验证（标题/双语 body/双资产/appcast edSignature/tap Cask 版本 + sha256）→ 打印剩余手动步骤 | B3 |

## 前置要求

- 在 macOS 上，已安装：`git`、`gh`（已 `gh auth login`）、`python3`、`xcodegen`、Xcode 命令行工具
- README 翻译 key（三选一，按此顺序解析；全缺即中止）：
  1. `README_SYNC_API_KEY` 环境变量
  2. `DEEPSEEK_API_KEY` 环境变量
  3. **macOS Keychain 项 `clipmemory-readme-sync`**（推荐，一次性配置，此后发版零询问）：
     ```bash
     security add-generic-password -U -s clipmemory-readme-sync -a deepseek -w '<key>'
     ```
- 翻译模型：默认 `deepseek-v4-flash`（⚠️ 旧默认 `deepseek-chat` 已被 DeepSeek API 拒绝，HTTP 400；2026-07-25 v2.5.13 发布时实测仅 `deepseek-v4-pro` / `deepseek-v4-flash` 可用）。要更高质量设 `README_SYNC_MODEL=deepseek-v4-pro`；换兼容 provider 用 `README_SYNC_BASE_URL` / `README_SYNC_MODEL` / `README_SYNC_API_KEY` 三件套（见 `Scripts/sync_readme.py` 头部注释）
- 当前分支为 `main`、工作树干净、本地有全部 tag（脚本会自己 `git fetch --tags`）

## 发版硬规则（吃过亏的，别再犯）

- **升级提示版本号固定写 `v2.4.0 起带自动升级模块（Sparkle）的版本`**，不是「上个版本起」——Sparkle v2.4.0（`a2eadfa`）引入，任何 ≥2.4.0 的版本都能自动更新。模板和生成器已固化此文案，手写 notes 时照抄（2026-07-20 用户反馈，v2.5.13 复发过一次）
- **release notes 必须手写双语**（`docs/release-notes-template.md`），禁止留生成器 stub；已存在的 notes 文件会被 release.sh 沿用不重生成——可以像 v2.5.13 一样先手写再跑脚本配 `--yes`
- **§7 母语审校**：发版前确认当期新增 L10n key 的 7 语言文案（controller-supplied draft 需用户过目拍板）
- **push/tag 必须用户显式确认**（白名单仓库也不例外）；`--yes` 只跳过脚本内 gate，不替代这个授权
- 全局 pre-commit hook：硬拒段（敏感模式）永不绕过；字段名 advisory 段无 TTY 时用 `yes y | script -q /dev/null git commit` 供 pty

## 用法

### 常规发布（推荐）

```bash
cd ~/Projects/ClipMemory
git checkout main && git pull
Scripts/release.sh v2.5.12
```

流程会在两个人工 gate 暂停：

1. **Release notes 编辑 gate**：脚本打开草稿（`$EDITOR`，默认 `open -e`），润色成用户视角双语说明后保存，回车继续。草稿占位符（`<一句话：用户得到什么>` 等）未清除会被校验拦截。
2. **Push 确认 gate**：展示 commit 摘要，输入 `yes` 才推送 main 和 tag。

### 先看后做（dry-run）

```bash
Scripts/release.sh v2.5.12 --dry-run
```

跑完 Phase 0 校验后，打印 release notes 草稿、README changelog 段、后续全部步骤清单，**零落盘、零推送**。

### 参数

| 参数 | 说明 |
|---|---|
| `--yes` | 非交互模式：跳过两个人工 gate（release notes 只做结构校验，慎用） |
| `--skip-tests` | preflight 不跑全量 `xcodebuild test`（CI 还会再跑一次） |
| `--dry-run` | 只校验 + 预览，不修改任何文件 |

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 某道校验/gate 失败（看输出定位） |
| 2 | 用法错误（版本号格式不对等） |
| 3 | 用户在确认 gate 主动中止 |
| * | `gh run watch` / `git push` 的退出码原样透出 |

## 失败后如何续跑

脚本各步幂等，失败后修好问题直接重跑同一条命令即可：

- release notes 文件已存在则**沿用不重生成**（你润色过的内容不会丢）
- 版本号/README 已 bump 过时，commit 步会因「无可提交改动」报错——说明 Phase 1 已完成过，可手动从 Phase 2 对应步骤继续，或 `git checkout -- .` 还原后整体重跑
- tag 已存在会直接报错拒绝覆盖，不会静默重打

## 发布后验证项（Phase 3 自动执行）

- `gh api` 查 release：标题非 stub、body 含 `## 中文` + `## English`、资产含 `ClipMemory.tar.gz` + `appcast.xml`
- main 分支 `appcast.xml` 含新版本 item 且带 `edSignature`
- tap 仓库 Cask：`version` 一致、`sha256` == release 资产 digest

全绿后仍需手动完成（RELEASE.md B4.12）：`brew upgrade --cask clipmemory` 本机验证、更新 STATUS.md / MEMORY.md、写 session-resume。

## 测试

```bash
bash Scripts/test/test_release.sh                    # release.sh 纯函数（34 项断言）
python3 Scripts/test/test_sync_readme.py             # sync_readme 单测（14 项）
python3 Scripts/test/test_sync_readme_dedupe.py      # dedupe/重放回归
bash Scripts/test/test_package_cask_update.sh        # package.sh Cask 更新
bash Scripts/test/test_update_appcast.sh             # appcast 插入幂等
```

release.sh 的 34 项断言覆盖纯函数：`version_gt`（数值比较，2.10.0 > 2.9.0）、`valid_semver`、`classify_commit`、`generate_release_notes`（fixture git 仓库）、`extract_readme_changelog`（与 pre-push verify 的 grep 模式兼容）、`validate_release_notes`。

## 设计说明

- **自包含（2026-07-25 起）**：原 `preflight.sh` / `pre_push_verify.sh` / `pre_push_main_sync.sh` / `safe_push.sh` 已作为函数内联（`run_preflight` / `run_pre_push_verify` / `sync_main_with_origin` 等），本工具是 Scripts/ 下唯一 push/release 工具；CI 专用的 `package.sh` / `update_appcast.sh` / `sync_readme.py` 保留不动
- **macOS 兼容**：BSD `sort` 无 `-V`，版本比较用 awk；BSD `sed -i ''`
- **已知细节**：`$VAR` 后直接跟全角字符会被 bash 并入变量名，脚本内一律 `${VAR}`
- 全局 pre-commit hook 的 advisory 段在非 TTY 下用 `yes y | script -q /dev/null git commit` 供 pty（RELEASE.md A4）；硬拒段（敏感模式）永不绕过

## 近期事故与对策（v2.5.12 / v2.5.13）

| 事故 | 对策（已落地） |
|---|---|
| 连续 tag 竞态截断 appcast 提交 | release.yml concurrency group 固定（REL-1） |
| appcast 推送被 branch protection 拦截 | 改 owner PAT + `http.extraheader`（admin bypass），token 不再写进 git config（REL-10） |
| `gh release download --tag` 参数错误 | tag 是位置参数，已修（#17） |
| 西语/葡语复数文案破碎 | `generate_stringsdict.py` 顺序敏感替换改显式翻译表（REL-5） |
| DeepSeek `deepseek-chat` 模型 HTTP 400 | sync_readme 默认模型改 `deepseek-v4-flash`，`README_SYNC_MODEL` 可覆盖（`8168ac5`） |
| 翻译 key 每次发版都要手动提供 | Keychain 项 `clipmemory-readme-sync` 回退（`32d427c`） |
| post-verify「raw 域 appcast 拉取失败」 | 多为 raw CDN 时滞误报——以 origin/main 内容 + Release 资产 feed 实测为准（v2.5.13 即此情况） |
| main 直接 push 与 appcast 自动提交撞车 | 本地 push 被拒后 `git pull --rebase` 再推（appcast commit 总在 release 之后落到 main） |

## 相关文件

| 文件 | 追踪状态 | 作用 |
|---|---|---|
| `Scripts/release.sh` | **本地**（`.git/info/exclude`） | 本工具，唯一 push/release 入口 |
| `Scripts/test/test_release.sh` | 本地 | release.sh 纯函数测试 |
| `Scripts/README-release.md` | 本地 | 本文档 |
| `Scripts/sync_readme.py` | 已入库 | 8 README 标题 + changelog 7 语种同步（LLM 翻译，内存构建成功后统一落盘） |
| `Scripts/test/test_sync_readme{,_dedupe}.py` | 已入库 | sync_readme 测试 |
| `Scripts/package.sh` | 已入库 | CI 打包（含 `verify_package()` 自检） |
| `Scripts/update_appcast.sh` | 已入库 | appcast 插入 `<item>`（幂等，REL-4） |
| `Scripts/generate_stringsdict.py` | 已入库 | 复数字符串生成（显式翻译表，REL-5） |
| `Scripts/test-ui.sh` | 已入库 | UI 冒烟测试（按 PID 采样 CPU，REL-13） |
| `docs/RELEASE.md` | 本地（gitignore） | 发布流程唯一标准（A 日常提交 / B 发版 12 步） |
| `docs/RELEASE_PUSH_CHECKLIST.md` | **已入库** | 单页 5-section 发版检查单（manual sections 仍需肉眼） |
| `docs/release-notes-template.md` | 本地（gitignore） | release notes 格式模板 |
| `.github/workflows/ci.yml` | 已入库 | PR/push 的 build-and-test（分支保护必需检查） |
| `.github/workflows/release.yml` | 已入库 | tag 触发：构建/签名/appcast/Release/tap 全自动 |
