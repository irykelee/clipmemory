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
ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$ROOT" || { echo "无法进入仓库: $ROOT" >&2; exit 1; }

# ---- opencode 数据/配置按项目隔离（防跨项目共享全局库导致项目互相可见）----
# opencode 默认把所有 session / tool-output / snapshot / session_diff 写进
# ~/.local/share/opencode/opencode.db（单一全局库）+ 共享 tool-output/ 等目录。
# 多个项目都用 opencode 审核时, 彼此的源码/diff 会落进同一个共享库, 在 TUI / session
# list 里互相可见。这里把数据层重定向到仓库内的 .opencode-data/（.gitignore 已排除）,
# 配置层重定向到 .opencode-cfg/（空目录 → 不加载全局 AGENTS.md / mcp.memorix,
# 顺带关掉跨项目记忆 MCP）。账号凭证(auth.json/account.json)是账号级、非项目数据,
# 用软链指回全局, 不复制, 模型鉴权不受影响。
export XDG_DATA_HOME="$ROOT/.opencode-data"
export XDG_CONFIG_HOME="$ROOT/.opencode-cfg"
mkdir -p "$XDG_DATA_HOME/opencode" "$XDG_CONFIG_HOME"
for _oc_cred in auth.json account.json; do
  if [[ -e "$HOME/.local/share/opencode/$_oc_cred" ]]; then
    ln -sf "$HOME/.local/share/opencode/$_oc_cred" "$XDG_DATA_HOME/opencode/$_oc_cred"
  fi
done

OPENCODE="${OPENCODE:-$HOME/.opencode/bin/opencode}"
# 模型链: 免费 + 非 MiniMax（生成端 Claude Code = MiniMax, 避免自己审自己）。
# 主模型 opencode/nemotron-3-ultra-free: NVIDIA 550B 试用端点、免费、非 MiniMax。
#   本仓库实战战绩三轮(2026-10-05/06, 事件流 28-43 万字节): 抓出 RestoreWizard
#   主线程 P1(ID-REVIEW-1014)、ID-REL-3 类名失配; 对照实验 15s 响应、
#   big-pickle 2026-10-05/06 故障窗口(约 11h)期间保持可用。会记录日志(trial use only)。
# 兜底 opencode/space-bunny-free: 2026-10-06 实测全池最快(0.2s 生成)、非 MiniMax。
# 第三 opencode/big-pickle: opencode 自有免费池、非 MiniMax、代码审查/找 bug 专精
#   (2026-09-22 实测可用, 首份报告即抓出 2 个真 P1)。属 stealth 免费模型, 免费期数据
#   可能用于改进模型 —— 个人本地项目可接受, 审含密钥/业务逻辑片段时慎用。
#   2026-10-05 17:32 起出现退化(无效报告), 21:29→10-06 08:08 硬挂约 11h(2-token
#   探针也挂、加速器无效), 08:40 恢复 —— 故障窗口内由 watchdog(ID-REVIEW-1016)
#   180s 熔断换链, 恢复后自动用回, 故保留第三位。
# REVIEW_MODEL 显式指定时只用那一个(不走兜底, 保持旧行为)。
# 注: deepseek/* 直连 api.deepseek.com, 实测 402 "Insufficient Balance"(v4-pro 自
#   2026-08-28, v4-flash 2026-09-22 实测同) —— 对本账号并非免费, 勿入链。
#   minimax-cn-coding-plan/* 为 MiniMax 官方端点: 生成端同源, 按上述政策不入审核链。
#   mimo 系为小米 MiMo(非 MiniMax), 但 flash 档能力偏弱。
#
# ID-REVIEW-1025 (2026-10-24): opencode 自有免费池当日全部耗尽额度
#   (provider.quota / HTTP 429 "Free usage limit reached" —— nemotron-3-ultra-free /
#   space-bunny-free / big-pickle 三个全部一样), 审核门禁整条链死掉一整天,
#   pre-push 每次都走到 "所有候选模型均未产出有效报告" 然后 exit 1 阻断 push。
#   openrouter/nvidia/nemotron-3-ultra-550b-a55b:free 是同一族模型(NVIDIA 550B)
#   的 OpenRouter 免费档, 2026-10-24 实测可用(2-token 探针即返回 PONG)。
#
# 链首放 **本地** ollama/qwen3.5:9b(本机 127.0.0.1, 不出网): 推代码这件事
# 本身要把 diff 送出机器, 审核再送一份给第三方就更没必要 —— 本地能审就本地审,
# 审不动才落到外部端点。
#
# ✅ 本机的 9B **能审下这份 diff 了**(ID-REVIEW-1026, 2026-10-24 实测):
#   走 ollama-review-chat.py 直连 /api/chat(think=false + num_predict +
#   num_ctx=32768)后, 实测 **19934 prompt tokens 正常处理**、产出 504 token
#   的完整报告(FINDINGS + REVIEW_VERDICT), 耗时约 250s。
#   此前"装不下"是 **opencode 驱动路径**的病: 它关不掉 thinking, 模型把
#   预算全烧在思考链上, 正文被 step_finish reason=length 截断成一句
#   "请告诉我下一步的具体目标" —— 换直连即可, 不必换模型、不必挪链尾。
#
# ⚠️ **端口不能写死**(ID-REVIEW-1033, 2026-10-25 实测踩坑):
#   本机同时跑着**两个** ollama 服务端 —— `.app` 自带的 0.24.0 占标准端口
#   11434, 但**跑不了任何新模型架构**(gemma4 的 mlx 架构直接报
#   "unsupported architecture: Gemma4UnifiedForConditionalGeneration");
#   Homebrew 的 0.40.11 跑在 11435 上一切正常。
#   ⇒ 写死 11434 ⇒ 链首**静默失效**(模型叫不动却不报错)⇒ 门禁退到外部
#     free 额度 ⇒ 额度耗尽时整条链死。
#   ⇒ 现在由 githooks/ollama-endpoints.sh 做**端点发现**: 显式 env 优先,
#     内置端口按 `sort -r -V` **版本降序**(新版在前), 探不到版本的排最后;
#     然后**逐个端点真调一次**, 直到某一个真的产出报告。
#   ⇒ 判据是「有没有产出」而不是「模型在不在清单」—— 旧服务端**也**认得
#     磁盘上的模型清单, 只是 runner 跑不动, 按清单判会误选。
#
# 📊 **同一份 ID-REVIEW-1032 diff 的三方实测对照**(2026-10-25):
#   | 模型 | 耗时 | 报告 | 判定 |
#   |---|---|---|---|
#   | qwen3.5:9b (本地 11435) | **22s** | 941 字符 / eval 465 | 5 findings, **1 条真问题** |
#   | gemma4:12b (本地 11435) | 151s | 998 字符 / eval 501 | 4 findings, **0 条真问题** |
#   | nemotron-3-ultra-550b:free (openrouter) | 129s | 12 findings | **4 条真问题** |
#   ⇒ 本地 9B **快 6-7 倍**, 但**严重度标注完全不可信**(它把已修好的 EINTR
#     逻辑报成 P0)⇒ 结论仍需**人工核验**, 不可直接当阻断依据(见
#     ID-REVIEW-1029 的 advisory/confirmed 双层机制)。
#   ⇒ 链首选 qwen3.5:9b 是为了**速度 + 不出网**, 不是为了"审得更准"。
if [[ -n "${REVIEW_MODEL:-}" ]]; then
  MODEL_CHAIN=("$REVIEW_MODEL")
else
  MODEL_CHAIN=("ollama/qwen3.5:9b" "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free" "opencode/nemotron-3-ultra-free" "opencode/space-bunny-free" "opencode/big-pickle")
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
      # 无新提交, 刷新审核点即可（main 链专属守卫, 同文末记录点逻辑:
      # REVIEW_RANGE 模式 / 非 main 分支一律不写 mark, 防跨分支污染）
      BR0=$(git branch --show-current 2>/dev/null)
      if [[ -z "${REVIEW_RANGE:-}" && "$BR0" == "main" ]]; then
        echo "$CUR" > "$MARK"
      fi
      exit 0
    fi
    RANGE="$PREV..HEAD"
  fi
fi
[[ -z "$RANGE" ]] && RANGE="HEAD~1..HEAD"   # 首次审核: 只审最近 1 个提交

# ---------------------------------------------------------------- 生成 diff 与提交摘要
# 注意: head 提前关管道会让 git 收到 SIGPIPE(141), 在 pipefail+set -e 下会静默退出。
# 必须加 || true 兜底（DIFF 仍会保留 head 已读到的前 400 行, 正是截断语义）。
#
# ID-REVIEW-1025 (2026-10-24, 独立审核发现): 那条 `| head -400` 截断是
# **按路径顺序**切的, 所以在一个大分支上, 审核模型可能从头到尾只看到
# .github/workflows/*.yml、CHANGELOG 和 project.pbxproj —— **一行 Swift
# 代码都看不到**, 然后照样输出 "REVIEW_VERDICT: PASS"。
# 也就是说这个门禁可以在"根本没看代码"的情况下放行 —— 正是"绿灯必须
# 能证伪"要防的那件事。实测: 一次 16670 行的 diff, 前 400 行只覆盖
# 4 个文件, 全是元数据。
#
# 改法: ① 跳过生成物与无关文件（pbxproj / workflows / CHANGELOG）,
# ② 改成**按文件**给预算（每文件 N 行, 最多 M 个文件）, 让有限的行数
# 覆盖尽量多的文件, 而不是被前 4 个文件吃光。
#
# ID-REVIEW-1026 (2026-10-24): 预算必须**按文件**重置 —— 原来 `lines` 是全局
# 计数器且从不重置，90 行预算被**第一个**文件吃光，后面的 38 个文件只剩
# `diff --git` 头、一行内容都没有。实测：那一次审核的"diff"= ci.yml 的开头
# 90 行 + 39 个文件名，**一行 Swift 代码都没有**，模型照样就 tsan.yml 报了
# P1、并对"提交摘要里提到但 diff 里看不到"的 Swift 改动连报 3 条 P2。
# 这正是 ID-REVIEW-1025 修过的同一个洞的另一半：那次把"全局 400 行"改成
# "每文件 N 行"的**意图**写进了注释，但 awk 并没有实现它。
DIFF=$(
  {
    git diff "$RANGE" -- \
      '*.swift' '*.md' '*.sh' '*.yml' '*.yaml' 2>/dev/null \
      | awk -v per_file=90 -v max_files=40 '
          /^diff --git / {
            file_no++
            if (file_no > max_files) { exit }
            lines = 0
            print
            next
          }
          file_no > 0 { if (lines < per_file) { print; lines++ } }
        ' || true
  } | head -1200 || true
)
# 审核覆盖度留痕：模型到底看到了几个文件的多少行 —— 报告里写清楚，
# 下一个人读报告时才知道"没提到的文件"是没看到还是真没问题。
DIFF_FILES=$(printf '%s\n' "$DIFF" | grep -c '^diff --git ' || true)
DIFF_LINES=$(printf '%s\n' "$DIFF" | grep -vc '^diff --git ' || true)
[[ -z "$DIFF" ]] && DIFF="(无 diff, 可能只有提交信息变更)"
LOG=$(git log --oneline "$RANGE" 2>/dev/null | head -20 || true)

# ---------------------------------------------------------------- opencode 独立审核
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"   # 附加 PID: post-commit 与 pre-push 同秒并发时报告不互相覆盖
REPORT="$REPORT_DIR/auto-review-$STAMP.md"

PROMPT="你是独立代码审核员, 审核 ClipMemory 仓库 main 分支的新提交。
ClipMemory 是一个 macOS 剪贴板管理器（Swift / SwiftUI / AppKit, 已部分迁移 Swift 6 严格并发）。
提交摘要:
$LOG

改动:
$DIFF

（本次审核看到的是**抽样窗口**：$DIFF_FILES 个文件、约 $DIFF_LINES 行 diff —— 文件外的改动本次没有出现在窗口里，看不到不等于没问题）
请检查: 逻辑正确性 / 边界条件 / 并发安全（actor / MainActor / 数据竞争）/ 内存与保留环 /
安全（Keychain / 文件权限 / 加密）/ 与仓库既有风格及 CLAUDE.md 约定一致性 / 测试覆盖。
文档与 SPEC（提交含 .md / SPEC / 账本 / 计划类文件时必须审, 纯文档提交同样全量审）:
与实现是否漂移、过时描述、计数/账本一致性、文档自身自洽（不得引用已被本次提交删除或改名的机制）。

重要约束: **只在本仓库目录内操作，且只做只读验证**（git / xcodebuild / 读文件 / rg），
不要访问 /tmp 或仓库外的路径，也不要在仓库里创建临时文件 —— 受限环境下写仓库外路径的权限
会被自动拒绝，导致本次审核半途而废、拿不到结论。

================ 请现在开始输出报告, 不要再调用任何工具 ================
输出格式（**必须原样照抄这两行前缀**, 报告的全部内容都在回复正文里, 不要写进文件）:

FINDINGS: <每条发现一行, 前面标 [P0]/[P1]/[P2]; 没有发现就写 'FINDINGS: none'>
FINDINGS: <可重复多行>
REVIEW_VERDICT: PASS

（REVIEW_VERDICT 必须是你的**最后一行**, 单独成行, 值为 PASS 或 FAIL —— 存在 P0 或 P1 则 FAIL。
没有发现问题时也**必须**输出 REVIEW_VERDICT: PASS, 不能只写一段叙述。
你的最终回复必须以 REVIEW_VERDICT 结尾。）"

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
    # 仅 main 链推进审核点（REVIEW_RANGE / 非 main 不写, 防 mark 被分支 HEAD 污染）
    BR1=$(git branch --show-current 2>/dev/null)
    if [[ -z "${REVIEW_RANGE:-}" && "$BR1" == "main" ]]; then
      echo "$CUR" > "$MARK"
    fi
    exit 0
fi

# 模型链循环: 主模型失败(空转/Insufficient Balance/限流)时自动兜底下一个, 避免"空报告空转"。
# REVIEW_MODEL 显式指定时链只有 1 个, 行为与旧版一致。
USED_MODEL=""
# ID-REVIEW-1016 (2026-10-05): per-model watchdog. 观测到的失败签名
# (orca-auto-review-20261005-212911/-220442, 手动 gate test -230508 与
# -073418): big-pickle 免费池对**任何请求**(含 2-token 极小探针、早午晚
# 全时段)挂起，RAWOUT 0 字节、opencode 不退出 —— 旧的同步调用让 pre-push
# 无限阻塞，MODEL_CHAIN 的 fallback(nemotron 对照实验 15s 正常)永远轮不到。
# 对照组实证与本地网络无关(加速器开启依旧 0 字节)。
# 修复 = 纯 bash 双 watchdog，不依赖 timeout/gtimeout 是否存在
# (nemotron 审核 20261006-074747 P1: stock macOS 缺 coreutils 时
# 基于 timeout 二进制的总上限整层消失)，verdict 语义不变(超时走既有
# "未产出有效报告 → continue"路径):
#   A) 首事件截止 FIRST_EVENT_DEADLINE 秒: RAWOUT 仍空 → 杀掉，
#      立刻 fallback(成功案例全部在首 2 分钟内开始产出事件流);
#   B) 总时长上限 REVIEW_MODEL_TIMEOUT 秒: 兜住"有事件但中途停更"。
# 杀进程带 TERM→KILL 5s 升级 + kill -0 活性检查(同轮审核
# 20261006-074747 P1/P2)；watchdog 在 wait 返回后立即被主流程回收，
# 理论上的 PID 复用窗口被压缩到纳秒级且加活性检查兜底。
FIRST_EVENT_DEADLINE="${REVIEW_FIRST_EVENT_DEADLINE:-180}"
REVIEW_MODEL_TIMEOUT="${REVIEW_MODEL_TIMEOUT:-900}"

# 本地 ollama 端点发现单元（ID-REVIEW-1033）：抽成独立文件是为了能 source 出来
# 做行为级测试（断言「优先版本号新的」「去重」「env 优先」）。
if [[ -f "$HOOKS_DIR/ollama-endpoints.sh" ]]; then
  # shellcheck source=githooks/ollama-endpoints.sh
  source "$HOOKS_DIR/ollama-endpoints.sh"
else
  ollama_discover_endpoints() { printf '%s\n' "${OLLAMA_HOST:-http://127.0.0.1:11434}"; }
  echo "[auto-review] ⚠️ 找不到 ollama-endpoints.sh —— 端点发现退化为只连 ${OLLAMA_HOST:-http://127.0.0.1:11434}" >&2
fi

for MODEL in "${MODEL_CHAIN[@]}"; do
RAWOUT="/tmp/orca-auto-review-$STAMP-${MODEL//\//_}.jsonl"
RAWERR="/tmp/orca-auto-review-$STAMP-${MODEL//\//_}.err"

  # ID-CRASH-0022 (2026-10-20): `opencode run` in opencode v2.0.30 no
  # longer accepts `--dir` — it exits with "Unrecognized flag: --dir" and
  # prints the usage text, which the report validator then rejects as a
  # failed model. The whole review chain had been silently dead since the
  # opencode upgrade (last successful report: 2026-10-07). The project
  # root is taken from the working directory, and this script already
  # `cd "$ROOT"` at the top, so the flag was redundant as well as
  # invalid.
  #
  # ID-REVIEW-1026 (2026-10-24): the ollama candidate goes **straight to
  # HTTP**, not through opencode. opencode v2 driving ollama cannot turn
  # thinking off (providers.ollama.options.think=false does not take effect)
  # — the model keeps emitting its chain of thought until the watchdog kills
  # it, the product is an empty report, and the review chain calls that a
  # failure. Measured 2026-10-24: all 5 candidate models (ollama/qwen3.5:9b
  # + 4 opencode free-tier ones) came up empty and the pre-push review gate
  # died with them — that is not the review failing, it is the gate itself
  # being broken. Talking to /api/chat directly with think=false +
  # options.num_predict really does turn thinking off, and it is bounded in
  # both time and size (measured: 35–47s for the same prompt).
  # The output is written in opencode's text-event shape, so **the downstream
  # extraction and validation need not change by a single line**.
  if [[ "$MODEL" == ollama/* ]]; then
    if [[ -z "${PYTHON_BIN:-}" ]]; then
      echo "[auto-review] ⚠️ ollama 直连需要 python3，未找到 — 跳过该候选" >&2
      : > "$RAWOUT"
    else
      # 小模型对长提示词的格式遵从度不稳：实测 9B 模型把 FINDINGS 写对了却
      # 没写结尾的 REVIEW_VERDICT 行 → 判定提取失败 → hook exit 1 → push 被挡。
      # 提示词的**末尾**再补一次格式要求（近因效应），并把发现条数封顶，
      # 让模型先写结论。
      OLLAMA_PROMPT="$PROMPT

[输出格式提醒 — 必须照做] 你的回复**必须**以单独一行结尾：
REVIEW_VERDICT: PASS
（若上面列出了 [P0] 或 [P1] 的发现，这一行写 FAIL）
这一行之后不要再输出任何内容。发现最多列 5 条，每条一行。"
      # ---------------------------------------------------------------- 端点发现
      # ID-REVIEW-1033 (2026-10-25)：本机可能**同时**跑着多个 ollama 服务端
      # （不同版本、不同端口）。实测踩到的坑：
      #   - `.app` 自带的 0.24.0 占着标准端口 11434，但**跑不了任何新模型架构**
      #     （gemma4 的 mlx 架构直接报 "unsupported architecture"）；
      #   - Homebrew 的 0.40.11 跑在另一个端口上，能跑一切。
      # ⇒ 旧实现只连 `OLLAMA_HOST`（默认 11434）⇒ 链首**静默失效**（模型叫不动
      # 但不报错），门禁退到外部 free 额度上 ⇒ 额度耗尽时整条链死。
      #
      # ⇒ 这里逐个探测本地端点，**按版本号从新到旧**排序，逐个真调一次，
      # 直到某一个**真的产出报告**。判据是「产出非空输出」而不是「有没有这个
      # 模型」—— 旧服务端**也**认得磁盘上的模型清单，只是 runner 跑不动。
      OLLAMA_MODEL_NAME="${MODEL#ollama/}"
      OLLAMA_EP=""
      while IFS= read -r ep_candidate; do
        [[ -z "$ep_candidate" ]] && continue
        printf '%s' "$OLLAMA_PROMPT" | "$PYTHON_BIN" "$HOOKS_DIR/ollama-review-chat.py" \
          --model "$OLLAMA_MODEL_NAME" \
          --endpoint "$ep_candidate" \
          --out "$RAWOUT" \
          --timeout "${REVIEW_OLLAMA_TIMEOUT:-900}" \
          --num-predict "${REVIEW_OLLAMA_NUM_PREDICT:-1600}" \
          > /dev/null 2> "$RAWERR" || true
        if [[ -s "$RAWOUT" ]]; then
          OLLAMA_EP="$ep_candidate"
          break
        fi
        echo "[auto-review]    端点 $ep_candidate 未能产出报告，换下一个" >&2
        : > "$RAWOUT"
      done < <(ollama_discover_endpoints)
      if [[ -z "$OLLAMA_EP" ]]; then
        echo "[auto-review] ⚠️ ollama 直连未产出报告（$MODEL，所有本地端点都试过了）" >&2
      else
        echo "[auto-review]    本地 ollama 端点：$OLLAMA_EP" >&2
      fi
    fi
  else
    "$OPENCODE" run --format json -m "$MODEL" "$PROMPT" \
      > "$RAWOUT" 2> "$RAWERR" &
    OC_PID=$!
    (
      sleep "$FIRST_EVENT_DEADLINE"
      if ! [ -s "$RAWOUT" ] && kill -0 "$OC_PID" 2>/dev/null; then
        kill "$OC_PID" 2>/dev/null || true
        sleep 5
        kill -9 "$OC_PID" 2>/dev/null || true
      fi
    ) &
    WATCHDOG_A=$!
    (
      sleep "$REVIEW_MODEL_TIMEOUT"
      if kill -0 "$OC_PID" 2>/dev/null; then
        kill "$OC_PID" 2>/dev/null || true
        sleep 5
        kill -9 "$OC_PID" 2>/dev/null || true
      fi
    ) &
    WATCHDOG_B=$!
    wait "$OC_PID" 2>/dev/null || true
    # watchdog 已自发杀掉 opencode 时它们往往还在 sleep 5 的 KILL 升级
    # 尾巴里——wait 返回后立即回收；set -e 下 kill 的非零返回会静默终止
    # 整个 hook(ID-REVIEW-1016 首测实证: nemotron 永远轮不到)，全部 || true。
    kill "$WATCHDOG_A" "$WATCHDOG_B" 2>/dev/null || true
    wait "$WATCHDOG_A" 2>/dev/null || true
    wait "$WATCHDOG_B" 2>/dev/null || true
  fi

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
  grep -qiE 'insufficient balance|rate.?limit|quota exceeded|unauthorized|402 payment' "$f" && return 1
  # ID-REVIEW-1025 (2026-10-24): a report that carries the CONCLUSION is
  # a report, whatever its length. "FINDINGS: none" + "REVIEW_VERDICT:
  # PASS" is a legitimate ~40-byte report — the 300B floor was calibrated
  # on real reports (whose smallest was ~1KB) and would have rejected
  # exactly that one, i.e. the gate would have failed a CLEAN review.
  if grep -qE '^[[:space:]#*_>-]*REVIEW_VERDICT' "$f"; then
    return 0
  fi
  # No conclusion → demand more: the historical size floor AND a
  # line-anchored FINDINGS line (a truncated report with neither is a
  # shell, and a shell must not pass).
  [[ "$size" -lt 300 ]] && return 1
  grep -qE '^[[:space:]#*_>-]*FINDINGS' "$f" || return 1
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

# ---------------------------------------------------------------- 人工核验层
# ID-REVIEW-1029 (2026-10-25): 本地小模型（ollama/qwen3.5:9b）**能抓真 bug，
# 但严重度标注不可信** —— v2.9.6 发版期间实测 3 份报告共 5 条 P1，人工逐条核验
# **全部误报**；还有一份出现「正文列了 2 条 [P1]、结论行却写 PASS」的自相矛盾。
# ⇒ 让它当放行裁决者 = 每次 push 都要人工绕过 hook 且不留痕；让它没声音 = 浪费
# 一个真能抓 bug 的独立信源。
#
# 本层做的事：findings 永远进报告（可审计），**要不要阻断由人的核验结论决定**。
# 台账 githooks/review-adjudication.jsonl（入库）每条结论带 file + fileSha256
# ⇒ 代码一改，结论自动失效，必须重新核验。
#
# 模式（REVIEW_GATE_MODE）：
#   advisory（默认）模型 findings 不单独阻断 push；只有人工记为 `confirmed`
#             的 finding 才阻断（直到该文件被改动）。
#   strict            保留旧行为：模型结论 FAIL 即阻断（大模型在链上时用）。
# 两种模式下人工 `confirmed` 都阻断。
GATE_MODE="${REVIEW_GATE_MODE:-advisory}"
ADJ_LEDGER="$HOOKS_DIR/review-adjudication.jsonl"
# ID-REVIEW-1031 (2026-10-25)：判定逻辑抽到 githooks/review-gate-adjudication.sh，
# 因为其中两条性质（崩溃 ⇒ fail-closed；台账为空 ⇒ 退回模型结论）必须被
# **行为级**测试覆盖 —— 此前只以「源码里有没有某句话」的形式断言过，
# 那种断言抓不住「逻辑被改坏但那句话还在」。
ADJ_STATUS="ok"
ADJ_ERR=""
if [[ -f "$HOOKS_DIR/review-gate-adjudication.sh" ]]; then
  # shellcheck source=githooks/review-gate-adjudication.sh
  source "$HOOKS_DIR/review-gate-adjudication.sh"
  REVIEW_ADJUDICATE_SCRIPT="$HOOKS_DIR/review-adjudicate.py"
  REVIEW_REPO_ROOT="$ROOT"
  ADJ_OUT=$(review_gate_adjudicate "$REPORT" "$ADJ_LEDGER" "$GATE_MODE" "$VERDICT" "${PYTHON_BIN:-}")
else
  echo "[auto-review] ⚠️ 找不到 review-gate-adjudication.sh —— 人工核验层不可用，按模型结论 ${VERDICT} 处理。" >&2
  ADJ_OUT=$(printf 'STATUS=missing\nEFFECTIVE_VERDICT=%s\nBLOCKING_COUNT=0\nADVISORY_COUNT=0\n' "$VERDICT")
fi
EFFECTIVE_VERDICT="$VERDICT"
ADJ_BLOCKING=0
ADJ_ADVISORY=0
while IFS='=' read -r key value; do
  case "$key" in
    STATUS)            ADJ_STATUS="$value" ;;
    EFFECTIVE_VERDICT) EFFECTIVE_VERDICT="$value" ;;
    BLOCKING_COUNT)    ADJ_BLOCKING="$value" ;;
    ADVISORY_COUNT)    ADJ_ADVISORY="$value" ;;
    ERROR)             ADJ_ERR="$value" ;;
  esac
done <<< "$ADJ_OUT"

case "$ADJ_STATUS" in
  crashed)
    # fail closed：核验层不可信时不能放行。
    echo "[auto-review] ⛔ 人工核验层崩溃（apply 执行失败）—— 无法判断人工核验结论，按 fail-closed 阻断。" >&2
    echo "[auto-review]    这通常是工具本身的 bug，要修；修好前可 git push --no-verify 显式越过。" >&2
    if [[ -n "$ADJ_ERR" ]]; then
      echo "[auto-review]    错误输出：${ADJ_ERR:0:800}" >&2
    fi
    ;;
  no-python)
    echo "[auto-review] ⚠️ 人工核验层不可用：找不到 python3 —— 按模型结论 ${VERDICT} 处理。" >&2
    ;;
  no-ledger)
    echo "[auto-review] ℹ️ 没有人工核验台账（$ADJ_LEDGER）—— 按模型结论 ${VERDICT} 处理。" >&2
    ;;
  missing)
    echo "[auto-review] ⚠️ 人工核验层不可用：缺少判定单元 —— 按模型结论 ${VERDICT} 处理。" >&2
    ;;
  *)
    if [[ "$EFFECTIVE_VERDICT" != "$VERDICT" ]]; then
      echo "[auto-review] ⚖️ 人工核验层生效：模型结论 ${VERDICT} → 生效结论 ${EFFECTIVE_VERDICT}（模式 ${GATE_MODE}）" >&2
    fi
    if [[ "${ADJ_ADVISORY:-0}" -gt 0 ]]; then
      echo "[auto-review] ℹ️ ${ADJ_ADVISORY} 条 P0/P1 未经人工核验 —— advisory 模式下不阻断 push。" >&2
      echo "[auto-review]    核验: python3 githooks/review-adjudicate.py list --report $REPORT" >&2
    fi
    # 说明：模型结论 PASS 时**照样**跑这一层 —— 人工记为 confirmed 的结论
    # 必须能把结论翻成 FAIL，否则「台账里明明记了真问题」却放行。
    ;;
esac

if [[ "$EFFECTIVE_VERDICT" == "FAIL" ]]; then
  # opencode 独立审核纪律: 存在 P0/P1 (VERDICT=FAIL) 时必须修复后重新提交再审,
  # 不能带病收工。审核点照常推进 —— 它标记的是「这段已审过」, 不是「这段已通过」。
  echo "[auto-review] ⚠️ 生效结论=FAIL —— 报告存在未解决的 P0/P1, 按审核纪律必须修复后重审。" >&2
  # pre-push 门禁模式(REVIEW_BLOCK_ON_FAIL=1, 由 githooks/pre-push 设置): FAIL 阻断 push。
  # 显式绕过: git push --no-verify（审核点不推进, 下次 push 会重审同一段）。
  if [[ -n "${REVIEW_BLOCK_ON_FAIL:-}" ]]; then
    if [[ "$ADJ_STATUS" == "crashed" ]]; then
      echo "[auto-review] ⛔ pre-push 门禁: 人工核验层崩溃, 无法确认人工核验结论 —— fail-closed 阻断本次 push。修好 review-adjudicate.py 后重试, 或 git push --no-verify 显式越过。" >&2
    elif [[ "${ADJ_BLOCKING:-0}" -gt 0 ]]; then
      echo "[auto-review] ⛔ pre-push 门禁: ${ADJ_BLOCKING} 条 finding 被人工记为 confirmed（真问题, 尚未修复）, 阻断本次 push。" >&2
    else
      echo "[auto-review] ⛔ pre-push 门禁: 生效结论=FAIL, 阻断本次 push。修复后重试, 或 git push --no-verify 显式越过。" >&2
    fi
    exit 1
  fi
fi

# 记录审核点（仅当 VERDICT 可识别; main 链专属 —— REVIEW_RANGE 模式 / 非 main 分支不写, 防跨分支污染）
BR=$(git branch --show-current 2>/dev/null)
if [[ -z "${REVIEW_RANGE:-}" && "$BR" == "main" ]]; then
  echo "$CUR" > "$MARK"
fi
exit 0
