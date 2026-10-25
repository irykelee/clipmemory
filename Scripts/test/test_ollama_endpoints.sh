#!/bin/bash
# TDD test for githooks/ollama-endpoints.sh — 审核门「本地 ollama 端点发现」
#
# 背景（ID-REVIEW-1033, 2026-10-25）：本机可能**同时**跑着多个 ollama 服务端。
# 实测：`.app` 自带的 0.24.0 占着标准端口 11434，但**跑不了 gemma4 的 mlx 架构**；
# Homebrew 的 0.40.11 跑在 11435 上一切正常。⇒ 写死端口 ⇒ 链首**静默失效**
# ⇒ 门禁退到外部 free 额度 ⇒ 额度耗尽时整条链死。
#
# ⚠️ 本测试的第一版**漏掉了两个真 bug**（实测复现后补上，勿再删）：
#   ① 假 curl 桩**永远 exit 0** —— 把「端点连不上」（curl 退出码 7）建模成了
#      「curl 成功但返回空」⇒ 于是没能暴露生产代码里
#      `ver=$(curl ... | sed ...)` 在 `set -euo pipefail` 下**整体中止**的缺陷：
#      11435 可用 + 11434 不可达 ⇒ 函数输出为空、exit 7 ⇒ **可用的端点被
#      一起丢掉** ⇒ 门禁完全跳过本地链首（正是本单元要消灭的失败模式）。
#      ⇒ 桩现在必须能区分「返回空」与「连不上」。
#   ② 测试全程用 PATH 上的 bash（5.x）⇒ 漏掉 **macOS 自带 /bin/bash 3.2** 下
#      `set -u` + 空数组展开会让本单元**当场崩**（`explicit[@]: unbound variable`）
#      ⇒ 门禁在默认 PATH 环境里直接死。⇒ 现在额外用 /bin/bash 跑一遍。
#
# 覆盖的判定：
#   1. 没有显式指定时：内置端口按**版本号降序**（新版在前）
#   2. 显式指定的 OLLAMA_HOST **排最前**（意图优先）
#   3. 显式候选与内置端口**去重**（同一个端点不出现两次）
#   4. 额外候选（REVIEW_OLLAMA_ENDPOINTS）**按逗号**分隔，且排在内置之前
#      （URL 本身含冒号 ⇒ 不能用冒号分隔，否则 http://host:port 会被切碎）
#   5. 探不到版本的端点排最后（兜底）
#   6. 门禁真的用了这个单元（接线检查）
#   7. **端点不可达（curl 非零退出）不得牵连其它端点**（生产 bug ①）
#   8. **显式候选内部的重复项必须去重**（生产 bug ②）
#   9. **macOS 系统 bash 3.2 下不崩**（生产 bug ③）
#
# Run: bash Scripts/test/test_ollama_endpoints.sh
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
UNIT="$SCRIPT_DIR/githooks/ollama-endpoints.sh"
GATE="$SCRIPT_DIR/githooks/orca-auto-review.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

FAILURES=0
pass() { echo "✅ $1"; }
fail() { echo "❌ $1" >&2; FAILURES=$((FAILURES + 1)); }

# --- 假 curl：按 URL 返回预置的版本号 ---
# FIXTURE 每行: <url>\t<version>
#   version 为空   = 端点可达但返回的内容里没有版本号（探不到版本）
#   version 为 "-" = **端点不可达**（curl 连不上 ⇒ 真实退出码 7）
#   其它          = 正常返回该版本号
STUB="$TEST_DIR/bin"
mkdir -p "$STUB"
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"
while [[ "${1:-}" == -* ]]; do shift; done
url="${@: -1}"
# ⚠️ 生产代码探测的是 `<base>/api/version`，而 FIXTURE 里写的是 **base**
#    （不带 /api/version）⇒ 这里把后缀剥掉再查表。
#    ⚠️ 第一版**漏了这个后缀** ⇒ 桩永远匹配不上 ⇒ 永远 exit 0 ⇒
#    「端点不可达」这条分支**从未被真正执行过**，断言是「因错得对」。
#    （变异验证 M-A 抓出来的：把生产代码改坏，测试照样全绿。）
base="${url%/api/version}"
if [[ -n "${FIXTURE:-}" && -f "$FIXTURE" ]]; then
  while IFS=$'\t' read -r u v; do
    if [[ "$u" == "$base" ]]; then
      case "$v" in
        "")     exit 0 ;;                       # 可达但没有版本号
        "-")    exit 7 ;;                       # 连不上（真实 curl 的退出码）
        *)      printf '{"version":"%s"}' "$v"; exit 0 ;;
      esac
    fi
  done < "$FIXTURE"
fi
exit 0
EOF
chmod +x "$STUB/curl"

# --- 跑一个场景：设置 fixture + 环境变量，打印发现的端点 ---
# $1=fixture $2=要用的 bash（默认 PATH 上的 bash） $3..=env 设置
discover() {
  local fixture="$1"; shift
  local bash_bin="${1:-bash}"; shift
  env FIXTURE="$fixture" PATH="$STUB:$PATH" "$@" "$bash_bin" -c '
    set -euo pipefail
    source "$1"
    ollama_discover_endpoints
  ' _ "$UNIT"
}

# ===================================================================
echo "--- 断言 0: 桩自身是可信的（自检）---"
# ⚠️ 这一条不是测生产代码，是测**测试桩**。
#   第一版桩把 FIXTURE 的 base URL 与生产代码探测的 `<base>/api/version`
#   对不上 ⇒ 桩永远匹配不上 ⇒ 永远 exit 0 ⇒ 「端点不可达」分支**从未执行过**
#   ⇒ 断言 7 是「因错得对」（变异验证 M-A 抓出来的）。
#   ⇒ 桩一旦失真，后面所有断言都会在**错误的模拟**上给出虚假的绿灯。
FS="$TEST_DIR/f0.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t-\n' > "$FS"
set +e
FIXTURE="$FS" PATH="$STUB:$PATH" curl -s -m 2 http://127.0.0.1:11435/api/version > "$TEST_DIR/o0a" 2>/dev/null
RC_OK=$?
FIXTURE="$FS" PATH="$STUB:$PATH" curl -s -m 2 http://127.0.0.1:11434/api/version > "$TEST_DIR/o0b" 2>/dev/null
RC_BAD=$?
set -e
[ "$RC_OK" = "0" ] && grep -q '"version":"0.40.11"' "$TEST_DIR/o0a" \
  && pass "桩能返回可达端点的版本号" \
  || fail "桩对可达端点没有正确返回（exit=$RC_OK，内容=$(cat "$TEST_DIR/o0a")）"
[ "$RC_BAD" = "7" ] \
  && pass "桩能模拟「端点连不上」（curl 退出码 7）" \
  || fail "桩没有模拟出「连不上」（exit=$RC_BAD，应为 7）——「不可达」分支根本没被执行过"

echo "--- 断言 1: 内置端口按版本号降序（新版在前）---"
F="$TEST_DIR/f1.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t0.24.0\n' > "$F"
OUT=$(discover "$F" bash env -u OLLAMA_HOST -u REVIEW_OLLAMA_ENDPOINTS)
FIRST=$(printf '%s\n' "$OUT" | head -1)
[ "$FIRST" = "http://127.0.0.1:11435" ] \
  && pass "版本号新的端点排第一（$FIRST）" || fail "版本排序错，第一行是 $FIRST"
printf '%s\n' "$OUT" | grep -q "11434" \
  && pass "旧端点仍在候选里（作为兜底）" || fail "旧端点被丢掉了"

echo "--- 断言 2: 显式 OLLAMA_HOST 排最前 ---"
OUT=$(discover "$F" bash env OLLAMA_HOST=http://127.0.0.1:11434)
FIRST=$(printf '%s\n' "$OUT" | head -1)
[ "$FIRST" = "http://127.0.0.1:11434" ] \
  && pass "显式指定的端点排第一" || fail "显式端点没排第一，第一行是 $FIRST"

echo "--- 断言 3: 显式候选与内置端口去重 ---"
COUNT=$(discover "$F" bash env OLLAMA_HOST=http://127.0.0.1:11434 | grep -c "11434" || true)
[ "$COUNT" = "1" ] \
  && pass "同一端点只出现一次（计数 $COUNT）" || fail "同一端点出现了 $COUNT 次"

echo "--- 断言 4: 额外候选按逗号分隔且排在前面 ---"
F4="$TEST_DIR/f4.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t0.24.0\nhttp://127.0.0.1:19999\t0.40.11\n' > "$F4"
OUT=$(discover "$F4" bash env -u OLLAMA_HOST REVIEW_OLLAMA_ENDPOINTS=http://127.0.0.1:19999,http://127.0.0.1:11435)
FIRST=$(printf '%s\n' "$OUT" | head -1)
[ "$FIRST" = "http://127.0.0.1:19999" ] \
  && pass "额外候选排第一" || fail "额外候选没排第一，第一行是 $FIRST"
# 冒号分隔会把 URL 切碎 —— 这里确认逗号分隔下 URL 完整
printf '%s\n' "$OUT" | grep -q "http://127.0.0.1:19999" \
  && pass "URL 没被切碎（逗号分隔）" || fail "URL 被切碎了：$(printf '%s\n' "$OUT" | tr '\n' ' ')"

echo "--- 断言 5: 探不到版本的端点排最后 ---"
F5="$TEST_DIR/f5.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t\n' > "$F5"
OUT=$(discover "$F5" bash env -u OLLAMA_HOST -u REVIEW_OLLAMA_ENDPOINTS)
LAST=$(printf '%s\n' "$OUT" | tail -1)
[ "$LAST" = "http://127.0.0.1:11434" ] \
  && pass "探不到版本的端点排最后" || fail "探不到版本的端点位置错，最后一行是 $LAST"

echo "--- 断言 6: 门禁真的用了这个单元 ---"
grep -q 'ollama-endpoints.sh' "$GATE" \
  && pass "门禁引用了端点发现单元" || fail "门禁没有引用端点发现单元"
grep -q 'ollama_discover_endpoints' "$GATE" \
  && pass "门禁调用了 ollama_discover_endpoints" || fail "门禁没有调用 ollama_discover_endpoints"
grep -q -- '--endpoint' "$GATE" \
  && pass "门禁把端点传给客户端（--endpoint）" || fail "门禁没有把端点传给客户端"

# ===================================================================
echo "--- 断言 7: 端点不可达（curl 非零退出）不得牵连其它端点 ---"
# 生产 bug ①：`ver=$(curl ... | sed ...)` 在 `set -euo pipefail` 下，
# curl 连不上时退出码 7 ⇒ 整个函数中止 ⇒ **排在前面、明明可用的端点
# 也一起被丢掉** ⇒ 门禁完全跳过本地链首。
# 场景：11435 可用（0.40.11）、11434 连不上（curl exit 7）。
F7="$TEST_DIR/f7.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t-\n' > "$F7"
set +e
OUT=$(discover "$F7" bash env -u OLLAMA_HOST -u REVIEW_OLLAMA_ENDPOINTS 2>"$TEST_DIR/e7")
RC=$?
set -e
[ "$RC" = "0" ] \
  && pass "不可达端点没有让函数中止（exit 0）" \
  || fail "不可达端点让函数中止了（exit $RC）：$(head -c 200 "$TEST_DIR/e7")"
printf '%s\n' "$OUT" | grep -q "http://127.0.0.1:11435" \
  && pass "可用的端点仍然被返回（11435 没被牵连）" \
  || fail "可用的 11435 被牵连丢掉了，输出=[$(printf '%s\n' "$OUT" | tr '\n' ' ')]"
printf '%s\n' "$OUT" | grep -q "http://127.0.0.1:11434" \
  && pass "不可达端点仍作为兜底候选列出" \
  || fail "不可达端点没有列出"

echo "--- 断言 8: 显式候选内部的重复项必须去重 ---"
# 生产 bug ②：按 explicit 原样输出 ⇒ 用户写两遍同一个端点就会被尝试两次
# ⇒ 白等一个完整超时（REVIEW_OLLAMA_TIMEOUT 默认 900s）。
OUT=$(discover "$F" bash env -u OLLAMA_HOST \
        REVIEW_OLLAMA_ENDPOINTS=http://127.0.0.1:11435,http://127.0.0.1:11435)
COUNT=$(printf '%s\n' "$OUT" | grep -c "http://127.0.0.1:11435" || true)
[ "$COUNT" = "1" ] \
  && pass "显式段内部的重复端点只出现一次（计数 $COUNT）" \
  || fail "显式段内部的重复端点出现了 $COUNT 次"

echo "--- 断言 9: macOS 系统 bash 3.2 下不崩 ---"
# 生产 bug ③：macOS 自带 /bin/bash 是 3.2，`set -u` + 空数组的 "${arr[@]}"
# 会报 `explicit[@]: unbound variable` 并让整个门禁崩掉。
if [[ -x /bin/bash ]] && /bin/bash --version 2>/dev/null | grep -q "version 3\."; then
  set +e
  OUT=$(discover "$F" /bin/bash env -u OLLAMA_HOST -u REVIEW_OLLAMA_ENDPOINTS 2>"$TEST_DIR/e9")
  RC=$?
  set -e
  [ "$RC" = "0" ] \
    && pass "bash 3.2 下不崩（exit 0）" \
    || fail "bash 3.2 下崩了（exit $RC）：$(head -c 200 "$TEST_DIR/e9")"
  FIRST3=$(printf '%s\n' "$OUT" | head -1)
  [ "$FIRST3" = "http://127.0.0.1:11435" ] \
    && pass "bash 3.2 下排序结果正确（$FIRST3）" \
    || fail "bash 3.2 下排序错，第一行是 $FIRST3"
else
  echo "⏭️  跳过：/bin/bash 不是 3.x（当前：$(/bin/bash --version 2>/dev/null | head -1)）"
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "✅ ollama-endpoints 全部断言通过"
  exit 0
else
  echo "❌ ollama-endpoints 有 ${FAILURES} 项断言失败" >&2
  exit 1
fi
