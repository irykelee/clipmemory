#!/bin/bash
# TDD test for githooks/review-adjudicate.py
#
# 背景（ID-REVIEW-1029, 2026-10-25）：审核门用本地 9B 模型做独立审核。该模型
# **能抓真 bug，但严重度标注不可信** —— v2.9.6 发版期间实测 3 份报告共 5 条 P1，
# 人工逐条核验**全部误报**。本测试锁死人工核验层的判定规则，防止它被改坏成
# 「永远放行」或「永远阻断」。
#
# 覆盖的判定：
#   1. advisory 模式：未核验的 P0/P1 **不阻断**（只是提示）
#   2. strict  模式：未核验的 P0/P1 阻断（保留旧行为）
#   3. 人工记为 confirmed ⇒ **两种模式都阻断**
#   4. 人工记为 false-positive ⇒ 不阻断，且 strict 模式下也放行该条
#   5. 结论里带 file ⇒ **该文件一改，结论自动失效**（回到未核验状态）
#   6. 过期结论失效
#   7. 不匹配该结论的**另一条** finding 仍算未核验
#   8. 台账里一行坏 JSON ⇒ 跳过告警，不影响其余结论
#   9. 正则编译失败 ⇒ 不匹配 + 响亮告警，不崩（**不退化为字面子串** ——
#      那样等于这条结论永远不生效，而台账里躺着一条 confirmed 却不生效，
#      正是最容易让人误以为「已经核验过了」的状态）
#  10. apply 幂等：重跑不叠加两遍核验段
#  11. 门禁接线：orca-auto-review.sh 的阻断判据用的是**生效结论**而不是模型结论
#  12. 台账的 file 字段不得越出仓库（路径穿越：相对上跳 + 绝对路径）
#  13. 报告正文里出现标记串 ⇒ findings 不得被抹掉（审自己时的自指陷阱）
#  14. apply 崩溃 ⇒ fail-closed（不能静默退回「模型结论说了算」）
#  15. 不传 REVIEW_ADJUDICATE_SCRIPT / REVIEW_REPO_ROOT 也不能崩
#  16. add 拒绝**编译失败**的 match 正则（写入端 fail-closed，不留占位）
#  17. add 拒绝**有未提交改动**的 file（先提交、后写锚）；已暂存未提交**允许**
#  18. add 拒绝**锚到台账自身**（写入即改文件 ⇒ 锚点落库即失效）
#  19. 干净文件 ⇒ add 成功，且入库的 fileSha256 == 文件实际内容的 sha256
#  20. audit 行为级：正则编译失败 ⇒ exit 1；锚点失效 / 缺失 / 无锚 **报数**；
#      默认不阻断（存量分批重验），--fail-on-stale 才 exit 1；且 audit **只读**
#
# Run: bash Scripts/test/test_review_adjudicate.sh
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ADJ="$SCRIPT_DIR/githooks/review-adjudicate.py"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

FAILURES=0
pass() { echo "✅ $1"; }
fail() { echo "❌ $1" >&2; FAILURES=$((FAILURES + 1)); }

# --- 假仓库根：放一个会被「改动」的关联文件 ---
REPO="$TEST_DIR/repo"
mkdir -p "$REPO/ClipMemory/Services"
printf 'original content\n' > "$REPO/ClipMemory/Services/Foo.swift"
TARGET_REL="ClipMemory/Services/Foo.swift"
TARGET_SHA=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$REPO/$TARGET_REL")

# --- 假报告：1 条 P1 + 1 条 P2 ---
make_report() {
  cat > "$1" <<'EOF'
FINDINGS: [P1] Scripts/release.sh: 轮询超时从 60s 延长至 300s，需确认是否违反 SLA 约定
FINDINGS: [P2] Tests/Foo.swift: 建议补充一条单元测试
REVIEW_VERDICT: FAIL
EOF
}

apply_ledger() {
  # apply_ledger <report> <ledger> <mode> <model_verdict>  → stdout
  python3 "$ADJ" apply --report "$1" --ledger "$2" --repo-root "$REPO" \
    --mode "$3" --model-verdict "$4"
}

field() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-; }

# ===================================================================
echo "--- 断言 1: advisory 模式下，未核验的 P0/P1 不阻断 ---"
R="$TEST_DIR/r1.md"; L="$TEST_DIR/l1.jsonl"; : > "$L"
make_report "$R"
OUT=$(apply_ledger "$R" "$L" advisory FAIL)
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "PASS" ] \
  && pass "advisory + 未核验 ⇒ PASS（不阻断）" || fail "advisory + 未核验 应为 PASS，实得：$(field "$OUT" EFFECTIVE_VERDICT)"
[ "$(field "$OUT" ADVISORY_COUNT)" = "1" ] \
  && pass "advisory 计数 = 1" || fail "advisory 计数应 = 1，实得：$(field "$OUT" ADVISORY_COUNT)"
grep -q "## 人工核验 / Adjudication" "$R" && pass "报告追加了核验段" || fail "报告未追加核验段"
grep -q "待核验的 P0/P1" "$R" && pass "报告列出待核验项" || fail "报告未列出待核验项"

# ===================================================================
echo "--- 断言 2: strict 模式下，未核验的 P0/P1 阻断 ---"
R="$TEST_DIR/r2.md"; L="$TEST_DIR/l2.jsonl"; : > "$L"
make_report "$R"
OUT=$(apply_ledger "$R" "$L" strict FAIL)
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "FAIL" ] \
  && pass "strict + 未核验 ⇒ FAIL（阻断）" || fail "strict + 未核验 应为 FAIL，实得：$(field "$OUT" EFFECTIVE_VERDICT)"

# ===================================================================
echo "--- 断言 3: 人工记为 confirmed ⇒ 两种模式都阻断 ---"
R="$TEST_DIR/r3.md"; L="$TEST_DIR/l3.jsonl"
cat > "$L" <<EOF
{"match": "轮询超时", "file": "$TARGET_REL", "fileSha256": "$TARGET_SHA", "severity": "P1", "verdict": "confirmed", "note": "真问题：SLA 确实会被拖长", "adjudicatedAt": "2026-10-25T10:00:00Z", "expiresAt": "2099-10-25T10:00:00Z"}
EOF
make_report "$R"
OUT=$(apply_ledger "$R" "$L" advisory PASS)
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "FAIL" ] \
  && pass "advisory + confirmed ⇒ FAIL（阻断）" || fail "advisory + confirmed 应为 FAIL，实得：$(field "$OUT" EFFECTIVE_VERDICT)"
[ "$(field "$OUT" BLOCKING_COUNT)" = "1" ] \
  && pass "阻断计数 = 1" || fail "阻断计数应 = 1，实得：$(field "$OUT" BLOCKING_COUNT)"

# ===================================================================
echo "--- 断言 4: 人工记为 false-positive ⇒ 不阻断（strict 下也放行） ---"
R="$TEST_DIR/r4.md"; L="$TEST_DIR/l4.jsonl"
cat > "$L" <<EOF
{"match": "轮询超时", "file": "$TARGET_REL", "fileSha256": "$TARGET_SHA", "severity": "P1", "verdict": "false-positive", "note": "误报：没有 SLA 约定这回事", "adjudicatedAt": "2026-10-25T10:00:00Z", "expiresAt": "2099-10-25T10:00:00Z"}
EOF
make_report "$R"
OUT=$(apply_ledger "$R" "$L" advisory FAIL)
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "PASS" ] \
  && pass "advisory + 误报 ⇒ PASS" || fail "advisory + 误报 应为 PASS，实得：$(field "$OUT" EFFECTIVE_VERDICT)"
R="$TEST_DIR/r4b.md"; make_report "$R"
OUT=$(apply_ledger "$R" "$L" strict FAIL)
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "PASS" ] \
  && pass "strict + 误报 ⇒ PASS（放行口子有效）" || fail "strict + 误报 应为 PASS，实得：$(field "$OUT" EFFECTIVE_VERDICT)"
grep -q "已核验为误报" "$R" && pass "报告标注了已核验误报" || fail "报告未标注已核验误报"

# ===================================================================
echo "--- 断言 5: 关联文件一改 ⇒ 结论自动失效（回到未核验） ---"
printf 'CHANGED content\n' > "$REPO/$TARGET_REL"
R="$TEST_DIR/r5.md"; make_report "$R"
OUT=$(apply_ledger "$R" "$L" strict FAIL)
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "FAIL" ] \
  && pass "文件改动后 strict ⇒ FAIL（结论已失效）" || fail "文件改动后 strict 应为 FAIL，实得：$(field "$OUT" EFFECTIVE_VERDICT)"
[ "$(field "$OUT" ADVISORY_COUNT)" = "1" ] \
  && pass "文件改动后回到未核验状态" || fail "文件改动后应回到未核验，实得 ADVISORY_COUNT=$(field "$OUT" ADVISORY_COUNT)"
# 还原文件，后续断言继续用
printf 'original content\n' > "$REPO/$TARGET_REL"

# ===================================================================
echo "--- 断言 6: 过期结论失效 ---"
R="$TEST_DIR/r6.md"; L="$TEST_DIR/l6.jsonl"
cat > "$L" <<EOF
{"match": "轮询超时", "verdict": "confirmed", "note": "过期了", "adjudicatedAt": "2020-01-01T00:00:00Z", "expiresAt": "2021-01-01T00:00:00Z"}
EOF
make_report "$R"
OUT=$(apply_ledger "$R" "$L" advisory PASS)
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "PASS" ] \
  && pass "过期结论不再阻断" || fail "过期结论不应阻断，实得：$(field "$OUT" EFFECTIVE_VERDICT)"

# ===================================================================
echo "--- 断言 7: 不匹配该结论的**另一条** finding 仍算未核验 ---"
R="$TEST_DIR/r7.md"; L="$TEST_DIR/l7.jsonl"
cat > "$L" <<EOF
{"match": "另一个完全不相关的话题", "verdict": "confirmed", "note": "只针对别的事", "adjudicatedAt": "2026-10-25T10:00:00Z", "expiresAt": "2099-10-25T10:00:00Z"}
EOF
make_report "$R"
OUT=$(apply_ledger "$R" "$L" advisory PASS)
[ "$(field "$OUT" BLOCKING_COUNT)" = "0" ] \
  && pass "不匹配的 finding 不算已确认" || fail "不匹配的 finding 不该算已确认，实得 BLOCKING_COUNT=$(field "$OUT" BLOCKING_COUNT)"
[ "$(field "$OUT" ADVISORY_COUNT)" = "1" ] \
  && pass "不匹配的 finding 仍算待核验" || fail "不匹配的 finding 应算待核验，实得 ADVISORY_COUNT=$(field "$OUT" ADVISORY_COUNT)"

# ===================================================================
echo "--- 断言 8: 台账里一行坏 JSON ⇒ 跳过，不影响其余 ---"
R="$TEST_DIR/r8.md"; L="$TEST_DIR/l8.jsonl"
cat > "$L" <<EOF
{"match": "轮询超时", "verdict": "confirmed", "note": "真问题", "adjudicatedAt": "2026-10-25T10:00:00Z", "expiresAt": "2099-10-25T10:00:00Z"}
{ this is not json at all
EOF
make_report "$R"
OUT=$(apply_ledger "$R" "$L" advisory PASS 2>"$TEST_DIR/r8.err")
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "FAIL" ] \
  && pass "坏行被跳过，其余结论仍生效" || fail "坏行影响了其余结论，实得：$(field "$OUT" EFFECTIVE_VERDICT)"
grep -q "不是合法 JSON" "$TEST_DIR/r8.err" \
  && pass "坏行有告警" || fail "坏行没有告警"

# ===================================================================
echo "--- 断言 9: 正则编译失败 ⇒ 不匹配 + 告警，不崩 ---"
R="$TEST_DIR/r9.md"; L="$TEST_DIR/l9.jsonl"
cat > "$L" <<'EOF'
{"match": "轮询超时(未闭合", "verdict": "confirmed", "note": "坏正则", "adjudicatedAt": "2026-10-25T10:00:00Z", "expiresAt": "2099-10-25T10:00:00Z"}
EOF
make_report "$R"
OUT=$(apply_ledger "$R" "$L" advisory PASS 2>"$TEST_DIR/r9.err")
[ "$(field "$OUT" EFFECTIVE_VERDICT)" = "PASS" ] \
  && pass "坏正则不匹配 ⇒ 不阻断（结论不生效）" || fail "坏正则不应生效，实得：$(field "$OUT" EFFECTIVE_VERDICT)"
[ "$(field "$OUT" ADVISORY_COUNT)" = "1" ] \
  && pass "坏正则 ⇒ 该 finding 回到待核验" || fail "坏正则后应回到待核验，实得：$(field "$OUT" ADVISORY_COUNT)"
grep -q "正则编译失败" "$TEST_DIR/r9.err" \
  && pass "坏正则有告警" || fail "坏正则没有告警"

# ===================================================================
echo "--- 断言 10: apply 幂等（重跑不叠加核验段） ---"
R="$TEST_DIR/r10.md"; L="$TEST_DIR/l10.jsonl"; : > "$L"
make_report "$R"
apply_ledger "$R" "$L" advisory FAIL > /dev/null
apply_ledger "$R" "$L" advisory FAIL > /dev/null
COUNT=$(grep -c "## 人工核验 / Adjudication" "$R" || true)
[ "$COUNT" = "1" ] && pass "核验段只出现一次" || fail "核验段出现了 ${COUNT} 次（应 1 次）"

# ===================================================================
echo "--- 断言 11: 门禁接线用的是生效结论，不是模型结论 ---"
GATE="$SCRIPT_DIR/githooks/orca-auto-review.sh"
# `apply` 的实际调用在判定单元里（ID-REVIEW-1031：判定逻辑抽成可 source 的
# 单元，才能做行为级测试），门禁本体负责调用它并按生效结论阻断。
ADJ_UNIT="$SCRIPT_DIR/githooks/review-gate-adjudication.sh"
grep -q 'review-adjudicate.py' "$ADJ_UNIT" \
  && pass "判定单元引用了 review-adjudicate.py" || fail "判定单元未引用 review-adjudicate.py"
grep -q 'apply --report' "$ADJ_UNIT" \
  && pass "判定单元调用了 apply --report" || fail "判定单元未调用 apply --report"
grep -q 'review_gate_adjudicate' "$GATE" \
  && pass "门禁调用了判定单元" || fail "门禁未调用判定单元"
grep -q 'if \[\[ "\$EFFECTIVE_VERDICT" == "FAIL" \]\]' "$GATE" \
  && pass "阻断判据用 EFFECTIVE_VERDICT" || fail "阻断判据未用 EFFECTIVE_VERDICT"
grep -q 'REVIEW_GATE_MODE' "$GATE" \
  && pass "门禁支持 REVIEW_GATE_MODE" || fail "门禁未支持 REVIEW_GATE_MODE"
grep -q 'if \[\[ "\$VERDICT" == "FAIL" \]\]' "$GATE" \
  && fail "门禁仍直接用模型结论 \$VERDICT 判定阻断" || pass "门禁不再直接用模型结论判阻断"

# ===================================================================
echo "--- 断言 12: 台账的 file 字段不得越出仓库（路径穿越）---"
# 背景（ID-REVIEW-1031, 2026-10-25）：台账是**入库文件**，`file` 字段的内容
# 来自仓库里 ⇒ 任何人往台账里写一行 `file: "../../secret.txt"` 就能让工具
# 去读仓库外的文件（os.path.join 遇绝对路径会整段丢掉 repo_root）。
#
# 用一个**真的存在**的仓库外文件做靶子 —— 否则「文件不存在」会先一步挡住，
# 断言就变成「因错得对」（实测：第一次写这条断言时，相对上跳那支根本没红）。
mkdir -p "$TEST_DIR/outside"
printf 'secret\n' > "$TEST_DIR/outside/secret.txt"
L12="$TEST_DIR/l12.jsonl"; : > "$L12"
set +e
python3 "$ADJ" add --ledger "$L12" --repo-root "$REPO" \
  --match 'x' --file '../outside/secret.txt' --verdict confirmed --note '越界路径' \
  > "$TEST_DIR/a12.out" 2> "$TEST_DIR/a12.err"
RC12=$?
set -e
[ "$RC12" != "0" ] \
  && pass "add 拒绝仓库外的 file（相对上跳，退出码 ${RC12}）" || fail "add 接受了仓库外的 file（相对上跳）"
[ ! -s "$L12" ] \
  && pass "越界的 file 没有写进台账" || fail "越界的 file 被写进了台账"
grep -q "仓库内" "$TEST_DIR/a12.err" \
  && pass "拒绝时说明了原因" || fail "拒绝时没有说明原因"
# 绝对路径同样越界
set +e
python3 "$ADJ" add --ledger "$L12" --repo-root "$REPO" \
  --match 'x' --file '/etc/passwd' --verdict confirmed --note '绝对路径' \
  > /dev/null 2>&1
RC12B=$?
set -e
[ "$RC12B" != "0" ] \
  && pass "add 拒绝绝对路径（退出码 ${RC12B}）" || fail "add 接受了绝对路径"
# 台账里已经躺着一行越界条目时，apply 也不能用它（不读那个文件）
L12C="$TEST_DIR/l12c.jsonl"
cat > "$L12C" <<EOF
{"match": "轮询超时", "verdict": "confirmed", "note": "越界条目", "file": "/etc/passwd", "fileSha256": "deadbeef", "severity": "P1", "adjudicatedAt": "2026-10-25T10:00:00Z", "expiresAt": "2099-10-25T10:00:00Z"}
EOF
R12="$TEST_DIR/r12.md"; make_report "$R12"
OUT=$(apply_ledger "$R12" "$L12C" advisory FAIL 2>"$TEST_DIR/r12.err")
[ "$(field "$OUT" BLOCKING_COUNT)" = "0" ] \
  && pass "越界条目不产生阻断（不读仓库外的文件）" || fail "越界条目产生了阻断：$(field "$OUT" BLOCKING_COUNT)"
[ "$(field "$OUT" ADVISORY_COUNT)" = "1" ] \
  && pass "越界条目等于「未核验」" || fail "越界条目不应算已核验"

# ===================================================================
echo "--- 断言 13: 报告正文里出现标记串，不得把 findings 抹掉 ---"
# 背景（ID-REVIEW-1031, 2026-10-25）：这个工具**审自己**时，模型的报告正文里
# 必然引用到「## 人工核验 / Adjudication」这行字。旧实现只按标题串剥离，
# 于是从第一个 "\n---" 起把后面全砍掉 —— 实测一次真实审核里 12 条 findings
# 被整段抹掉，而门禁照样报 PASS（审计痕迹被静默销毁）。
R13="$TEST_DIR/r13.md"; L13="$TEST_DIR/l13.jsonl"; : > "$L13"
cat > "$R13" <<'EOF'
Some prose from the model.

---

FINDINGS: [P1] review-adjudicate.py::strip_previous_adjudication finds "## 人工核验 / Adjudication" and strips back
FINDINGS: [P2] 另一条 finding
REVIEW_VERDICT: FAIL
EOF
BEFORE13=$(grep -c '^FINDINGS' "$R13" || true)
OUT=$(apply_ledger "$R13" "$L13" advisory FAIL)
AFTER13=$(grep -c '^FINDINGS' "$R13" || true)
[ "$BEFORE13" = "$AFTER13" ] \
  && pass "apply 前后 findings 条数不变（${AFTER13}）" || fail "apply 把 findings 从 $BEFORE13 条变成 $AFTER13 条"
grep -q 'strip_previous_adjudication finds' "$R13" \
  && pass "正文里引用的标题行仍在" || fail "正文被误删"
# 幂等：跑两次只留一份核验段（用哨兵计数，标题行在正文里也有）
apply_ledger "$R13" "$L13" advisory FAIL > /dev/null
apply_ledger "$R13" "$L13" advisory FAIL > /dev/null
SENT13=$(grep -c 'cm-adjudication:v1' "$R13" || true)
[ "$SENT13" = "1" ] \
  && pass "重复 apply 后核验段只留一份（哨兵计数 ${SENT13}）" || fail "核验段叠加了 $SENT13 份"

# ===================================================================
echo "--- 断言 14: apply 崩溃 ⇒ fail-closed（行为级，不是 grep 源码）---"
# 背景（ID-REVIEW-1031, 2026-10-25）：旧实现把「输出为空」一律当成「缺
# python3 或台账」，在 apply **崩溃**时真实原因被掩盖，更糟的是静默退回
# 「模型结论说了算」= 安全层失效时 fail-open。
#
# 实测教训：这一条最初写成「grep 源码里有没有 fail-closed 字样」——
# 把逻辑改成 fail-open 后**断言照样全绿**（字样还在，只是行为变了）。
# ⇒ 必须**真的调用**判定单元，用一个「假装崩溃的 python」看它到底判什么。
ADJ_UNIT="$SCRIPT_DIR/githooks/review-gate-adjudication.sh"
[ -f "$ADJ_UNIT" ] && pass "判定单元存在" || fail "缺少判定单元 $ADJ_UNIT"
# shellcheck source=/dev/null
source "$ADJ_UNIT"

# 假装崩溃的 python：任何参数都退出 1
CRASH_PY="$TEST_DIR/crash-python.sh"
cat > "$CRASH_PY" <<'EOF'
#!/bin/bash
echo "boom: simulated crash" >&2
exit 1
EOF
chmod +x "$CRASH_PY"

# 崩溃用例必须传 model_verdict=**PASS** 才能分辨 fail-closed 与 fail-open：
# 传 FAIL 时两条路径的结果都是 FAIL，断言就变成同义反复（实测：这么写时，
# 把 fail-closed 改成 fail-open 的变异**没被抓住**）。
R14="$TEST_DIR/r14.md"; make_report "$R14"
OUT14=$(REVIEW_ADJUDICATE_SCRIPT="$ADJ" REVIEW_REPO_ROOT="$REPO" \
  review_gate_adjudicate "$R14" "$L13" advisory PASS "$CRASH_PY")
[ "$(field "$OUT14" STATUS)" = "crashed" ] \
  && pass "apply 崩溃被识别为 crashed" || fail "崩溃未被识别：STATUS=$(field "$OUT14" STATUS)"
[ "$(field "$OUT14" EFFECTIVE_VERDICT)" = "FAIL" ] \
  && pass "崩溃时 fail-closed（模型说 PASS 也判 FAIL）" || fail "崩溃时没有 fail-closed：$(field "$OUT14" EFFECTIVE_VERDICT)"
grep -q "boom: simulated crash" <<< "$OUT14" \
  && pass "崩溃原因被带出来" || fail "崩溃原因没有带出来"

# 正常 python（真的跑一遍）⇒ 不崩，且结论由台账决定
OUT14B=$(REVIEW_ADJUDICATE_SCRIPT="$ADJ" REVIEW_REPO_ROOT="$REPO" \
  review_gate_adjudicate "$R14" "$L13" advisory FAIL "$(command -v python3)")
[ "$(field "$OUT14B" STATUS)" = "ok" ] \
  && pass "正常路径 STATUS=ok" || fail "正常路径 STATUS=$(field "$OUT14B" STATUS)"
[ "$(field "$OUT14B" EFFECTIVE_VERDICT)" = "PASS" ] \
  && pass "正常路径按台账给出结论（无人工结论 ⇒ advisory 下 PASS）" || fail "正常路径结论异常"

# 没有台账 ⇒ 退回模型结论（不是崩溃，也不是阻断）
# 同样传 model_verdict=PASS，才能与「崩溃 ⇒ FAIL」区分开。
OUT14C=$(REVIEW_ADJUDICATE_SCRIPT="$ADJ" REVIEW_REPO_ROOT="$REPO" \
  review_gate_adjudicate "$R14" "$TEST_DIR/nonexistent-ledger.jsonl" advisory PASS "$(command -v python3)")
[ "$(field "$OUT14C" STATUS)" = "no-ledger" ] \
  && pass "没有台账 ⇒ STATUS=no-ledger" || fail "没有台账时 STATUS=$(field "$OUT14C" STATUS)"
[ "$(field "$OUT14C" EFFECTIVE_VERDICT)" = "PASS" ] \
  && pass "没有台账 ⇒ 退回模型结论（模型 PASS ⇒ PASS，不是崩溃的 FAIL）" || fail "没有台账时没有退回模型结论"

# 门禁必须真的用这个单元
grep -q 'review-gate-adjudication.sh' "$GATE" \
  && pass "门禁引用了判定单元" || fail "门禁没有引用判定单元"
grep -q 'review_gate_adjudicate' "$GATE" \
  && pass "门禁调用了判定单元的函数" || fail "门禁没有调用判定单元的函数"

# ===================================================================
echo "--- 断言 15: 不传 REVIEW_ADJUDICATE_SCRIPT / REVIEW_REPO_ROOT 也不能崩 ---"
# ID-REVIEW-1033：外部审核（qwen3.5:9b）指出判定单元的默认路径指向
# `$HOME/.local/bin/review-adjudicate.py` —— **那个文件根本不存在**。
# 调用方一旦漏传 env，python 调用必然失败 ⇒ status=crashed ⇒ fail-closed
# ⇒ **每次 push 都被挡**，且报错与真实故障无关。
# ⇒ 默认值必须从**单元自身位置**推导，调用方不传也能跑。
R15="$TEST_DIR/r15.md"; make_report "$R15"
OUT15=$(env -u REVIEW_ADJUDICATE_SCRIPT -u REVIEW_REPO_ROOT \
  bash -c '
    source "$1"
    review_gate_adjudicate "$2" "$3" advisory PASS "$(command -v python3)"
  ' _ "$ADJ_UNIT" "$R15" "$L13")
[ "$(field "$OUT15" STATUS)" = "ok" ] \
  && pass "不传 env 也能正常跑（STATUS=ok，不是 crashed）" \
  || fail "不传 env 就崩了：STATUS=$(field "$OUT15" STATUS)"
# 默认推导出来的脚本路径必须**真的存在**
ADJ_SELF="$(cd "$(dirname "$ADJ_UNIT")" && pwd)/review-adjudicate.py"
[ -f "$ADJ_SELF" ] \
  && pass "默认脚本路径指向真实文件" || fail "默认脚本路径不存在：$ADJ_SELF"

# ===================================================================
echo "--- 断言 16: add 拒绝编译失败的 match 正则（写入端 fail-closed）---"
# 背景（核验员 P3-1, 2026-11-05）：台账里若躺着一行 `match` 正则**编译不过**
# ⇒ 匹配期**永不命中** ⇒ 那条结论等于没写 ⇒ 而它在台账里看着像「已核验过」。
# ⇒ 写入端必须**当场拒**，不能等到匹配期才发现。
REPO2="$TEST_DIR/gitrepo"
LEDGER16="$REPO2/ledger16.jsonl"
mkdir -p "$REPO2"
git -C "$REPO2" init -q
git -C "$REPO2" config user.email "adj-test@example.com"
git -C "$REPO2" config user.name "AdjTest"
printf 'anchored content\n' > "$REPO2/anchored.txt"
printf 'clean content\n' > "$REPO2/clean.txt"
printf 'dirty content\n' > "$REPO2/dirty.txt"
git -C "$REPO2" add -A
# ⚠️ 必须屏蔽 hook：全局 core.hooksPath 会让这个**临时仓库**的 commit 触发
# 真实仓库的 pre-commit（含联网的 LLM 审查）⇒ 单测变成依赖网络 ⇒ 会随机变慢/变红。
git -C "$REPO2" -c core.hooksPath=/dev/null commit -q -m "init"
: > "$LEDGER16"
set +e
python3 "$ADJ" add --ledger "$LEDGER16" --repo-root "$REPO2" \
  --match '坏正则(未闭合' --file 'anchored.txt' --severity P1 \
  --verdict confirmed --note '断言16用例' \
  > "$TEST_DIR/a16.out" 2> "$TEST_DIR/a16.err"
RC16=$?
set -e
[ "$RC16" = "2" ] \
  && pass "add 拒绝编译失败的 match（退出码 2）" || fail "add 接受了编译失败的 match（退出码 ${RC16}）"
grep -q "正则编译失败" "$TEST_DIR/a16.err" \
  && pass "拒绝原因指明是正则编译失败" || fail "拒绝原因没指出正则编译失败"
[ ! -s "$LEDGER16" ] \
  && pass "坏正则没有写进台账" || fail "坏正则被写进了台账"

# ===================================================================
echo "--- 断言 17: add 拒绝有未提交改动的 file（先提交、后写锚）---"
# 背景（核验员 P1-1, 2026-11-05）：同一个 commit 内既改锚文件又写锚 sha ⇒
# 锚的是**中间态** ⇒ 落库即失效 ⇒ 结构上不可能生效。
LEDGER17="$REPO2/ledger17.jsonl"; : > "$LEDGER17"
printf 'dirty content CHANGED\n' > "$REPO2/dirty.txt"
set +e
python3 "$ADJ" add --ledger "$LEDGER17" --repo-root "$REPO2" \
  --match '某个结论' --file 'dirty.txt' --severity P1 \
  --verdict confirmed --note '断言17用例' \
  > "$TEST_DIR/a17.out" 2> "$TEST_DIR/a17.err"
RC17=$?
set -e
[ "$RC17" = "2" ] \
  && pass "add 拒绝有未提交改动的 file（退出码 2）" || fail "add 接受了中间态 file（退出码 ${RC17}）"
grep -q "未提交改动" "$TEST_DIR/a17.err" \
  && pass "拒绝原因指明是未提交改动" || fail "拒绝原因没指出未提交改动"
[ ! -s "$LEDGER17" ] \
  && pass "中间态锚点没有写进台账" || fail "中间态锚点被写进了台账"

# 对照：已 `git add` 但**还没 commit** ⇒ 工作区 == 索引 ⇒ 允许写锚。
# 这一支专门区分「比对索引」与「比对 HEAD」：按 HEAD 比会把它误判成脏 ⇒ 误伤。
git -C "$REPO2" add dirty.txt
set +e
python3 "$ADJ" add --ledger "$LEDGER17" --repo-root "$REPO2" \
  --match '某个结论' --file 'dirty.txt' --severity P1 \
  --verdict confirmed --note '断言17对照：已暂存未提交' \
  > "$TEST_DIR/a17b.out" 2> "$TEST_DIR/a17b.err"
RC17B=$?
set -e
[ "$RC17B" = "0" ] \
  && pass "已暂存未提交的 file 允许写锚（比对的是索引，不是 HEAD）" \
  || fail "已暂存未提交的 file 被误拒（退出码 ${RC17B}）"

# ===================================================================
echo "--- 断言 18: add 拒绝锚到台账自身（自引用）---"
# 写入这一行本身就会改变那个文件的内容 ⇒ 锚点在落库那一刻**立刻失效** ⇒
# 结构上不可能生效 ⇒ 直接拒。
# ⚠️ 台账必须**放在仓库内**且**已存在**：否则会先被「越出仓库」或「文件不存在」
# 那两条守卫挡下 ⇒ 退出码同样是 2 ⇒ 断言就变成「因错得对」。
LEDGER18="$REPO2/ledger18.jsonl"; : > "$LEDGER18"
set +e
python3 "$ADJ" add --ledger "$LEDGER18" --repo-root "$REPO2" \
  --match '某个结论' --file 'ledger18.jsonl' --severity P1 \
  --verdict confirmed --note '断言18用例' \
  > "$TEST_DIR/a18.out" 2> "$TEST_DIR/a18.err"
RC18=$?
set -e
[ "$RC18" = "2" ] \
  && pass "add 拒绝锚到台账自身（退出码 2）" || fail "add 接受了自锚（退出码 ${RC18}）"
grep -q "台账自身" "$TEST_DIR/a18.err" \
  && pass "拒绝原因指明是台账自身" || fail "拒绝原因不是台账自身（可能是别的守卫）"
[ ! -s "$LEDGER18" ] \
  && pass "自锚条目没有写进台账" || fail "自锚条目被写进了台账"

# ===================================================================
echo "--- 断言 19: 干净文件 ⇒ add 成功，且 fileSha256 与实际一致 ---"
LEDGER19="$REPO2/ledger19.jsonl"; : > "$LEDGER19"
set +e
python3 "$ADJ" add --ledger "$LEDGER19" --repo-root "$REPO2" \
  --match '某个结论' --file 'clean.txt' --severity P1 \
  --verdict confirmed --note '断言19用例' \
  > "$TEST_DIR/a19.out" 2> "$TEST_DIR/a19.err"
RC19=$?
set -e
[ "$RC19" = "0" ] \
  && pass "干净文件允许写锚（退出码 0）" || fail "干净文件被拒（退出码 ${RC19}）"
COUNT19=$(grep -c . "$LEDGER19" || true)
[ "$COUNT19" = "1" ] \
  && pass "台账写入 1 条" || fail "台账应写入 1 条，实得 ${COUNT19}"
SHA19=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$REPO2/clean.txt")
REC19=$(python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1],encoding='utf-8') if l.strip()]
print(rows[0].get('fileSha256','') if rows else '')
" "$LEDGER19")
[ "$REC19" = "$SHA19" ] \
  && pass "fileSha256 与文件实际内容一致" || fail "fileSha256 与实际不一致：记的是 ${REC19:0:12} 实际是 ${SHA19:0:12}"
REC19F=$(python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1],encoding='utf-8') if l.strip()]
print(rows[0].get('file','') if rows else '')
" "$LEDGER19")
[ "$REC19F" = "clean.txt" ] \
  && pass "file 字段原样入库" || fail "file 字段实得：${REC19F}"

# ===================================================================
echo "--- 断言 20: audit 行为级（正则编译 / 锚点失效 / 缺失 / 无锚 / 只读）---"
# 背景（核验员 P1-1）：台账**自己**是绿的（JSON 合法、行数对）⇒ 而结论可能
# 早就死了（正则编译不过 / 锚点 sha 对不上）⇒ advisory 下不阻断 ⇒ 没人知道。
# ⇒ audit 必须把「静默失效」变成**看得见的数**。
LEDGER20="$REPO2/ledger20.jsonl"
cat > "$LEDGER20" <<EOF
{"match": "坏正则(未闭合", "verdict": "confirmed", "note": "正则编译不过", "severity": "P1", "adjudicatedAt": "2026-11-05T00:00:00Z", "expiresAt": "2099-11-05T00:00:00Z"}
{"match": "锚点失效", "file": "clean.txt", "fileSha256": "0000000000000000000000000000000000000000000000000000000000000000", "verdict": "confirmed", "note": "锚点对不上", "severity": "P1", "adjudicatedAt": "2026-11-05T00:00:00Z", "expiresAt": "2099-11-05T00:00:00Z"}
{"match": "没有锚", "verdict": "confirmed", "note": "无 file 锚", "severity": "P2", "adjudicatedAt": "2026-11-05T00:00:00Z", "expiresAt": "2099-11-05T00:00:00Z"}
{"match": "文件没了", "file": "gone.txt", "fileSha256": "deadbeef", "verdict": "confirmed", "note": "锚点文件缺失", "severity": "P3", "adjudicatedAt": "2026-11-05T00:00:00Z", "expiresAt": "2099-11-05T00:00:00Z"}
EOF
SHA20BEFORE=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$LEDGER20")
set +e
python3 "$ADJ" audit --ledger "$LEDGER20" --repo-root "$REPO2" \
  > "$TEST_DIR/a20.out" 2> "$TEST_DIR/a20.err"
RC20=$?
set -e
[ "$RC20" = "1" ] \
  && pass "audit 遇到编译失败的正则 ⇒ 退出码 1（硬错）" || fail "audit 退出码应为 1，实得 ${RC20}"
grep -q "正则编译失败" "$TEST_DIR/a20.err" \
  && pass "audit 在 stderr 报出正则编译失败" || fail "audit 没有在 stderr 报出正则编译失败"
grep -qF "match 正则编译失败：**1** 条" "$TEST_DIR/a20.out" \
  && pass "audit 报出编译失败条数 = 1" || fail "audit 没报出编译失败条数 = 1"
grep -qF "锚点**已失效**" "$TEST_DIR/a20.out" \
  && pass "audit 报出锚点失效" || fail "audit 没报出锚点失效"
grep -qF "锚点文件**不存在**：1 条" "$TEST_DIR/a20.out" \
  && pass "audit 报出锚点文件缺失 = 1 条" || fail "audit 没报出锚点文件缺失 = 1 条"
grep -qF "无 file 锚（结论**永不**自动失效）：1 条" "$TEST_DIR/a20.out" \
  && pass "audit 报出无锚条数 = 1" || fail "audit 没报出无锚条数 = 1"
SHA20AFTER=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$LEDGER20")
[ "$SHA20BEFORE" = "$SHA20AFTER" ] \
  && pass "audit 是只读的（台账内容未变）" || fail "audit 改动了台账"

# 只有锚点失效（无编译失败）⇒ 默认**不阻断**，--fail-on-stale 才阻断。
LEDGER20B="$REPO2/ledger20b.jsonl"
cat > "$LEDGER20B" <<EOF
{"match": "锚点失效", "file": "clean.txt", "fileSha256": "0000000000000000000000000000000000000000000000000000000000000000", "verdict": "confirmed", "note": "锚点对不上", "severity": "P1", "adjudicatedAt": "2026-11-05T00:00:00Z", "expiresAt": "2099-11-05T00:00:00Z"}
EOF
set +e
python3 "$ADJ" audit --ledger "$LEDGER20B" --repo-root "$REPO2" > "$TEST_DIR/a20b.out" 2>&1
RC20B=$?
set -e
[ "$RC20B" = "0" ] \
  && pass "只有锚点失效时 audit 默认不阻断（存量分批重验）" || fail "audit 默认应不阻断，实得 ${RC20B}"
grep -qF "**1** 条" "$TEST_DIR/a20b.out" \
  && pass "audit 报出失效条数 = 1" || fail "audit 没报出失效条数 = 1"
set +e
python3 "$ADJ" audit --ledger "$LEDGER20B" --repo-root "$REPO2" --fail-on-stale \
  > "$TEST_DIR/a20c.out" 2> "$TEST_DIR/a20c.err"
RC20C=$?
set -e
[ "$RC20C" = "1" ] \
  && pass "--fail-on-stale 时锚点失效 ⇒ 退出码 1" || fail "--fail-on-stale 时退出码应为 1，实得 ${RC20C}"

# ===================================================================
echo
if [[ $FAILURES -eq 0 ]]; then
  echo "✅ review-adjudicate 全部断言通过"
  exit 0
else
  echo "❌ review-adjudicate 有 ${FAILURES} 项断言失败" >&2
  exit 1
fi
