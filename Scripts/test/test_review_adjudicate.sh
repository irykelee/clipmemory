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
grep -q 'review-adjudicate.py" apply' "$GATE" \
  && pass "门禁调用了 review-adjudicate.py apply" || fail "门禁未调用 review-adjudicate.py apply"
grep -q 'if \[\[ "\$EFFECTIVE_VERDICT" == "FAIL" \]\]' "$GATE" \
  && pass "阻断判据用 EFFECTIVE_VERDICT" || fail "阻断判据未用 EFFECTIVE_VERDICT"
grep -q 'REVIEW_GATE_MODE' "$GATE" \
  && pass "门禁支持 REVIEW_GATE_MODE" || fail "门禁未支持 REVIEW_GATE_MODE"
grep -q 'if \[\[ "\$VERDICT" == "FAIL" \]\]' "$GATE" \
  && fail "门禁仍直接用模型结论 \$VERDICT 判定阻断" || pass "门禁不再直接用模型结论判阻断"

# ===================================================================
echo
if [[ $FAILURES -eq 0 ]]; then
  echo "✅ review-adjudicate 全部断言通过"
  exit 0
else
  echo "❌ review-adjudicate 有 ${FAILURES} 项断言失败" >&2
  exit 1
fi
