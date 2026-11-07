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
# ⇒ ⇒ **seam**（只为自检能指向**合成夹具** ⇒ ⇒ 默认行为**逐字不变**）：
#   CM_PROBES_CORPUS — 探针清单路径
#   CM_PROBES_GUARD  — 被跑的守卫路径
CORPUS_PATH = os.environ.get("CM_PROBES_CORPUS") or os.path.join(HERE, "prose-guard-probes.json")
GUARD_REL = os.path.join("Scripts", "test", "test_rule_prose_copies.py")
GUARD_PATH = os.environ.get("CM_PROBES_GUARD") or os.path.join(REPO, GUARD_REL)


def load_corpus(corpus_path: str = None) -> dict | None:
    if not os.path.exists(corpus_path):
        print(f"❌ 读不到探针清单：{corpus_path}", file=sys.stderr)
        return None
    try:
        with open(corpus_path, encoding="utf-8") as fh:
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


def run_corpus(corpus_path: str, guard_path: str, baseline_guard: str = None) -> int:
    """跑一遍清单 ⇒ ⇒ 返回退出码（0 = 全部符合期望）。"""
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--baseline-guard", default=None,
                        help="基线守卫的路径（可选）⇒ ⇒ 复算旧版一侧")
    parser.add_argument("--json", dest="json_out", default=None,
                        help="把逐条结果写成 JSON")
    # ⇒ ⇒ `--self-test` 是**本脚本**的开关 ⇒ ⇒ 不能被清单的 argparse 吃进去
    args = parser.parse_args([a for a in sys.argv[1:] if a != "--self-test"])

    corpus = load_corpus(corpus_path)
    if corpus is None:
        return 2
    probes = corpus.get("probes") or []
    if not probes:
        print("❌ 探针清单是**空的** ⇒ ⇒ 没法跑 ⇒ ⇒ 绝不冒充「全绿」",
              file=sys.stderr)
        return 2
    if not os.path.exists(guard_path):
        print(f"❌ 读不到散文守卫：{guard_path}", file=sys.stderr)
        return 2

    guards = [("new", guard_path)]
    baseline = baseline_guard if baseline_guard is not None else args.baseline_guard
    if baseline:
        if not os.path.exists(baseline):
            print(f"❌ 读不到基线守卫：{baseline}", file=sys.stderr)
            return 2
        guards.append(("old", baseline))

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



# ── 自检：合成夹具 ⇒ ⇒ 逐条注入违规 ⇒ ⇒ 必须**报出来** ──────────────────
# ⇒ ⇒ 为什么需要：本脚本是「**验证探针清单**」的那个 ⇒ ⇒ 它自己**失效**了
# ⇒ ⇒ ⇒ ⇒ 「清单符合期望」这句话就是**假的** ⇒ ⇒ ⇒ ⇒ 而它**没人验证** ⇒ ⇒ ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ 与 `test_release.sh` / `test_adjudication_claims.py` 同族。
def self_test() -> int:
    import tempfile
    problems = []
    work = tempfile.mkdtemp(prefix="cm-probes-st-")
    try:
        guard = os.path.join(work, "fake_guard.py")
        with open(guard, "w", encoding="utf-8") as fh:
            fh.write("import os, sys\nsys.exit(int(os.environ.get('FAKE_GUARD_RC', '0')))\n")
        base_guard = os.path.join(work, "fake_base.py")
        with open(base_guard, "w", encoding="utf-8") as fh:
            fh.write("import os, sys\nsys.exit(int(os.environ.get('FAKE_BASE_RC', '0')))\n")
        corpus = os.path.join(work, "corpus.json")

        def write(probes):
            with open(corpus, "w", encoding="utf-8") as fh:
                json.dump({"probes": probes}, fh)

        def run(probes, guard_rc="0", base_rc="0", baseline=None):
            write(probes)
            os.environ["FAKE_GUARD_RC"] = guard_rc
            os.environ["FAKE_BASE_RC"] = base_rc
            try:
                return run_corpus(corpus, guard, baseline)
            finally:
                os.environ.pop("FAKE_GUARD_RC", None)
                os.environ.pop("FAKE_BASE_RC", None)

        green = {"name": "p1", "segment": "A", "expect": "green", "keyword": "", "text": "x\n"}
        red = {"name": "p2", "segment": "A", "expect": "red", "keyword": "", "text": "y\n"}

        # ① 正向控制：期望与守卫行为一致 ⇒ 必须 exit 0
        if run([green], guard_rc="0") != 0:
            problems.append("正向控制失败：期望 green + 守卫 exit 0 ⇒ 却报红")
        if run([red], guard_rc="1") != 0:
            problems.append("正向控制失败：期望 red + 守卫 exit 1 ⇒ 却报红")
        # ② 注入违规 ①：期望 red 但守卫**不报** ⇒ 必须报「逃逸」
        if run([red], guard_rc="0") == 0:
            problems.append("注入无效：期望 red 而守卫 exit 0 ⇒ 清单跑批**没报逃逸** ⇒ 它瞎了")
        # ③ 注入违规 ②：期望 green 但守卫**乱报** ⇒ 必须报「误报」
        if run([green], guard_rc="1") == 0:
            problems.append("注入无效：期望 green 而守卫 exit 1 ⇒ 清单跑批**没报误报** ⇒ 它瞎了")
        # ④ 注入违规 ③：基线口径漂了 ⇒ 必须报「基线口径漂了」
        drifted = dict(red); drifted["baseline_expect"] = 1   # 守卫实际 exit 0 ⇒ 口径错
        if run([drifted], guard_rc="1", base_rc="0", baseline=base_guard) == 0:
            problems.append("注入无效：基线口径漂了 ⇒ 清单跑批**没报** ⇒ 它瞎了")
        # ⑤ 坏清单 ⇒ 必须 exit 2（**不是**「干净」）
        with open(corpus, "w", encoding="utf-8") as fh:
            fh.write("{ not json")
        os.environ["FAKE_GUARD_RC"] = "0"
        try:
            if run_corpus(corpus, guard) != 2:
                problems.append("坏清单必须 exit 2（读不出来）⇒ 它却报「干净」")
        finally:
            os.environ.pop("FAKE_GUARD_RC", None)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if problems:
        print("❌ 自检失败：", file=sys.stderr)
        for p in problems:
            print("   - " + p, file=sys.stderr)
        return 1
    print("✅ 自检通过：合成夹具下**逃逸 / 误报 / 基线口径漂了 / 坏清单**四类都报得出来"
          "（⇒ 这个跑批器**有牙齿**）")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    return run_corpus(CORPUS_PATH, GUARD_PATH)


if __name__ == "__main__":
    sys.exit(main())
