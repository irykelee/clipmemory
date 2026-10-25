#!/usr/bin/env python3
"""review-adjudicate.py — 审核门的人工核验台账（adjudication ledger）。

为什么需要它（ID-REVIEW-1029, 2026-10-25）
-------------------------------------------
审核门用本地小模型（ollama/qwen3.5:9b）做独立审核。这个模型**能抓真 bug**
（注入实验 1/1 命中），但**严重度标注不可信**：v2.9.6 发版期间实测 3 份
报告共 5 条 P1，人工逐条核验**全部是误报**；其中还有一份出现「正文列了
2 条 [P1]，结论行却写 REVIEW_VERDICT: PASS」的自相矛盾。

⇒ 让它当**放行裁决者**会被自己的误报卡死（每次 push 都要人工绕过 hook，
且绕过不留痕）；让它完全没声音又浪费了一个真能抓 bug 的独立信源。

本模块提供的折中：**findings 永远进报告（可审计），但要不要阻断由人的
核验结论决定**。台账 `githooks/review-adjudication.jsonl` 每行一条 JSON：

    {"match": "granularSave.*空 Tag", "file": "ClipMemory/Services/ClipboardStore+Persistence.swift",
     "fileSha256": "…", "severity": "P1", "verdict": "false-positive",
     "note": "已按目录解析真实 tag；该路径在占位后端下不可达",
     "adjudicatedAt": "2026-10-25T10:00:00Z", "expiresAt": "2026-10-25T10:00:00Z"}

判定规则（一条 finding 要被「人工结论」接管，需同时满足）：
  1. `match` 正则命中该 finding 文本（正则编译失败则退化为字面子串）；
  2. `severity` 缺省或与该 finding 的严重度一致；
  3. 未过期（`expiresAt` 在未来）；
  4. 若填了 `file`：该文件当前内容的 sha256 必须仍等于 `fileSha256`
     ⇒ **代码一改，这条结论自动失效**，必须重新核验。

两条 verdict 的语义：
  - `confirmed`    真问题 ⇒ **阻断 push**，直到该文件被改动（自动失效）；
  - `false-positive` 误报 ⇒ 该 finding 不再具备阻断力（strict 模式下即放行口子）。

门禁模式（`REVIEW_GATE_MODE`）：
  - `advisory`（默认）模型 findings **不单独**阻断 push；只有人工记为
    `confirmed` 的 finding 才阻断。理由：本地小模型的严重度不可信
    （见上），把它的标签当裁决依据，等于让噪音拥有否决权。
  - `strict`      保留旧行为：模型结论 FAIL 即阻断（适用于链上挂了
    严重度可信的大模型时）。
  两种模式下，人工记为 `confirmed` 的 finding **都**阻断。

用法
----
    review-adjudicate.py list  [--ledger P] [--report P] [--repo-root P]
    review-adjudicate.py add   --match REGEX [--file PATH] [--severity P0|P1]
                               --note TEXT [--expires-days N] [--ledger P]
    review-adjudicate.py apply --report P [--ledger P] [--repo-root P]
                               [--mode advisory|strict]

`apply` 会把核验结论写进报告（追加 "## 人工核验 / Adjudication" 段），
并把生效结论打到 stdout：

    EFFECTIVE_VERDICT=PASS|FAIL
    BLOCKING_COUNT=N
    ADVISORY_COUNT=N
"""

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import sys

BLOCKING_SEVERITIES = ("P0", "P1")
DEFAULT_LEDGER = "githooks/review-adjudication.jsonl"
DEFAULT_EXPIRY_DAYS = 365

# 报告里的 finding 行形态：`FINDINGS: [P1] 文本`（可能带 markdown 装饰）
FINDING_RE = re.compile(
    r"^\s*(?:[-*+>]\s*)?(?:\*\*)?\s*FINDINGS\s*:\s*"
    r"\[?(P[0-3])\]?\s*(?:\*\*)?\s*[:：]?\s*(.*)$"
)


# ---------------------------------------------------------------- 基础工具

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now():
    return _dt.datetime.now(_dt.timezone.utc)


def iso(dt):
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(text):
    if not text:
        return None
    try:
        return _dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def match_text(pattern, text):
    """正则匹配。正则编译失败 ⇒ **不匹配**并告警。

    为什么不退化成字面子串：那样等于「这条结论永远不生效」，而台账里躺着
    一条 `confirmed` 结论却不生效，正是最容易让人误以为「已经核验过了」的状态。
    宁可让它不匹配 + 响亮告警，把问题摆到台面上让操作者改对。
    """
    if not pattern:
        return False
    try:
        return re.search(pattern, text) is not None
    except re.error as err:
        print(
            f"[review-adjudicate] ⚠️ match 正则编译失败，已跳过该条结论（不匹配）：{pattern!r} — {err}",
            file=sys.stderr,
        )
        return False


# ---------------------------------------------------------------- 台账读写

def load_ledger(path):
    """读台账。坏行跳过并告警 —— 一行坏 JSON 不该让整个门禁失效。"""
    entries = []
    if not os.path.isfile(path):
        return entries
    with open(path, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as err:
                print(
                    f"[review-adjudicate] ⚠️ 台账 {path}:{lineno} 不是合法 JSON，已跳过：{err}",
                    file=sys.stderr,
                )
                continue
            if not isinstance(item, dict) or "match" not in item:
                print(
                    f"[review-adjudicate] ⚠️ 台账 {path}:{lineno} 缺少 match 字段，已跳过",
                    file=sys.stderr,
                )
                continue
            entries.append(item)
    return entries


def entry_is_active(entry, now=None):
    now = now or utc_now()
    expires = parse_iso(entry.get("expiresAt"))
    if expires is not None and expires < now:
        return False
    return True


def entry_applies(entry, finding, repo_root):
    """这条人工结论是否适用于这条 finding（见模块 docstring 的四条规则）。"""
    if entry.get("severity") and entry.get("severity") != finding["severity"]:
        return False
    if not entry_is_active(entry):
        return False
    if not match_text(entry.get("match", ""), finding["text"]):
        return False
    target = entry.get("file")
    if target:
        path = os.path.join(repo_root, target)
        if not os.path.isfile(path):
            return False
        recorded = entry.get("fileSha256")
        if not recorded:
            return False
        if sha256_file(path) != recorded:
            return False
    return True


def find_entry(finding, entries, repo_root):
    for entry in entries:
        if entry_applies(entry, finding, repo_root):
            return entry
    return None


# ---------------------------------------------------------------- 报告解析

def parse_findings(report_text):
    """从报告正文抽出 findings。**只认 FINDINGS 行** —— 报告里回显的
    普通文本（哪怕含 '[P1]' 字样）不算一条 finding。"""
    findings = []
    for line in report_text.splitlines():
        match = FINDING_RE.match(line)
        if not match:
            continue
        severity = match.group(1)
        text = match.group(2).strip()
        if not text:
            continue
        findings.append({"severity": severity, "text": text})
    return findings


def strip_previous_adjudication(report_text):
    """幂等：重跑 apply 时先把上一轮写的核验段剥掉，避免叠加两遍。"""
    marker = "## 人工核验 / Adjudication"
    index = report_text.find(marker)
    if index < 0:
        return report_text
    head = report_text[:index]
    # 剥到该段之前最近的 "---" 分隔线为止（那段是本模块自己写的）
    divider = head.rfind("\n---")
    if divider >= 0:
        head = head[:divider]
    return head.rstrip("\n") + "\n"


def annotate_report(report_path, findings, entries, repo_root, mode, effective):
    """把核验结论写进报告（审计痕迹）。"""
    blocking = [f for f in findings if f["severity"] in BLOCKING_SEVERITIES]
    confirmed = []
    cleared = []
    unadjudicated = []
    for finding in blocking:
        entry = find_entry(finding, entries, repo_root)
        if entry is None:
            unadjudicated.append(finding)
        elif entry.get("verdict") == "confirmed":
            confirmed.append((finding, entry))
        else:
            cleared.append((finding, entry))

    lines = ["", "---", "", "## 人工核验 / Adjudication", ""]
    counts = {}
    for finding in findings:
        counts[finding["severity"]] = counts.get(finding["severity"], 0) + 1
    summary = " / ".join(f"{sev} {counts[sev]}" for sev in sorted(counts)) or "无"
    lines.append(f"- 本次 findings 共 {len(findings)} 条：{summary}")
    lines.append(f"- 门禁模式：`{mode}`")
    if confirmed:
        lines.append(f"- ⛔ **阻断项**（人工记为 confirmed，尚未修复）：{len(confirmed)}")
        for finding, entry in confirmed:
            note = entry.get("note") or ""
            lines.append(f"  - [{finding['severity']}] {finding['text'][:160]}"
                         + (f" — {note}" if note else ""))
    else:
        lines.append("- ⛔ 阻断项（人工记为 confirmed，尚未修复）：0")
    if cleared:
        lines.append(f"- ✅ 已核验为误报：{len(cleared)}")
        for finding, entry in cleared:
            note = entry.get("note") or ""
            lines.append(f"  - [{finding['severity']}] {finding['text'][:160]}"
                         + (f" — {note}" if note else ""))
    if unadjudicated:
        lines.append(f"- ⚠️ **待核验的 P0/P1**（advisory 模式下不阻断 push）：{len(unadjudicated)}")
        for finding in unadjudicated:
            lines.append(f"  - [{finding['severity']}] {finding['text'][:160]}")
        lines.append("")
        lines.append("  核验方法：")
        lines.append("  ```bash")
        lines.append("  python3 githooks/review-adjudicate.py list --report <上面的报告>")
        lines.append("  python3 githooks/review-adjudicate.py add --match '<正则>' \\")
        lines.append("      --file <相关文件> --note '<为什么这么判>'")
        lines.append("  ```")
    lines.append(f"- 生效结论：**{effective}**")
    lines.append("")

    with open(report_path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))

    return {
        "confirmed": confirmed,
        "cleared": cleared,
        "unadjudicated": unadjudicated,
    }


# ---------------------------------------------------------------- 命令

def cmd_apply(args):
    if not os.path.isfile(args.report):
        print(f"[review-adjudicate] 报告不存在：{args.report}", file=sys.stderr)
        return 2
    with open(args.report, encoding="utf-8") as handle:
        report_text = handle.read()

    findings = parse_findings(report_text)
    entries = load_ledger(args.ledger)
    repo_root = os.path.abspath(args.repo_root)

    confirmed = []
    unadjudicated = []
    for finding in findings:
        if finding["severity"] not in BLOCKING_SEVERITIES:
            continue
        entry = find_entry(finding, entries, repo_root)
        if entry is None:
            unadjudicated.append(finding)
        elif entry.get("verdict") == "confirmed":
            confirmed.append(finding)

    # 判定：
    #  - 人工记为 confirmed 的 finding ⇒ 一律阻断（直到文件改动使结论失效）；
    #  - strict 模式下，**未被核验的** P0/P1 也阻断（已核验为误报的除外）；
    #  - strict 模式下若一条 P0/P1 都解析不出、而模型结论是 FAIL ⇒ 保守阻断
    #    （没有可核验的对象，不能当成通过）。
    blocking_findings = [f for f in findings if f["severity"] in BLOCKING_SEVERITIES]
    model_blocks = False
    if args.mode == "strict":
        model_blocks = bool(unadjudicated) or (
            not blocking_findings and args.model_verdict == "FAIL"
        )

    effective = "FAIL" if (confirmed or model_blocks) else "PASS"

    # 幂等：先把上一轮写的核验段剥掉，再写本轮的（重跑不会叠加两遍）
    with open(args.report, encoding="utf-8") as handle:
        current = handle.read()
    cleaned = strip_previous_adjudication(current)
    if cleaned != current:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(cleaned)

    annotate_report(args.report, findings, entries, repo_root, args.mode, effective)

    print(f"EFFECTIVE_VERDICT={effective}")
    print(f"BLOCKING_COUNT={len(confirmed)}")
    print(f"ADVISORY_COUNT={len(unadjudicated)}")
    print(f"MODE={args.mode}")
    if effective == "FAIL":
        for finding in confirmed:
            print(f"BLOCKED_CONFIRMED=[{finding['severity']}] {finding['text'][:160]}")
        if model_blocks and args.mode == "strict":
            print("BLOCKED_BY_MODEL=模型结论 FAIL 或存在未核验的 P0/P1（strict 模式）")
    return 0


def cmd_list(args):
    if not os.path.isfile(args.report):
        print(f"[review-adjudicate] 报告不存在：{args.report}", file=sys.stderr)
        return 2
    with open(args.report, encoding="utf-8") as handle:
        report_text = handle.read()
    findings = parse_findings(report_text)
    entries = load_ledger(args.ledger)
    repo_root = os.path.abspath(args.repo_root)
    print(f"报告：{args.report}")
    print(f"台账：{args.ledger}（{len(entries)} 条）")
    print("")
    for finding in findings:
        entry = find_entry(finding, entries, repo_root)
        if entry is None:
            state = "待核验" if finding["severity"] in BLOCKING_SEVERITIES else "（无需核验）"
            print(f"  [{finding['severity']}] {state}")
            print(f"      {finding['text']}")
        else:
            note = entry.get("note") or ""
            print(f"  [{finding['severity']}] 已核验：{entry.get('verdict')}"
                  + (f" — {note}" if note else ""))
            print(f"      {finding['text']}")
    return 0


def cmd_add(args):
    entry = {
        "match": args.match,
        "verdict": args.verdict,
        "note": args.note,
        "adjudicatedAt": iso(utc_now()),
    }
    if args.file:
        path = os.path.join(args.repo_root, args.file)
        if not os.path.isfile(path):
            print(f"[review-adjudicate] 文件不存在：{args.file}", file=sys.stderr)
            return 2
        entry["file"] = args.file
        entry["fileSha256"] = sha256_file(path)
    if args.severity:
        entry["severity"] = args.severity
    expires = utc_now() + _dt.timedelta(days=args.expires_days)
    entry["expiresAt"] = iso(expires)

    os.makedirs(os.path.dirname(os.path.abspath(args.ledger)), exist_ok=True)
    with open(args.ledger, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    print(f"已写入台账：{args.ledger}")
    print(json.dumps(entry, ensure_ascii=False, indent=2))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="审核门的人工核验台账")
    # 公共参数挂在**每个子命令**上（不是顶层）—— 顶层参数必须写在子命令之前，
    # 而门禁与测试都是 `review-adjudicate.py apply --ledger ...` 这种写法。
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--ledger", default=os.path.join(os.getcwd(), DEFAULT_LEDGER),
                        help="台账路径（JSONL，每行一条 JSON）")
    common.add_argument("--repo-root", default=os.getcwd(), help="仓库根目录")
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", parents=[common], help="列出报告里的 findings 及其核验状态")
    p_list.add_argument("--report", required=True)
    p_list.set_defaults(func=cmd_list)

    p_add = sub.add_parser("add", parents=[common], help="记一条人工核验结论")
    p_add.add_argument("--match", required=True, help="命中 finding 正则（编译失败则按字面子串）")
    p_add.add_argument("--file", help="相关文件（填了则该文件一改，这条结论自动失效）")
    p_add.add_argument("--severity", choices=["P0", "P1", "P2", "P3"])
    p_add.add_argument("--verdict", required=True, choices=["confirmed", "false-positive"])
    p_add.add_argument("--note", required=True, help="为什么这么判")
    p_add.add_argument("--expires-days", type=int, default=DEFAULT_EXPIRY_DAYS)
    p_add.set_defaults(func=cmd_add)

    p_apply = sub.add_parser("apply", parents=[common], help="按台账给出生效结论并写回报告")
    p_apply.add_argument("--report", required=True)
    p_apply.add_argument("--mode", default="advisory", choices=["advisory", "strict"])
    p_apply.add_argument("--model-verdict", default="", help="模型自己给的结论（PASS/FAIL）")
    p_apply.set_defaults(func=cmd_apply)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
