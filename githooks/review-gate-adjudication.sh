#!/bin/bash
# githooks/review-gate-adjudication.sh — 审核门「人工核验层」的判定单元。
#
# 为什么要独立成一个文件（ID-REVIEW-1031, 2026-10-25）：
# 这段判定有两处**必须被行为级测试**覆盖的性质，而它们此前只以「源码里有没有
# 某句话」的形式被断言过 —— 那种断言抓不住「逻辑被改坏但那句话还在」：
#
#   1. **apply 崩溃 ⇒ fail-closed**。旧实现把「输出为空」一律当成「缺 python3
#      或台账」；apply 真正崩溃（语法错 / 异常）时真实原因被掩盖，更糟的是
#      静默退回「模型结论说了算」= 安全层失效时 fail-open。
#   2. **台账为空 / 没有台账 ⇒ 退回模型结论**（不是崩溃，不是阻断）。
#
# 抽出来之后，测试可以 source 本文件、用一个「假装崩溃的 python」直接调用
# review_gate_adjudicate，断言它**真的**阻断 —— 而不是去 grep 源码文本。
#
# 用法：
#   source githooks/review-gate-adjudication.sh
#   review_gate_adjudicate <report> <ledger> <mode> <model_verdict> [python_bin]
#
# 输出（stdout，一行一个 key=value）：
#   STATUS=ok|no-python|no-ledger|crashed
#   EFFECTIVE_VERDICT=PASS|FAIL
#   BLOCKING_COUNT=N
#   ADVISORY_COUNT=N
#
# 语义：
#   ok        正常跑完 ⇒ EFFECTIVE_VERDICT 由台账决定
#   crashed   apply 执行失败 / 无输出 ⇒ **fail-closed**（EFFECTIVE_VERDICT=FAIL）
#   no-python 根本没有 python3 ⇒ 退回模型结论（工具压根跑不了）
#   no-ledger 没有台账 ⇒ 退回模型结论（没有任何人工结论，正常状态）

review_gate_adjudicate() {
  local report="$1" ledger="$2" mode="$3" model_verdict="$4" python_bin="${5:-}"
  local status="ok" out="" err="" err_file=""

  if [[ -z "$python_bin" ]]; then
    status="no-python"
  elif [[ ! -f "$ledger" ]]; then
    status="no-ledger"
  else
    err_file="$(mktemp "${TMPDIR:-/tmp}/cm-adjudicate-err.XXXXXX" 2>/dev/null || echo "")"
    if [[ -n "$err_file" ]]; then
      if ! out="$("$python_bin" "${REVIEW_ADJUDICATE_SCRIPT:-$HOME/.local/bin/review-adjudicate.py}" \
          apply --report "$report" --ledger "$ledger" --repo-root "${REVIEW_REPO_ROOT:-$PWD}" \
          --mode "$mode" --model-verdict "$model_verdict" 2>"$err_file")"; then
        status="crashed"
        err="$(head -c 800 "$err_file" 2>/dev/null || true)"
      fi
      rm -f "$err_file"
    else
      if ! out="$("$python_bin" "${REVIEW_ADJUDICATE_SCRIPT:-$HOME/.local/bin/review-adjudicate.py}" \
          apply --report "$report" --ledger "$ledger" --repo-root "${REVIEW_REPO_ROOT:-$PWD}" \
          --mode "$mode" --model-verdict "$model_verdict" 2>/dev/null)"; then
        status="crashed"
      fi
    fi
    # 正常路径必定输出 4 行 key=value；空输出本身就是异常。
    if [[ "$status" == "ok" && -z "$out" ]]; then
      status="crashed"
      err="apply 没有输出任何结果（预期 EFFECTIVE_VERDICT/BLOCKING_COUNT/ADVISORY_COUNT/MODE）"
    fi
  fi

  local effective="$model_verdict" blocking=0 advisory=0
  case "$status" in
    crashed)
      # fail closed：核验层不可信时不能放行。
      effective="FAIL"
      ;;
    no-python|no-ledger)
      effective="$model_verdict"
      ;;
    *)
      while IFS='=' read -r key value; do
        case "$key" in
          EFFECTIVE_VERDICT) effective="$value" ;;
          BLOCKING_COUNT)    blocking="$value" ;;
          ADVISORY_COUNT)    advisory="$value" ;;
        esac
      done <<< "$out"
      ;;
  esac

  printf 'STATUS=%s\n' "$status"
  printf 'EFFECTIVE_VERDICT=%s\n' "$effective"
  printf 'BLOCKING_COUNT=%s\n' "$blocking"
  printf 'ADVISORY_COUNT=%s\n' "$advisory"
  if [[ -n "$err" ]]; then
    printf 'ERROR=%s\n' "${err//$'\n'/ }"
  fi
  return 0
}
