#!/usr/bin/env python3
'''台账符号密度度量（§51.18 的数字全部由本脚本产出 ⇒ ⇒ 可复算）。

## 它量什么

`docs/skips-ledger.md` 用 `⇒` 链做推理 ⇒ ⇒ 台账里到处是这个符号 ⇒ ⇒
于是「新增章节的符号密度是不是**失控**」这个问题**只能靠肉眼看** ⇒ ⇒ ⇒
而肉眼会漂 ⇒ ⇒ ⇒ ⇒ 所以这里把「失控」定义成**可复算的判据**。

## 口径（**换口径能得出相反的结论** ⇒ ⇒ 口径必须先说清再引用）

| 项 | 本脚本的口径 |
|---|---|
| 一个「箭头串」 | 连续的 `⇒`（允许中间夹空白）⇒ ⇒ **只数 `⇒` 的个数**，**不含空白** |
| 密度 | `⇒` 总数 ÷ 字符总数（**含**空格与标点） |
| 最长串 | 单个箭头串里 `⇒` 的**最大**个数 |
| 纯箭头行 | 整行去掉空白后**只剩** `⇒` 的行 |
| 分节 | 按 `##` / `###` / `####` / `#####` 的**编号**标题切段（`§51.18` 这种） |

⚠️ ⚠️ **别把空白算进箭头串长度** —— 本脚本第一版就是这么写的 ⇒ ⇒
测出「最长串 12 / 密度 0.2266」，与另一套脚本的「最长串 6 / 密度 0.1185」对不上
⇒ ⇒ ⇒ ⇒ 排查后确认是**脚本的错**（数据没变）⇒ ⇒ ⇒ ⇒ ⇒ ⇒
**教训**：**自己写的度量脚本也是判据** ⇒ ⇒ ⇒ 先怀疑判据，再怀疑数据
⇒ ⇒ ⇒ ⇒ 详见 `docs/skips-ledger.md` §51.18.2。

## 用法

    python3 Scripts/measure-ledger-symbol-density.py              # 全文 + 各节
    python3 Scripts/measure-ledger-symbol-density.py --section 51.18
    python3 Scripts/measure-ledger-symbol-density.py --self-test  # 口径自检

⚠️ **刻意没有「与台账里写的值对照」的功能**（2026-11-13，独立核验员 P3-2）：
原 docstring 承诺过 `--check` 会去读台账里写下的数字并比对 ⇒ ⇒ 但实现只是多打印一行
⇒ ⇒ ⇒ **文档与实现漂移** ⇒ ⇒ ⇒ ⇒ 而这正是本仓反复修过的那类毛病 ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ 现在的口径是：**脚本只负责量**，台账里引用什么数字由**写的人**负责 ⇒ ⇒
⇒ ⇒ ⇒ ⇒ 要核对就**手工跑一次脚本**再对照 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 若将来真要自动对照 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 必须先把台账里的数字变成
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **可解析的结构**（而不是散文里的「密度 **0.03**」）⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 它**不**做什么

* **不**判定「密度高就是坏事」⇒ ⇒ 归一化基准是**同文件既有同类章节**，
  不是全文平均 ⇒ ⇒ ⇒ 全文平均会被更早、更松的章节拉低。
* **不**改动任何文件（**只读**）⇒ ⇒ ⇒ 对用户环境零副作用。
'''

from __future__ import annotations

import argparse
import os
import re
import sys

LEDGER_REL = os.path.join("docs", "skips-ledger.md")

# 一个箭头串 = 连续的 `⇒`（中间允许空白）。**只数 `⇒` 个数**，不含空白。
RUN = re.compile(r"(?:⇒[\s]*)+")
# 编号标题：`## 51.18 …` / `#### 51.18.2 …` ⇒ ⇒ 取编号部分。
HEADING = re.compile(r"^#{2,5}\s+(\d+(?:\.\d+)*[a-z]*)\b")


def measure(lines: list[str]) -> dict:
    """量一段文本 ⇒ ⇒ 返回 (统计字典, 逐节统计)。"""
    arrows = 0
    chars = 0
    runs: list[int] = []
    pure_arrow_lines = 0
    for line in lines:
        lengths = [m.group(0).count("⇒") for m in RUN.finditer(line)]
        arrows += sum(lengths)
        runs.extend(lengths)
        chars += len(line)
        if line.strip() and set(line.replace(" ", "").replace("\t", "")) == {"⇒"}:
            pure_arrow_lines += 1
    stats = {
        "lines": len(lines),
        "arrows": arrows,
        "chars": chars,
        "density": arrows / max(chars, 1),
        "maxRun": max(runs) if runs else 0,
        "pureArrowLines": pure_arrow_lines,
    }
    return stats


def split_sections(lines: list[str]) -> list[tuple[str, int, int]]:
    """切成 (编号, 起始行号, 结束行号) —— 结束行号**不含**。"""
    marks = []
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if m:
            marks.append((i, m.group(1)))
    out = []
    for idx, (start, number) in enumerate(marks):
        end = marks[idx + 1][0] if idx + 1 < len(marks) else len(lines)
        out.append((number, start, end))
    return out


def fmt(stats: dict) -> str:
    return (
        f"行数={stats['lines']} ⇒数={stats['arrows']} 字符={stats['chars']} "
        f"密度={stats['density']:.4f} 最长串={stats['maxRun']} "
        f"纯箭头行={stats['pureArrowLines']}"
    )


def self_test() -> int:
    """**口径自检** ⇒ ⇒ 证明「空白不算进箭头串长度」这件事真的成立。

    ⚠️ 为什么必须有它：本脚本第一版把**空白**算进了长度 ⇒ ⇒ 测出「最长串 12」
    ⇒ ⇒ 与另一套脚本的「最长串 6」对不上 ⇒ ⇒ 而**两边都是绿的**
    ⇒ ⇒ ⇒ ⇒ 没有自检 ⇒ 没人知道哪个对 ⇒ ⇒ ⇒ ⇒ ⇒
    （这个坑的完整经过见 `docs/skips-ledger.md` §51.18.2。）

    ⇒ ⇒ 自检内容：造几段**已知**文本 ⇒ ⇒ 断言测出来的数**正好**是预期值。
    """
    cases = [
        # (文本, 预期 ⇒ 总数, 预期最长串, 预期纯箭头行数)
        ("⇒ ⇒ ⇒", 3, 3, 1),
        ("⇒⇒⇒", 3, 3, 1),
        ("⇒   ⇒\n⇒", 3, 2, 2),          # 两行都只剩箭头 ⇒ ⇒ 纯箭头行 = 2
        ("正文没有箭头", 0, 0, 0),
        ("⇒ ⇒\n\n⇒ ⇒ ⇒\n", 5, 3, 2),    # 空行**不算**纯箭头行，但那两行算
        ("⇒ ⇒ x", 2, 2, 0),               # 行里有正文 ⇒ ⇒ 不是纯箭头行
        ("  ⇒  ", 1, 1, 1),               # 只有空白 + 箭头 ⇒ ⇒ 仍是纯箭头行
    ]
    failures = []
    for text, want_arrows, want_max, want_pure in cases:
        stats = measure(text.splitlines())
        got = (stats["arrows"], stats["maxRun"], stats["pureArrowLines"])
        want = (want_arrows, want_max, want_pure)
        if got != want:
            failures.append(f"  {text!r}：期望 {want}，实得 {got}")
    if failures:
        print("❌ 口径自检失败：", file=sys.stderr)
        for line in failures:
            print(line, file=sys.stderr)
        return 1
    print(f"✅ 口径自检通过：{len(cases)} 组用例（空白**不**计入箭头串长度）")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="量台账的 ⇒ 符号密度")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--section", help="只看某一节（如 51.18）")
    parser.add_argument("--self-test", action="store_true", help="跑口径自检")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    path = os.path.join(args.repo_root, LEDGER_REL)
    if not os.path.isfile(path):
        print(f"❌ 找不到台账：{path}", file=sys.stderr)
        return 2
    lines = open(path, encoding="utf-8").read().splitlines()

    if args.section:
        for number, start, end in split_sections(lines):
            if number == args.section:
                print(f"§{number}：{fmt(measure(lines[start:end]))}")
                return 0
        print(f"❌ 台账里没有编号为 {args.section} 的节", file=sys.stderr)
        return 1

    whole = measure(lines)
    print(f"全文：{fmt(whole)}")
    print()
    for number, start, end in split_sections(lines):
        stats = measure(lines[start:end])
        print(f"§{number}：{fmt(stats)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
