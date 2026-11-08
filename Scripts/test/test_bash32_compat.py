#!/usr/bin/env python3
"""ID-CI-0021 — bash 3.2 兼容性守卫（macOS runner 的 /bin/bash 就是 3.2）。

为什么需要这个守卫
------------------
2026-11-08：`.github/workflows/ci.yml` 的 README 词汇表检查（DOC-0003）内联
用了 `declare -A EXPECTED_TRASH=(["README.md"]="回收站" …)`。那个台阶跑在
**macos-latest** ⇒ 系统的 `/bin/bash` 是 **3.2** ⇒ **没有关联数组** ⇒
bash 3.2 把 `["README.md"]` 当**算术表达式**解析 ⇒ 语法错误 ⇒ **7 个元素被
静默丢弃**（`declare` 整体仍返回 0 ⇒ `set -e` 抓不到）⇒ 数组为空 ⇒ 检查循环
**一次都不跑** ⇒ 照样打印「✅ consistent」⇒ ⇒ **假绿**（查了 0 个文件却声称
查了 7 个）。同一轮还发现 `Scripts/lint-appcast-coverage.sh` 用了
`mapfile`（bash 4.0+）⇒ **在 macOS 上直接死掉**，而它的头部注释却写着
「the portable form is identical」⇒ ⇒ **注释是假的**（CI 跑 ubuntu ⇒ 一直绿）。

两个坑的共同点：**macOS 的 bash 3.2 与 ubuntu 的 bash 5 的差异，在 CI 的
ubuntu 台阶上永远看不见** ⇒ ⇒ 所以必须在**代码层面**挡住，而不是靠 CI 变红。

规则
----
`Scripts/**` 下的 shell 脚本、以及 `.github/workflows/*.yml` 里的 shell 代码，
**不得**使用 bash 4.0+ 才有的构造：

===================  ========  ==========================================
构造                  起始版本   备注
===================  ========  ==========================================
``mapfile``          4.0       读数组；bash 3.2 没有
``readarray``        4.0       同上（另一个名字）
``declare -A``       4.0       关联数组；bash 3.2 没有
``declare -g``       4.2       全局作用域声明
``local -n``         4.3       nameref
``wait -n``          4.3
``shopt -s globstar`` 4.0       `**` 递归展开
``${v,,}`` / ``${v^^}`` 4.0      大小写转换
``[[ -v var ]]``     4.2       变量是否存在
``coproc``           4.0
``${v@Q}``           4.4       转换类展开
===================  ========  ==========================================

**注释里提到这些名字是允许的**（正文经常要解释这些坑）⇒ 所以本守卫先剥掉
注释再匹配。

豁免（allowlist）
-----------------
`Scripts/test/bash32_compat_allowlist.txt`：每行 `路径<TAB>理由`。
只在确实需要（例如某个 fixture 故意含有这些字符串）时才加。

用法
----
    python3 Scripts/test/test_bash32_compat.py .            # 检查
    python3 Scripts/test/test_bash32_compat.py . --self-test # 自检
"""

import argparse
import os
import re
import sys

# (名字, 起始 bash 版本, 正则) —— 正则只匹配**代码**，注释已被剥掉
CONSTRUCTS = [
    ("mapfile/readarray (bash 4.0+)", "4.0",
     r"(?:^|[;&|(\s])(?:mapfile|readarray)\b"),
    ("declare -A / typeset -A / local -A (bash 4.0+)", "4.0",
     r"\b(?:declare|typeset|local)\s+-A\b"),
    ("declare -g / local -g (bash 4.2+)", "4.2",
     r"\b(?:declare|typeset|local)\s+-g\b"),
    ("local -n nameref (bash 4.3+)", "4.3",
     r"\blocal\s+-n\b"),
    ("wait -n (bash 4.3+)", "4.3",
     r"\bwait\s+-n\b"),
    ("shopt -s globstar (bash 4.0+)", "4.0",
     r"\bshopt\s+-s\s+globstar\b"),
    ("${v,,} / ${v^^} (bash 4.0+)", "4.0",
     r"\$\{[A-Za-z_][A-Za-z0-9_]*(?:,,|\^\^)"),
    ("[[ -v var ]] (bash 4.2+)", "4.2",
     r"\[\[\s+-v\s"),
    ("coproc (bash 4.0+)", "4.0",
     r"(?:^|[;&|(\s])coproc\b"),
    ("${v@Q} 等转换展开 (bash 4.4+)", "4.4",
     r"\$\{[A-Za-z_][A-Za-z0-9_]*@[A-Za-z]"),
]

ALLOWLIST_RELPATH = "Scripts/test/bash32_compat_allowlist.txt"

# 只扫描这些地方：shell 脚本 + workflow（workflow 里跑的就是 shell）
SCAN_DIRS = ("Scripts", "githooks", ".githooks")
SCAN_SUFFIXES = (".sh", ".bash")
WORKFLOW_DIR = ".github/workflows"


def strip_shell_comment(line):
    """去掉行尾注释（粗略但够用：跟踪单/双引号状态）。

    目的只有一个：**注释里提到 `declare -A` 之类的名字不该被当成违规**。
    """
    out = []
    quote = None
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < n:
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t;"):
            break
        out.append(ch)
        i += 1
    return "".join(out)


def iter_scanned_files(root):
    for rel_dir in SCAN_DIRS:
        base = os.path.join(root, rel_dir)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in (".git", "build", "__pycache__")]
            for name in sorted(filenames):
                if name.endswith(SCAN_SUFFIXES):
                    full = os.path.join(dirpath, name)
                    yield os.path.relpath(full, root), full
    wf_base = os.path.join(root, WORKFLOW_DIR)
    if os.path.isdir(wf_base):
        for name in sorted(os.listdir(wf_base)):
            if name.endswith((".yml", ".yaml")):
                full = os.path.join(wf_base, name)
                yield os.path.join(WORKFLOW_DIR, name), full


def load_allowlist(root):
    path = os.path.join(root, ALLOWLIST_RELPATH)
    allowed = {}
    if not os.path.isfile(path):
        return allowed
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            allowed[parts[0].strip()] = parts[1].strip()
    return allowed


def find_violations(root):
    """返回 [(relpath, lineno, 构造名, 该行内容)]"""
    allowed = load_allowlist(root)
    violations = []
    for rel, full in iter_scanned_files(root):
        if rel in allowed:
            continue
        try:
            with open(full, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().split("\n")
        except OSError:
            continue
        for idx, raw in enumerate(lines, 1):
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                continue
            code = strip_shell_comment(raw)
            for name, _min_bash, pattern in CONSTRUCTS:
                if re.search(pattern, code):
                    violations.append((rel, idx, name, stripped[:100]))
    return violations


def check(root):
    violations = find_violations(root)
    if violations:
        print("❌ bash 3.2 兼容性守卫：发现 bash 4.0+ 构造（ID-CI-0021）")
        print("")
        print("为什么这条要命：")
        print("  - CI 的 macos-latest 台阶用的系统 /bin/bash 是 **3.2**；")
        print("    ubuntu 台阶是 bash 5 ⇒ ubuntu 上永远绿 ⇒ 只有 macOS 上才炸。")
        print("  - bash 3.2 上 `declare -A` 会**静默丢弃**元素 ⇒ 检查循环零次执行")
        print("    ⇒ 打印「✅ 通过」却**一个文件都没查**（假绿）。")
        print("  - `mapfile` 在 bash 3.2 上直接 \"command not found\" ⇒ 脚本当场死。")
        print("")
        print("怎么改：")
        print("  - 关联数组 ⇒ 改成**竖线分隔的清单文件 + while read**")
        print("    （文件与期望值相邻 ⇒ 不会像平行数组那样错位）")
        print("  - mapfile  ⇒ 改成 `while IFS= read -r line; do arr+=(\"$line\"); done < <(...)`")
        print("  - 空数组展开（bash 3.2 + set -u）⇒ 写成 \"${arr[@]+\"${arr[@]}\"}\"")
        print("")
        print("违规：")
        for rel, lineno, name, text in violations:
            print(f"  - {rel}:{lineno} — {name}")
            print(f"      {text}")
        print("")
        print("（确实需要豁免 ⇒ 在 "
              f"{ALLOWLIST_RELPATH} 里加一行「路径<TAB>理由」）")
        return False
    print("✅ bash 3.2 兼容性守卫：Scripts/ 与 workflow 里没有 bash 4.0+ 构造")
    return True


def selftest(root):
    """自检：注入违规 ⇒ 必须被抓到；干净文件 ⇒ 必须不报。

    这一段本身就是本轮教训的对照组：**守卫自己不能假绿**。
    """
    tmp = os.path.join(root, ".bash32_compat_selftest_tmp")
    failures = []

    def run_case(label, content, expect_violation, rel_name="Scripts/tmp_probe.sh"):
        target = os.path.join(tmp, rel_name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(content)
        try:
            violations = find_violations(tmp)
            hit = any(v[0] == rel_name for v in violations)
            if hit != expect_violation:
                failures.append(
                    f"{label}: expected violation={expect_violation}, got {hit} "
                    f"(violations={violations})")
                print(f"  ❌ {label}")
            else:
                print(f"  ✅ {label}")
        finally:
            os.remove(target)

    print("== test_bash32_compat.py 自检 ==")

    # 干净文件 ⇒ 不报
    run_case("干净脚本不报", "#!/usr/bin/env bash\nset -euo pipefail\nfoo=1\necho \"$foo\"\n",
             False)

    # 注释里提到这些名字 ⇒ 不报（正文经常要解释这些坑）
    run_case("注释里提到 declare -A 不报",
             "#!/usr/bin/env bash\n# bash 3.2 lacks `declare -A`\n# also no `mapfile`\necho ok\n",
             False)

    # 真违规 ⇒ 必须报
    for label, snippet in [
        ("declare -A 被抓", "declare -A M=([a]=1)\n"),
        ("mapfile 被抓", "mapfile -t x < <(echo hi)\n"),
        ("readarray 被抓", "readarray -t x < <(echo hi)\n"),
        ("declare -g 被抓", "declare -g X=1\n"),
        ("local -n 被抓", "local -n ref=$1\n"),
        ("wait -n 被抓", "wait -n\n"),
        ("globstar 被抓", "shopt -s globstar\n"),
        ("${v,,} 被抓", "echo ${name,,}\n"),
        ("[[ -v ]] 被抓", "if [[ -v HOME ]]; then echo yes; fi\n"),
        ("coproc 被抓", "coproc PROC { echo hi; }\n"),
    ]:
        run_case(label, "#!/usr/bin/env bash\n" + snippet, True)

    # 豁免文件里的违规不该报
    os.makedirs(os.path.join(tmp, "Scripts"), exist_ok=True)
    allow_path = os.path.join(tmp, ALLOWLIST_RELPATH)
    os.makedirs(os.path.dirname(allow_path), exist_ok=True)
    with open(allow_path, "w", encoding="utf-8") as fh:
        fh.write("Scripts/allowed_probe.sh\t故意：fixture 里含这些字符串\n")
    run_case("豁免文件里的违规不报", "#!/usr/bin/env bash\ndeclare -A M=([a]=1)\n",
             False, rel_name="Scripts/allowed_probe.sh")

    # 清理
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("")
        for f in failures:
            print(f"❌ {f}")
        print(f"自检结果：{len(failures)} 项失败")
        return False
    print("自检结果：12/12 通过")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=".",
                        help="repo root (default: current directory)")
    parser.add_argument("--self-test", action="store_true",
                        help="run the guard's own self-test")
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    if args.self_test:
        return 0 if selftest(root) else 1
    return 0 if check(root) else 1


if __name__ == "__main__":
    sys.exit(main())
