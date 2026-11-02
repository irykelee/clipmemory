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
#
# ⚠️ ID-REVIEW-1049 第六轮（2026-11-01 深夜，独立核验员 P1-1 / P1-2）：
#   第五轮把「锁的清单」搬到了树外（`Scripts/canary-gate-locks.txt`），
#   但**清单自己没有任何锁** ⇒ 掏空清单（只剩注释）⇒ 本脚本「逐条核对」
#   逐条通过（0 条 = 0 个问题）⇒ exit 0 ⇒ ⇒ **V8 并没有关闭**。
#   ⇒ ⇒ 修法：**本脚本自己**持有清单的三个常量 ——
#     `EXPECTED_FILE_ENTRIES` / `EXPECTED_GUARD_ENTRIES` /
#     `EXPECTED_MANIFEST_SHA256` ⇒ 清单被掏空 / 被改 ⇒ exit 1；
#     且每个 `guard` 条目还带**最少断言数** ⇒ 守卫被掏空（函数还在、
#     断言没了）⇒ exit 1。
#   ⇒ ⇒ *清单在锁的外面 ⇒ **锁必须在清单的外面**。*
set -uo pipefail

# ⚠ ID-REVIEW-1049 第六轮：模式开关 ⇒ CI 里「契约 + 接线」与「清单完整性」
#   各自一个 step ⇒ 失败时**一眼看得出是哪一层**（独立核验员 P3-5：第五轮
#   的新机制**寄生**在第四轮的 step 里 ⇒ 失败归属不清）。
#   all（默认，release.sh 用它）= 全部 ；contract = 契约 + 接线 ；
#   manifest = 只跑清单自身的完整性（条目数 + sha256 + 守卫断言数）。
MODE="${1:-all}"
MODE="${MODE#--}"   # `--manifest` 与 `manifest` 都接受
if [[ "$MODE" != "all" && "$MODE" != "contract" && "$MODE" != "manifest" ]]; then
  echo "用法：$0 [all|contract|manifest]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/Scripts/verify-production-canaries.py"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
RELEASE_SH="$REPO_ROOT/Scripts/release.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
asserts=0
ok()  { asserts=$((asserts + 1)); echo "✅ $1"; }
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
if [[ "$MODE" != "manifest" ]]; then
run_gate() { # $1 = log path, $2 = expected exit code, $3 = 说明
  local log="$1" want="$2" desc="$3" got=0
  python3 "$GATE" "$log" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    ok "$desc ⇒ 退出码 $got"
  else
    bad "$desc ⇒ 期望退出码 ${want}，实得 $got"
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
fi  # ← 模式：contract

# ---------------------------------------------------------------- ③ 锁的清单（**树外**）
if [[ "$MODE" != "contract" ]]; then
# ⚠️ ID-REVIEW-1049 第五轮：第四轮的三把锁（㉑ / ㉒ / 本脚本）**自己**零保护
#   —— 独立核验员实测：只删 ㉑ + ㉒ 两个函数 ⇒ 全量 1439/4/0 全绿、CI 绿、
#   本脚本 exit 0 ⇒ ⇒ 锁的「清单」必须搬到**锁的外面**（`Scripts/canary-gate-locks.txt`）
#   ⇒ 由本脚本（树外）逐条核对。
# ⚠️ ID-REVIEW-1049 第六轮（独立核验员 P1-1）：**清单自己也会被掏空** ⇒
#   「逐条核对」在 0 条时**逐条通过** ⇒ exit 0 ⇒ ⇒ 清单的**条目数**与**内容
#   sha256** 必须硬编码在**本脚本**里 ⇒ 清单在锁的外面 ⇒ **锁在清单的外面**。
#
# ⚠️ ID-REVIEW-1049 第六轮（独立核验员 P1-2）：清单只查「函数**存在**」⇒
#   把 ㉒ 的**断言**删掉（函数保留）⇒ 清单照样 exit 0 ⇒ 守卫名存实亡
#   ⇒ ⇒ `guard` 条目多带一个字段：该守卫体内**最少**的**断言数**。
MANIFEST="$REPO_ROOT/Scripts/canary-gate-locks.txt"

# ⚠️ 这三个常量就是「清单的锁」⇒ 改清单必须**同步**改它们 ⇒ 任何清单改动
#   都是**两个文件**的协同改动 ⇒ ⇒ **review 里一眼看得见**（本文件的全部意义）。
#
# ⚠️ **怎么重新生成 EXPECTED_MANIFEST_SHA256**（审核门 P1 指到的缺口，
#   2026-11-01 深夜已补 —— 原先只写「硬编码」，没写**口径** ⇒ 改清单的人
#   没法自己重算）：
#
#     python3 -c "import hashlib;p='Scripts/canary-gate-locks.txt';raw=open(p,encoding='utf-8').read();eff=[l.strip() for l in raw.splitlines() if l.strip() and not l.strip().startswith('#')];print(hashlib.sha256(('\n'.join(eff)+'\n').encode('utf-8')).hexdigest())"
#
#   ⇒ **口径**：清单的**有效行**（非空、非注释）**逐行 strip** ⇒ 用换行连接
#   ⇒ 末尾**再加一个**换行 ⇒ 取 sha256。
#   ⇒ ⇒ **注释不参与哈希** ⇒ 日常改注释**不必**重算 ⇒ 改**条目**才必须。
EXPECTED_FILE_ENTRIES=3
EXPECTED_GUARD_ENTRIES=9
EXPECTED_MANIFEST_SHA256=98fe0e37d390cdf70468ccff75fb9a52de2589ac67b6c353c6643f3f09ea4c3e

if [[ ! -f "$MANIFEST" ]]; then
  # ⚠️ 这里**不能**用反引号：双引号里的反引号是**命令替换** ⇒ bash 会去执行
  #    那个文件 ⇒ 报 "Permission denied" 且把路径吞成空 ⇒ 报错文案反而失真
  #    （2026-11-01 实测踩到）⇒ ⇒ 用「」。
  bad "锁的清单缺失（Scripts/canary-gate-locks.txt）—— 清单在**锁的外面**"
  bad "  ⇒ 缺失 = 没人知道少了哪把锁 ⇒ 必须失败，不得静默放过"
else
  manifest_out="$(python3 - "$REPO_ROOT" "$MANIFEST" \
    "$EXPECTED_FILE_ENTRIES" "$EXPECTED_GUARD_ENTRIES" "$EXPECTED_MANIFEST_SHA256" <<'PY'
import hashlib
import os
import re
import sys

root, manifest = sys.argv[1], sys.argv[2]
want_files, want_guards = int(sys.argv[3]), int(sys.argv[4])
want_sha = sys.argv[5]

problems = []

with open(manifest, encoding="utf-8") as fh:
    raw = fh.read()

# 「有效行」= 非空、非注释 ⇒ **注释不参与哈希** ⇒ 日常改注释不必动本脚本。
effective = [
    line.strip() for line in raw.splitlines()
    if line.strip() and not line.strip().startswith("#")
]

# ① **内容 sha256** ⇒ 清单被**改一条**（哪怕个数没变）也必须被抓。
sha = hashlib.sha256(("\n".join(effective) + "\n").encode("utf-8")).hexdigest()
if sha != want_sha:
    problems.append(
        "清单有效行的 sha256 = " + sha + " ≠ 期望 " + want_sha
        + " ⇒ 清单被**改过**（哪怕条目个数没变）"
    )

# ② **条目数棘轮** ⇒ 清单被**掏空**（只剩注释）必须被抓。
n_file = sum(1 for line in effective if line.split()[0] == "file")
n_guard = sum(1 for line in effective if line.split()[0] == "guard")
if n_file != want_files:
    problems.append(
        "清单里 `file` 条目 = " + str(n_file) + " ≠ 期望 " + str(want_files)
        + " ⇒ 清单被掏空 / 被删条"
    )
if n_guard != want_guards:
    problems.append(
        "清单里 `guard` 条目 = " + str(n_guard) + " ≠ 期望 " + str(want_guards)
        + " ⇒ 清单被掏空 / 被删条"
    )

FUNC_PATTERN = (
    r"^[ \t]*(?:(?:public|private|internal|fileprivate|static|final|override"
    r"|class|mutating|@[\w.]+)\s+)*func\s+"
)
ASSERT_PATTERN = re.compile(r"\bXCTAssert\w*|\bXCTFail\b|\bXCTUnwrap\b")


def func_body(source, name):
    """The body of `func <name>(...)`.

    ⚠️ Deliberately **indentation**-delimited (not brace counting): a `}`
    inside a string literal would break brace counting, and this repo's Swift
    is SwiftLint-formatted ⇒ indentation is the stable delimiter.
    """
    lines = source.splitlines()
    pattern = re.compile(FUNC_PATTERN + re.escape(name) + r"\s*\(")
    for i, line in enumerate(lines):
        if pattern.match(line):
            indent = len(line) - len(line.lstrip())
            for j in range(i + 1, len(lines)):
                stripped = lines[j].strip()
                own_indent = len(lines[j]) - len(lines[j].lstrip())
                if stripped == "}" and own_indent == indent:
                    return "\n".join(lines[i + 1:j])
    return None


def assertion_count(source, name):
    """How many assertions the guard really has.

    ⇒ The **audit** guard delegates to `assert*` private helpers ⇒ their
    assertions count too (otherwise it would look toothless while it is not).
    """
    body = func_body(source, name)
    if body is None:
        return None
    count = len(ASSERT_PATTERN.findall(body))
    for helper in sorted(set(re.findall(r"\b(assert[A-Za-z0-9_]*)\s*\(", body))):
        if helper == name:
            continue
        helper_body = func_body(source, helper)
        if helper_body is None:
            continue
        count += len(ASSERT_PATTERN.findall(helper_body))
    return count


for line in effective:
    parts = line.split()
    if parts[0] == "file" and len(parts) == 3:
        rel, want = parts[1], parts[2]
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            problems.append("清单声明的文件不存在：" + rel)
            continue
        try:
            want = int(want)
        except ValueError:
            problems.append("清单里 `file` 的数量不是整数：" + line)
            continue
        source = open(path, encoding="utf-8").read()
        n = len(re.findall(r"func\s+test[A-Za-z0-9_]*\s*\(", source))
        if n < want:
            problems.append(
                rel + " 的 `func test` 数量 = " + str(n) + " < 清单声明的 "
                + str(want) + " ⇒ 有守卫被删了"
            )
        else:
            print("✅ " + rel + " 的 `func test` 数量 = " + str(n) + " ≥ " + str(want))
    elif parts[0] == "guard" and len(parts) == 4:
        name, rel, want = parts[1], parts[2], parts[3]
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            problems.append("清单声明的守卫所属文件不存在：" + rel)
            continue
        try:
            want = int(want)
        except ValueError:
            problems.append("清单里 `guard` 的断言数不是整数：" + line)
            continue
        source = open(path, encoding="utf-8").read()
        if func_body(source, name) is None:
            problems.append("守卫 " + name + " **不存在**于 " + rel + " ⇒ 它被删了")
            continue
        n = assertion_count(source, name)
        if n is None or n < want:
            problems.append(
                "守卫 " + name + " 的断言数 = " + str(n) + " < 清单声明的 "
                + str(want)
                + " ⇒ 它的断言被**掏空**了（函数还在 ⇒ 只查「存在」抓不到）"
            )
        else:
            print("✅ 守卫 " + name + " 在 " + rel + " 里存在，断言数 = "
                  + str(n) + " ≥ " + str(want))
    else:
        problems.append("清单里有无法识别的行：" + line)

for p in problems:
    print("❌ " + p)
sys.exit(1 if problems else 0)
PY
)"
  manifest_rc=$?
  printf '%s\n' "$manifest_out"
  # 清单核对段自己打印的 ✅ 也计入断言数（⇒ 汇总行的条数 = 全脚本的断言数）
  while IFS= read -r line; do
    case "$line" in
      "✅"*) asserts=$((asserts + 1)) ;;
    esac
  done <<< "$manifest_out"
  if [[ "$manifest_rc" == "0" ]]; then
    ok "锁的清单（树外）逐条核对通过"
  else
    bad "锁的清单（树外）核对失败 —— 上面每一条 ❌ 都是「一把锁不见了」"
  fi
fi
fi  # ← 模式：manifest

# ---------------------------------------------------------------- 汇总
# ⚠️ 机器可读的汇总行 ⇒ 台账**不**再 hard-code「几条 ✅」（条数会随断言增减
#   而漂移 ⇒ 写死就会变成下一次陈旧数字的来源 ⇒ 第五轮就是这么错的）。
echo "SUMMARY mode=$MODE asserts=$asserts fails=$fails"
if [[ "$fails" == "0" ]]; then
  echo "✅ 树外闸门的契约与接线全部成立（mode=${MODE}）"
  exit 0
fi
echo "❌ 树外闸门的契约/接线有 $fails 处不成立（mode=${MODE}）"
exit 1
