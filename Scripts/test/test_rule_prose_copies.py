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

# guard-exempt: begin

# 「窄表述」：一个**触发实例**的字面形状，**不是规则**。
# ⇒ ⇒ **不按字面枚举**（枚举 ⇒ 同义改写全逃逸：实测「连续 3 个双引号」
# ⇒ ⇒ 「三连双引号」两个变体**都**静默逃逸）⇒ ⇒ 改成**模式**：
# ⇒ ⇒ 「数量 + 量词 + 引号词」⇒ ⇒ 数字 / 量词换写法也逃不掉。
NARROW_PATTERNS = (
    re.compile(r"[三3]\s*(?:个|连|重)\s*(?:连续\s*)?(?:双\s*)?引号"),
    re.compile(r"[三3]\s*引号"),
)
# 「这是旧的 / 错的 / 不是规则」的标记 ⇒ 出现在同一个块里就放过。
NARROW_MARKERS = (
    "已作废", "原先", "原写", "曾经", "旧", "窄", "不是规则", "订正",
    "≠", "触发实例", "错误规则", "改为", "改回", "不再是", "移除",
    "作废", "deprecat",
)
# 「规则标签」：出现它 ⇒ 这个块**在陈述规则**（而不是在讲历史 bug）。
RULE_LABELS = ("**规则**", "**真规则**", "**规则**（")
# ⇒ ⇒ `RULE` 必须是**独立的词** ⇒ ⇒ 否则 `RULE_LABELS` / `is_rule_statement`
# ⇒ ⇒ 这些**标识符**会被当成规则陈述（实测假阳性）。
RULE_LABEL_RE = re.compile(r"\bRULE\b")
# ⇒ ⇒ 加粗只是**一种**写法 ⇒ ⇒ 未加粗的「规则：」「真规则：」「规则是」
# ⇒ ⇒ **同样是规则陈述** ⇒ ⇒ 一并认（实测三个变体全部静默逃逸）。
RULE_LABELS_WEAK = ("规则：", "规则是", "规则为", "规则说", "Rule:")
# 「词法上」这个限定词（中英皆可）。
QUALIFIERS = ("词法", "lexical")
# 判据的机器可读出处。
CORPUS_NAME = "shell-heredoc-quote-corpus.json"

SCAN_SUFFIXES = (".py", ".sh", ".yml", ".yaml", ".md")

# 守卫自己会**提到**这些词 ⇒ ⇒ 它不能检自己（否则必然报红）。
SELF_REL = os.path.join("Scripts", "test", "test_rule_prose_copies.py")
# ⇒ ⇒ **不豁免整个文件**（那样它自己的散文副本漂移就没人查了 —— 实测过）
# ⇒ ⇒ 只豁免**常量定义区**（那里必须**列举**这些短语 ⇒ 否则自证循环）
# ⇒ ⇒ ⇒ 用哨兵注释圈起来 ⇒ ⇒ 其余部分照查。
EXEMPT_BEGIN = "# guard-exempt: begin"
EXEMPT_END = "# guard-exempt: end"


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
        stripped = line.strip()
        if stripped.startswith("|"):
            # ⇒ ⇒ **表格行单独成块** ⇒ ⇒ 否则「整张表」会被当成**一个**
            # ⇒ ⇒ 散文块 ⇒ ⇒ 表头 + 每一行一起被判定 ⇒ ⇒ 表头里没有的
            # ⇒ ⇒ 词也会被算进去（实测：两张表的**表头行**被误判成
            # ⇒ ⇒ 「在陈述规则」）⇒ ⇒ ⇒ **表格行的语义单位就是一行**。
            if current:
                blocks.append((start, current))
                current = []
            blocks.append((lineno, [line]))
            continue
        if stripped:
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
# ⇒ ⇒ **强信号**：提到 heredoc ⇒ ⇒ 几乎必然是在陈述**这条**规则 ⇒ ⇒
# ⇒ ⇒ 不再要求另外两个特征词同时在（否则散文一简写就整块逃逸）。
SUBSTITUTION = re.compile(r"\$\(\s*(?:…|\.\.\.|)\s*\)")
QUOTE_WORD = re.compile(r"双引号|单引号|引号|quote", re.IGNORECASE)

# guard-exempt: end


def check_sentinel_shape(rel: str, text: str) -> list[str]:
    '''哨兵注释**两侧必须有空行** ⇒ ⇒ 否则报红。

    ⇒ ⇒ 块切分是「连续的非空行」⇒ ⇒ 哨兵行若与相邻行同属一块 ⇒ ⇒
    ⇒ ⇒ **豁免区与外部就分不开** ⇒ ⇒ 「整块在区内才豁免」会**误报**
    ⇒ ⇒ 「有交集就豁免」会**连带放过区外的违规**（实测两种都踩过）⇒ ⇒
    ⇒ ⇒ 所以这条约定必须**由机器查**，不能靠人记得。
    '''
    problems: list[str] = []
    lines = text.split("\n")
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped not in (EXEMPT_BEGIN, EXEMPT_END):
            continue
        prev_blank = (idx == 0) or not lines[idx - 1].strip()
        next_blank = (idx == len(lines) - 1) or not lines[idx + 1].strip()
        if stripped == EXEMPT_BEGIN and not any(
                later.strip() == EXEMPT_END for later in lines[idx + 1:]):
            problems.append(
                f"{rel}:{idx + 1}: 哨兵 `{EXEMPT_BEGIN}` **没有配对的** "
                f"`{EXEMPT_END}` ⇒ ⇒ 豁免区会一路延伸到文件尾 ⇒ ⇒ 报红"
            )
            continue
        if not (prev_blank and next_blank):
            problems.append(
                f"{rel}:{idx + 1}: 哨兵注释（{stripped}）**两侧必须都是空行**"
                f" ⇒ ⇒ 否则它与相邻行同属一块 ⇒ ⇒ 豁免区与外部分不开"
                f" ⇒ ⇒ 豁免要么误报、要么连带放过区外的违规 ⇒ ⇒ 补空行"
            )
    return problems


def exempt_line_ranges(text: str) -> list[tuple[int, int]]:
    '''哨兵注释圈出的**豁免行号区间**（常量定义区）⇒ ⇒ 返回 [(起, 止)]。'''
    ranges: list[tuple[int, int]] = []
    start: int | None = None
    for lineno, line in enumerate(text.split("\n"), 1):
        # ⇒ ⇒ **整行精确匹配**（不是「行内包含」）⇒ ⇒ 否则
        # ⇒ ⇒ `EXEMPT_BEGIN = "# guard-exempt: begin"` 这一行**本身**
        # ⇒ ⇒ 就被当成哨兵 ⇒ ⇒ 区间被截成两行（实测踩过）。
        if line.strip() == EXEMPT_BEGIN:
            # ⇒ ⇒ **多区间**（原来只认第一对 ⇒ ⇒ 第二对哨兵完全无效）
            if start is None:
                start = lineno
        elif line.strip() == EXEMPT_END and start is not None:
            ranges.append((start, lineno))
            start = None
    return ranges


def check_text(rel: str, text: str,
               exempt_ranges: list[tuple[int, int]] | None = None) -> list[str]:
    '''检查一份文本 ⇒ ⇒ 返回问题列表（空 = 干净）。'''
    problems: list[str] = []
    lines = text.split("\n")
    exempt_ranges = exempt_ranges or []
    prev_blob = ""
    for start, block in blocks_of(lines):
        end = start + len(block) - 1
        # ⇒ ⇒ 「**整块**都在豁免区内」才豁免 ⇒ ⇒ 「有交集即豁免」是错的：
        # ⇒ ⇒ 块切分是「连续非空行」⇒ ⇒ 哨兵注释行与**紧随其后**的内容
        # ⇒ ⇒ 往往**同属一个块** ⇒ ⇒ 用交集判定 ⇒ ⇒ **区外的违规会被
        # ⇒ ⇒ 连带放过**（实测自检当场抓到）。
        if any(lo <= start and end <= hi for lo, hi in exempt_ranges):
            continue
        blob = "\n".join(block)
        # ① 窄表述
        hit = [pat.pattern for pat in NARROW_PATTERNS if pat.search(blob)]
        # ⇒ ⇒ 「紧邻**上一块**带标记」也算放过 ⇒ ⇒ 因为**表格**这类块
        # ⇒ ⇒ **无法在块内加标记**（会破坏 markdown 渲染）⇒ ⇒ 标记通常
        # ⇒ ⇒ 写在表格**上方**的说明行里 ⇒ ⇒ 那是**上一块**。
        marked = (any(marker in blob for marker in NARROW_MARKERS)
                  or any(marker in prev_blob for marker in NARROW_MARKERS))
        if hit and not marked:
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
            or (bool(SUBSTITUTION.search(blob)) and bool(QUOTE_WORD.search(blob)))
        )
        is_rule_statement = (
            any(label in blob for label in RULE_LABELS)
            or any(label in blob for label in RULE_LABELS_WEAK)
            or bool(RULE_LABEL_RE.search(blob))
        )
        if about_this_rule and is_rule_statement:
            if not any(q in blob for q in QUALIFIERS):
                problems.append(
                    f"{rel}:{start}: 这个块在**陈述规则**，却**没有**「词法上」"
                    f" / 「lexical」这个限定词 ⇒ ⇒ 触发条件其实是"
                    f"「heredoc **词法上**在 `$( … )` 的**文本内**」"
                    f"（不是「运行时在 `$( )` 里执行」）⇒ ⇒ 漏了它 ⇒ 读者会推反"
                    f" ⇒ ⇒ 补上限定词（或指向语料）"
                )
            if CORPUS_NAME not in blob and "CORPUS_NAME" not in blob:
                problems.append(
                    f"{rel}:{start}: 这个块在**陈述规则**，却**没有**指向判据的"
                    f"机器可读出处（`{CORPUS_NAME}`）⇒ ⇒ 散文副本会**继续漂**"
                    f" ⇒ ⇒ 补上指针（散文副本的职责是「说清为什么 + 指到真相」，"
                    f"不是「复述真相」）"
                )
        # ⇒ ⇒ **检查完之后**才更新 ⇒ ⇒ 否则 `prev_blob` 会在被检查**之前**
        # ⇒ ⇒ 就变成**当前块** ⇒ ⇒ 「上一块」兜底形同虚设（实测踩过）。
        # ⇒ ⇒ **表格行不更新** ⇒ ⇒ 否则表格行的「上一块」是**上一表格行**
        # ⇒ ⇒ （`|---|---|`）⇒ ⇒ 写在表格**上方**的标记就失效了（实测踩过）。
        if not block[0].strip().startswith("|"):
            prev_blob = blob
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


# guard-exempt: begin

def self_test() -> list[str]:
    '''在**合成文本**上证明「有牙齿」⇒ ⇒ 不依赖仓库里的任何文件。

    ⚠️ **每一条判据都必须有对应用例** ⇒ ⇒ 否则「有自检」≠「自检在跑」
    ⇒ ⇒ ⇒ **本轮（第十一轮）新增的 11 个负对照探针全部收进这里** ⇒ ⇒
    ⇒ ⇒ 守卫**自己**必须复现「修复前绿 / 修复后红」。
    '''
    problems: list[str] = []

    def expect_red(name: str, text: str, keyword: str) -> None:
        found = check_text(f"synthetic:{name}", text)
        if not any(keyword in problem for problem in found):
            problems.append(
                f"自检失败：{name} **本应报红**（期望看到「{keyword}」）却仍然全绿"
                f" ⇒ ⇒ 本守卫**没有牙齿**"
            )

    def expect_green(name: str, text: str,
                     exempt: list[tuple[int, int]] | None = None) -> None:
        found = check_text(f"synthetic:{name}", text, exempt)
        if found:
            problems.append(
                f"自检失败：{name} **本应全绿**却报红 ⇒ ⇒ 判据过严"
                f" ⇒ ⇒ {found[0][:140]}"
            )

    # ── 正对照：合规块必须**不报** ──────────────────────────────
    expect_green("good", (
        "⇒ ⇒ **规则**：**词法上**在 `$( … )` 内的 heredoc，正文引号各自成对。\n"
        f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n"
    ))
    expect_green("marked_history", (
        "⇒ ⇒ 我原先把规则写成「连续三个双引号」⇒ ⇒ 那**不是规则**。\n"
    ))
    # ⇒ ⇒ 正常表述**不该**被当成窄表述（「0 引号基线」不是触发实例）
    expect_green("zero_quote", (
        "⇒ ⇒ 每条场景先跑一个 **0 引号基线**：基线若就 FAIL ⇒ 那是**样本构造错了**。\n"
    ))
    # ⇒ ⇒ **代码标识符**不该被当成规则标签（`RULE_LABELS` 含 "RULE"）
    expect_green("identifier_rule_labels", (
        "⇒ ⇒ 判据用 `RULE_LABELS` 与 `is_rule_statement` 两个变量。\n"
    ))
    # ⇒ ⇒ 指针用**变量名**引用也算数（代码里不写字面量）
    expect_green("pointer_via_variable", (
        "⇒ ⇒ **规则**：**词法上**在 `$( … )` 内的 heredoc，引号各自成对。\n"
        "⇒ ⇒ 判据见 `CORPUS_NAME`。\n"
    ))

    # ── 负对照 ①：窄表述**变体**（数字 / 量词换写法）────────────
    expect_red("narrow_digit_variant",
                "⇒ ⇒ 规则：正文里不能出现连续 3 个双引号。\n", "窄表述")
    expect_red("narrow_trio_variant",
                "⇒ ⇒ 规则：正文里不能出现三连双引号。\n", "窄表述")

    # ── 负对照 ②：**未加粗**的规则标签 ─────────────────────────
    expect_red("plain_rule_label",
                "⇒ ⇒ 规则：`$( … )` 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")
    expect_red("plain_true_rule_label",
                "⇒ ⇒ 真规则：`$( … )` 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")

    # ── 负对照 ③：规则陈述**省略某个特征词** ⇒ 仍必须被抓 ──────
    expect_red("rule_without_heredoc",
                "⇒ ⇒ **规则**：`$( … )` 里的引号必须各自成对。\n", "限定词")
    expect_red("rule_without_substitution",
                "⇒ ⇒ **规则**：heredoc 正文里的引号必须各自成对。\n", "限定词")
    expect_red("rule_without_quote_word",
                "⇒ ⇒ **规则**：heredoc 在 `$( … )` 里的正文要怎么处理。\n", "限定词")

    # ── 负对照 ④：缺「词法上」**且**缺语料指针 ─────────────────
    expect_red("rule_missing_qualifier_and_pointer",
                "⇒ ⇒ **规则**：**词法上**在 `$( … )` 内的 heredoc，引号各自成对。\n"
                .replace("**词法上**", ""), "限定词")

    # ── 哨兵机制：区内豁免、区外照查 ───────────────────────────
    sentinel_text = (
        "前置说明。\n"
        "\n"
        "# guard-exempt: begin\n"
        "\n"
        "NARROW = (\"三个双引号\",)\n"
        "\n"
        "# guard-exempt: end\n"
        "\n"
        "（哨兵区外面没有违规内容 ⇒ 期望全绿）\n"
    )
    exempt = exempt_line_ranges(sentinel_text)
    if not exempt:
        problems.append("自检失败：哨兵区间**没被识别** ⇒ ⇒ 豁免机制没跑起来")
    else:
        expect_green("sentinel_block", sentinel_text, exempt)
    outside = (
        "前置说明。\n"
        "\n"
        "# guard-exempt: begin\n"
        "\n"
        "X = 1\n"
        "\n"
        "# guard-exempt: end\n"
        "\n"
        "⇒ ⇒ 规则：正文里不能出现连续 3 个双引号。\n"
    )
    found = check_text("synthetic:sentinel_outside", outside,
                       exempt_line_ranges(outside))
    if not any("窄表述" in problem for problem in found):
        problems.append("自检失败：哨兵区**之外**的窄表述竟然全绿 ⇒ ⇒ 豁免范围过宽")

    # ── 哨兵形状：两侧无空行 ⇒ 必须报红 ───────────────────────
    bad_sentinel = (
        "前置说明。\n"
        "# guard-exempt: begin\n"
        "X = 1\n"
        "# guard-exempt: end\n"
        "\n"
        "⇒ ⇒ 规则：正文里不能出现连续 3 个双引号。\n"
    )
    found = check_sentinel_shape("synthetic:bad_sentinel", bad_sentinel)
    if not any("两侧必须都是空行" in problem for problem in found):
        problems.append(
            "自检失败：哨兵**两侧没有空行**却没报红 ⇒ ⇒ 豁免约定没人查"
            f" ⇒ ⇒ 两种豁免判定都会出问题"
        )

    # ── 「上一块带标记」兜底：表格类块（块内无法加标记）────────
    table_case = (
        "⇒ ⇒ ⚠️ **下表是触发实例**，**不是规则** ⇒ ⇒\n"
        "| 形状 | bash 3.2 |\n"
        "|---|---|\n"
        "| `a 三引号 b` | FAIL |\n"
    )
    expect_green("table_prev_block_marker", table_case)

    return problems


# guard-exempt: end

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
        exempt_ranges: list[tuple[int, int]] = []
        if not rel.endswith(SCAN_SUFFIXES):
            continue
        path = os.path.join(root, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        problems += check_sentinel_shape(rel, text)
        if rel.endswith(SELF_REL):
            exempt_ranges = exempt_line_ranges(text)
        problems += check_text(rel, text, exempt_ranges)

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
