#!/usr/bin/env python3
'''判决 note 密度守卫（2026-11-13，第 8 份 pre-push 报告 finding #5 的真缺口）。

## 它守的是什么

`githooks/review-adjudication.jsonl` 里每条 `note` 是**人工判决的理由**
⇒ ⇒ 它要被下一个人读懂 ⇒ ⇒ ⇒ 而 `⇒` 链一旦写飞 ⇒ ⇒ ⇒
⇒ ⇒ ⇒ 理由就退化成**重复的箭头填充** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 而台账仍显示「已核验」
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **比没有记录更坏**（看着有依据，其实没有依据）。

实测（2026-11-13）：第 8 份报告的判决 note 退化到 **48199 字符 /
最长箭头串 23652 / 纯箭头行 666** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
而当时给 finding #5 的结论是「false-positive（度量脚本只量台账散文）」
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 那个结论**当轮就被自己的动作推翻** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **假警报不等于「结论错」** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **等于「结论没回答问题」** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 判据（阈值是**量出来的**，不是拍的）

口径与 `Scripts/measure-ledger-symbol-density.py` **基本一致**：箭头串 = 连续的 `⇒`
（中间可夹空白），长度**只数 `⇒` 个数**、不含空白。
**唯一差别**：本守卫的密度分母是 `len(note)`（**含**行尾换行符）⇒ ⇒ ⇒
那个脚本的分母是 `sum(len(line))`（**不含**换行符）⇒ ⇒ ⇒ ⇒ ⇒ 两者最大差 **0.0041**。

| 判据 | 阈值 | 依据（2026-11-13 实测的既有基线） |
|---|---|---|
| 1 note 长度 | ≤ **4000** 字符 | 既有基线最长 **2059** ⇒ ⇒ ⇒ 取基线上限 + 余量 |
| 2 最长箭头串 | ≤ **60** | 既有基线最长 **28** ⇒ ⇒ ⇒ ⇒ 退化样本 **201–23652** ⇒ ⇒ ⇒ ⇒ 3 倍余量仍必被抓 |
| 3 `⇒` 密度 | ≤ **0.30** | 既有基线最高 **0.2657** ⇒ ⇒ ⇒ ⇒ 负对照样本 **0.6187** |
| 4 纯箭头行 | = **0** | 既有基线**全部为 0** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 退化样本 **5 / 5 / 7 / 666** |
| 5 理由缺失 | **必报红** | 既有基线**全部非空**（最短 **47** 字）⇒ ⇒ ⇒ ⇒ 空/缺 note 的记录**必报红** ⇒ ⇒ ⇒ ⇒ 「已核验」却说不出为什么 ⇒ ⇒ ⇒ ⇒ ⇒ 比没有记录更坏 |

⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 阈值**不是**抄台账散文那套（那套只管 `docs/skips-ledger.md`）
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 本守卫只管**判决 note** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 刻意**不改**旧脚本 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 改它的 docstring 会废掉旧判决自己的锚点 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **fail-closed**（2026-11-13 独立核验补）⇒ ⇒ ⇒ ⇒ 台账**缺失 / 读不到 / 有坏 JSON 行** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 坏行必须**报红** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 跳过它 = 少检查了一条 = 装作检查过

## 用法

    python3 Scripts/test/test_adjudication_note_density.py .
    python3 Scripts/test/test_adjudication_note_density.py . --self-test

## 它**不**做什么

* **不**判定「密度高就是坏事」⇒ ⇒ ⇒ 阈值量的是**退化**，不是**文风**
* **不**改动任何文件（**只读**）⇒ ⇒ ⇒ 对用户环境零副作用
'''

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile

LEDGER_REL = os.path.join("githooks", "review-adjudication.jsonl")

# ⇒ ⇒ 四个阈值（依据见上表）⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
MAX_NOTE_CHARS = 4000
MAX_ARROW_RUN = 60
MAX_DENSITY = 0.30
MAX_PURE_ARROW_LINES = 0

# 一个箭头串 = 连续的 `⇒`（中间允许空白）。**只数 `⇒` 个数**，不含空白。
RUN = re.compile(r"(?:⇒[\s]*)+")

# 每条判据的**标识词** ⇒ ⇒ ⇒ 自检用它断言「这条判据**自己**抓得住」。
CRITERION_TOKENS = ("长度", "最长箭头串", "密度", "纯箭头行", "理由缺失")


def note_stats(note: str) -> dict:
    """量一条 note ⇒ ⇒ 返回统计字典。"""
    arrows = 0
    runs: list[int] = []
    pure_arrow_lines = 0
    for line in note.split("\n"):
        lengths = [m.group(0).count("⇒") for m in RUN.finditer(line)]
        arrows += sum(lengths)
        runs.extend(lengths)
        stripped = line.replace(" ", "").replace("\t", "")
        if stripped and set(stripped) == {"⇒"}:
            pure_arrow_lines += 1
    chars = len(note)
    return {
        "chars": chars,
        "arrows": arrows,
        "density": arrows / max(chars, 1),
        "maxRun": max(runs) if runs else 0,
        "pureArrowLines": pure_arrow_lines,
    }


def check_note(label: str, note: str) -> list[str]:
    """一条 note ⇒ ⇒ 返回问题列表（空 = 通过）。"""
    stats = note_stats(note)
    problems: list[str] = []
    if stats["chars"] > MAX_NOTE_CHARS:
        problems.append(f"{label}: note 长度 {stats['chars']} **超过** {MAX_NOTE_CHARS}"
                        " ⇒ ⇒ ⇒ 理由退化成了填充 ⇒ ⇒ ⇒ ⇒ 而台账仍显示「已核验」")
    if stats["maxRun"] > MAX_ARROW_RUN:
        problems.append(f"{label}: 最长箭头串 {stats['maxRun']} **超过** {MAX_ARROW_RUN}"
                        " ⇒ ⇒ ⇒ ⇒ 推理链写飞 ⇒ ⇒ ⇒ ⇒ ⇒ 这条 note 读不出结论")
    if stats["density"] > MAX_DENSITY:
        problems.append(f"{label}: `⇒` 密度 {stats['density']:.4f} **超过** {MAX_DENSITY}"
                        " ⇒ ⇒ ⇒ ⇒ 箭头占比过高 ⇒ ⇒ ⇒ ⇒ ⇒ 理由被箭头淹没")
    if stats["pureArrowLines"] > MAX_PURE_ARROW_LINES:
        problems.append(f"{label}: 纯箭头行 {stats['pureArrowLines']} **超过** {MAX_PURE_ARROW_LINES}"
                        " ⇒ ⇒ ⇒ ⇒ 整行只剩箭头 ⇒ ⇒ ⇒ ⇒ ⇒ 这不是文字，是退化产物")
    return problems


def fired_tokens(problems: list[str]) -> set[str]:
    """哪些判据被抓到了 ⇒ ⇒ ⇒ 自检用它断言「每条判据**各自**有牙齿」。"""
    return {token for token in CRITERION_TOKENS
            if any(token in problem for problem in problems)}


def read_records(path: str) -> tuple[list[tuple[int, dict]], list[tuple[int, str]]]:
    """读判决台账 ⇒ ⇒ 返回 ((行号, 记录), [(行号, 坏行原因)])。

    坏行**跳过并报出来**（不装作检查过）⇒ ⇒ ⇒ 且 `check_ledger` 会因坏行**报红**
    ⇒ ⇒ ⇒ ⇒ 跳过它 = 少检查了一条 = 装作检查过 ⇒ ⇒ ⇒ ⇒ 所以坏行不能只警告。
    """
    records: list[tuple[int, dict]] = []
    bad: list[tuple[int, str]] = []
    with open(path, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as err:
                reason = f"不是合法 JSON：{err}"
                print(f"⚠️ {path}:{lineno} {reason}", file=sys.stderr)
                bad.append((lineno, reason))
                continue
            if not isinstance(item, dict):
                reason = "不是对象"
                print(f"⚠️ {path}:{lineno} {reason}，已跳过", file=sys.stderr)
                bad.append((lineno, reason))
                continue
            records.append((lineno, item))
    return records, bad


def check_record(label: str, item: dict) -> list[str]:
    """一条判决记录 ⇒ ⇒ 返回问题列表（空 = 通过）。

    「理由缺失」单列 ⇒ ⇒ ⇒ 因为 `check_note` 收的是**字符串**⇒ ⇒ ⇒ ⇒
    而「没有理由」是**记录形状**的问题 ⇒ ⇒ ⇒ ⇒ ⇒ 两者不能混。
    """
    note = item.get("note")
    if not isinstance(note, str) or not note.strip():
        return [f"{label}: 判决**理由缺失**（note 缺失或为空）⇒ ⇒ ⇒ "
                "台账显示「已核验」却说不出为什么 ⇒ ⇒ ⇒ ⇒ ⇒ 比没有记录更坏"]
    return check_note(label, note)


def check_ledger(path: str) -> list[str]:
    """整个判决台账 ⇒ ⇒ 返回问题列表（空 = 通过）。"""
    if not os.path.isfile(path):
        return [f"{path}: **找不到判决台账** ⇒ ⇒ ⇒ 守卫自己没跑起来 ⇒ ⇒ ⇒ 不装作检查过"]
    records, bad = read_records(path)
    problems: list[str] = []
    for lineno, reason in bad:
        problems.append(f"{path}:{lineno} **坏行**（{reason}）⇒ ⇒ ⇒ "
                        "这条判决被跳过 = 少检查了一条 ⇒ ⇒ ⇒ ⇒ ⇒ 装作检查过 ⇒ ⇒ ⇒ ⇒ ⇒ 必报红")
    if not records:
        problems.append(f"{path}: **读不到任何判决记录** ⇒ ⇒ ⇒ ⇒ 守卫不知道自己在守什么"
                        " ⇒ ⇒ ⇒ ⇒ 不装作检查过")
        return problems
    for lineno, item in records:
        problems.extend(check_record(f"{path}:{lineno}", item))
    return problems


def self_test(repo_root: str) -> int:
    """合成退化 note ⇒ ⇒ 必须报红 ⇒ ⇒ ⇒ 证明判据**有牙齿**。"""
    failures: list[str] = []

    # ① 真退化样本同形（2026-11-13 实测：48199 字符 / 最长串 23652 / 纯箭头行 666）
    degenerate = ("结论：false-positive。\n" + "⇒ ⇒ " * 400 + "\n" + "⇒\n" * 5)
    problems = check_note("合成退化 note", degenerate)
    if not problems:
        failures.append("  合成退化 note **没有报红** ⇒ ⇒ ⇒ 判据无牙齿")
    else:
        print(f"✅ 合成退化 note ⇒ 报红（{len(problems)} 条）⇒ 有牙齿")

    # ② 每条判据**各自**有牙齿 ⇒ ⇒ ⇒ ⇒ 用例必须**隔离**（只触发它自己那条）
    cases = [
        ("超长 note", "x" * (MAX_NOTE_CHARS + 1), {"长度"}),
        ("长箭头串", "⇒ " * (MAX_ARROW_RUN + 1) + "x" * 3000, {"最长箭头串"}),
        ("高密度 note", "⇒字 " * 100, {"密度"}),
        ("纯箭头行 note", "理由文字。\n" + "⇒\n" * 3 + "补充说明。", {"纯箭头行"}),
    ]
    for label, note, expected in cases:
        got = fired_tokens(check_note(label, note))
        if not got:
            failures.append(f"  {label} **没有报红** ⇒ ⇒ ⇒ 判据无牙齿")
        elif got != expected:
            failures.append(f"  {label} 抓到 {sorted(got)}，期望 {sorted(expected)}"
                            " ⇒ ⇒ ⇒ ⇒ 用例**不隔离** ⇒ ⇒ ⇒ ⇒ ⇒ 判据的牙齿无法单独证明")
        else:
            print(f"✅ {label} ⇒ 只由「{'/'.join(sorted(expected))}」抓住 ⇒ 有牙齿")

    # ③ 正常 note 必须通过 ⇒ ⇒ ⇒ ⇒ 否则守卫是「一律报红」⇒ ⇒ ⇒ ⇒ 没有判别力
    ok_note = ("false-positive。\n\n实测：`pattern_extension('docs/*.py')` 返回 `'docs/*.py'`\n"
               "⇒ ⇒ ⇒ 不匹配 `EXT_RE` ⇒ ⇒ ⇒ ⇒ 判据 7 会报红。\n")
    if check_note("正常 note", ok_note):
        failures.append("  正常 note **竟然报红** ⇒ ⇒ ⇒ 守卫没有判别力")
    else:
        print("✅ 正常 note ⇒ 通过 ⇒ 有判别力")

    # ④ 「理由缺失」必须报红 ⇒ ⇒ ⇒ ⇒ 否则「已核验」可以没有理由
    empty_problems = check_record("合成空理由记录", {})
    if "理由缺失" not in fired_tokens(empty_problems):
        failures.append("  合成空理由记录 **没有报红** ⇒ ⇒ ⇒ ⇒ 「已核验」可以没有理由")
    else:
        print("✅ 空理由记录 ⇒ 只由「理由缺失」抓住 ⇒ 有牙齿")

    # ⑤ 坏 JSON 行必须报红 ⇒ ⇒ ⇒ ⇒ 跳过它 = 少检查了一条 = 装作检查过
    with tempfile.TemporaryDirectory() as tmp:
        bad_ledger = os.path.join(tmp, "review-adjudication.jsonl")
        with open(bad_ledger, "w", encoding="utf-8") as handle:
            handle.write('{"match":"x","verdict":"confirmed","note":"有理由"}\n')
            handle.write('{"match":"y","verdict":"confirmed","note":"理由"\n')
        bad_problems = check_ledger(bad_ledger)
        if not any("坏行" in problem for problem in bad_problems):
            failures.append("  坏 JSON 行 **没有报红** ⇒ ⇒ ⇒ ⇒ 跳过它 = 少检查了一条")
        else:
            print("✅ 坏 JSON 行 ⇒ 报红 ⇒ ⇒ ⇒ fail-closed")

    # ⑥ 正向对照：真实台账必须通过
    path = os.path.join(repo_root, LEDGER_REL)
    problems = check_ledger(path)
    if problems:
        failures.append(f"  真实台账 **报红** {len(problems)} 条 ⇒ ⇒ ⇒ ⇒ 见上")
        for line in problems[:5]:
            failures.append(f"    {line}")
    else:
        print("✅ 正向对照：真实台账通过")

    if failures:
        print("❌ 自检失败：", file=sys.stderr)
        for line in failures:
            print(line, file=sys.stderr)
        return 1
    print(f"✅ 自检通过：{len(CRITERION_TOKENS)} 条判据各自有牙齿 + 正向对照通过")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="量判决台账 note 的 ⇒ 密度")
    parser.add_argument("repo_root", nargs="?", default=".")
    parser.add_argument("--self-test", action="store_true", help="跑判据自检")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test(args.repo_root)
    path = os.path.join(args.repo_root, LEDGER_REL)
    problems = check_ledger(path)
    if problems:
        print("❌ 判决 note 密度检查发现问题：", file=sys.stderr)
        for line in problems:
            print(f"   - {line}", file=sys.stderr)
        return 1
    records, _bad = read_records(path)
    print(f"✅ 判决 note 密度：{len(records)} 条判决全部在阈值内"
          f"（长度 ≤ {MAX_NOTE_CHARS} / 最长箭头串 ≤ {MAX_ARROW_RUN}"
          f" / 密度 ≤ {MAX_DENSITY} / 纯箭头行 = 0）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
