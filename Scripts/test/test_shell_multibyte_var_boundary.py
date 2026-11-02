#!/usr/bin/env python3
'''ID-REVIEW-1049 第六/八轮：shell 脚本的**可移植性**静态守卫（两道检查）。

## 检查一：「多字节字符紧跟未加花括号的变量」（第六轮，2026-11-01）

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

## 检查二：**bash 3.2 的语法**（第八轮，2026-11-02）

第八轮的改动把 CI **跑红了**，报的却是另一条 bash 3.2 家族的坑：

    Scripts/test/test_verify_production_canaries.sh: line 548: unexpected EOF
    while looking for matching `"'

⇒ 根因（**实测**，微实验复现）：**heredoc 放在 `$( … )` 里**时，bash **3.2**
会把 heredoc 正文里的引号**算进外层的配对计数** ⇒ ⇒ 正文里**奇数个**双引号
（**或**奇数个单引号）⇒ 配不上 ⇒ 报「找不到配对的双引号」
⇒ ⇒ **同一个文件本机 bash 5.3 通过、CI 的 bash 3.2 报错**
⇒ ⇒ 又是「**看起来绿**」。

    # 最小复现（3.2 失败 / 5.3 通过）：
    out="$(cat <<'PY'
    a " b
    PY
    )"

    # 修法（3.2 / 5.3 都通过）：heredoc **先落成临时文件**，再在 `$( )` 里调用
    cat > "$TMP/x.py" <<'PY'
    a " b
    PY
    out="$(python3 "$TMP/x.py")"

⇒ ⇒ **修法**就是把 heredoc **挪出** `$( )`（实测：不在 `$( )` 里时，bash 3.2
对**任意**引号奇偶**完全无感**）。

⚠️ **规则要写准**（第八轮核验员 P1-1 订正）：**不是**「正文里不能出现三个连续
双引号」—— 那是**一个触发实例**的字面形状，**不是规则**。实测矩阵（bash 3.2）：

| 正文里的引号 | 个数 | 在 `$( )` **内** | 在 `$( )` **外** |
|---|---|---|---|
| 双引号 | 1 / 3 / 5 / 7（**奇数**） | **解析失败** | ok |
| 双引号 | 2 / 4 / 6 / 8（**偶数**） | ok | ok |
| 单引号 | 1 / 3（**奇数**） | **解析失败** | ok |
| 单引号 | 2 / 4（**偶数**） | ok | ok |

⇒ ⇒ **规则**（**第十轮订正后的版本**；判据的**机器可读单一出处** =
`Scripts/test/shell-heredoc-quote-corpus.json`）：**词法上**在 `$( … )` 的
**文本内**的 heredoc，其正文里双引号与单引号**各自必须成对**（偶数个）；
**词法上**不在 `$( … )` 内（含「heredoc 在函数体内、而该函数在 `$( )` 内
被调用」这种）⇒ ⇒ **完全无感**。bash **5.3** 对以上**全部**形状都通过
⇒ ⇒ 本机（5.3）**永远测不出来**。

⇒ ⇒ **本守卫**现在**额外**用 **`/bin/bash`（macOS 自带 = 3.2）** 对每个 shell
脚本跑一遍 `bash -n`（**只解析、不执行**）⇒ ⇒ **语法层面的 3.2/5.x 差异**
从此在**提交前**就被抓住，而不是等 CI 炸。

⚠️ `/bin/bash` 不存在（非 macOS）⇒ **明确打印「跳过」** ⇒ **不假装检查过**。

## 它**不**检查什么

* 加了花括号的 `${VAR}` ⇒ **安全**（`}` 明确终止名字）⇒ 不报。
* 注释行（`#` 开头）⇒ 不会被 shell 解析 ⇒ 不报。
* `$$` / `$?` / `$1` 这类**特殊参数**后面跟多字节字符 ⇒ 本守卫**不报**
  （`$?` 这类不含名字、不会被吸走）；⚠️ 这是已知的**保守取舍**：宁可漏报
  也不误报 ⇒ 误报会让 CI 变成噪声源。
* `bash -n` **只查语法**，不查运行期行为。

## 退出码

| code | meaning |
|---|---|
| **0** | 干净（没有可移植性隐患） |
| **1** | 发现了隐患（每条一行，带文件:行号） |
| **2** | **守卫自己没跑起来**（用法错误 / 仓库读不到）⇒ 绝不冒充「干净」 |

## ⚠️ **只读**：它只读仓库里的文本文件、并用 `bash -n` **只解析不执行** ⇒
不碰用户的偏好设置、钥匙串、剪贴板。
'''

from __future__ import annotations

import os
import re
import subprocess
import sys

# 未加花括号的变量引用，后面紧跟一个**非 ASCII**字节。
PATTERN = re.compile(rb"\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7f])")

SKIP_DIRS = {
    ".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm",
    "vendor", "ThirdParty",
}
SUFFIXES = (".sh", ".bash", ".yml", ".yaml")
SHELL_SUFFIXES = (".sh", ".bash")
# macOS 自带的 bash = **3.2**（CI 的 macOS runner 就是它）⇒ 拿它验语法。
BASH3 = "/bin/bash"


def candidate_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            if name.endswith(SUFFIXES):
                yield os.path.join(dirpath, name)


def yaml_problems(root: str):
    '''⚠️ **附带**检查：workflow / 配置的 YAML **能不能解析**。

    ⇒ 为什么附带：2026-11-01 深夜本轮就因为 step 名里**漏了引号**
    （`name: Shell portability: …` ⇒ YAML 里的 `:` ⇒ "mapping values are
    not allowed here"）而**本地没发现** ⇒ ⇒ 与本脚本的其它检查一样，
    **能静态发现的，别留给 CI**。
    ⇒ 没有 PyYAML 时**跳过**（不假装检查过）。
    '''
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


def bash3_syntax_problems(root: str):
    '''用 **bash 3.2**（`/bin/bash`）对每个 shell 脚本做**只解析**的语法检查。

    ⇒ 为什么必须有（第八轮实测）：bash 3.2 与 5.x 有**语法层面的差异**
    （如 `$( )` 里的 heredoc，其正文里**奇数个**同类引号 ⇒ 3.2 解析失败、
    5.3 通过；heredoc 在 `$( )` 外 ⇒ 3.2 对**任意**奇偶都无感）⇒ ⇒ 本机
    默认 bash 5.3 **永远测不出来** ⇒ ⇒ 只能**显式**用 `/bin/bash` 验。
    ⚠️ 本守卫**不数引号**、只**解析** ⇒ ⇒ 因此对**任何**引号形状都有效
    （规则写错不会让守卫变瞎 —— 这是它比「按形状写规则」强的地方）。

    ⇒ `bash -n` **只解析、不执行** ⇒ 对仓库与用户环境**零副作用**。
    ⇒ `/bin/bash` 不存在 ⇒ 返回 `None`（调用方据此明确打印「跳过」），
    **不假装检查过**。
    '''
    if not os.path.exists(BASH3):
        return None
    problems = []
    for path in candidate_files(root):
        if not path.endswith(SHELL_SUFFIXES):
            continue
        try:
            result = subprocess.run(
                [BASH3, "-n", path], capture_output=True, text=True, timeout=30
            )
        except (OSError, subprocess.SubprocessError) as exc:
            problems.append(
                f"{os.path.relpath(path, root)}: 无法用 {BASH3} -n 检查：{exc}"
            )
            continue
        if result.returncode != 0:
            first = (result.stderr or "").strip().splitlines()
            detail = first[0] if first else f"exit={result.returncode}"
            problems.append(
                f"{os.path.relpath(path, root)}: **bash 3.2 语法检查没过** ⇒ {detail}"
                " ⇒ ⇒ 本机 bash 5.x 可能**测不出来**（CI 会红）"
            )
    return problems


def bash3_version() -> str:
    try:
        out = subprocess.run(
            [BASH3, "--version"], capture_output=True, text=True, timeout=30
        ).stdout
        return out.splitlines()[0].strip() if out else "?"
    except (OSError, subprocess.SubprocessError):
        return "?"


def zero_files_problem(scanned: int) -> str | None:
    '''扫了 **0** 个文件 ⇒ ⇒ 报红（**不是**「干净」，是「**没扫到**」）。

    ⚠️ 与 V10 / V17 同族：「**只抓认识的形状 ⇒ 静默漏检**」——
    ⇒ ⇒ 这里的「形状」是**文件清单** ⇒ ⇒ 路径规则失效 / 仓库结构变了
    ⇒ ⇒ 守卫会输出「✅ 扫了 **0** 个文件：没有隐患」⇒ ⇒ **静默放行**
    ⇒ ⇒ 而 CI 照样绿 ⇒ ⇒ ⇒ 与「验收表被改名 ⇒ 数字核对被静默关闭」
    ⇒ ⇒ 是**同一个洞**的两个实例。
    '''
    if scanned > 0:
        return None
    return (
        "扫了 **0** 个文件 ⇒ ⇒ 这**不是**「干净」，是「**没扫到**」"
        " ⇒ ⇒ 路径规则失效 / 仓库结构变了 ⇒ ⇒ 报红（不假装检查过）"
    )


def tracked_candidate_count(root: str) -> int | None:
    '''**独立**枚举（`git ls-files`）⇒ ⇒ 返回应被扫到的文件数（None = 无法枚举）。

    ⇒ ⇒ 为什么要有**第二条枚举路径**：本守卫的文件清单来自 `os.walk`
    ⇒ ⇒ ⇒ 而 `os.walk` 的结果**没人核对** ⇒ ⇒ ⇒ 若路径规则失效（跳过目录
    ⇒ ⇒ ⇒ 写错、后缀写错、walk 提前退出）⇒ ⇒ ⇒ 扫到的文件变少 ⇒ ⇒ ⇒
    ⇒ ⇒ ⇒ 而「零文件」判据**只覆盖最极端的一种**（`scanned == 0`）⇒ ⇒ ⇒
    ⇒ ⇒ ⇒ 剩下 1 个文件那种失效 ⇒ ⇒ ⇒ 守卫**照样报绿**（核验员 P3-3）
    ⇒ ⇒ ⇒ ⇒ ⇒ 本函数用**另一条**枚举路径交叉核对 ⇒ ⇒ ⇒ 与 V13
    ⇒ ⇒ ⇒ ⇒（两份实现各写各的 ⇒ ⇒ 差值能暴露单边错误）同款。

    ⚠️ **已从工作树删掉、但还在 git index 里**的文件**不计入** ⇒ ⇒
    ⇒ ⇒ 否则「删了文件还没 stage」会误报 ⇒ ⇒ ⇒ 只数**磁盘上真的存在**的。
    '''
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files"],
            capture_output=True, text=True, timeout=60,
        ).stdout
    except Exception:  # noqa: BLE001  # pylint: disable=broad-except
        return None
    files = [line for line in out.split("\n") if line.strip()]
    if not files:
        return None
    count = 0
    for rel in files:
        if not rel.endswith(SUFFIXES):
            continue
        if os.path.exists(os.path.join(root, rel)):
            count += 1
    return count


def fewer_files_problem(scanned: int, expected: int | None) -> str | None:
    '''扫到的文件数**少于**独立枚举出的数量 ⇒ ⇒ 报红。

    ⇒ ⇒ 「零文件」只是**最极端**的一种失效形态（核验员 P3-3）⇒ ⇒
    ⇒ ⇒ 本条堵的是**这一类**（「**少扫了**」）⇒ ⇒ ⇒ 判据是**纯函数**
    ⇒ ⇒ ⇒ ⇒ 所以自检能直接测它（不必真的造一个坏掉的仓库）。
    '''
    if expected is None or scanned >= expected:
        return None
    return (
        f"扫到 **{scanned}** 个文件，而**独立枚举**（`git ls-files`）出 "
        f"**{expected}** 个 ⇒ ⇒ **少扫了** ⇒ ⇒ 路径规则失效 / 仓库结构变了"
        f" ⇒ ⇒ 报红（不假装检查过）"
    )


def self_test() -> list[str]:
    '''证明「有牙齿」：零文件**必须**报红；少扫了**也必须**报红。'''
    problems: list[str] = []
    if zero_files_problem(0) is None:
        problems.append(
            "自检失败：扫了 **0** 个文件竟然**不报红** ⇒ ⇒ "
            "「没扫到」会被当成「干净」⇒ ⇒ 本守卫**没有牙齿**"
        )
    if zero_files_problem(3) is not None:
        problems.append(
            "自检失败：扫了 3 个文件竟然报红 ⇒ ⇒ 判据过严"
        )
    # ⇒ ⇒ 「少扫了」这一类失效（P3-3）⇒ ⇒ 必须也能报红。
    if fewer_files_problem(1, 5) is None:
        problems.append(
            "自检失败：只扫到 1 个文件、独立枚举出 5 个时**不报红** ⇒ ⇒ "
            "「少扫了」这种失效形态**判据没覆盖** ⇒ ⇒ 本守卫**没有牙齿**"
        )
    if fewer_files_problem(5, 5) is not None:
        problems.append(
            "自检失败：扫到 5 个、独立枚举也是 5 个时竟然报红 ⇒ ⇒ 判据过严"
        )
    if fewer_files_problem(3, None) is not None:
        problems.append(
            "自检失败：**无法枚举**时竟然报红 ⇒ ⇒ 判据过严（应当跳过而不是报错）"
        )
    return problems


def main(argv: list[str]) -> int:
    if "--self-test" in argv[1:]:
        problems = self_test()
        if problems:
            print("❌ 自检失败：", file=sys.stderr)
            for problem in problems:
                print("   - " + problem, file=sys.stderr)
            return 1
        print("✅ 自检通过：扫了 **0** 个文件**必须报红**；"
              "「少扫了」（独立枚举对不上）**也必须报红**"
              " ⇒ ⇒ 本守卫有牙齿")
        return 0
    if len(argv) != 2:
        print("用法：test_shell_multibyte_var_boundary.py <repo-root> [--self-test]",
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

    zero = zero_files_problem(scanned)
    if zero:
        problems.append(zero)

    # ⇒ ⇒ **少扫了**（P3-3：零文件只是最极端的一种失效形态）⇒ ⇒
    # ⇒ ⇒ 用**独立**的枚举路径交叉核对 ⇒ ⇒ 「路径规则失效 ⇒ 只剩 1 个
    # ⇒ ⇒ 文件」这种形态也能被抓住 ⇒ ⇒ 不再只覆盖 `scanned == 0`。
    fewer = fewer_files_problem(scanned, tracked_candidate_count(root))
    if fewer:
        problems.append(fewer)

    problems.extend(yaml_problems(root))

    bash3 = bash3_syntax_problems(root)
    bash3_checked = bash3 is not None
    if bash3 is None:
        print(f"⚠️ {BASH3} 不存在（非 macOS）⇒ **bash 3.2 语法检查已跳过**"
              "（不假装检查过）")
    else:
        problems.extend(bash3)

    if problems:
        print("❌ 静态守卫发现隐患：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    suffix = (
        f"；并用 {BASH3}（{bash3_version()}）对每个 shell 脚本跑了 `bash -n`"
        if bash3_checked else ""
    )
    print(f"✅ 扫了 {scanned} 个 shell / workflow 文件：没有"
          "「多字节字符紧跟未加花括号的 $VAR」隐患，YAML 也都能解析" + suffix)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
