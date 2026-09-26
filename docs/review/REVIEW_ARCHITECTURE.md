# 审查体系架构（Review Architecture）· ClipMemory

> ClipMemory 审查体系的一站式说明：**为什么存在 → 由哪些环节构成 → 如何执行 → 如何沉淀**。
> 适配自 WESTERN `docs/superpowers/audits/REVIEW_ARCHITECTURE.md`，按 ClipMemory（Swift/SwiftUI/AppKit 剪贴板管理器）实际情况裁剪。
> as-of：2026-09-22。

---

## 1. 体系总览

### 1.1 为什么存在

ClipMemory 已有深厚的人工/AI 审查传统（`docs/review/code-review-2026-09-21.md` 等 4 路并行审查、`docs/superpowers/audits/` 数十份审计）。但原有审查是**周期性、手动**的，缺少 WESTERN 已验证的**每次 commit 自动独立审核**闭环。

引入 opencode 独立审核补上这一环：

- **信任但验证（trust-but-verify）**：任何"已完成/已修复/PASS"的声称，必须能被独立复现、抽查、反证。
- **独立审核 ≠ 自审**：自查（build/lint）不算数。必须有不共享结论的独立主体参与。
- **诚实状态报告**：未完成标 ⬜、完成标 ✅，不美化；发现前轮判断错误要显式纠正。
- **防假锁定**：测试断言必须真实验证逻辑路径，mock 不能掩盖实现错误。

### 1.2 核心原则

| 原则 | 含义 |
|---|---|
| 双层结构 | 变更涉及维度逐项打勾 → 指定方向复扫 |
| 证据强制 | 每项 PASS/SKIPPED 必须附最小证据，无证据或证据不实 = FAIL |
| 独立对抗终审 | 关键改动派独立主体复核；commit 后由 opencode 自动审核 |
| 交付前过终审 | 独立审核通过后才统一交付，禁止先发未终审中间版 |

### 1.3 一句话概括

> **任何交付物（代码改动 / 审查结论），须经"主审（人工 + 现有 review 传统）+ 独立 opencode 自动审核"验证通过，才算收工。**

### 1.4 体系构成

```
审查对象（Swift 代码改动 / 审查结论）
   │
   ├─ 主审（现有 review 传统 + 人工 ledger）
   │    ① 变更涉及维度逐项核验（CLAUDE.md 约定 / 并发 / 安全 / 测试）
   │    ② 修复验证（用与发现不同角度验证）→ 审查账落盘
   │
   ├─ 独立 opencode 自动审核（不共享主审结论）
   │    ① main 分支 post-commit 自动触发 githooks/orca-auto-review.sh
   │    ② 开发分支手动跑同一脚本
   │
   └─ 交付门：独立审核 VERDICT=PASS → 统一交付；P0/P1 不能带病收工
```

---

## 2. 独立 opencode 自动审核（本仓库新增环节）

### 2.1 触发

- `.git/hooks/post-commit`（经 `githooks/install.sh` 装入）在 **main 分支每次 commit 后**后台触发 `githooks/orca-auto-review.sh`（opencode 独立模型）。
- **pre-push 门禁**：`git push` 前自动审核所有未审提交（**任何分支**，逐分支显式算范围），VERDICT=FAIL 阻断 push（`--no-verify` 显式越过）——保证离开本机的变更必然被审过。
- 非 main 分支的 commit 不自动触发（WIP 降噪）；需要时手动跑：`bash githooks/orca-auto-review.sh`，或依赖 pre-push 门禁兜底。
- 报告写 `docs/reviews/auto-review-<时间戳>.md`（含 FINDINGS + `REVIEW_VERDICT: PASS/FAIL`）。

### 2.2 义务

- commit 后**主动**查看最新报告；存在 P0/P1（VERDICT=FAIL）必须修复、重新提交、再审至 PASS。
- P2 为参考性建议，可不逐条采纳但应说明取舍。
- 开发分支（如 `fix/p1-audit-2026-09-22`、`fix/id-store-0014`）合并前手动跑一次，避免把 P0/P1 带进 main。

### 2.3 机制要点（移植自 WESTERN，已实战验证）

- **审核范围**：上次审核点（`githooks/.last-reviewed`）→ 当前 HEAD；首次只审最近 1 个提交。
- **解析 robust**：`opencode --format json` 事件流抽取模型文本，python3 主 + jq 兜底，三层降级。
- **防空转**：报告必须 ≥300 字节且含 `FINDINGS`/`REVIEW_VERDICT` 且不含余额/限流错误标记；空转/失败不推进审核点、在 `githooks/review-failures.log` 留痕。**唯一例外**：opencode 二进制缺失时的 SKIP 路径会推进审核点（避免永久卡死），但该推进同样只限 main 链（REVIEW_RANGE/非 main 不写 mark）。
- **VERDICT 提取**：行首锚定 + 形态判定 + 取最后一次，规避回显/散文污染（详见脚本注释）。

### 2.4 模型与成本

- 默认 `opencode/big-pickle`（代码审查专精，限时免费 stealth 模型）。
- 复杂推理可切 `REVIEW_MODEL=opencode/nemotron-3-ultra-free bash githooks/orca-auto-review.sh`。
- 免费期数据可能用于改进模型；审含密钥/业务逻辑片段时慎用（本仓库为个人本地项目，可接受）。

### 2.5 跨项目隔离（2026-09-26 新增）

多个项目都用 opencode 审核时，opencode 默认把所有 session / tool-output / snapshot 写进**单一全局库** `~/.local/share/opencode/opencode.db` + 共享 `tool-output/` 等目录，导致各项目的源码/diff 在 TUI / session list 里互相可见。本仓库的 `orca-auto-review.sh` 已在调用 opencode 前把数据层与配置层重定向到仓库内隔离目录：

- `XDG_DATA_HOME=$ROOT/.opencode-data`：session / 工具输出 / 快照按项目落盘，不再进全局库。
- `XDG_CONFIG_HOME=$ROOT/.opencode-cfg`：空目录 → 不加载全局 `AGENTS.md` / `mcp.memorix`，顺带关掉跨项目记忆 MCP。
- 账号凭证 `auth.json` / `account.json` 是账号级（非项目数据），用软链指回全局，模型鉴权不受影响。
- `.opencode-data/` 与 `.opencode-cfg/` 已加入 `.gitignore`，不入库。

验证：运行前后全局库 mtime 不变、per-project `opencode.db` 被创建、`git status --ignored` 显示二者为忽略态。改法在 WESTERN `.githooks/`、`~/.workbuddy/skills/opencode-review-setup/templates/` 同源同步。

---

## 3. 与现有审查传统的衔接

| 环节 | 形式 | 触发 | 价值 |
|---|---|---|---|
| 现有 review（如 `docs/review/code-review-2026-09-21.md`） | 人工/AI 深度、周期性 | 主理人发起 | 系统性、跨文件、架构级 |
| ID-STORE-0014 ledger（§10.38/§10.39） | 人工逐轮核验 | 每轮修复后 | 特定 bug 链的可追溯闭环 |
| opencode 自动审核（本新增） | 独立模型快审 | commit / 手动 | 抓主审没看到的事实盲区 |

三者互补：深度审查定方向，ledger 追具体 bug 链，自动审核守逐 commit 门禁。

---

## 4. 交付纪律

- 交付代码改动给用户前，须等独立 opencode 审核 VERDICT=PASS（或主理人明确接受 P2 取舍）后统一交付。
- **P0/P1 不能带病收工**；P2 参考性，采纳与否说明理由。
- 交付时说明：验证方式、覆盖范围、结果、仍存在的缺口。

---

## 5. 维护与演进

- `githooks/orca-auto-review.sh` 是单源真相；WESTERN 同款脚本的边界 case 修复（VERDICT 提取、防空转）已随移植带入。
- 若模型/CLI 变化导致解析失败，先查 `githooks/review-failures.log` 与 `/tmp/orca-auto-review.log`。
- 本文随批次持续演进，新增维度/新教训同步更新。

---

## 附录：关键文件

| 文件 | 用途 |
|---|---|
| `githooks/orca-auto-review.sh` | opencode 自动审核脚本（单源真相） |
| `githooks/post-commit` | 串联 Qoder tracker + opencode 触发（经 install.sh 装入 .git/hooks/） |
| `githooks/install.sh` | 安装 pre-commit + post-commit |
| `docs/reviews/auto-review-*.md` | 自动审核报告（gitignore 排除，可 `git add -f` 归档） |
| `githooks/.last-reviewed` | 上次审核 commit 标记（gitignore 排除） |
| `docs/review/code-review-2026-09-21.md` | 现有深度审查范例 |
| `CLAUDE.md` §独立代码审核 | 纪律速查 |
