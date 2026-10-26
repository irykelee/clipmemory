#!/bin/bash
# githooks/ollama-endpoints.sh — 本地 ollama 服务端「端点发现」。
#
# 为什么需要它（ID-REVIEW-1033, 2026-10-25）：
# 本机可能**同时**跑着多个 ollama 服务端（不同安装来源、不同版本、不同端口）。
# 实测踩到的坑：
#   - `/Applications/Ollama.app` 自带的 **0.24.0** 认不得 Gemma4 架构(HTTP 500);
#   - Homebrew 的 **0.40.11** 能跑 Gemma4。2026-10-25 下午起 0.40.11 接管标准端口
#     11434(并 disable 了 Ollama.app 的 LaunchAgent) ⇒ 现在 11434 = 0.40.11 唯一存活。
#     (历史备注: 当天上午 0.40.11 曾在 11435, 现已归位 11434。)
#
# ⇒ 写死端口 ⇒ 链首**静默失效**（模型叫不动却不报错）⇒ 门禁退到外部 free
#   额度 ⇒ 额度耗尽时整条链死。
#
# ⚠️ **为什么不能靠「模型在不在清单里」判**（实测结论，别再走回头路）：
#   两个服务端**共用同一个模型库**（`~/.ollama/models`）⇒ 两边的
#   `/api/tags` 返回**完全相同**的清单 ⇒ 清单**根本无法区分**两个端点。
#   真正的差别在 **runner**：0.24.0 跑不了 gemma4 的 mlx 架构
#   （`unsupported architecture: Gemma4UnifiedForConditionalGeneration`，
#   0.2s 内报错），0.40.11 一切正常。
#   ⇒ 唯一可靠的判据是「**真调一次，看有没有产出**」。
#
# 本单元只负责**列出候选并排序**；「真调一次」由 orca-auto-review.sh 做。
#
# 用法：
#   source githooks/ollama-endpoints.sh
#   ollama_discover_endpoints        # 每行一个 endpoint，版本号新的在前
#
# 候选来源（去重、按此优先级）：
#   1. `OLLAMA_HOST`（显式指定永远优先）
#   2. `REVIEW_OLLAMA_ENDPOINTS`（**逗号**分隔的额外候选 —— 不能用冒号：
#      URL 本身含冒号，按冒号切会把 `http://host:port` 切成三段）
#   3. 常见本地端口 11435 / 11434
#
# 排序：`sort -V` 是版本语义的**升序**（0.9.1 < 0.24.0 < 0.40.11），
# 而我们要**新版在前** ⇒ 必须加 `-r`（实测漏了 `-r` 会把旧版排前面，
# 正好选中了跑不动新模型的那个服务端）；探不到版本号的排到最后当兜底。

ollama_discover_endpoints() {
  # ⚠️ 数组展开一律用 `${arr[@]+"${arr[@]}"}` 写法。
  #   本单元被 `set -euo pipefail` 的调用方 source（orca-auto-review.sh），
  #   而 **macOS 自带的 /bin/bash 是 3.2** —— 3.2 下 `set -u` + 空数组的
  #   `"${arr[@]}"` 会直接报 `arr[@]: unbound variable` 并**让整个门禁崩掉**。
  #   实测：`env -u OLLAMA_HOST /bin/bash -c 'source 本单元'` → 当场 exit 1。
  #   该写法在 3.2 与 5.x 下行为一致（空数组展开为空，非空原样展开）。
  local -a explicit=() builtin=() explicit_out=() builtin_out=() versions=() seen=()
  local ep s dup ver raw

  # ---- 第一段：显式指定的候选，**按给定顺序**（意图优先）----
  if [[ -n "${OLLAMA_HOST:-}" ]]; then explicit+=("$OLLAMA_HOST"); fi
  if [[ -n "${REVIEW_OLLAMA_ENDPOINTS:-}" ]]; then
    local IFS_SAVE="$IFS"
    IFS=','
    for ep in $REVIEW_OLLAMA_ENDPOINTS; do explicit+=("$ep"); done
    IFS="$IFS_SAVE"
  fi
  # ---- 第二段：内置的常见本地端口 ----
  builtin+=("http://127.0.0.1:11435" "http://127.0.0.1:11434")

  # ---- 显式段：去重后按原顺序输出 ----
  # ⚠️ 必须**按 seen 取**而不是按 explicit 原样取：否则用户把同一个端点写
  #   两遍（`REVIEW_OLLAMA_ENDPOINTS=a,a`）就会输出两行 ⇒ 门禁会对同一个
  #   端点**重复尝试**，白等一个完整超时（实测 REVIEW_OLLAMA_TIMEOUT 默认
  #   900s）。
  for ep in "${explicit[@]+"${explicit[@]}"}"; do
    # ⚠️ **去首尾空白**（外部审核 gemma4:12b 抓到的真问题）：用户写
    #   `REVIEW_OLLAMA_ENDPOINTS=a, b`（逗号后带空格，很自然）时，
    #   `IFS=','` 只按逗号切 ⇒ 第二项会**带上前导空格** ⇒ curl 拿到
    #   `" http://host:port/api/version"` 这种**非法 URL** ⇒ 该端点被静默跳过。
    #   实测复现：输出第二行是 " http://127.0.0.1:19998"（带空格）。
    #   ⇒ 显式候选一律 trim；trim 后为空的一律丢弃。
    ep="${ep#"${ep%%[![:space:]]*}"}"
    ep="${ep%"${ep##*[![:space:]]}"}"
    [[ -z "$ep" ]] && continue
    dup=0
    for s in "${seen[@]+"${seen[@]}"}"; do
      [[ "$s" == "$ep" ]] && dup=1 && break
    done
    [[ $dup -eq 1 ]] && continue
    seen+=("$ep")
    explicit_out+=("$ep")
  done

  # ---- 内置段：排除已出现在显式段里的，查版本后降序 ----
  for ep in "${builtin[@]+"${builtin[@]}"}"; do
    local explicit_hit=0
    for s in "${explicit_out[@]+"${explicit_out[@]}"}"; do
      [[ "$s" == "$ep" ]] && explicit_hit=1 && break
    done
    [[ $explicit_hit -eq 1 ]] && continue
    dup=0
    for s in "${seen[@]+"${seen[@]}"}"; do
      [[ "$s" == "$ep" ]] && dup=1 && break
    done
    [[ $dup -eq 1 ]] && continue
    seen+=("$ep")
    # ⚠️ 探测版本**绝不能让整个函数死掉**。
    #   端点不可达时 curl 退出码非 0（连不上 = 7）⇒ 若直接写成
    #   `ver=$(curl ... | sed ...)`，调用方的 `set -e` + `pipefail` 会让
    #   **这个函数当场中止** ⇒ 连**排在它前面、明明可用**的端点也一起丢掉。
    #   实测复现（11435 通 / 11434 挂）：输出为空、exit 7 ⇒ 门禁于是
    #   **完全跳过本地链首**，退回外部 free 额度 —— 正是本单元要消灭的那个
    #   失败模式，只是换了个触发条件。
    #   ⇒ 用 `|| raw=""` 显式兜住 curl 的非零退出；解析失败照样走
    #     「探不到版本 ⇒ 排最后」的兜底分支。
    raw=$(curl -s -m 2 "$ep/api/version" 2>/dev/null) || raw=""
    ver=$(printf '%s' "$raw" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    if [[ -n "$ver" ]]; then
      versions+=("$ver"$'\t'"$ep")
    else
      versions+=("0.0.0"$'\t'"$ep")
    fi
  done

  if [[ ${#versions[@]} -gt 0 ]]; then
    while IFS= read -r ep; do builtin_out+=("$ep"); done < <(
      printf '%s\n' "${versions[@]+"${versions[@]}"}" | sort -r -V -t$'\t' -k1,1 | cut -f2)
  fi

  local -a out=("${explicit_out[@]+"${explicit_out[@]}"}" "${builtin_out[@]+"${builtin_out[@]}"}")
  [[ ${#out[@]} -eq 0 ]] && return 0
  printf '%s\n' "${out[@]}"
}
