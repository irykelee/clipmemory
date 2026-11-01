#!/usr/bin/env bash
# ID-REVIEW-1049 第四轮（2026-11-01）：**树外闸门**自己的契约测试。
#
# ⚠️ **为什么需要它**（独立核验员 P1-1，2026-11-01 实测）：把
# `Scripts/verify-production-canaries.py` + `.github/workflows/ci.yml` 里调用
# 它的那一步 + `Scripts/release.sh` 里的闸门块**一起删掉** ⇒ 全量测试仍然
# **1436 / 4 skipped / 0 failures / TEST SUCCEEDED** ⇒ CI 绿、发版绿、
# 测试绿、**零告警** ⇒ ⇒ 第三轮的**唯一**新增机制可以被无声移除。
#
# ⇒ ⇒ *「谁说自己做到了」搬到了树外，但**树外那把锁没人锁**。*
#
# ⇒ 本测试断言两件事：
#   ① **退出码契约**：0 = 安全网开着 / 1 = 检查跑了但网关着 / 2 = 闸门坏了
#      ⇒ **中和点**在「skipped 日志必须返回 1」这一条：把脚本改成永远
#      `exit 0` ⇒ 这里立刻变红。
#   ② **接线**：ci.yml 与 release.sh 仍然调用它，且 CI 仍然区分退出码 2。
#
# ⚠️ **只读**：它只读仓库里的三个文件和临时目录里的合成日志 ⇒ 不碰用户的
# 偏好设置、钥匙串、剪贴板。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/Scripts/verify-production-canaries.py"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
RELEASE_SH="$REPO_ROOT/Scripts/release.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "✅ $1"; }
bad() { echo "❌ $1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------- 合成日志
canary_lines() { # $1 = outcome
  local o="$1"
  for t in testNoProductionPollution \
           testProductionDataBlobsAreUnchanged \
           testFirstLaunchFlagIsNeverChangedDuringTheSuite; do
    echo "Test Case '-[ClipMemoryTests.ZZZSuiteTeardownTests $t]' $o (0.001 seconds)."
  done
}

audit_line() { # $1 = outcome
  echo "Test Case '-[ClipMemoryTests.ZZZTheCanariesWereNotDisarmedTests testTheProductionCanariesWereNotDisarmed]' $1 (0.001 seconds)."
}

good_log="$TMP/good.log"
{ canary_lines passed; audit_line passed; } > "$good_log"

skipped_log="$TMP/skipped.log"
{
  echo "Test Case '-[ClipMemoryTests.ZZZSuiteTeardownTests testNoProductionPollution]' skipped (0.001 seconds)."
  canary_lines passed
  audit_line passed
} > "$skipped_log"

no_audit_log="$TMP/no_audit.log"
{ canary_lines passed; } > "$no_audit_log"

empty_log="$TMP/empty.log"
: > "$empty_log"

# ---------------------------------------------------------------- ① 退出码契约
run_gate() { # $1 = log path, $2 = expected exit code, $3 = 说明
  local log="$1" want="$2" desc="$3" got=0
  python3 "$GATE" "$log" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    ok "$desc ⇒ 退出码 $got"
  else
    bad "$desc ⇒ 期望退出码 $want，实得 $got"
  fi
}

run_gate "$good_log"     0 "三个 canary + 审计都 passed ⇒ 安全网开着"
run_gate "$skipped_log"  1 "有 canary 是 skipped ⇒ 安全网关着（**中和点：这里必须返回 1**）"
run_gate "$no_audit_log" 1 "canary 审计没有 passed ⇒ 无法证明安全网开着"
run_gate "$empty_log"    1 "日志里一个 passed 都没有 ⇒ 安全网关着"

got=0; python3 "$GATE" "$TMP/definitely-missing.log" >/dev/null 2>&1 || got=$?
if [[ "$got" == "2" ]]; then
  ok "日志文件不存在 ⇒ 退出码 2（闸门坏了）"
else
  bad "日志文件不存在 ⇒ 期望 2，实得 $got"
fi

got=0; python3 "$GATE" >/dev/null 2>&1 || got=$?
if [[ "$got" == "2" ]]; then
  ok "无参数 ⇒ 退出码 2（用法错误）"
else
  bad "无参数 ⇒ 期望 2，实得 $got"
fi

# ---------------------------------------------------------------- ② 接线
if grep -q "Scripts/verify-production-canaries.py" "$CI_YML"; then
  ok "ci.yml 仍然调用树外闸门"
else
  bad "ci.yml **不再**调用树外闸门 ⇒ 闸门形同虚设"
fi

if grep -q "Scripts/verify-production-canaries.py" "$RELEASE_SH"; then
  ok "release.sh 仍然调用树外闸门"
else
  bad "release.sh **不再**调用树外闸门 ⇒ 发版放行时不再核对安全网"
fi

# ci.yml 必须把「2 = 闸门坏了」与「1 = 网关着」**分开处理**
# ⇒ 两种合法写法：显式判 2（`== "2"`），或「除 0/1 外一律闸门坏了」（`!= "0"`）。
if grep -q '"\$code" != "0"' "$CI_YML" || grep -q '"\$code" == "2"' "$CI_YML"; then
  ok "ci.yml 区分了「闸门坏了」与「安全网关着」"
else
  bad "ci.yml 没有区分退出码 2 ⇒ 闸门坏了会被读成安全网关着"
fi

if grep -q "canary_gate" "$RELEASE_SH"; then
  ok "release.sh 有 canary_gate 三态分支"
else
  bad "release.sh 没有 canary_gate 分支"
fi

# ---------------------------------------------------------------- 汇总
if [[ "$fails" == "0" ]]; then
  echo "✅ 树外闸门的契约与接线全部成立"
  exit 0
fi
echo "❌ 树外闸门的契约/接线有 $fails 处不成立"
exit 1
