#!/bin/bash
# TDD test for githooks/ollama-endpoints.sh — 审核门「本地 ollama 端点发现」
#
# 背景（ID-REVIEW-1033, 2026-10-25）：本机可能**同时**跑着多个 ollama 服务端。
# 实测：`.app` 自带的 0.24.0 占着标准端口 11434，但**跑不了任何新模型架构**
# （gemma4 的 mlx 架构直接报 unsupported architecture）；Homebrew 的 0.40.11
# 跑在 11435 上能跑一切。⇒ 写死端口 ⇒ 链首**静默失效** ⇒ 门禁退到外部
# free 额度 ⇒ 额度耗尽时整条链死。
#
# 覆盖的判定：
#   1. 没有显式指定时：内置端口按**版本号降序**（新版在前）
#   2. 显式指定的 OLLAMA_HOST **排最前**（意图优先）
#   3. 显式候选与内置端口**去重**（同一个端点不出现两次）
#   4. 额外候选（REVIEW_OLLAMA_ENDPOINTS）**按逗号**分隔，且排在内置之前
#      （URL 本身含冒号 ⇒ 不能用冒号分隔，否则 http://host:port 会被切碎）
#   5. 探不到版本的端点排最后（兜底）
#   6. 门禁真的用了这个单元（接线检查）
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
STUB="$TEST_DIR/bin"
mkdir -p "$STUB"
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
# 用法: curl -s -m 2 <url>  → 从 FIXTURE 里查该 URL 的版本 JSON
url="${@: -1}"
while [[ "$1" == -* ]]; do shift; done
url="${@: -1}"
if [[ -n "${FIXTURE:-}" && -f "$FIXTURE" ]]; then
  # FIXTURE 每行: <url>\t<version>（version 为空表示该端点探不到）
  while IFS=$'\t' read -r u v; do
    if [[ "$u" == "$url" ]]; then
      if [[ -z "$v" ]]; then exit 0; fi
      printf '{"version":"%s"}' "$v"
      exit 0
    fi
  done < "$FIXTURE"
fi
exit 0
EOF
chmod +x "$STUB/curl"

# --- 跑一个场景：设置 fixture + 环境变量，打印发现的端点 ---
discover() {
  local fixture="$1"; shift
  env FIXTURE="$fixture" PATH="$STUB:$PATH" "$@" bash -c '
    source "$1"
    ollama_discover_endpoints
  ' _ "$UNIT"
}

# ===================================================================
echo "--- 断言 1: 内置端口按版本号降序（新版在前）---"
F="$TEST_DIR/f1.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t0.24.0\n' > "$F"
OUT=$(discover "$F" env -u OLLAMA_HOST -u REVIEW_OLLAMA_ENDPOINTS)
FIRST=$(printf '%s\n' "$OUT" | head -1)
[ "$FIRST" = "http://127.0.0.1:11435" ] \
  && pass "版本号新的端点排第一（$FIRST）" || fail "版本排序错，第一行是 $FIRST"
printf '%s\n' "$OUT" | grep -q "11434" \
  && pass "旧端点仍在候选里（作为兜底）" || fail "旧端点被丢掉了"

echo "--- 断言 2: 显式 OLLAMA_HOST 排最前 ---"
OUT=$(discover "$F" env OLLAMA_HOST=http://127.0.0.1:11434)
FIRST=$(printf '%s\n' "$OUT" | head -1)
[ "$FIRST" = "http://127.0.0.1:11434" ] \
  && pass "显式指定的端点排第一" || fail "显式端点没排第一，第一行是 $FIRST"

echo "--- 断言 3: 显式候选与内置端口去重 ---"
COUNT=$(discover "$F" env OLLAMA_HOST=http://127.0.0.1:11434 | grep -c "11434" || true)
[ "$COUNT" = "1" ] \
  && pass "同一端点只出现一次（计数 $COUNT）" || fail "同一端点出现了 $COUNT 次"

echo "--- 断言 4: 额外候选按逗号分隔且排在前面 ---"
F4="$TEST_DIR/f4.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t0.24.0\nhttp://127.0.0.1:19999\t0.40.11\n' > "$F4"
OUT=$(discover "$F4" env -u OLLAMA_HOST REVIEW_OLLAMA_ENDPOINTS=http://127.0.0.1:19999,http://127.0.0.1:11435)
FIRST=$(printf '%s\n' "$OUT" | head -1)
[ "$FIRST" = "http://127.0.0.1:19999" ] \
  && pass "额外候选排第一" || fail "额外候选没排第一，第一行是 $FIRST"
# 冒号分隔会把 URL 切碎 —— 这里确认逗号分隔下 URL 完整
printf '%s\n' "$OUT" | grep -q "http://127.0.0.1:19999" \
  && pass "URL 没被切碎（逗号分隔）" || fail "URL 被切碎了：$(printf '%s\n' "$OUT" | tr '\n' ' ')"

echo "--- 断言 5: 探不到版本的端点排最后 ---"
F5="$TEST_DIR/f5.tsv"
printf 'http://127.0.0.1:11435\t0.40.11\nhttp://127.0.0.1:11434\t\n' > "$F5"
OUT=$(discover "$F5" env -u OLLAMA_HOST -u REVIEW_OLLAMA_ENDPOINTS)
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

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "✅ ollama-endpoints 全部断言通过"
  exit 0
else
  echo "❌ ollama-endpoints 有 ${FAILURES} 项断言失败" >&2
  exit 1
fi
