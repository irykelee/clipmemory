#!/usr/bin/env python3
'''ID-REVIEW-1049 第十轮：bash 3.2 的「heredoc 引号奇偶」规则的**可执行回归**。

## 它守的是什么（不是仓库扫描器！）

`Scripts/test/test_shell_multibyte_var_boundary.py` 的第二道检查已经用
`/bin/bash -n` 逐个扫仓库里的 shell 脚本 ⇒ **仓库里的真实隐患**它能抓住
（而且它**不按形状写规则** ⇒ 规则写错也不会让它变瞎）。

⇒ ⇒ **本脚本不重复那件事**。本脚本守的是**另一头**：

> **我们写在文档 / 注释里的那条规则，本身是否仍然成立。**

即：台账 §50.20.2 / 守卫 docstring / 契约脚本注释里那句
「`$( … )` 里的 heredoc，正文里的引号**各自必须成对**（偶数个）
⇒ ⇒ 这条规则**每一条散文副本**都可能：
  ① 写**窄**（只说「连续三个双引号」⇒ 一个触发实例的字面形状，**不是规则**）；
  ② 漏**维度**（函数体内的 heredoc ⇒ 词法上**不在** `$( )` 内 ⇒ 安全）；
  ③ 被**改了一处忘了其余**（第九轮实测：守卫 docstring 改了，契约脚本注释
     与台账两处**没改** ⇒ 同一处错误规则的**三个副本**里只修了一个）。

⇒ ⇒ **修法（本轮，代号 V15）**：
  1. **判据的机器可读单一出处** = `Scripts/test/shell-heredoc-quote-corpus.json`
     （本脚本的 `--regenerate` 产出 ⇒ **永远来自实测**，不靠手抄）；
  2. **判据被 sha256 锁住**（`EXPECTED_CORPUS_SHA256` 硬编码在本脚本里）
     ⇒ 改语料 ⇒ 必须同时改本脚本 ⇒ **协同成本**（与 canary-gate-locks 同款）；
  3. **每条规则副本都必须与语料一致** —— 由本脚本比对实测值；
  4. **场景构造本身要可验证** —— 每条场景先跑一个 **0 引号基线**：
     基线若就 FAIL ⇒ 那是**样本构造错了**（例如 heredoc 终止符被缩进），
     ⇒ 本脚本报「场景构造错误」而**不是**把 FAIL 当成期望值。
     ⚠️ 本轮作者第一版探针就踩了这个坑：终止符缩进 ⇒ 全列 FAIL ⇒
     差点把「函数体内的 heredoc 恒失败」这条**假规则**写进台账。

⇒ ⇒ **它不做什么**：不判断「某个 shell 脚本写得对不对」⇒ 那件事归
`test_shell_multibyte_var_boundary.py`（问解析器）。

## 用法

    python3 Scripts/test/test_shell_heredoc_quote_rule.py .          # 比对（默认）
    python3 Scripts/test/test_shell_heredoc_quote_rule.py . --regenerate
    python3 Scripts/test/test_shell_heredoc_quote_rule.py . --self-test

`--regenerate` 重测并**重写**语料，同时打印新语料的 sha256 ⇒ 请把该值
同步到本脚本的 `EXPECTED_CORPUS_SHA256`（否则下一轮比对会红 —— 这是**故意**的：
语料与锁不一致 ⇒ 报红，不静默放过）。

`--self-test` 内部注入一条**假期望**并断言检测逻辑确实会报红
⇒ 证明「有牙齿」；不依赖任何仓库文件被改动。

## 退出码

| code | meaning |
|---|---|
| **0** | 干净（实测与语料一致） |
| **1** | 有差异（实测 ≠ 语料，或语料哈希不符，或场景构造错误） |
| **2** | 守卫自己没跑起来（用法错误 / 仓库读不到）⇒ 绝不冒充「干净」 |

## ⚠️ **只读**：它只读仓库里的语料文件、并用 `bash -n` **只解析不执行**
⇒ 不碰用户的偏好设置、钥匙串、剪贴板；临时脚本写在系统临时目录里。
'''

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

# ⚠️ **锁在语料的外面**（ID-REVIEW-1049 六轮 V9 / 十轮 V15）：
#   语料（= 规则的机器可读出处）**自己**也必须被锁住，否则「改语料里的期望值」
#   = 改规则 = 静默改判据 ⇒ 守卫会照着错的期望值跑 ⇒ 一致 ⇒ 绿。
#   ⇒ 期望值硬编码在本脚本里 ⇒ 改语料必须同时改本脚本 ⇒ 协同成本。
EXPECTED_CORPUS_SHA256 = "c65e9891e70bcaf50c19be9922519aeb5f565c1be32a4aac6cb652bb32aa9efa"

CORPUS_REL = os.path.join("Scripts", "test", "shell-heredoc-quote-corpus.json")

BASH3 = "/bin/bash"

# 双引号 / 单引号各测到几个。
DQ_COUNTS = list(range(0, 9))
SQ_COUNTS = list(range(0, 5))

# ⚠️ 形状模板里 heredoc 的**终止符必须顶格**（bash 的硬要求）⇒
#   否则「终止符缩进」这个**独立**的失败原因会混进「引号奇偶」的结果里
#   ⇒ 矩阵看起来整齐、结论却是假的（本轮作者第一版探针就栽在这里）。
SHAPES: dict[str, dict[str, object]] = {
    "outside_top": {
        "desc": "heredoc 在顶层（词法上不在任何 `$( )` 内）",
        "in_sub_lexically": False,
        "template": (
            'cat > "$OUT" <<\'PY\'\n'
            "body %Q% end\n"
            "PY\n"
            "echo ok\n"
        ),
    },
    "in_sub": {
        "desc": "heredoc 词法上在 `$( … )` 内（最小复现）",
        "in_sub_lexically": True,
        "template": (
            'out="$(cat > "$OUT" <<\'PY\'\n'
            "body %Q% end\n"
            "PY\n"
            ')"\n'
            "echo ok\n"
        ),
    },
    "in_nested_sub": {
        "desc": "heredoc 词法上在**嵌套**的 `$( … )` 内",
        "in_sub_lexically": True,
        "template": (
            'out="$(echo "$(cat > "$OUT" <<\'PY\'\n'
            "body %Q% end\n"
            "PY\n"
            ')")"\n'
            "echo ok\n"
        ),
    },
    "in_sub_group": {
        "desc": "heredoc 词法上在 `$( … )` 内的 `{ … }` 组里",
        "in_sub_lexically": True,
        "template": (
            'out="$( { cat > "$OUT" <<\'PY\'\n'
            "body %Q% end\n"
            "PY\n"
            '} )"\n'
            "echo ok\n"
        ),
    },
    "in_sub_pipeline": {
        "desc": "heredoc 词法上在 `$( … )` 内的**管道**里",
        "in_sub_lexically": True,
        "template": (
            'out="$(cat > "$OUT" <<\'PY\' | cat\n'
            "body %Q% end\n"
            "PY\n"
            ')"\n'
            "echo ok\n"
        ),
    },
    "in_func_body": {
        "desc": "heredoc 在**函数体内**，函数在**顶层**被调用",
        "in_sub_lexically": False,
        "template": (
            "f() {\n"
            'cat > "$OUT" <<\'PY\'\n'
            "body %Q% end\n"
            "PY\n"
            "}\n"
            "f\n"
            "echo ok\n"
        ),
    },
    "in_func_body_called_in_sub": {
        "desc": "heredoc 在**函数体内**，函数**在 `$( … )` 内被调用**"
                "（运行时在 `$( )` 里，但**词法上不在** ⇒ 安全）",
        "in_sub_lexically": False,
        "template": (
            "f() {\n"
            'cat > "$OUT" <<\'PY\'\n'
            "body %Q% end\n"
            "PY\n"
            "}\n"
            'out="$(f)"\n'
            "echo ok\n"
        ),
    },
    "func_def_in_sub": {
        "desc": "**函数定义本身**词法上在 `$( … )` 内 ⇒ 触发",
        "in_sub_lexically": True,
        "template": (
            'out="$(f() {\n'
            'cat > "$OUT" <<\'PY\'\n'
            "body %Q% end\n"
            "PY\n"
            '}; f)"\n'
            "echo ok\n"
        ),
    },
}


def quote_body(quote: str, count: int) -> str:
    ch = '"' if quote == "dq" else "'"
    return "a " + ch * count + " b"


def build_script(shape: str, quote: str, count: int, tmpdir: str) -> str:
    template = str(SHAPES[shape]["template"])
    out = os.path.join(tmpdir, "out.txt")
    body = template.replace("%Q%", quote_body(quote, count)).replace("$OUT", out)
    return body


def run_bash_n(script: str, interpreter: str, tmpdir: str) -> int | None:
    path = os.path.join(tmpdir, "probe.sh")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(script)
    try:
        result = subprocess.run(
            [interpreter, "-n", path], capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.returncode


def bash_major(interpreter: str) -> int | None:
    try:
        out = subprocess.run(
            [interpreter, "--version"], capture_output=True, text=True, timeout=30
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for token in out.split():
        if token.startswith(("3.", "4.", "5.", "6.")):
            return int(token.split(".")[0])
    return None


def find_bash5() -> str | None:
    '''找到 PATH 上**主版本 ≥ 5** 的 bash ⇒ 返回其路径。

    ⚠️ **为什么不能直接用 `"bash"`**（实测踩过 ⇒ CI 跑红，2026-11-02）：
    * 本机：`bash` = `/opt/homebrew/bin/bash`（**5.3**）⇒ 用它验 5.x 列。
    * **GitHub 的 macOS runner**：`bash` = **`/bin/bash`（3.2）** ⇒ 用它验
      「5.x 列」⇒ 实测拿到 **rc=2**（3.2 的行为）⇒ 与语料里「5.x = 0」的
      期望**冲突** ⇒ ⇒ **CI 红**，而本机全绿。
    ⇒ ⇒ 也就是说：*「`bash`」这个名字在两台机器上指的是**不同的东西***
    ⇒ ⇒ ⇒ **语料里的一列必须绑定到「某个明确版本的 bash」，而不是一个名字**
    ⇒ ⇒ 本函数找**主版本 ≥ 5** 的那个 ⇒ 找不到 ⇒ **该列跳过**（不假装检查过）。
    '''
    candidates = [
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        "/usr/bin/bash",
    ]
    which = shutil.which("bash")
    if which:
        candidates.insert(0, which)
    seen: set[str] = set()
    for path in candidates:
        if path in seen:
            continue
        seen.add(path)
        major = bash_major(path)
        if major is not None and major >= 5:
            return path
    return None


def corpus_sha256(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def observed_cases(tmpdir: str) -> list[dict[str, object]]:
    bash5 = find_bash5()
    cases: list[dict[str, object]] = []
    for shape in SHAPES:
        for quote, counts in (("dq", DQ_COUNTS), ("sq", SQ_COUNTS)):
            for count in counts:
                script = build_script(shape, quote, count, tmpdir)
                rc32 = run_bash_n(script, BASH3, tmpdir)
                rc53 = run_bash_n(script, bash5, tmpdir) if bash5 else None
                cases.append({
                    "shape": shape,
                    "quote": quote,
                    "count": count,
                    "expect_bash32_rc": rc32,
                    "expect_bash53_rc": rc53,
                })
    return cases


def build_corpus(cases: list[dict[str, object]]) -> dict[str, object]:
    return {
        "schema": "cm1049-heredoc-quote-rule/v1",
        "note": (
            "ID-REVIEW-1049 第十轮：bash 3.2 的「heredoc 引号奇偶」规则的"
            "**机器可读出处**。\n"
            "本文件由 `python3 Scripts/test/test_shell_heredoc_quote_rule.py ."
            " --regenerate` 生成 ⇒ 期望值**来自实测**，不靠手抄。\n"
            "⚠️ sha256 硬编码在那个脚本里（EXPECTED_CORPUS_SHA256）⇒ 改本文件"
            "必须同时改脚本 ⇒ 协同成本。\n"
            "⚠️ `expect_bash32_rc` = /bin/bash（macOS 自带 3.2）`bash -n` 的退出码；"
            "`expect_bash53_rc` = PATH 上 bash ≥5 的退出码（不存在时为 null ⇒ "
            "该列**跳过**，不假装检查过）。\n"
            "⚠️ count=0 的行是**基线**：形状构造本身必须合法（rc=0）⇒ 否则"
            "整列数据作废。"
        ),
        "shapes": {
            name: {
                "desc": str(info["desc"]),
                "in_sub_lexically": bool(info["in_sub_lexically"]),
            }
            for name, info in SHAPES.items()
        },
        "counts": {"dq": DQ_COUNTS, "sq": SQ_COUNTS},
        "cases": cases,
    }


def check_baselines(corpus: dict) -> list[str]:
    problems: list[str] = []
    for case in corpus.get("cases", []):
        if int(case["count"]) != 0:
            continue
        rc32 = case.get("expect_bash32_rc")
        if rc32 is None:
            problems.append(
                f"{case['shape']}/{case['quote']}: 基线（0 引号）没能跑起来"
                "⇒ 场景构造本身有问题 ⇒ 该形状的整组数据作废"
            )
        elif int(rc32) != 0:
            problems.append(
                f"{case['shape']}/{case['quote']}: 基线（0 引号）就 FAIL"
                f"（rc={rc32}）⇒ **场景构造错了**（例如 heredoc 终止符被缩进）"
                "⇒ 该形状的整组数据作废 —— 不可把它当成期望值"
            )
    return problems


def compare(corpus: dict, tmpdir: str, bash5: str | None = None) -> list[str]:
    problems: list[str] = []
    by_key = {
        (c["shape"], c["quote"], int(c["count"])): c
        for c in corpus.get("cases", [])
    }
    for shape in SHAPES:
        for quote, counts in (("dq", DQ_COUNTS), ("sq", SQ_COUNTS)):
            for count in counts:
                key = (shape, quote, count)
                case = by_key.get(key)
                if case is None:
                    problems.append(f"{shape}/{quote}/{count}: 语料里**缺这一条**")
                    continue
                script = build_script(shape, quote, count, tmpdir)
                rc32 = run_bash_n(script, BASH3, tmpdir)
                if rc32 is None:
                    problems.append(f"{shape}/{quote}/{count}: 没能用 {BASH3} -n 检查")
                    continue
                want32 = case.get("expect_bash32_rc")
                if want32 is None:
                    problems.append(
                        f"{shape}/{quote}/{count}: 语料里没有 3.2 的期望值"
                        "⇒ 该条**没被检查过**（不假装检查过）"
                    )
                elif rc32 != int(want32):
                    problems.append(
                        f"{shape}/{quote}/{count}: 实测 rc={rc32} ≠ 语料期望 "
                        f"rc={want32} ⇒ **规则与实测不符**"
                    )
                want53 = case.get("expect_bash53_rc")
                if want53 is not None:
                    # ⚠️ **只在真的找到 ≥5 的 bash 时才验这一列** ——
                    #   否则「`bash`」在 CI 上指的是 **3.2** ⇒ 会拿 3.2 的行为
                    #   去对「5.x 的期望」⇒ **必然冲突** ⇒ CI 假红
                    #   （实测踩过，2026-11-02）。
                    if bash5 is None:
                        continue
                    rc53 = run_bash_n(script, bash5, tmpdir)
                    if rc53 is None:
                        problems.append(
                            f"{shape}/{quote}/{count}: 没能用 {bash5} -n 检查 5.x 列"
                        )
                    elif rc53 != int(want53):
                        problems.append(
                            f"{shape}/{quote}/{count}: 实测(bash≥5) rc={rc53} ≠ "
                            f"语料期望 rc={want53}"
                        )
    return problems


def self_test() -> list[str]:
    '''注入一条**假期望**，断言检测逻辑确实会报红 ⇒ 证明「有牙齿」。'''
    problems: list[str] = []
    with tempfile.TemporaryDirectory() as tmpdir:
        cases = observed_cases(tmpdir)
        corpus = build_corpus(cases)
        clean = compare(corpus, tmpdir, find_bash5())
        if clean:
            problems.append(
                "自检失败：刚生成的语料与实测**本应一致**，却报出 "
                f"{len(clean)} 处差异 ⇒ 比对逻辑本身有问题"
            )
        # 注入假期望
        first = corpus["cases"][0]
        first["expect_bash32_rc"] = 99
        poisoned = compare(corpus, tmpdir, find_bash5())
        if not poisoned:
            problems.append(
                "自检失败：注入假期望后**仍然全绿** ⇒ 本守卫**没有牙齿**"
            )
        # 破坏基线
        corpus2 = build_corpus(observed_cases(tmpdir))
        for case in corpus2["cases"]:
            if int(case["count"]) == 0:
                case["expect_bash32_rc"] = 7
                break
        baseline_problems = check_baselines(corpus2)
        if not baseline_problems:
            problems.append(
                "自检失败：破坏基线后**仍然全绿** ⇒ 基线检查没有牙齿"
            )
    return problems


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    unknown = flags - {"--regenerate", "--self-test"}
    if unknown:
        print(f"❌ 未知参数：{' '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    if len(args) != 1:
        print(
            "用法：test_shell_heredoc_quote_rule.py <repo-root> "
            "[--regenerate|--self-test]",
            file=sys.stderr,
        )
        return 2
    root = args[0]
    if not os.path.isdir(root):
        print(f"❌ 仓库目录不存在：{root}", file=sys.stderr)
        return 2

    if "--self-test" in flags:
        problems = self_test()
        if problems:
            print("❌ 自检失败：", file=sys.stderr)
            for problem in problems:
                print("   - " + problem, file=sys.stderr)
            return 1
        print("✅ 自检通过：注入假期望 ⇒ 会报红；破坏基线 ⇒ 会报红"
              "（⇒ 本守卫有牙齿）")
        return 0

    corpus_path = os.path.join(root, CORPUS_REL)
    if not os.path.exists(BASH3):
        print(f"⚠️ {BASH3} 不存在（非 macOS）⇒ **bash 3.2 那一列已跳过**"
              "（不假装检查过）")

    if "--regenerate" in flags:
        with tempfile.TemporaryDirectory() as tmpdir:
            cases = observed_cases(tmpdir)
            corpus = build_corpus(cases)
        blob = json.dumps(corpus, ensure_ascii=False, indent=2, sort_keys=True)
        blob += "\n"
        os.makedirs(os.path.dirname(corpus_path), exist_ok=True)
        with open(corpus_path, "w", encoding="utf-8") as fh:
            fh.write(blob)
        digest = hashlib.sha256(blob.encode("utf-8")).hexdigest()
        print(f"✅ 已重写语料：{CORPUS_REL}")
        print(f"   新 sha256 = {digest}")
        print("   ⇒ 请把它同步到本脚本的 EXPECTED_CORPUS_SHA256")
        return 0

    if not os.path.exists(corpus_path):
        print(f"❌ 语料缺失（{CORPUS_REL}）—— 规则没有机器可读的出处",
              file=sys.stderr)
        return 1
    digest = corpus_sha256(corpus_path)
    try:
        with open(corpus_path, encoding="utf-8") as fh:
            corpus = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"❌ 语料读不了：{exc}", file=sys.stderr)
        return 2

    problems: list[str] = []
    if EXPECTED_CORPUS_SHA256 == "TO_BE_FILLED_BY_REGENERATE":
        problems.append(
            "语料哈希尚未填入本脚本（EXPECTED_CORPUS_SHA256）⇒ "
            "语料**没被锁住** ⇒ 改它等于改判据而不被发现"
        )
    elif digest != EXPECTED_CORPUS_SHA256:
        problems.append(
            f"语料 sha256 不符：实测 {digest} ≠ 期望 {EXPECTED_CORPUS_SHA256}"
            " ⇒ 语料被改过（或被换行/编码动过）⇒ 判据可能被悄悄改掉"
        )
    problems.extend(check_baselines(corpus))

    with tempfile.TemporaryDirectory() as tmpdir:
        problems.extend(compare(corpus, tmpdir, find_bash5()))

    if problems:
        print("❌ 规则守卫发现不一致：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    total = len(corpus.get("cases", []))
    bash5 = find_bash5()
    if bash5 is None:
        suffix = "；⚠️ **本机没有 bash ≥ 5** ⇒ 5.x 列**已跳过**（不假装检查过）"
    else:
        suffix = f"；5.x 列用 `{bash5}`（bash {bash_major(bash5)}）复核"
    print(f"✅ {total} 条规则用例与实测**逐条一致**（{BASH3} = "
          f"bash {bash_major(BASH3)}）⇒ 规则没有漂移；语料 sha256 已锁定"
          + suffix)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
