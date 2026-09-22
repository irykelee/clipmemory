# docs/reviews/ · Auto-review 报告归档

> opencode 独立模型自动审核产物。每份报告对应 `main` 分支一次 commit 的独立审查结果。
> 主理人 SOP：commit 后**主动**查看本目录最新报告，P0/P1 必须修复直到 PASS。

---

## 最新 N 份报告入口

```bash
# 最新 5 份报告
ls -t docs/reviews/ | head -5

# 最新 1 份报告 + VERDICT
ls -t docs/reviews/auto-review-*.md | head -1 | xargs grep -E "VERDICT|FINDINGS|P0|P1"
```

## 命名规则

```
auto-review-YYYYMMDD-HHMMSS.md
```

例：`auto-review-20260922-090000.md` = 2026-09-22 09:00:00 触发

## 触发机制

- **自动（commit）**：`main` 分支每次 `git commit` 后，`.git/hooks/post-commit`（经 `githooks/install.sh` 安装）后台触发 `githooks/orca-auto-review.sh`。
- **自动（push）**：任何分支 `git push` 前，pre-push 门禁强制审核所有未审提交，VERDICT=FAIL 阻断 push（`--no-verify` 显式越过）。
- **手动**（开发分支）：提交前手动跑 `bash githooks/orca-auto-review.sh`，对当前 `HEAD~1..HEAD` 审核。
- 审核点记在 `githooks/.last-reviewed`，避免重复审核；范围 = 上次审核点 → 当前 HEAD。

## VERDICT 取值

| VERDICT | 含义 | 主理人义务 |
|---|---|---|
| `PASS` | 无 P0/P1 | 即可继续 |
| `FAIL` | 有 P0 或 P1 | **必须修复**直到 PASS |
| `SKIP` | opencode 不可用 / 无新提交 | 手动补救或跳过 |
| （未识别） | 模型改了输出格式 | 人工确认，下次提交重试 |

## FINDINGS 等级

| 等级 | 含义 | 主理人义务 |
|---|---|---|
| **P0** | 安全/正确性/崩溃风险 | **必修** |
| **P1** | 重要 bug / 显著质量 | **必修** |
| **P2** | 机会修复 / 文档漂移 | 参考性，采纳与否说明理由 |

唯一跳过 = 主理人亲说明"先不修"。

## 与现有手动审查的关系

- `docs/review/code-review-2026-09-21.md` 等是**人工/AI 深度审查**（4 路并行、P1/P2/P3）。
- 本目录的 auto-review 是**每次 commit 的独立模型快审**，抓主审/人工没看到的事实盲区。
- 两者互补，不替代。深度审查结论以 `docs/review/` 为准；逐 commit 门禁以本目录为准。

## gitignore 说明

`docs/reviews/auto-review-*.md` 与 `.tmp-review-*.md` 被 `.gitignore` 排除（避免随无关提交入库）。
如需归档某份报告：`git add -f docs/reviews/auto-review-<stamp>.md`。
运行时标记 `githooks/.last-reviewed`、`githooks/review-failures.log` 同样被排除。

## 维护纪律

- 不删历史报告——保留作 audit trail（如需归档可 `git add -f` 后提交）。
- 开发分支提交前手动跑脚本（或依赖 pre-push 门禁在 push 时强制审）；`main` 分支 commit 自动触发。
- 审核在空转（无结论/余额/限流）时会在 `githooks/review-failures.log` 与 `/tmp/orca-auto-review.log` 留痕，不会静默失效。
