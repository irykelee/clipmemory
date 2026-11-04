#!/usr/bin/env python3
'''ID-REVIEW-1049 第十三轮：散文副本守卫的**探针清单**跑批（审核门 P2 / 核验员 P3-3）。

## 为什么要有这个脚本

⇒ ⇒ 台账与上一轮报告里出现过「**16/16** 全部报红」「**10** 组全部 PASS」这类
⇒ ⇒ ⇒ ⇒ **手写数字** ⇒ ⇒ ⇒ ⇒ 而那份探针清单**只存在于 `/tmp`** ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **第三方无法复算** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ *⇒ ⇒ 「口径不清的数字比没有数字更坏」* ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

⇒ ⇒ ⇒ ⇒ 现在清单**入库**（`Scripts/test/prose-guard-probes.json`）⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ 由本脚本跑 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 清单长什么样

| 段 | 条数 | 语义 |
|---|---|---|
| **E** | **16** | 独立核验员构造的**新逃逸路径** ⇒ ⇒ 期望**报红** ⇒ ⇒ 绿了就是**逃逸** |
| **A** | **10 组**（**20** 条） | 每组 = 一条**负对照**（期望红）+ 一条**正对照**（期望绿）⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 负对照 **10** 条 + 正对照 **10** 条 |

⇒ ⇒ 合计 **39** 条探针（E 16 + A 20 + **R 3**）⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 基线一侧怎么算

⇒ ⇒ 传 `--baseline-guard <路径>`（例如 `git show 473fade:Scripts/test/…` 的输出）
⇒ ⇒ ⇒ ⇒ 本脚本会**同时**跑基线守卫 ⇒ ⇒ ⇒ ⇒ 并与清单里 `baseline_expect`
⇒ ⇒ ⇒ ⇒ 记录的值比对 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ *⇒ ⇒ 「旧版逃逸 N 条」也变成机器数* ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 用法

    python3 Scripts/test/test_prose_guard_probes.py
    python3 Scripts/test/test_prose_guard_probes.py --baseline-guard /tmp/base_guard.py

## 退出码

| code | meaning |
|---|---|
| **0** | 每条探针都符合清单里的期望 |
| **1** | 有探针不符合期望 ⇒ ⇒ 绝不冒充「全绿」 |
| **2** | 清单读不到 / 守卫跑不起来 ⇒ ⇒ 绝不冒充「干净」 |
'''

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

# ⚠️⚠️ **不要让 Python 写 `.pyc`** ⇒ 本脚本只写临时目录。
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CORPUS_PATH = os.path.join(HERE, "prose-guard-probes.json")
GUARD_REL = os.path.join("Scripts", "test", "test_rule_prose_copies.py")
GUARD_PATH = os.path.join(REPO, GUARD_REL)


def load_corpus() -> dict | None:
    if not os.path.exists(CORPUS_PATH):
        print(f"❌ 读不到探针清单：{CORPUS_PATH}", file=sys.stderr)
        return None
    try:
        with open(CORPUS_PATH, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"❌ 探针清单读不出来：{exc}", file=sys.stderr)
        return None


def run_probe(workdir: str, name: str, text: str,
              guards: list[tuple[str, str]]) -> dict[str, dict]:
    '''把一条探针放进**独立临时 git 仓库** ⇒ ⇒ 跑各守卫 ⇒ ⇒ 记 exit + 输出。'''
    repo_dir = os.path.join(workdir, name)
    shutil.rmtree(repo_dir, ignore_errors=True)
    os.makedirs(repo_dir, exist_ok=True)
    subprocess.run(["git", "init", "-q", repo_dir], check=True,
                   capture_output=True)
    subprocess.run(["git", "-C", repo_dir, "config", "user.email", "v@v"],
                   check=True, capture_output=True)
    subprocess.run(["git", "-C", repo_dir, "config", "user.name", "v"],
                   check=True, capture_output=True)
    with open(os.path.join(repo_dir, "probe.md"), "w", encoding="utf-8") as fh:
        fh.write(text)
    subprocess.run(["git", "-C", repo_dir, "add", "-A"], check=True,
                   capture_output=True)
    result: dict[str, dict] = {}
    for label, guard in guards:
        proc = subprocess.run([sys.executable, guard, repo_dir],
                              capture_output=True, text=True, timeout=180)
        result[label] = {
            "exit": proc.returncode,
            "out": (proc.stdout + proc.stderr).strip(),
        }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--baseline-guard", default=None,
                        help="基线守卫的路径（可选）⇒ ⇒ 复算旧版一侧")
    parser.add_argument("--json", dest="json_out", default=None,
                        help="把逐条结果写成 JSON")
    args = parser.parse_args()

    corpus = load_corpus()
    if corpus is None:
        return 2
    probes = corpus.get("probes") or []
    if not probes:
        print("❌ 探针清单是**空的** ⇒ ⇒ 没法跑 ⇒ ⇒ 绝不冒充「全绿」",
              file=sys.stderr)
        return 2
    if not os.path.exists(GUARD_PATH):
        print(f"❌ 读不到散文守卫：{GUARD_PATH}", file=sys.stderr)
        return 2

    guards = [("new", GUARD_PATH)]
    if args.baseline_guard:
        if not os.path.exists(args.baseline_guard):
            print(f"❌ 读不到基线守卫：{args.baseline_guard}", file=sys.stderr)
            return 2
        guards.append(("old", args.baseline_guard))

    workdir = tempfile.mkdtemp(prefix="cm-prose-probes-")
    rows: list[dict] = []
    # ⇒ ⇒ ⚠️ **new 侧**与 **baseline 侧**的失败**分开计数** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 第十三轮核验员 P3-4 实测：合在一起算 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 基线漂移会**少报** new 侧符合数 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 而标签仍写「当前守卫」⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    new_failures: list[str] = []
    baseline_failures: list[str] = []
    try:
        for probe in probes:
            name = probe["name"]
            verdicts = run_probe(workdir, name, probe["text"], guards)
            new = verdicts["new"]
            keyword = probe.get("keyword") or ""
            if probe["expect"] == "red":
                ok = new["exit"] == 1 and (not keyword or keyword in new["out"])
                reason = ("期望报红" if new["exit"] == 1 else "**没报红（逃逸）**")
                if new["exit"] == 1 and keyword and keyword not in new["out"]:
                    reason = f"报红了但没看到「{keyword}」"
            else:
                ok = new["exit"] == 0
                reason = "期望全绿" if ok else "**误报**"
            row = {
                "name": name,
                "segment": probe.get("segment", "?"),
                "expect": probe["expect"],
                "keyword": keyword,
                "new_exit": new["exit"],
                "ok": ok,
                "reason": reason,
                "note": probe.get("note", ""),
            }
            if "old" in verdicts:
                row["old_exit"] = verdicts["old"]["exit"]
                expected_old = probe.get("baseline_expect")
                if expected_old is not None:
                    row["baseline_expect"] = expected_old
                    row["baseline_ok"] = (row["old_exit"] == expected_old)
                    if not row["baseline_ok"]:
                        baseline_failures.append(
                            f"{name}：基线 exit {row['old_exit']}，"
                            f"清单里记的是 {expected_old} ⇒ ⇒ 基线口径**漂了**"
                        )
            rows.append(row)
            if not ok:
                new_failures.append(f"{name}：{reason} ⇒ ⇒ {new['out'][:160]}")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print(f"{'probe':<28}{'段':<4}{'期望':<8}{'新':<5}{'旧':<5}verdict")
    print("-" * 84)
    for row in rows:
        old = row.get("old_exit", "-")
        print(f"{row['name']:<28}{row['segment']:<4}"
              f"{row['expect']:<8}{row['new_exit']:<5}{str(old):<5}"
              f"{'OK' if row['ok'] else 'FAIL'}（{row['reason']}）")

    red = sum(1 for r in rows if r["expect"] == "red")
    green = sum(1 for r in rows if r["expect"] == "green")
    by_segment: dict[str, list[int]] = {}
    for r in rows:
        seg = by_segment.setdefault(r["segment"], [0, 0])
        seg[0 if r["expect"] == "red" else 1] += 1
    seg_text = " / ".join(
        f"{seg} 段 {v[0]} 红 + {v[1]} 绿" for seg, v in sorted(by_segment.items())
    )
    print()
    new_ok = len(rows) - len(new_failures)
    print(f"合计 **{len(rows)}** 条探针（{seg_text}）"
          f" ⇒ ⇒ **当前守卫**：{new_ok}/{len(rows)} 符合期望")
    # ⇒ ⇒ ⚠️ **别写成 `"old" in {…}`** ⇒ ⇒ ⇒ ⇒ 集合里装的是 `old_exit`
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ *「查不到 ⇒ ⇒ 静默放过」那族*
    if any("old_exit" in r for r in rows):
        olds = [r["old_exit"] for r in rows if "old_exit" in r]
        print(f"基线一侧：{sum(1 for e in olds if e == 1)}/{len(olds)} 报红"
              f" ⇒ ⇒ 「旧版逃逸 {sum(1 for e in olds if e == 0)} 条」**机器数**")
    else:
        print("基线一侧：**没核对**（没提供 `--baseline-guard`）⇒ ⇒ "
              "旧版那一列**这次没测**⇒ ⇒ 绝不冒充「核对过」")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(rows, fh, ensure_ascii=False, indent=1)

    if new_failures or baseline_failures:
        print("❌ 探针清单跑批失败：", file=sys.stderr)
        for item in new_failures:
            print("   - [当前守卫] " + item, file=sys.stderr)
        for item in baseline_failures:
            print("   - [基线口径] " + item, file=sys.stderr)
        return 1

    noted = [r for r in rows if r.get("note")]
    if noted:
        print()
        print("⚠️ 带订正说明的探针（期望值**实跑**出来的 ⇒ ⇒ 不是抄来的）：")
        for row in noted:
            print(f"   - {row['name']}：{row['note']}")
    print("✅ 探针清单全部符合期望 ⇒ ⇒ 「N/16」「N/10」这些数字**可复现**了")
    return 0


if __name__ == "__main__":
    sys.exit(main())
