#!/usr/bin/env bash
# 定期清理测试留下的 UserDefaults plist —— **手动可跑**；本文件**不注册**任何后台任务。
#
# 用法：
#     bash Scripts/cleanup-test-plists-periodic.sh            # 干跑 + 记录日志（不删）
#     bash Scripts/cleanup-test-plists-periodic.sh --apply    # 干跑 + 记录日志 + 执行删除
#
# 它做什么：
#   ① 先**干跑**（`cleanup-test-plists.py` 不带 --apply）⇒ 把「会删什么」写进日志
#   ② 只有带 `--apply` 时才真的删
#   ③ 删除范围 = **命中测试源码里 `suiteName:` 字面量**的那些文件（判据来自**源码**，不是猜测）
#      ⇒ `com.clipmemory.app`（生产域）**永不**被删
#      ⇒ 名字形似但字面量已消失的「疑似」项**一律保留**
#
# ⚠️ **想让它每月自动跑**：本仓库**故意不注册**后台任务（那是不可逆动作，得由你决定）。
#    两种自选方式（都只跑本脚本，不改仓库）：
#      A. launchd：把下面内容存成 ~/Library/LaunchAgents/com.clipmemory.cleanup-test-plists.plist
#         → 再 `launchctl load ~/Library/LaunchAgents/com.clipmemory.cleanup-test-plists.plist`
#      B. cron：  → `crontab -e` 加一行
#         0 4 1 * * /bin/bash <REPO_ROOT>/Scripts/cleanup-test-plists-periodic.sh --apply
#
#    ⚠️ 模板里的 `<REPO_ROOT>` = **你这台机器上**本仓库的绝对路径 ⇒ ⇒ 复制前
#    先把它换掉（脚本**自己**用 `$(dirname $0)/..` 推导路径 ⇒ 仓库挪了也不怕；
#    ⇒ ⇒ 只有**定时任务**的启动路径是写死的 ⇒ ⇒ 挪仓库时要顺手改这一处）。
#
#    launchd 模板：
#      <?xml version="1.0" encoding="UTF-8"?>
#      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
#      <plist version="1.0">
#      <dict>
#        <key>Label</key><string>com.clipmemory.cleanup-test-plists</string>
#        <key>ProgramArguments</key>
#        <array>
#          <string>/bin/bash</string>
#          <string>&lt;REPO_ROOT&gt;/Scripts/cleanup-test-plists-periodic.sh</string>
#          <string>--apply</string>
#        </array>
#        <key>StartCalendarInterval</key>
#        <dict><key>Day</key><integer>1</integer><key>Hour</key><integer>4</integer></dict>
#        <key>StandardOutPath</key><string>&lt;HOME&gt;/Library/Logs/ClipMemory/cleanup-test-plists.log</string>
#        <key>StandardErrorPath</key><string>&lt;HOME&gt;/Library/Logs/ClipMemory/cleanup-test-plists.log</string>
#      </dict>
#      </plist>
#
# 退出码：0 = 跑完（干跑模式恒为 0）；1 = 清理脚本自身失败。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ⇒ ⇒ 两个 **seam**（只为测试能指向合成的夹具 ⇒ ⇒ 默认行为**逐字不变**）：
#   CM_CLEANER_PATH — 清理脚本的路径（默认：仓库里那个）
#   CM_LOG_DIR       — 日志目录（默认：~/Library/Logs/ClipMemory）
CLEANER="${CM_CLEANER_PATH:-$REPO_ROOT/Scripts/cleanup-test-plists.py}"
LOG_DIR="${CM_LOG_DIR:-$HOME/Library/Logs/ClipMemory}"
LOG_FILE="$LOG_DIR/cleanup-test-plists.log"

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$CLEANER" ]]; then
  echo "❌ 找不到清理脚本：$CLEANER" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') cleanup-test-plists ====="
  echo "模式：$([[ $APPLY -eq 1 ]] && echo '干跑 + 执行删除' || echo '仅干跑（不删）')"
  echo "--- 干跑 ---"
} >>"$LOG_FILE"

python3 "$CLEANER" >>"$LOG_FILE" 2>&1
DRY_RC=$?

if [[ $DRY_RC -ne 0 ]]; then
  echo "❌ 干跑失败（exit ${DRY_RC}），详见 ${LOG_FILE}" >&2
  exit 1
fi

if [[ $APPLY -eq 0 ]]; then
  echo "✅ 干跑完成（**未删除任何文件**）⇒ 报告在 $LOG_FILE"
  exit 0
fi

{
  echo "--- 执行删除 ---"
} >>"$LOG_FILE"
python3 "$CLEANER" --apply >>"$LOG_FILE" 2>&1
APPLY_RC=$?

if [[ $APPLY_RC -ne 0 ]]; then
  echo "❌ 删除步骤失败（exit ${APPLY_RC}），详见 ${LOG_FILE}" >&2
  exit 1
fi

echo "✅ 清理完成 ⇒ 日志在 $LOG_FILE"
