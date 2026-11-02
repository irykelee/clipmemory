#!/usr/bin/env python3
'''ID-REVIEW-1049 第十轮 c 之五：规则的**散文副本**不许漂（V15 的收口）。

## 它守的是什么

本族的 **V15**：*散文里的规则本身就是「会漂的副本」* ⇒ ⇒ 同一处错误规则
可以同时以「**窄**」「**宽**」「**漏改**」三种形态留在仓库里 ⇒ ⇒
**改一处 ≠ 修完**。

⇒ ⇒ 这条洞已经**发作过两次**：
  ① 第九轮：守卫 docstring 改了，契约脚本注释与台账两处**没改**
     （同一条窄规则「连续三个双引号」三处并存）⇒ 本轮清掉；
  ② **第十轮独立核验员实测出 4 处**：规则的散文副本**缺「词法上」这个
     限定词** ⇒ ⇒ 其中**一处是本轮自己新写的**（`.github/workflows/ci.yml`
     的注释）⇒ ⇒ ⇒ *「我以为我改完了」被证伪*。

⇒ ⇒ **人靠不住**（同一条洞，两次都是「漏改」而不是「改错」）⇒ ⇒
⇒ ⇒ **散文副本的漂移必须由机器查**。

## 判据（两条，都在**块**级判定，不是行级）

块 = 连续的非空行（散文里一句话常被折成好几行 ⇒ ⇒ 行级判据会**漏**）。

1. **窄表述**：块里出现「连续三个双引号」/「三个连续双引号」/「遇到三引号」
   ⇒ ⇒ 那个块**必须**带一个「**这是旧的/错的/不是规则**」的标记
   （已作废 / 原先 / 旧 / 窄 / 不是规则 / 订正 / ≠ / 触发实例 / 错误规则 …）
   ⇒ ⇒ 没有标记 ⇒ **报红**（⇒ 说明有人把**触发实例**当规则写下来了）。
2. **规则陈述缺限定词**：块里出现「**规则**」/「**真规则**」/「`RULE`」
   这类**规则标签** ⇒ ⇒ 那个块**必须**
   ① 带「**词法上**」/「lexical」这个限定词（**第十轮实测的关键维度**：
      触发条件是 heredoc **词法上**在 `$( … )` 的**文本内**，**不是**
      「运行时在 `$( )` 里执行」⇒ 漏了它 ⇒ 读者会把两种情况**推反**），
   ② **指向判据的机器可读出处**
      `Scripts/test/shell-heredoc-quote-corpus.json`
   ⇒ ⇒ 缺任一项 ⇒ **报红**。

⇒ ⇒ **为什么是「指向语料」而不是「把规则抄一遍」**：抄一遍就又是一个
会漂的副本 ⇒ ⇒ ⇒ *散文副本的**职责**应当是「说清为什么 + 指到真相」，
不是「复述真相」* ⇒ ⇒ 这正是 V15 的解法。

## 它**不**做什么

* **不**判断散文里的规则**对不对** ⇒ ⇒ 那是语料守卫
  （`test_shell_heredoc_quote_rule.py`）的活 ⇒ ⇒ 本守卫只管
  「**副本有没有跟上真身**」。
* **不**扫仓库里**所有**文件 ⇒ ⇒ 只扫**可能写着这条规则**的那几类
  （`.py` / `.sh` / `.yml` / `.yaml` / `.md`），且只扫 **git 已跟踪**的文件。
* **只读**：它只读文件 ⇒ 不碰用户的偏好设置 / 钥匙串 / 剪贴板。

## 用法

    python3 Scripts/test/test_rule_prose_copies.py .            # 检查（默认）
    python3 Scripts/test/test_rule_prose_copies.py . --self-test

## 退出码

| code | meaning |
|---|---|
| **0** | 干净（散文副本都带标记、规则陈述都带限定词 + 语料指针） |
| **1** | 有漂移（窄表述无标记 / 规则陈述缺限定词或缺语料指针） |
| **2** | 守卫自己没跑起来 ⇒ 绝不冒充「干净」 |
'''

from __future__ import annotations

import os
import re
import subprocess
import sys

# 「窄表述」：一个**触发实例**的字面形状，**不是规则**。
NARROW_PHRASES = ("连续三个双引号", "三个连续双引号", "遇到三引号")
# 「这是旧的 / 错的 / 不是规则」的标记 ⇒ 出现在同一个块里就放过。
NARROW_MARKERS = (
    "已作废", "原先", "原写", "曾经", "旧", "窄", "不是规则", "订正",
    "≠", "触发实例", "错误规则", "改为", "改回", "不再是", "移除",
    "作废", "deprecat",
)
# 「规则标签」：出现它 ⇒ 这个块**在陈述规则**（而不是在讲历史 bug）。
RULE_LABELS = ("**规则**", "**真规则**", "**规则**（", "RULE")
# 「词法上」这个限定词（中英皆可）。
QUALIFIERS = ("词法", "lexical")
# 判据的机器可读出处。
CORPUS_NAME = "shell-heredoc-quote-corpus.json"

SCAN_SUFFIXES = (".py", ".sh", ".yml", ".yaml", ".md")

# 守卫自己会**提到**这些词 ⇒ ⇒ 它不能检自己（否则必然报红）。
SELF_REL = os.path.join("Scripts", "test", "test_rule_prose_copies.py")


def blocks_of(lines: list[str]) -> list[tuple[int, list[str]]]:
    '''把文本切成块（连续的非空行）⇒ ⇒ 返回 [(起始行号, [行, …])]。

    ⚠️ **引用块不切块**：散文里常有「标题行 + 空行 + `>` 引用」的写法
    ⇒ ⇒ 若按空行切，**规则本体**会被切成**另一个块** ⇒ ⇒ 标签与本体分离
    ⇒ ⇒ ⇒ 守卫就抓不到「本体缺限定词」⇒ ⇒ ⇒ *这正是第十轮核验员点名的
    `docs/skips-ledger.md:5020` 那种写法* ⇒ ⇒ **空行后若紧跟 `>` 引用行
    ⇒ ⇒ 视为同一块**。
    '''
    blocks: list[tuple[int, list[str]]] = []
    current: list[str] = []
    start = 0
    total = len(lines)
    for lineno, line in enumerate(lines, 1):
        if line.strip():
            if not current:
                start = lineno
            current.append(line)
            continue
        # 空行：若**下一个**非空行是 `>` 引用 ⇒ 不切块（引用是本块的一部分）。
        nxt = ""
        for probe in range(lineno, total):
            if lines[probe].strip():
                nxt = lines[probe].strip()
                break
        if current and not nxt.startswith(">"):
            blocks.append((start, current))
            current = []
    if current:
        blocks.append((start, current))
    return blocks


# 「这条规则」的特征词 ⇒ ⇒ 只有**同时**提到它们的块，才可能在陈述**这条**规则
#   （台账里还有别的规则 —— 生产域写入规则等 ⇒ ⇒ 标签「**规则**」会误命中）。
THIS_RULE_MARKERS = ("heredoc",)
SUBSTITUTION = re.compile(r"\$\(\s*(?:…|\.\.\.|)\s*\)")
QUOTE_WORD = re.compile(r"双引号|单引号|引号|quote", re.IGNORECASE)


def check_text(rel: str, text: str) -> list[str]:
    '''检查一份文本 ⇒ ⇒ 返回问题列表（空 = 干净）。'''
    problems: list[str] = []
    lines = text.split("\n")
    for start, block in blocks_of(lines):
        blob = "\n".join(block)
        # ① 窄表述
        hit = [phrase for phrase in NARROW_PHRASES if phrase in blob]
        if hit and not any(marker in blob for marker in NARROW_MARKERS):
            problems.append(
                f"{rel}:{start}: 块里出现「{hit[0]}」这个**窄表述**"
                f"（一个触发实例的字面形状，**不是规则**）"
                f" ⇒ ⇒ 但这个块**没有任何**「已作废 / 原先 / 窄 / 订正 …」标记"
                f" ⇒ ⇒ **报红**：要么补标记，要么把规则写准"
            )
        # ② 规则陈述缺限定词 / 缺语料指针
        #    ⇒ 必须**这条规则**的特征词都在 ⇒ ⇒ 否则台账里**别的**规则
        #    （生产域写入规则等）会被误命中。
        about_this_rule = (
            any(marker in blob for marker in THIS_RULE_MARKERS)
            and bool(SUBSTITUTION.search(blob))
            and bool(QUOTE_WORD.search(blob))
        )
        if about_this_rule and any(label in blob for label in RULE_LABELS):
            if not any(q in blob for q in QUALIFIERS):
                problems.append(
                    f"{rel}:{start}: 这个块在**陈述规则**，却**没有**「词法上」"
                    f" / 「lexical」这个限定词 ⇒ ⇒ 触发条件其实是"
                    f"「heredoc **词法上**在 `$( … )` 的**文本内**」"
                    f"（不是「运行时在 `$( )` 里执行」）⇒ ⇒ 漏了它 ⇒ 读者会推反"
                    f" ⇒ ⇒ 补上限定词（或指向语料）"
                )
            if CORPUS_NAME not in blob:
                problems.append(
                    f"{rel}:{start}: 这个块在**陈述规则**，却**没有**指向判据的"
                    f"机器可读出处（`{CORPUS_NAME}`）⇒ ⇒ 散文副本会**继续漂**"
                    f" ⇒ ⇒ 补上指针（散文副本的职责是「说清为什么 + 指到真相」，"
                    f"不是「复述真相」）"
                )
    return problems


def tracked_files(root: str) -> list[str]:
    '''git 已跟踪的文件 ⇒ ⇒ 只查**入库**的东西（CI 看的就是它们）。'''
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files"],
            capture_output=True, text=True, timeout=60,
        ).stdout
    except Exception:  # noqa: BLE001  # pylint: disable=broad-except
        out = ""
    files = [line for line in out.split("\n") if line.strip()]
    if files:
        return files
    # git 不可用 ⇒ 退化成「扫工作树里常见的几类文件」。
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", ".build", "DerivedData")]
        for name in filenames:
            if name.endswith(SCAN_SUFFIXES):
                found.append(os.path.relpath(os.path.join(dirpath, name), root))
    return sorted(found)


def self_test() -> list[str]:
    '''在**合成文本**上证明「有牙齿」⇒ ⇒ 不依赖仓库里的任何文件。'''
    problems: list[str] = []
    good = (
        "⇒ ⇒ **规则**：**词法上**在 `$( … )` 内的 heredoc，正文引号各自成对。\n"
        f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n"
    )
    if check_text("synthetic:good", good):
        problems.append("自检失败：合规的规则块**竟然报红** ⇒ 判据过严")
    narrow_no_marker = "⇒ ⇒ 规则：正文里不能出现连续三个双引号。\n"
    found = check_text("synthetic:narrow", narrow_no_marker)
    if not any("窄表述" in problem for problem in found):
        problems.append("自检失败：窄表述**无标记**却仍然全绿 ⇒ 本守卫没有牙齿")
    rule_no_qualifier = (
        "⇒ ⇒ **规则**：`$( … )` 里的 heredoc，正文引号各自成对。\n"
        f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n"
    )
    found = check_text("synthetic:noqual", rule_no_qualifier)
    if not any("限定词" in problem for problem in found):
        problems.append("自检失败：规则块**缺「词法上」**却仍然全绿 ⇒ 本守卫没有牙齿")
    rule_no_pointer = (
        "⇒ ⇒ **规则**：**词法上**在 `$( … )` 内的 heredoc，正文引号各自成对。\n"
    )
    found = check_text("synthetic:nopointer", rule_no_pointer)
    if not any("机器可读出处" in problem for problem in found):
        problems.append("自检失败：规则块**缺语料指针**却仍然全绿 ⇒ 本守卫没有牙齿")
    narrow_with_marker = (
        "⇒ ⇒ 我原先把规则写成「连续三个双引号」⇒ ⇒ 那**不是规则**。\n"
    )
    if check_text("synthetic:marked", narrow_with_marker):
        problems.append("自检失败：带标记的历史表述**竟然报红** ⇒ 判据过严")
    return problems


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    unknown = flags - {"--self-test"}
    if unknown:
        print(f"❌ 未知参数：{' '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    if len(args) != 1:
        print("用法：test_rule_prose_copies.py <repo-root> [--self-test]", file=sys.stderr)
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
        print("✅ 自检通过：窄表述无标记 / 规则块缺限定词 / 规则块缺语料指针"
              "**全部报红**；合规块与带标记的历史表述**全部不误报**"
              "（⇒ 本守卫有牙齿）")
        return 0

    problems: list[str] = []
    scanned = 0
    for rel in tracked_files(root):
        if rel.endswith(SELF_REL):
            continue
        if not rel.endswith(SCAN_SUFFIXES):
            continue
        path = os.path.join(root, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        problems += check_text(rel, text)

    if problems:
        print("❌ 规则的散文副本漂移了：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    print(f"✅ 散文副本检查通过：{scanned} 个已跟踪文件里，规则的散文副本"
          f"**都**带标记、**都**带「词法上」限定词 + 语料指针"
          f" ⇒ ⇒ 规则漂移由机器查，不再靠人记得")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
