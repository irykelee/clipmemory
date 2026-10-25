#!/bin/bash
# githooks/ollama-endpoints.sh — 本地 ollama 服务端「端点发现」。
#
# 为什么需要它（ID-REVIEW-1033, 2026-10-25）：
# 本机可能**同时**跑着多个 ollama 服务端（不同安装来源、不同版本、不同端口）。
# 实测踩到的坑：
#   - `.app` 自带的 **0.24.0** 占着标准端口 11434，但**跑不了任何新模型架构**
#     （gemma4 的 mlx 架构直接报 "unsupported architecture: Gemma4UnifiedForConditionalGeneration"）；
#   - Homebrew 的 **0.40.11** 跑在另一个端口上，Metal/Apple M4，一切正常。
#
# ⇒ 写死端口 ⇒ 链首**静默失效**（模型叫不动却不报错）⇒ 门禁退到外部 free 额度
#   ⇒ 额度耗尽时整条链死。
# ⇒ 按「模型在不在清单里」判也不够：旧服务端**也**认得磁盘上的模型清单，
#   只是 runner 跑不动 ⇒ 只能靠「真调一次，看有没有产出」来定。
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
  local -a explicit=() builtin=() seen=() versions=()
  local ep ver s dup

  # ---- 第一段：显式指定的候选，**按给定顺序**（意图优先）----
  [[ -n "${OLLAMA_HOST:-}" ]] && explicit+=("$OLLAMA_HOST")
  if [[ -n "${REVIEW_OLLAMA_ENDPOINTS:-}" ]]; then
    local IFS_SAVE="$IFS"
    IFS=','
    for ep in $REVIEW_OLLAMA_ENDPOINTS; do explicit+=("$ep"); done
    IFS="$IFS_SAVE"
  fi
  # ---- 第二段：内置的常见本地端口，按版本号**降序**（新版优先）----
  builtin+=("http://127.0.0.1:11435" "http://127.0.0.1:11434")

  local -a all=("${explicit[@]}" "${builtin[@]}")
  for ep in "${all[@]}"; do
    [[ -z "$ep" ]] && continue
    dup=0
    for s in "${seen[@]}"; do
      [[ "$s" == "$ep" ]] && dup=1 && break
    done
    [[ $dup -eq 1 ]] && continue
    seen+=("$ep")
  done

  # 显式候选原样先出（不查版本、不排序）
  local -a out=()
  for ep in "${explicit[@]}"; do
    for s in "${seen[@]}"; do
      if [[ "$s" == "$ep" ]]; then out+=("$ep"); break; fi
    done
  done
  # 内置端口：查版本后降序；探不到版本的排最后当兜底。
  # ⚠️ 显式候选里已经出现过的端口要从内置段**剔除**，否则会重复尝试同一个
  #    端点（实测：OLLAMA_HOST=11434 时 11434 出现在结果里两次）。
  for ep in "${builtin[@]}"; do
    local found=0 explicit_hit=0
    for s in "${explicit[@]}"; do
      [[ "$s" == "$ep" ]] && explicit_hit=1 && break
    done
    [[ $explicit_hit -eq 1 ]] && continue
    for s in "${seen[@]}"; do
      [[ "$s" == "$ep" ]] && found=1 && break
    done
    [[ $found -eq 0 ]] && continue
    ver=$(curl -s -m 2 "$ep/api/version" 2>/dev/null \
          | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    if [[ -n "$ver" ]]; then
      versions+=("$ver"$'\t'"$ep")
    else
      versions+=("0.0.0"$'\t'"$ep")
    fi
  done
  if [[ ${#versions[@]} -gt 0 ]]; then
    while IFS= read -r ep; do out+=("$ep"); done < <(
      printf '%s\n' "${versions[@]}" | sort -r -V -t$'\t' -k1,1 | cut -f2)
  fi

  [[ ${#out[@]} -eq 0 ]] && return 0
  printf '%s\n' "${out[@]}"
}
