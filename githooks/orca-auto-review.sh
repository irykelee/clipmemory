#!/usr/bin/env bash
set -euo pipefail
#
# orca-auto-review.sh — ClipMemory main 分支自动独立审核
# 由 githooks/post-commit 触发（后台运行, 不阻塞 git commit）
# 也可手动调用: bash githooks/orca-auto-review.sh
#
# 逻辑（移植自 WESTERN .githooks/orca-auto-review.sh, 适配 ClipMemory）:
#   1. 取"上次审核点(githooks/.last-reviewed) → 当前 HEAD" 之间的新提交
#   2. 生成 diff, 交给 opencode headless (独立模型) 审核
#   3. 报告写 docs/reviews/auto-review-<stamp>.md, 含 FINDINGS + REVIEW_VERDICT
#   4. 更新审核点, 避免重复审核
#
# 与 WESTERN 的差异:
#   - 解析层主用 python3（ClipMemory 无 runtime/venv）, jq 兜底
#   - 运行时标记落在 githooks/（本仓库 hook 约定用小写 githooks/）
#   - prompt 针对 Swift/SwiftUI/AppKit 剪贴板管理器
#
set -eo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$ROOT" || { echo "无法进入仓库: $ROOT" >&2; exit 1; }

OPENCODE="${OPENCODE:-$HOME/.opencode/bin/opencode}"
# 模型链: 免费 + 非 MiniMax（生成端 Claude Code = MiniMax, 避免自己审自己）。
# 主模型 opencode/big-pickle: opencode 自有免费池、非 MiniMax、代码审查/找 bug 专精
#   (2026-09-22 实测可用, 首份报告即抓出 2 个真 P1)。属 stealth 免费模型, 免费期数据
#   可能用于改进模型 —— 个人本地项目可接受, 审含密钥/业务逻辑片段时慎用。
# 兜底 opencode/nemotron-3-ultra-free: NVIDIA 550B 试用端点、免费、非 MiniMax;
#   会记录日志(trial use only)。第三梯队候选: opencode/ling-3.0-flash-fin-free。
# REVIEW_MODEL 显式指定时只用那一个(不走兜底, 保持旧行为)。
# 注: deepseek/* 直连 api.deepseek.com, 实测 402 "Insufficient Balance"(v4-pro 自
#   2026-08-28, v4-flash 2026-09-22 实测同) —— 对本账号并非免费, 勿入链。
#   minimax*/mimo 之外的免费池: mimo 系为小米 MiMo(非 MiniMax), 但 flash 档能力偏弱。
if [[ -n "${REVIEW_MODEL:-}" ]]; then
  MODEL_CHAIN=("$REVIEW_MODEL")
else
  MODEL_CHAIN=("opencode/big-pickle" "opencode/nemotron-3-ultra-free")
fi

# 运行时标记与失败台账落在脚本所在目录（githooks/）, 由 .gitignore 排除
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
MARK="$HOOKS_DIR/.last-reviewed"
REPORT_DIR="$ROOT/docs/reviews"
mkdir -p "$REPORT_DIR"

PYTHON_BIN="$(command -v python3 || true)"

# ---------------------------------------------------------------- 确定待审范围
CUR=$(git rev-parse HEAD)
RANGE=""
if [[ -n "${REVIEW_RANGE:-}" ]]; then
  # pre-push 门禁传入显式范围: 不读审核点, 结束也不写 —— mark 专属 main 链, 防跨分支污染
  # (审核模型 2026-09-22 抓出的 P1: 共享 mark 被 feature 分支 push 污染后会永久退化为
  #  HEAD~1..HEAD, 门禁静默失效)
  RANGE="$REVIEW_RANGE"
elif [[ -f "$MARK" ]]; then
  PREV=$(cat "$MARK" 2>/dev/null || true)
  if [[ -n "$PREV" ]] && git merge-base --is-ancestor "$PREV" HEAD 2>/dev/null; then
    COUNT=$(git rev-list --count "$PREV..HEAD" 2>/dev/null || echo 0)
    if [[ "${COUNT:-0}" -eq 0 ]]; then
      # 无新提交, 刷新审核点即可
      echo "$CUR" > "$MARK"
      exit 0
    fi
    RANGE="$PREV..HEAD"
  fi
fi
[[ -z "$RANGE" ]] && RANGE="HEAD~1..HEAD"   # 首次审核: 只审最近 1 个提交

# ---------------------------------------------------------------- 生成 diff 与提交摘要
# 注意: head 提前关管道会让 git 收到 SIGPIPE(141), 在 pipefail+set -e 下会静默退出。
# 必须加 || true 兜底（DIFF 仍会保留 head 已读到的前 400 行, 正是截断语义）。
DIFF=$(git diff "$RANGE" 2>/dev/null | head -400 || true)
[[ -z "$DIFF" ]] && DIFF="(无 diff, 可能只有提交信息变更)"
LOG=$(git log --oneline "$RANGE" 2>/dev/null | head -10 || true)

# ---------------------------------------------------------------- opencode 独立审核
mkdir -p "$REPORT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$REPORT_DIR/auto-review-$STAMP.md"

PROMPT="你是独立代码审核员, 审核 ClipMemory 仓库 main 分支的新提交。
ClipMemory 是一个 macOS 剪贴板管理器（Swift / SwiftUI / AppKit, 已部分迁移 Swift 6 严格并发）。
提交摘要:
$LOG

改动:
$DIFF

请检查: 逻辑正确性 / 边界条件 / 并发安全（actor / MainActor / 数据竞争）/ 内存与保留环 /
安全（Keychain / 文件权限 / 加密）/ 与仓库既有风格及 CLAUDE.md 约定一致性 / 测试覆盖。
文档与 SPEC（提交含 .md / SPEC / 账本 / 计划类文件时必须审, 纯文档提交同样全量审）:
与实现是否漂移、过时描述、计数/账本一致性、文档自身自洽（不得引用已被本次提交删除或改名的机制）。
输出格式:
- FINDINGS: 每条一行, 标注严重度 [P0]/[P1]/[P2]
- REVIEW_VERDICT: 必须是你的**最后一行输出**, 单独成行, 值为 PASS 或 FAIL
  （存在 P0 或 P1 则 FAIL）。给出结论后不要再继续探索或输出其它内容。

重要约束: **只在本仓库目录内操作，且只做只读验证**（git / xcodebuild / 读文件 / rg），
不要访问 /tmp 或仓库外的路径，也不要在仓库里创建临时文件 —— 受限环境下写仓库外路径的权限
会被自动拒绝，导致本次审核半途而废、拿不到结论。无论验证到什么程度，
**都必须先给出 REVIEW_VERDICT**。"

TMPREPORT="$REPORT_DIR/.tmp-review-$STAMP.md"
# 原始 JSON 事件流与 stderr 分开落盘（stderr 混进 JSON 会让解析失败）。
# 放 /tmp：属诊断产物，不进仓库（docs/reviews/ 的 .gitignore 只覆盖 auto-review-*.md）。
# RAWOUT/RAWERR 在模型循环内按模型名分文件（见下方 for MODEL in MODEL_CHAIN）。

# --format json：拿到的是**事件流**，可区分「模型自己的文本」与「工具输出」。
#
# 为什么不能用 default 格式（历史 bug, WESTERN 2026-09-12 定位）：
# default 输出的是**整段转录**——模型读过的文件、跑过的命令、tail 过的报告，
# 全部原样混进报告。于是 `tail -40 另一份报告` 回显出来的 `**REVIEW_VERDICT: PASS**`
# 会被当成**本次**结论。换成 JSON 后，回显内容是 tool 事件，本次结论是 text 事件，二者物理分离。
# P0-3 修复: opencode 缺失时显式 skip（不静默断链）
# 旧行为: opencode 不存在 → set -eo pipefail 使脚本 exit nonzero → MARK 不更新
#         → 下次 commit COUNT=0 提前 exit 0 → 审核链静默断裂
# 新行为: 先检测 opencode 是否可执行，不可用时写明告警报告 + 推进 MARK
if ! command -v "$OPENCODE" >/dev/null 2>&1; then
    echo "[auto-review] WARN opencode not found at $OPENCODE, skipping review (P0-3 fix)" >&2
    echo "[auto-review]    Run manually: bash githooks/orca-auto-review.sh" >&2
    {
        printf '# 自动审核报告 (跳过)\n\n'
        printf '> **opencode 不可用，跳过本次自动审核**\n\n'
        printf '## 审核摘要\n\n'
        printf '- **审核时间**: %s\n' "$STAMP"
        printf '- **待审范围**: %s\n' "$RANGE"
        printf '- **跳过原因**: opencode 未找到于 %s\n' "$OPENCODE"
        printf '- **手动补救**: `bash githooks/orca-auto-review.sh`\n\n'
        printf '## 提交摘要\n\n'
        printf '```\n%s\n```\n\n' "$LOG"
        printf '## FINDINGS\n\n'
        printf '（手动审核时补充）\n\n'
        printf '## REVIEW_VERDICT\n\n'
        printf 'SKIP (opencode unavailable)\n'
    } > "$REPORT"
    # 告警写 review-failures.log（让下次 commit 不再重复告警）
    echo "$STAMP opencode_missing range=$RANGE" >> "$HOOKS_DIR/review-failures.log"
    echo "$CUR" > "$MARK"
    exit 0
fi

# 模型链循环: 主模型失败(空转/Insufficient Balance/限流)时自动兜底下一个, 避免"空报告空转"。
# REVIEW_MODEL 显式指定时链只有 1 个, 行为与旧版一致。
USED_MODEL=""
for MODEL in "${MODEL_CHAIN[@]}"; do
RAWOUT="/tmp/orca-auto-review-$STAMP-${MODEL//\//_}.jsonl"
RAWERR="/tmp/orca-auto-review-$STAMP-${MODEL//\//_}.err"

"$OPENCODE" run --format json --dir "$ROOT" -m "$MODEL" "$PROMPT" \
  > "$RAWOUT" 2> "$RAWERR" || true

# 抽取模型自己的文本块（type=="text"）拼成报告。三层降级，每层都留痕：
#   L1 python3 —— 系统 python3（ClipMemory 无 runtime venv）
#   L2 jq —— 万一 python3 缺失；
#   L3 原始输出 —— 解析全崩时退回旧行为（宽松，但不会把审核变成静默空转）。
extract_model_text() {
  local raw="$1" out=""
  if [[ -n "$PYTHON_BIN" ]]; then
    out=$("$PYTHON_BIN" -c '
import json, sys
out = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("type") == "text":
        t = (ev.get("part") or {}).get("text")
        # 必须 strip 后再判：实测形态里有 text 事件内容恰为 "\n\n"
        # （WESTERN P2 auto-review 20260912-133638 指出）。若只写 `if t:`，纯空白会
        # 被当成有效文本，这里返回非空 → 下面 `-z` 分支不触发 →
        # 诊断信息永远打不出来，只能靠末尾 300B 长度门禁以「通用信息」兜住，
        # 排查时看不出真实原因是「模型没写正文」。
        if t and t.strip():
            out.append(t)
sys.stdout.write("\n".join(out))
' "$raw" 2>/dev/null || true)
  fi
  # jq 分支要与 python 分支**判等**：同样丢掉纯空白文本，否则 L1 得到的空
  # 会被 L2 用空白重新填满，修复在降级路径上失效。
  if [[ -z "$out" ]] && command -v jq >/dev/null 2>&1; then
    out=$(jq -rs '[.[]|select(.type=="text")|.part.text|select(test("\\S"))]|join("\n")' "$raw" 2>/dev/null || true)
  fi
  printf '%s' "$out"
}

MODEL_TEXT=$(extract_model_text "$RAWOUT")
# 事件条数用于区分两类「没有文本」：①输出根本不是事件流（该退回原始输出）；
# ②是事件流但模型一个字正文都没写（本次运行没完成，退回原始 JSON 毫无意义）。
EVENTS=$(grep -c '^{' "$RAWOUT" 2>/dev/null || true)
EVENTS=${EVENTS:-0}
if [[ -z "$MODEL_TEXT" ]]; then
  if [[ "$EVENTS" -gt 0 ]]; then
    # 实测形态：15 个 step 全是 tool_use，3 个 text 事件内容都是 "\n\n"，
    # 末尾还有一次工具报错 —— 模型没产出任何结论。这属于「本次审核未完成」，
    # 必须按失败处置（不落盘、不推进审核点），而不是把 JSON 当成报告硬凑。
    echo "[auto-review] ⚠️ 模型本次未产出任何文本结论（事件流 $EVENTS 条，无有效正文）" >&2
    echo "[auto-review]    常见原因: 中途被权限拒绝 / 步数耗尽 / 模型异常退出。原始事件流: $RAWOUT" >&2
    MODEL_TEXT="（本次 opencode 运行未产出任何文本结论：事件流 $EVENTS 条，无有效正文。
常见原因：中途被权限拒绝、步数耗尽、或模型异常退出。原始事件流见 $RAWOUT）
"
  else
    # 输出不是 JSON 事件流（例如直接在 stdout 上报错）→ 退回原始输出，
    # 让 is_valid_report 的错误标记检查（Insufficient Balance / rate limit 等）仍能生效。
    echo "[auto-review] ⚠️ 输出不是 JSON 事件流，退回原始输出: $RAWOUT" >&2
    # tr -d '\0'：转录里夹 NUL 时命令替换会报 "ignored null byte in input" 并静默丢弃。
    MODEL_TEXT=$(tr -d '\0' < "$RAWOUT" 2>/dev/null || true)
  fi
fi

# 报告 = 模型文本（+ stderr 摘要）。stderr 单独附在后面而不是混进正文，
# 既保住 is_valid_report 对空转/余额类错误标记的检查，又不污染结论判定。
{
  printf '%s\n' "$MODEL_TEXT"
  if [[ -s "$RAWERR" ]]; then
    printf '\n---\n\n> ⚠️ 本次运行的 stderr（**不是**模型输出，保留以便定位空转/报错）:\n>\n'
    head -c 2000 "$RAWERR" | sed 's/^/> /'
    printf '\n'
  fi
} > "$TMPREPORT"

# ------------------------------------------------- 守卫: 拒绝空/错误报告, 空转要可见
# 历史教训: 模型报错("Insufficient Balance" / 空输出) 也曾照写报告文件,
# 攒出空壳存根, 而 MARK 照常推进 —— 审核机制静默失效却看起来在跑。
# 规则: 报告必须 ≥300 字节 且 含 FINDINGS 或 REVIEW_VERDICT, 且不含已知错误标记。
# 门槛 300B 的依据: WESTERN 历史样本 149 份中, 110 份空壳为 43/78/179 字节;
# 39 份真实报告最小 ~1KB。300B 留足余量, 又拦得住最短的空壳变体。
#
# ⚠️ `FINDINGS|REVIEW_VERDICT` 必须**行首锚定**(前缀只允许空白 + markdown 装饰符)。
# 历史 bug（WESTERN 2026-09-12 定位）: 原来是裸子串匹配，于是一份**被中途截断、
# 根本没有结论段**的报告也能过关 —— 只要正文里出现过这几个字就算数。行首锚定后,
# 回显命令行（以 `printf`/`$`/`/` 开头）出局, 不完整转录被拒。
is_valid_report() {
  local f="$1"
  local size
  size=$(wc -c < "$f" | tr -d ' ')
  [[ "$size" -lt 300 ]] && return 1
  grep -qiE 'insufficient balance|rate.?limit|quota exceeded|unauthorized|402 payment' "$f" && return 1
  grep -qE '^[[:space:]#*_>-]*(FINDINGS|REVIEW_VERDICT)' "$f" || return 1
  return 0
}

if ! is_valid_report "$TMPREPORT"; then
  SIZE=$(wc -c < "$TMPREPORT" | tr -d ' ')
  # 取前 3 整行做摘要（LC_ALL=C 字节模式 + iconv 丢弃残缺尾字节, 保证合法 UTF-8）。
  SNIPPET=$(head -3 "$TMPREPORT" 2>/dev/null | LC_ALL=C tr '\n' ' ' \
    | head -c 300 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)
  echo "[auto-review] ⚠️ 模型 $MODEL 未生成有效报告 (${SIZE}B), 尝试下一个兜底模型" >&2
  echo "[auto-review]    输出: $SNIPPET" >&2
  echo "[auto-review]    待审范围 $RANGE 保持不变, 全部兜底失败才会终止重试。" >&2
  # 后台跑时 stderr 会沉进 /tmp 日志, 额外落一份持久台账, 便于人工发现"审核在空转"
  echo "$STAMP model=$MODEL range=$RANGE size=${SIZE}B :: $SNIPPET" >> "$HOOKS_DIR/review-failures.log"
  rm -f "$TMPREPORT"
  # 不推进审核点, 不写报告 —— 空转必须留下可见告警, 而不是静默存根; 继续试下一个模型
  continue
fi

mv "$TMPREPORT" "$REPORT"
USED_MODEL="$MODEL"
break
done

if [[ -z "${USED_MODEL:-}" ]]; then
  echo "[auto-review] ⚠️ 所有候选模型均未产出有效报告 (chain=${MODEL_CHAIN[*]})" >&2
  echo "[auto-review]    待审范围 $RANGE 保持不变, 下次 commit 会重试。" >&2
  exit 1
fi

# 提取 VERDICT：行首锚定 + 形态判定 + 取最后一次。
#
# 历史 bug ①（WESTERN 2026-09-12 定位）：原实现 `grep -E '^REVIEW_VERDICT'` 一旦模型把结论写成
# `## REVIEW_VERDICT`（标题行，PASS 在下一行）或 `**REVIEW_VERDICT: PASS**`（加粗），
# 行首锚点就匹配不到 → 开头的 set -eo pipefail 让赋值失败 → set -e 在写审核点之前杀死脚本。
#
# 历史 bug ②（WESTERN 2026-09-12 定位）：改成全文扫 `REVIEW_VERDICT` 子串后又反向失守 ——
# 正文里回显的 shell 命令和代码都会被当成结论，把 PASS/FAIL 读反。
#
# 现实现三重约束：
#   1. 行首锚定：前缀只能是空白 + markdown 装饰符 → 回显行出局；
#   2. 形态判定：关键字之后必须是装饰/标点/结论词；独占一行 → 向下看 4 行；同行 → 直接取；
#      后面接散文 → 判定为非结论声明，忽略；
#   3. 取最后一次出现（真实报告的结论就在收尾段），token 需词边界（failed/PASSED 不算）。
#
# ⚠️ **不要用 `BEGIN{IGNORECASE=1}`**（WESTERN P2 20260912-133638 指出）：那是 gawk 扩展，
# macOS One True AWK 静默忽略它。改用显式 `toupper()` 归一化后再匹配（toupper 只动 ASCII, 安全）。
VERDICT=$(awk '
  { u = toupper($0) }
  u ~ /^[[:space:]#*_>-]*REVIEW_VERDICT/ {
    rest = u
    sub(/^[[:space:]#*_>-]*REVIEW_VERDICT/, "", rest)
    sub(/^[[:space:]:：*_>-]+/, "", rest)
    if (rest ~ /^(PASS|FAIL)([^A-Z]|$)/) { last = substr(rest, 1, 4); pending = 0 }
    else if (rest == "") { pending = 4 }
    else { pending = 0 }
  }
  pending > 0 {
    line = " " u " "
    if (match(line, /[^A-Z](PASS|FAIL)[^A-Z]/)) last = substr(line, RSTART + 1, 4)
    pending--
  }
  END { if (last) print last }' "$REPORT" 2>/dev/null || true)
echo "[auto-review] $STAMP 审核 ${RANGE}: VERDICT=${VERDICT:-未识别} → $REPORT"

if [[ -z "$VERDICT" ]]; then
  # 提取失败**不等于**审核通过。报告里有 FINDINGS 但读不出结论 → 无法判断是否 PASS。
  # 此时不推进审核点（与 is_valid_report 失败的处置一致），让下次提交重审这一段。
  echo "[auto-review] ⚠️ 未能从报告提取 REVIEW_VERDICT（模型可能改了输出格式），请人工确认: $REPORT" >&2
  echo "[auto-review]    待审范围 $RANGE 保持不变, 下次提交会重试。" >&2
  echo "$STAMP model=$MODEL range=$RANGE size=$(wc -c < "$REPORT" | tr -d ' ')B :: VERDICT 未识别(格式变化?)" \
    >> "$HOOKS_DIR/review-failures.log"
  exit 1
fi

if [[ "$VERDICT" == "FAIL" ]]; then
  # opencode 独立审核纪律: 存在 P0/P1 (VERDICT=FAIL) 时必须修复后重新提交再审,
  # 不能带病收工。审核点照常推进 —— 它标记的是「这段已审过」, 不是「这段已通过」。
  echo "[auto-review] ⚠️ VERDICT=FAIL —— 报告存在 P0/P1, 按审核纪律必须修复后重审。" >&2
  # pre-push 门禁模式(REVIEW_BLOCK_ON_FAIL=1, 由 githooks/pre-push 设置): FAIL 阻断 push。
  # 显式绕过: git push --no-verify（审核点不推进, 下次 push 会重审同一段）。
  if [[ -n "${REVIEW_BLOCK_ON_FAIL:-}" ]]; then
    echo "[auto-review] ⛔ pre-push 门禁: VERDICT=FAIL, 阻断本次 push。修复后重试, 或 git push --no-verify 显式越过。" >&2
    exit 1
  fi
fi

# 记录审核点（仅当 VERDICT 可识别; main 链专属 —— REVIEW_RANGE 模式 / 非 main 分支不写, 防跨分支污染）
BR=$(git branch --show-current 2>/dev/null)
if [[ -z "${REVIEW_RANGE:-}" && "$BR" == "main" ]]; then
  echo "$CUR" > "$MARK"
fi
exit 0
