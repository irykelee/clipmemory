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

# ---------------------------------------------------------------- ③ 锁的清单（**树外**）
# ⚠️ ID-REVIEW-1049 第五轮：第四轮的三把锁（㉑ / ㉒ / 本脚本）**自己**零保护
#   —— 独立核验员实测：只删 ㉑ + ㉒ 两个函数 ⇒ 全量 1439/4/0 全绿、CI 绿、
#   本脚本 exit 0 ⇒ ⇒ 锁的「清单」必须搬到**锁的外面**（`Scripts/canary-gate-locks.txt`）
#   ⇒ 由本脚本（树外）逐条核对。
MANIFEST="$REPO_ROOT/Scripts/canary-gate-locks.txt"
if [[ ! -f "$MANIFEST" ]]; then
  # ⚠️ 这里**不能**用反引号：双引号里的反引号是**命令替换** ⇒ bash 会去执行
  #    那个文件 ⇒ 报 "Permission denied" 且把路径吞成空 ⇒ 报错文案反而失真
  #    （2026-11-01 实测踩到）⇒ ⇒ 用「」。
  bad "锁的清单缺失（Scripts/canary-gate-locks.txt）—— 清单在**锁的外面**"
  bad "  ⇒ 缺失 = 没人知道少了哪把锁 ⇒ 必须失败，不得静默放过"
else
  manifest_out="$(python3 - "$REPO_ROOT" "$MANIFEST" <<'PY'
import os, re, sys
root, manifest = sys.argv[1], sys.argv[2]
problems = []
with open(manifest, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if parts[0] == "file" and len(parts) == 3:
            rel, want = parts[1], int(parts[2])
            path = os.path.join(root, rel)
            if not os.path.isfile(path):
                problems.append(f"清单声明的文件不存在：{rel}")
                continue
            src = open(path, encoding="utf-8").read()
            n = len(re.findall(r"func\s+test[A-Za-z0-9_]*\s*\(", src))
            if n < want:
                problems.append(
                    f"{rel} 的 `func test` 数量 = {n} < 清单声明的 {want} ⇒ 有守卫被删了"
                )
            else:
                print(f"✅ {rel} 的 `func test` 数量 = {n} ≥ {want}")
        elif parts[0] == "guard" and len(parts) == 3:
            name, rel = parts[1], parts[2]
            path = os.path.join(root, rel)
            if not os.path.isfile(path):
                problems.append(f"清单声明的守卫所属文件不存在：{rel}")
                continue
            src = open(path, encoding="utf-8").read()
            if re.search(r"func\s+" + re.escape(name) + r"\s*\(", src):
                print(f"✅ 守卫 {name} 在 {rel} 里存在")
            else:
                problems.append(f"守卫 {name} **不存在**于 {rel} ⇒ 它被删了")
        else:
            problems.append(f"清单里有无法识别的行：{line}")
for p in problems:
    print(f"❌ {p}")
sys.exit(1 if problems else 0)
PY
)"
  manifest_rc=$?
  printf '%s\n' "$manifest_out"
  if [[ "$manifest_rc" == "0" ]]; then
    ok "锁的清单（树外）逐条核对通过"
  else
    bad "锁的清单（树外）核对失败 —— 上面每一条 ❌ 都是「一把锁不见了」"
  fi
fi

# ---------------------------------------------------------------- 汇总
if [[ "$fails" == "0" ]]; then
  echo "✅ 树外闸门的契约与接线全部成立"
  exit 0
fi
echo "❌ 树外闸门的契约/接线有 $fails 处不成立"
exit 1
