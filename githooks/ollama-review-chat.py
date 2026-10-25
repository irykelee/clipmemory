#!/usr/bin/env python3
"""ollama-review-chat.py — 审核门专用的 ollama 直连客户端。

为什么不用 opencode 驱动 ollama（ID-REVIEW-1026, 2026-10-24）
------------------------------------------------------------
opencode v2 驱动 ollama 时**关不掉 thinking**：
`providers.ollama.options.think=false` 不生效，模型会一直输出思考链，
直到审核门的 watchdog 把它杀掉 —— 产物是空报告，审核链判失败。
2026-10-24 实测：5 个候选模型（ollama/qwen3.5:9b + 4 个 opencode 免费池）
全部空转，pre-push 审核门整条链死掉，push 被"基础设施故障"挡住。

直连 `/api/chat` 传 `think=false` + `options.num_predict` 可以真正关掉
thinking，并且能限时限量地产出报告。小提示词实测 35–47s；带完整审核 diff
的实测（2026-10-24，19934 prompt tokens + num_ctx=32768）约 250s，其中
prompt 处理 165s、生成 ~85s —— 默认超时按最坏情形给到 900s。

输出格式
--------
按 `opencode run --format json` 的**文本事件**形状写一行 JSON：

    {"type":"text","part":{"text":"...报告正文..."}}

这样审核门原有的 `extract_model_text`（python3 → jq → 原始输出 三层降级）
与 `is_valid_report` 守卫**一行都不用改**。

用法
----
    ollama-review-chat.py --model qwen3.5:9b --out /tmp/raw.jsonl < prompt.txt
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_ENDPOINT = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
DEFAULT_TIMEOUT = 900.0
DEFAULT_NUM_PREDICT = 1600
DEFAULT_NUM_CTX = 32768


def main() -> int:
    parser = argparse.ArgumentParser(description="ollama 直连审核客户端")
    parser.add_argument("--model", required=True, help="ollama 模型名，如 qwen3.5:9b")
    parser.add_argument("--out", required=True, help="JSON 事件流输出路径")
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help="ollama 服务地址")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="整体超时秒数")
    parser.add_argument(
        "--num-predict",
        type=int,
        default=DEFAULT_NUM_PREDICT,
        help="生成上限（token）；太小会把报告截断，太大会拖到超时",
    )
    parser.add_argument("--temperature", type=float, default=0.2, help="采样温度")
    parser.add_argument(
        "--num-ctx",
        type=int,
        default=DEFAULT_NUM_CTX,
        help="上下文长度；小于提示词长度时 ollama 会截断提示词",
    )
    args = parser.parse_args()

    prompt = sys.stdin.read()
    if not prompt.strip():
        print("ollama-review-chat: prompt 为空", file=sys.stderr)
        return 2

    payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        # 关掉 thinking —— 这正是 opencode 驱动路径做不到的那一步。
        "think": False,
        "options": {
            "num_predict": args.num_predict,
            "temperature": args.temperature,
            # ollama 的默认 num_ctx 很小（常见 4096），审核提示词里带着
            # 1200 行 diff（实测几万 token）⇒ 服务端会把提示词**截断**，
            # 模型看到的只有开头一小段，于是输出在句中被硬生生掐断
            # （实测：输出停在 "FINDINGS: [P2] Scripts/l" 这种半个词上）。
            # 显式给足上下文，模型才能看完 diff 并写完结论。
            "num_ctx": args.num_ctx,
        },
    }

    url = args.endpoint.rstrip("/") + "/api/chat"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as err:
        print(f"ollama-review-chat: HTTP {err.code}: {err.read()[:400]!r}", file=sys.stderr)
        return 3
    except Exception as err:  # noqa: BLE001 — 任何网络/超时异常都要留痕后失败
        print(f"ollama-review-chat: {type(err).__name__}: {err}", file=sys.stderr)
        return 4

    try:
        data = json.loads(body)
    except Exception as err:  # noqa: BLE001
        print(f"ollama-review-chat: 响应不是 JSON: {err}", file=sys.stderr)
        print(body[:400].decode("utf-8", "replace"), file=sys.stderr)
        return 5

    message = data.get("message") or {}
    text = message.get("content") or ""
    if not text.strip():
        print(
            "ollama-review-chat: 模型没有产出正文 "
            f"(done_reason={data.get('done_reason')!r}, "
            f"eval_count={data.get('eval_count')!r})",
            file=sys.stderr,
        )
        return 6

    event = {"type": "text", "part": {"text": text}}
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")
    print(
        f"ollama-review-chat: {args.model} 产出 {len(text)} 字符 "
        f"(eval_count={data.get('eval_count')})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
