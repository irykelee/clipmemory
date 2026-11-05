#!/bin/bash
# Tests for Scripts/cleanup-test-plists-periodic.sh（ID-BETA-0001 之二）。
#
# ⇒ ⇒ 这个脚本**会删文件** ⇒ ⇒ 所以它自己的自测**必须**证明：
#   ① 默认（无参数）= **干跑** ⇒ 一个文件都不删
#   ② `--apply` 才删
#   ③ 未知参数 ⇒ 拒绝（exit 1）
#   ④ 日志真的写出来了
#   ⑤ **绝不碰用户的 ~/Library/Preferences** ⇒ ⇒ 全程用合成的 seam
#      （CM_CLEANER_PATH / CM_LOG_DIR）
#
# Run: bash Scripts/test/test_cleanup_test_plists_periodic.sh
# Exit 0 = PASS, non-zero = FAIL

set -uo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cleanup-test-plists-periodic.sh"

PASS=0
FAIL=0
ok()  { echo "  ✅ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $*"; FAIL=$((FAIL + 1)); }

# ── 合成夹具：一个假的清理脚本（记录自己被调了几次、删了什么）────────
FAKE_CLEANER="$TEST_DIR/fake-cleaner.sh"
cat > "$FAKE_CLEANER" <<'EOF'
#!/usr/bin/env python3
# 假的清理器（**Python**，因为真脚本用 `python3 "$CLEANER"` 调它）：干跑时**不删**；
# --apply 时删掉 $FAKE_TARGET
import os, sys
print("fake-cleaner called with:", " ".join(sys.argv[1:]))
if "--apply" in sys.argv:
    target = os.environ.get("FAKE_TARGET", "")
    if target and os.path.exists(target):
        os.remove(target)
    print("fake-cleaner deleted:", target or "none")
else:
    print("DRY RUN - nothing was deleted.")
sys.exit(0)
EOF
chmod +x "$FAKE_CLEANER"

TARGET="$TEST_DIR/target-file.txt"
echo "payload" > "$TARGET"

LOG_DIR="$TEST_DIR/logs"
run_script() {
    CM_CLEANER_PATH="$FAKE_CLEANER" \
    CM_LOG_DIR="$LOG_DIR" \
    FAKE_TARGET="$TARGET" \
    bash "$SCRIPT" "$@"
}

echo "=== ① 默认（无参数）= 干跑 ⇒ 不删任何文件 ==="
out=$(run_script 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || bad "exit ${rc}（期望 0）"
[[ -f "$TARGET" ]] && ok "目标文件仍在（没删）" || bad "目标文件被删了（默认不该删）"
grep -q "未删除任何文件" <<< "$out" && ok "输出声明了「未删除任何文件」" || bad "输出没声明未删除：$out"
[[ -f "$LOG_DIR/cleanup-test-plists.log" ]] && ok "日志文件已写出" || bad "日志文件缺失"

echo "=== ② --apply 才删 ==="
out=$(run_script --apply 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || bad "exit ${rc}（期望 0）"
[[ ! -f "$TARGET" ]] && ok "目标文件被删了" || bad "目标文件还在（--apply 该删）"
grep -q "fake-cleaner deleted" "$LOG_DIR/cleanup-test-plists.log" && ok "日志记录了删除" || bad "日志没记录删除"

echo "=== ③ 未知参数 ⇒ 拒绝 ==="
# ⇒ ⇒ ② 已经把目标删了 ⇒ ⇒ 这里**重建**一个 ⇒ ⇒ 才能验证「拒绝路径没删东西」
echo "payload3" > "$TARGET"
out=$(run_script --wat 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "exit 1（拒绝未知参数）" || bad "exit ${rc}（期望 1）"
grep -q "未知参数" <<< "$out" && ok "输出说明了未知参数" || bad "输出没说明：$out"
[[ -f "$TARGET" ]] && ok "拒绝时没有删任何东西" || bad "拒绝路径却删了文件"

echo "=== ④ 日志里能看出「干跑 + 执行删除」两段 ==="
LOG_DIR="$TEST_DIR/logs2"
echo "payload2" > "$TARGET"
run_script --apply >/dev/null 2>&1
grep -q "干跑" "$LOG_DIR/cleanup-test-plists.log" && ok "日志有干跑段" || bad "日志缺干跑段"
grep -q "执行删除" "$LOG_DIR/cleanup-test-plists.log" && ok "日志有执行删除段" || bad "日志缺执行删除段"

echo "=== ⑤ 绝不碰用户的 ~/Library/Preferences ==="
if grep -q 'Library/Preferences' "$SCRIPT"; then
    bad "脚本里出现了 ~/Library/Preferences ⇒ 路径应来自 cleaner 自己"
else
    ok "脚本本身不直接引用 ~/Library/Preferences（由 cleaner 决定范围）"
fi
if grep -q 'CM_CLEANER_PATH' "$SCRIPT" && grep -q 'CM_LOG_DIR' "$SCRIPT"; then
    ok "两个 seam 都在（测试能指向合成夹具）"
else
    bad "缺少 seam ⇒ 自测会碰到真实环境"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "✅ All $PASS checks passed."
    exit 0
fi
echo "❌ $FAIL of $((PASS + FAIL)) checks failed."
exit 1
