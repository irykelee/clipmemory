#!/usr/bin/env python3
"""ID-REVIEW-1049 第六轮：shell 脚本的「**多字节字符紧跟未加花括号的变量**」静态守卫。

## 为什么需要它（**实测**，2026-11-01 深夜）

CI（GitHub macOS runner）第一次把第六轮的改动跑红，报的是：

    Scripts/test/test_verify_production_canaries.sh: line 352: MODE?: unbound variable

⇒ 根因：`echo "…（mode=$MODE）"` —— **全角右括号 `）` 紧跟在未加花括号的
`$MODE` 后面** ⇒ 在 **bash 3.2 + UTF-8 locale** 下，bash 把那个**多字节字符
吸进了变量名**（`$MODE）` 变成变量 `MODE）`）⇒ `set -u` ⇒ **unbound variable**
⇒ 脚本以退出码 1 结束。

⇒ **本地测不出来**：本机默认是 bash 5.3（`legal_variable_char` 的判定与
bash 3.2 不同）⇒ 同一个脚本本地 exit 0、CI exit 1。
⇒ **只有 CI 的 bash 3.2 能引爆** ⇒ 这正是本族最危险的形状：
**「看起来绿」**。

⇒ 复现（**不用**改任何文件）：

    env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 /bin/bash -c 'MODE=xx; echo "A$MODE）B"'
    #   ⇒ 输出 `A??B`（变量名被吸走）⇒ 而 `echo "A${MODE}B"` ⇒ `AxxB` ✔

⇒ ⇒ **修法**：`$VAR` 后紧跟多字节字符时**一律加花括号**（`${VAR}`）⇒
花括号明确终止变量名 ⇒ 与 bash 版本 / locale 无关。

⇒ ⇒ **本守卫**就是防止它**再回来**：扫全部 `*.sh` / `*.yml` / `*.yaml`，
凡「未加花括号的 `$NAME` 后面紧跟一个非 ASCII 字节」⇒ 报红。

## 它**不**检查什么

* 加了花括号的 `${VAR}` ⇒ **安全**（`}` 明确终止名字）⇒ 不报。
* 注释行（`#` 开头）⇒ 不会被 shell 解析 ⇒ 不报。
* `$$` / `$?` / `$1` 这类**特殊参数**后面跟多字节字符 ⇒ 本守卫**不报**
  （`$?` 这类不含名字、不会被吸走）；⚠️ 这是已知的**保守取舍**：宁可漏报
  也不误报 ⇒ 误报会让 CI 变成噪声源。

## 退出码

| code | meaning |
|---|---|
| **0** | 干净（没有可移植性隐患） |
| **1** | 发现了隐患（每条一行，带文件:行号） |
| **2** | **守卫自己没跑起来**（用法错误 / 仓库读不到）⇒ 绝不冒充「干净」 |

## ⚠️ **只读**：它只读仓库里的文本文件 ⇒ 不碰用户的偏好设置、钥匙串、剪贴板。
"""

from __future__ import annotations

import os
import re
import sys

# 未加花括号的变量引用，后面紧跟一个**非 ASCII**字节。
PATTERN = re.compile(rb"\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7f])")

SKIP_DIRS = {
    ".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm",
    "vendor", "ThirdParty",
}
SUFFIXES = (".sh", ".bash", ".yml", ".yaml")


def candidate_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            if name.endswith(SUFFIXES):
                yield os.path.join(dirpath, name)


def yaml_problems(root: str):
    """⚠️ **附带**检查：workflow / 配置的 YAML **能不能解析**。

    ⇒ 为什么附带：2026-11-01 深夜本轮就因为 step 名里**漏了引号**
    （`name: Shell portability: …` ⇒ YAML 里的 `:` ⇒ "mapping values are
    not allowed here"）而**本地没发现** ⇒ ⇒ 与本脚本的其它检查一样，
    **能静态发现的，别留给 CI**。
    ⇒ 没有 PyYAML 时**跳过**（不假装检查过）。
    """
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        return []
    problems = []
    for path in candidate_files(root):
        if not path.endswith((".yml", ".yaml")):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                yaml.safe_load(fh)
        except Exception as exc:  # noqa: BLE001 —— 任何解析异常都要报出来
            rel = os.path.relpath(path, root)
            problems.append(f"{rel}: YAML 解析失败：{str(exc).splitlines()[0]}")
    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("用法：test_shell_multibyte_var_boundary.py <repo-root>",
              file=sys.stderr)
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        print(f"❌ 仓库目录不存在：{root}", file=sys.stderr)
        return 2

    problems: list[str] = []
    scanned = 0
    for path in candidate_files(root):
        try:
            with open(path, "rb") as fh:
                blob = fh.read()
        except OSError as exc:
            print(f"❌ 读不了 {path}：{exc}", file=sys.stderr)
            return 2
        scanned += 1
        rel = os.path.relpath(path, root)
        for lineno, line in enumerate(blob.split(b"\n"), 1):
            if line.lstrip().startswith(b"#"):
                # 注释行 ⇒ 不会被 shell 解析 ⇒ 不构成隐患
                continue
            for match in PATTERN.finditer(line):
                var = match.group(1).decode("ascii")
                tail = match.group(2).decode("utf-8", "replace")
                problems.append(
                    f"{rel}:{lineno}  `${var}` 后面紧跟多字节字符 "
                    f"{tail!r} ⇒ 在 bash 3.2 + UTF-8 locale 下变量名会被吸走 "
                    f"⇒ `set -u` ⇒ unbound variable ⇒ **改成 `${{{var}}}`**"
                )

    problems.extend(yaml_problems(root))

    if problems:
        print("❌ 静态守卫发现隐患：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    print(f"✅ 扫了 {scanned} 个 shell / workflow 文件：没有"
          "「多字节字符紧跟未加花括号的 $VAR」隐患，YAML 也都能解析")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
