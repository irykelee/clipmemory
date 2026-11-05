# ID-REVIEW-1049 接手说明（2026-11-05）

> **一句话**：这条线**已经建好了机器**，现在**降级为「按需触发」** —— 有审核门
> findings 才开新轮；机器自己会报红，不用人去盯。

## 一、这条线现在由什么组成（都已上线、都在 CI 里）

| 组件 | 位置 | 它保证什么 |
|---|---|---|
| 审核门 | `.git/hooks/post-commit` → `githooks/orca-auto-review.sh` | 每次 commit 后跑独立模型审 diff ⇒ 报告进 `docs/reviews/` |
| 人工核验台账 | `githooks/review-adjudication.jsonl`（**200** 条） | 每条结论带 `file` + `fileSha256` ⇒ **代码一改，结论自动失效** |
| 台账体检 | `python3 githooks/review-adjudicate.py audit` | 报出「正则编译不过 / 锚点失效 / 文件缺失 / 无锚点」四类问题 |
| **重验检查表** | `Scripts/test/test_adjudication_claims.py`（**135** 静态判据 + **7** 实跑判据 + **128** 键覆盖表） | 逐条把台账结论**拆成机器可查的判据** ⇒ 「一条不漏」可证明 |
| 散文副本守卫 | `Scripts/test/test_rule_prose_copies.py` | 规则在文档里的**散文副本**不许漂移 |
| 变异集 | `Scripts/mutation/prose_guard_mutants.py` | 「守卫有牙齿」这句话**每次 push 重跑一遍** |
| workflow schema 守卫 | `Scripts/test/test_workflow_schema.py` | 「YAML 能 parse」≠「schema 合法」 |
| beta 通道接线守卫 | `Scripts/test/test_beta_channel_wiring.py` | beta 的三根线（app 端默认关 / 发布侧带通道 / 不动 tap） |

## 二、什么时候开新轮

| 触发 | 动作 |
|---|---|
| 审核门报 **FAIL**（有 P0/P1） | **开一轮**：逐条核验 → 修 → 入账 → 重锚 → 推 |
| 审核门 PASS 但 findings 里有真问题 | 同上（PASS 只表示模型没判红，不表示没有真问题） |
| 改动了上面任何一个守卫/台账 | **必须**在同一轮里把它的**机器数**（断言数 / 覆盖表键数 / 扫描文件数）刷新 |
| 改了 `docs/skips-ledger.md` | ⇒ 锚在它上面的结论**全部失效** ⇒ ⇒ 重锚（**先提交台账，再重锚**，见下） |

## 三、三条会重复踩的坑（都已写进台账 §50.28.3）

1. **批量重锚 = 说谎** ⇒ ⇒ 没核验过的结论刷上当前 sha ⇒ 等于断言「已核验过」
   ⇒ ⇒ **过期比假重锚好** ⇒ ⇒ 要重锚就**逐条核验后再锚**。
2. **判据失败 ≠ 结论过期** ⇒ ⇒ 判据写错与结论漂移是**两件事** ⇒ ⇒ 分开记。
3. **顺序纪律：先提交台账 → 再写锚** ⇒ ⇒ 改台账会让锚在它上面的结论**立刻**失效
   ⇒ ⇒ 反过来做就等于「落库即失效」。

## 四、还有哪些**故意没做**的

- **`release.sh --beta` 的自动发版路径** ⇒ 已做（ID-BETA-0001 Phase 2）。
- **快照 golden 的 record path** ⇒ **故意没做**：没有 env-gated record path 时，
  「重录 golden」= **信号销毁**（台账 §50.27/§39 的诊断条：CI 失配机制**未定位**，
  定位前重录无意义）⇒ ⇒ **机制定位之前不许重录**。
- **元工作继续开新轮** ⇒ ⇒ 用户 2026-11-04 已拍板：**回产品面** ⇒ ⇒ 这条线**按需触发**。
