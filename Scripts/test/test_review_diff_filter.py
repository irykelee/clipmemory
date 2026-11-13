#!/usr/bin/env python3
'''审核窗口白名单守卫（2026-11-13，ID-REVIEW-1032 的同族洞）。

## 它守的是什么

`githooks/orca-auto-review.sh` 把**抽样窗口**喂给独立审核模型 ⇒ ⇒
喂什么 ⇒ ⇒ 决定模型**能看见什么** ⇒ ⇒ ⇒ 看不见的东西 ⇒ ⇒ ⇒
模型没资格下结论 ⇒ ⇒ ⇒ ⇒ 所以白名单漏了哪类文件 ⇒ ⇒ ⇒ 那类文件的改动
**对审核完全不可见** ⇒ ⇒ ⇒ ⇒ 这不是「模型不够仔细」，是**工具的输入缺口**。

2026-11-13 实测：白名单 = swift / md / sh / yml / yaml ⇒ ⇒ ⇒
`*.py` 与 `*.jsonl` **都不在里面** ⇒ ⇒ ⇒ ⇒ 而这两个扩展名在本仓**恰好是门禁本身**：

* `*.py` = 22 个守卫与脚本（`Scripts/test/test_*.py`、`githooks/review-adjudicate.py`…）
* `*.jsonl` = `githooks/review-adjudication.jsonl` = **人工判决台账** ⇒ ⇒ 它决定
  哪条 finding 会被记成 `confirmed` ⇒ ⇒ ⇒ 从而**决定哪次 push 被阻断**

实测后果：范围 `4ab58c1..825fb2f` 的审核窗口里**只有 markdown** ⇒ ⇒
新入库的 179 行 Python 脚本**一行都没被模型看到**；范围 `825fb2f..b9ddc4e` 的
窗口里也**没有** jsonl 的 hunk ⇒ ⇒ ⇒ ⇒ 审核模型据此连报 2 条
「本次提交并未包含 jsonl 变更」的**假结论** ⇒ ⇒ ⇒ ⇒ ⇒

⇒ ⇒ ⇒ ⇒ **「窗口里没有」与「仓库里没有」是两件事** ⇒ ⇒ ⇒ ⇒

## 判据

1. 从 `githooks/orca-auto-review.sh` 里解析出 `git diff "$RANGE" --` 的
   **pathspect 白名单**（一组带引号的扩展名通配）。
2. 白名单**必须**包含 `*.py` 与 `*.jsonl`（门禁决定型文件）⇒ ⇒ 少一个 ⇒ 报红。
3. 仓库里**必须真的存在**这两类 tracked 文件 ⇒ ⇒ 否则判据是空的（报红，
   免得「白名单里有 `*.py` 但仓库没有 .py」这种假绿）。
4. `--self-test`：把白名单**改坏**（去掉 `*.py` / 去掉 `*.jsonl` /
   给白名单加上 `:(glob)` magic）⇒ ⇒ 每一种都必须**报红** ⇒ ⇒ ⇒
   证明判据**有牙齿**（不是「存在即通过」）。
5. **深度覆盖实测**：在**隔离的临时仓库**里，把白名单里的**每一个**扩展名
   在根目录与三层子目录各放一个文件 ⇒ ⇒ 看 `git diff` 到底命中哪些 ⇒ ⇒
   全部命中才算过 ⇒ ⇒ ⇒ 漏一个 ⇒ 报红 ⇒ ⇒ ⇒ ⇒
   ⇒ ⇒ ⇒ 「嵌套路径边缘情况」从此是**机器判据**，不是散文担心。
6. **glob magic 陷阱**：pathspec 一旦带上 `:(glob)` magic，`*` 就**不再跨 `/`**
   ⇒ ⇒ 实测 `:(glob)*.py` **只命中根目录** ⇒ ⇒ ⇒ 深层文件**静默失明**
   ⇒ ⇒ ⇒ ⇒ 要跨深度必须写 `:(glob)**/*.py` ⇒ ⇒ ⇒
   ⇒ ⇒ 用了 magic 却**没**写 `**/` 的 ⇒ ⇒ 报红。

## 用法

    python3 Scripts/test/test_review_diff_filter.py .
    python3 Scripts/test/test_review_diff_filter.py . --self-test

## 它**不**做什么

* **不**规定白名单**只能**有哪些扩展名 ⇒ ⇒ 新增类型是**允许**的
  （例如将来把守卫语料 `*.json` 也纳进来）⇒ ⇒ ⇒ 判据只钉住「**不能漏**」。
* **不**检查模型看到了多少行 ⇒ ⇒ 那是抽样预算（`per_file` / `max_files` /
  `head -1200`）的事 ⇒ ⇒ ⇒ 本守卫只管「**哪些文件进得来**」。
* **只读**：只读两个文件 ⇒ ⇒ 对用户环境零副作用。
'''

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile

HOOK_REL = os.path.join("githooks", "orca-auto-review.sh")
# 必须进窗口的类型：它们**决定门禁行为**（守卫脚本 + 人工判决台账）。
REQUIRED_PATTERNS = ("*.py", "*.jsonl")

# pathspec 的 glob magic 前缀 ⇒ ⇒ 带上它，`*` 就**不再跨 `/`**。
GLOB_MAGIC = ":(glob)"
# 深度探针只认**纯扩展名** ⇒ ⇒ 带通配或分隔符的 pathspec 探不了 ⇒ ⇒ 跳过。
EXT_RE = re.compile(r"^[A-Za-z0-9_+-]+$")
# 深度探针的层级：根目录 + 三层子目录 ⇒ ⇒ 用来暴露「只命中根目录」的截断。
PROBE_DEPTH_DIRS = ("", "d1/", "d1/d2/", "d1/d2/d3/")


def split_magic(pattern: str) -> tuple[list[str], str]:
    """拆出 pathspec 的 magic 签名与剩余部分。

    `:(glob,icase)*.py` ⇒ ⇒ (['glob', 'icase'], '*.py') ⇒ ⇒
    ⇒ ⇒ **不能只认 `:(glob)` 这个前缀** ⇒ ⇒ 实测 `:(glob,icase)*.py`
    ⇒ ⇒ 同样**只命中根目录** ⇒ ⇒ ⇒ ⇒ 签名必须**整个解析**。
    """
    if not pattern.startswith(":("):
        return [], pattern
    end = pattern.find(")")
    if end == -1:
        return [], pattern
    inner = pattern[2:end]
    parts = [part.strip() for part in inner.split(",") if part.strip()]
    return parts, pattern[end + 1:]


def pattern_extension(pattern: str) -> str:
    """从 pathspec 里取出扩展名 ⇒ ⇒ 去掉 magic 前缀与通配。"""
    _, rest = split_magic(pattern)
    if rest.startswith("**/"):
        rest = rest[3:]
    if rest.startswith("*."):
        rest = rest[2:]
    return rest


def glob_magic_offenders(patterns: list[str]) -> list[str]:
    """哪些 pathspec 用了 glob magic 却**没**写 `**/` ⇒ ⇒ 它们只命中根目录。"""
    offenders = []
    for pat in patterns:
        magic, rest = split_magic(pat)
        if not any("glob" in part.lower() for part in magic):
            continue
        if not rest.startswith("**/"):
            offenders.append(pat)
    return offenders

# `git diff "$RANGE" -- \` 后面那一行（或几行）里的带引号通配。
DIFF_LINE = re.compile(r"""git\s+diff\s+"\$RANGE"\s+--\s*\\?\s*(.*?)2>/dev/null""",
                       re.DOTALL)
QUOTED = re.compile(r"'([^']+)'")


def extract_patterns(script_text: str) -> list[str]:
    """从钩子脚本里取出 diff 白名单（带引号的通配），按出现顺序。"""
    match = DIFF_LINE.search(script_text)
    if not match:
        return []
    return QUOTED.findall(match.group(1))


def probe_pathspec_depth(patterns: list[str]) -> tuple[list[str], list[str], str]:
    """在**隔离的临时仓库**里实测白名单的深度覆盖。

    对白名单里的**每一个**扩展名，在根目录与三层子目录各放一个文件 ⇒ ⇒
    返回 (实际命中的相对路径, 本该命中却没命中的相对路径, 对照文件)
    ⇒ ⇒ 隔离 ⇒ ⇒ 不碰本仓索引与工作区 ⇒ ⇒ 零副作用。
    """
    exts: list[str] = []
    for pat in patterns:
        ext = pattern_extension(pat)
        if ext and EXT_RE.match(ext) and ext not in exts:
            exts.append(ext)
    if not exts:
        return [], [], ""
    # 对照文件的扩展名必须**不在**白名单里 ⇒ ⇒ 否则它会被正常命中 ⇒ ⇒ 对照失效。
    control_ext = "probectl"
    while control_ext in exts:
        control_ext += "x"
    probe_files = [f"{prefix}probe.{ext}" for ext in exts for prefix in PROBE_DEPTH_DIRS]
    control_rel = f"d1/d2/d3/control.{control_ext}"
    with tempfile.TemporaryDirectory(prefix="clipmemory-pathspec-") as tmp:
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        subprocess.run(["git", "-C", repo, "init", "-q"],
                       capture_output=True, text=True, check=True)
        for rel in probe_files + [control_rel]:
            path = os.path.join(repo, rel)
            parent = os.path.dirname(path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("probe\n")
        # `-f` ⇒ ⇒ 绕开**全局** excludesFile（本机的全局忽略可能挡掉某些扩展名）
        subprocess.run(["git", "-C", repo, "add", "-f", "-A"],
                       capture_output=True, text=True, check=True)
        proc = subprocess.run(
            ["git", "-C", repo, "diff", "--cached", "--name-only", "--", *patterns],
            capture_output=True, text=True, check=True)
        matched = {line.strip() for line in proc.stdout.splitlines() if line.strip()}
    missed = [rel for rel in probe_files if rel not in matched]
    return sorted(matched), missed, control_rel


def check_filter(script_text: str, tracked: list[str]) -> list[str]:
    """纯判据 ⇒ ⇒ `--self-test` 可以直接调它。返回问题列表（空 = 通过）。"""
    problems: list[str] = []
    patterns = extract_patterns(script_text)
    if not patterns:
        return [f"{HOOK_REL}: **解析不出** `git diff \"$RANGE\" --` 的 pathspec 白名单"
                " ⇒ ⇒ 守卫不知道自己在守什么 ⇒ ⇒ 不装作检查过"]
    for required in REQUIRED_PATTERNS:
        if required not in patterns:
            problems.append(
                f"{HOOK_REL}: 白名单**漏了** `{required}`"
                f"（当前 = {', '.join(patterns)}）"
                " ⇒ ⇒ 这类文件对审核模型**完全不可见**"
                " ⇒ ⇒ ⇒ 门禁决定型文件（守卫脚本 / 人工判决台账）的改动"
                " ⇒ ⇒ ⇒ 模型没资格下结论"
            )
    for required in REQUIRED_PATTERNS:
        suffix = required.lstrip("*")
        if not any(f.endswith(suffix) for f in tracked):
            problems.append(
                f"{HOOK_REL}: 白名单里有 `{required}` ⇒ ⇒ 但仓库里**没有**任何 "
                f"tracked `{suffix}` 文件 ⇒ ⇒ ⇒ 这条判据是**空的**"
                " ⇒ ⇒ ⇒ 判据为空 = 假绿"
            )
    for offender in glob_magic_offenders(patterns):
        problems.append(
            f"{HOOK_REL}: 白名单里的 `{offender}` 用了 **glob magic**"
            " ⇒ ⇒ 实测 `:(glob)*.py` **只命中根目录**"
            " ⇒ ⇒ ⇒ 深层文件（如 `Scripts/test/*.py`）会**静默失明**"
            " ⇒ ⇒ ⇒ ⇒ 要跨深度必须写 `:(glob)**/*.py`，或保持非 magic 的 `*.py`"
        )
    try:
        matched, missed, control_rel = probe_pathspec_depth(patterns)
    except (OSError, subprocess.SubprocessError) as exc:
        problems.append(
            f"{HOOK_REL}: 深度探针**跑不起来**（{exc.__class__.__name__}）"
            " ⇒ ⇒ ⇒ 守卫不知道白名单在深层目录命中什么"
            " ⇒ ⇒ ⇒ ⇒ 不装作检查过 ⇒ ⇒ 报红"
        )
        return problems
    for rel in missed:
        problems.append(
            f"{HOOK_REL}: 白名单 {', '.join(patterns)} 在**深度探针**里"
            f"**漏掉**了 `{rel}` ⇒ ⇒ 深层目录的文件对审核**完全不可见**"
            f" ⇒ ⇒ ⇒ 实测命中 = {', '.join(matched) or '（空）'}"
        )
    if control_rel and control_rel in matched:
        problems.append(
            f"{HOOK_REL}: 深度探针里对照文件 `{control_rel}` **不该命中**却命中了"
            " ⇒ ⇒ ⇒ 白名单比预期宽 ⇒ ⇒ 需复查"
        )
    return problems


def tracked_files(repo_root: str) -> list[str]:
    proc = subprocess.run(["git", "-C", repo_root, "ls-files"],
                           capture_output=True, text=True, check=False)
    return [line for line in proc.stdout.splitlines() if line.strip()]


def self_test(repo_root: str) -> int:
    """把白名单**改坏** ⇒ ⇒ 每一种都必须报红 ⇒ ⇒ 证明判据有牙齿。"""
    script_path = os.path.join(repo_root, HOOK_REL)
    original = open(script_path, encoding="utf-8").read()
    tracked = tracked_files(repo_root)
    failures = []
    for required in REQUIRED_PATTERNS:
        mutated = original.replace(f"'{required}'", "", 1)
        if mutated == original:
            failures.append(f"  变异失败：脚本里找不到 '{required}' ⇒ ⇒ 自检没意义")
            continue
        problems = check_filter(mutated, tracked)
        if not problems:
            failures.append(f"  变异体（去掉 {required}）**没有报红** ⇒ ⇒ 判据无牙齿")
        else:
            print(f"✅ 变异体（去掉 {required}）⇒ 报红 ⇒ 有牙齿")
    def expect_red(label: str, mutated: str, must_contain: list[str]) -> None:
        """变异体必须报红 ⇒ ⇒ 且必须由**指定的那几条**判据抓住 ⇒ ⇒ 否则那条没牙齿。"""
        if mutated == original:
            failures.append(f"  变异失败：{label} ⇒ ⇒ 自检没意义")
            return
        problems = check_filter(mutated, tracked)
        if not problems:
            failures.append(f"  变异体（{label}）**没有报红** ⇒ ⇒ 判据无牙齿")
            return
        missing = [token for token in must_contain
                   if not any(token in p for p in problems)]
        if missing:
            failures.append(f"  变异体（{label}）报红了，但没有命中 {missing}"
                            " ⇒ ⇒ 对应判据**没有牙齿**")
            return
        print(f"✅ 变异体（{label}）⇒ 报红 ⇒ 有牙齿")

    # 变异方向 ③：给白名单加 `:(glob)` magic ⇒ ⇒ 深度覆盖被打断 ⇒ ⇒
    # ⇒ ⇒ 必须**两条判据**都抓到：静态的「glob magic」+ 实测的「深度探针」。
    mutated = original
    for required in REQUIRED_PATTERNS:
        mutated = mutated.replace(f"'{required}'", f"'{GLOB_MAGIC}{required}'")
    expect_red("加 `:(glob)` magic", mutated, ["magic", "深度探针"])

    # 变异方向 ④：换成**长格式** magic 拼写 `:(glob,icase)` ⇒ ⇒
    # ⇒ ⇒ 只认 `:(glob)` 前缀的写法会**漏掉**它 ⇒ ⇒ ⇒ 实测它同样**只命中根目录**
    # ⇒ ⇒ ⇒ 所以判据 6 必须**整个解析签名**。
    mutated = original
    for required in REQUIRED_PATTERNS:
        mutated = mutated.replace(f"'{required}'", f"':(glob,icase){required}'")
    expect_red("加 `:(glob,icase)` 长格式 magic", mutated, ["magic", "深度探针"])
    # 正向对照：原脚本必须通过
    if check_filter(original, tracked):
        failures.append("  正向对照失败：原脚本竟然报红")
    else:
        print("✅ 正向对照：原脚本通过")
    if failures:
        print("❌ 自检失败：", file=sys.stderr)
        for line in failures:
            print(line, file=sys.stderr)
        return 1
    print(f"✅ 自检通过：{len(REQUIRED_PATTERNS) + 2} 个变异方向全部报红"
          f"（白名单必须含 {' / '.join(REQUIRED_PATTERNS)}，且不得用缺 `**/` 的 glob magic）")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in args:
        repo_root = args[0] if args and not args[0].startswith("-") else "."
        return self_test(repo_root)
    repo_root = args[0] if args and not args[0].startswith("-") else "."
    script_path = os.path.join(repo_root, HOOK_REL)
    if not os.path.isfile(script_path):
        print(f"❌ 找不到 {HOOK_REL} ⇒ ⇒ 守卫自己没跑起来 ⇒ ⇒ 不冒充「干净」",
              file=sys.stderr)
        return 2
    script_text = open(script_path, encoding="utf-8").read()
    problems = check_filter(script_text, tracked_files(repo_root))
    if problems:
        print("❌ 审核窗口白名单检查发现问题：", file=sys.stderr)
        for line in problems:
            print(f"   - {line}", file=sys.stderr)
        return 1
    patterns = extract_patterns(script_text)
    print(f"✅ 审核窗口白名单：{', '.join(patterns)}"
          f" ⇒ ⇒ 守卫脚本与人工判决台账**都在窗口里**")
    return 0


if __name__ == "__main__":
    sys.exit(main())
