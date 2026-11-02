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

## 判据（**三条**，都在**块**级判定，不是行级）

块 = 连续的非空行（散文里一句话常被折成好几行 ⇒ ⇒ 行级判据会**漏**）；
⇒ ⇒ **表格行各自成块**（表格行的语义单位就是一行 ⇒ ⇒ 整张表当一块 ⇒ ⇒
表头里的词会被算进每一行）。

1. **窄表述**：块里出现「**数量 + 量词 + 引号词**」这一族**字面形状**
   （`连续 3 个双引号` / `三连双引号` / `三双引号` / `三个以上双引号` /
   全角 `３个双引号` …）⇒ ⇒ 那是**触发实例**的形状、**不是规则** ⇒ ⇒
   那个块**必须**带一个「**这是旧的/错的/不是规则**」的标记
   （已作废 / 原先 / 旧规则 / 旧写法 / 窄表述 / 窄规则 / 不是规则 / 订正 /
   ≠ / 触发实例 / 错误规则 …）⇒ ⇒ 没有标记 ⇒ **报红**
   （⇒ 说明有人把**触发实例**当规则写下来了）。
   ⚠️ **只有表格行**允许把标记写在**上一块**（表格**上方**）—— 表格**块内**
   加标记会破坏 markdown 渲染 ⇒ ⇒ 那是该兜底**唯一**的正当理由 ⇒ ⇒
   ⇒ ⇒ **散文块不享受**（第十一轮核验员 P1-1：作用域写成「所有块」⇒ ⇒
   ⇒ ⇒ 中文散文里上一段出现「旧」字就把下一段整块放过 ⇒ ⇒ 方向相反的回归）。
2. **规则陈述缺限定词**：块里出现**规则标签** ⇒ ⇒ 那个块**必须**
   ① 带「**词法上**」/「lexical」这个限定词（**第十轮实测的关键维度**：
      触发条件是 heredoc **词法上**在 `$( … )` 的**文本内**，**不是**
      「运行时在 `$( )` 里执行」⇒ 漏了它 ⇒ 读者会把两种情况**推反**），
   ② **指向判据的机器可读出处**
      `Scripts/test/shell-heredoc-quote-corpus.json`
   ⇒ ⇒ 缺任一项 ⇒ **报红**。
   ⇒ ⇒ **规则标签是形态判定**（不是固定枚举）：`**规则**` / `**真规则**` /
   `**Rule**` 这类**加粗标签**，**或**「规则 / Rule」后面跟着**结构词**
   （是 / 为 / ： / : / 要求 / 如下 / 说 / ，）⇒ ⇒ ⇒ 换措辞也逃不掉
   （第十一轮核验员 P2-3 实测：固定 5 元组漏掉四种写法）。
3. **台账里的「自检断言数」必须等于机器数** ⇒ ⇒ 否则**报红** ⇒ ⇒
   ⇒ 「**陈旧数字没人管**」从这一条起被堵（第十一轮核验员 P2-1 实测：
   ⇒ ⇒ 台账写「16 个自检用例」，源码实测 18 ⇒ ⇒ 三个数字**都数不上**）。

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
* **不豁免整个自己**：守卫**自己**的散文副本也照查 ⇒ ⇒ 只豁免**哨兵圈定的
  常量定义区**（那里必须**列举**这些短语 ⇒ 否则自证循环）⇒ ⇒ 哨兵区
  **有数量上限**（多了 ⇒ 报红 ⇒ ⇒ 豁免区不能被用来**藏违规**）。

## 它的**自检**（`--self-test`）

⇒ ⇒ 自检与**检查模式走同一条路径**（`scan_documents`）⇒ ⇒ 否则「**只测方法
⇒ ⇒ 不测调用点**」⇒ ⇒ 变异掉检查模式里的接线点 ⇒ ⇒ 自检照样全绿
⇒ ⇒ ⇒ 第十一轮核验员 P2-2 实测：旧自检对 **4 条**判据无覆盖
⇒ ⇒ ⇒ ⇒ 而「**用例数由机器数**」⇒ ⇒ 台账里那个数字**由本守卫核对**。

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
    # ⇒ ⇒ **数量只列奇数**（三/五/七/九 + 3/5/7/9）⇒ ⇒ **为什么**：
    # ⇒ ⇒ 触发形状 = **奇数个**引号（偶数个是**合法样本**）⇒ ⇒ ⇒ 而
    # ⇒ ⇒ 「**10** 个双引号」这类**样本计数**表述 ⇒ ⇒ **不该**报红 ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ （核验员 P3-2 实测：拓宽成「三~十」后，「我们构造了 10 个
    # ⇒ ⇒ ⇒ 双引号的样本」被误报 ⇒ ⇒ **新增红面**）⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ **语义判据**（奇 = 触发）比「数字范围」准 ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⚠️ **显式列举、不用字符类** ⇒ ⇒ ⇒ 「10」写成 `[…十10]` 会让
    # ⇒ ⇒ ⇒ 「1」「0」被**单独**算进类 ⇒ ⇒ ⇒ 「**0 引号基线**」被误报
    # ⇒ ⇒ ⇒ ⇒ （本轮自曝 S-1）⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 而现在类里**没有数字**
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **这一类 bug 结构上不可能再发生**。
    re.compile(
        r"(?:[三五七九]|[3579]|[３５７９])"
        r"\s*(?:个|连|重)?\s*(?:以上)?\s*(?:连续)?\s*(?:双\s*|单\s*)?引号"
    ),
    re.compile(r"[三3３]\s*引号"),
)
# 「这是旧的 / 错的 / 不是规则」的标记 ⇒ 出现在同一个块里就放过。
NARROW_MARKERS = (
    "已作废", "原先", "原写", "曾经", "旧规则", "旧写法", "旧版",
    "窄表述", "窄规则", "不是规则", "订正",
    "≠", "触发实例", "错误规则", "改为", "改回", "不再是", "移除",
    "作废", "deprecat",
)
# 「规则标签」：出现它 ⇒ 这个块**在陈述规则**（而不是在讲历史 bug）。
# ⇒ ⇒ **形态判定**而不是固定枚举（核验员 P2-3 实测：「规则要求：」「规则:」
# ⇒ ⇒ 「按规则，」「规则如下：」「Rule:」五种写法在固定 5 元组下**全部逃逸**
# ⇒ ⇒ ⇒ 与本轮 V19 批判的「只抓认识的形状」同构 ⇒ ⇒ 必须形态化）。
# ⇒ ⇒ ⚠️ **加粗形式必须保留**：`**规则**` 是仓库里的**主流写法**
# ⇒ ⇒ ⇒ 判据 ①（窄表述）与判据 ②（规则陈述缺限定词）都靠它识别
# ⇒ ⇒ ⇒ 「这个块在陈述规则」⇒ ⇒ 若只认「后面带结构词」的形态 ⇒ ⇒
# ⇒ ⇒ ⇒ 连核验员自己的 fix7 负对照（`| **规则** | heredoc 里的引号各自成对 |`）
# ⇒ ⇒ ⇒ 都会**逃逸** ⇒ ⇒ ⇒ 形态化**不能**把主流写法弄丢。
RULE_LABEL_BOLD = re.compile(r"\*\*\s*(?:真)?(?:规则|Rule)\s*\*\*")
RULE_LABEL_STRUCTURE = re.compile(
    r"(?:真)?(?:规则|Rule)\s*(?:是|为|：|:|要求|如下|说|，|,)"
)
# ⇒ ⇒ `RULE` 必须是**独立的词** ⇒ ⇒ 否则 `RULE_LABELS` / `is_rule_statement`
# ⇒ ⇒ 这些**标识符**会被当成规则陈述（实测假阳性）。
RULE_LABEL_RE = re.compile(r"\bRULE\b")
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
# ⇒ ⇒ **哨兵豁免区数量上限**（守卫自己文件里）⇒ ⇒ 哨兵是**唯一**的豁免通道
# ⇒ ⇒ ⇒ 而它**可以任意新增** ⇒ ⇒ 实测：在守卫自己文件里加一个哨兵区，
# ⇒ ⇒ ⇒ 把违规散文放进去 ⇒ ⇒ 守卫 **exit 0**（违规被藏住）⇒ ⇒ 核验员
# ⇒ ⇒ ⇒ P3-2 点名 ⇒ ⇒ ⇒ ⇒ 「豁免区内容无人核对」⇒ ⇒ ⇒ ⇒ 所以给它一个
# ⇒ ⇒ ⇒ **上限** ⇒ ⇒ ⇒ 多出来的那个必须有人**明确改常量**并**在台账记账**
# ⇒ ⇒ ⇒ ⇒ （协同成本 ⇒ ⇒ 与 sha256 锁同款 ⇒ ⇒ 而非「靠自觉」）。
MAX_SELF_EXEMPT_REGIONS = 2
# 台账里**必须**写着本守卫自检的断言数 ⇒ ⇒ 否则「自检用例数」这个数字
# ⇒ ⇒ 就是**没人核对**的手写数字（核验员 P2-1 / P3-1 实测：台账写 16、
# ⇒ ⇒ 源码实测 18 ⇒ ⇒ 三个数字都数不上）⇒ ⇒ ⇒ 本行由**机器**核对。
LEDGER_REL = os.path.join("docs", "skips-ledger.md")
SELF_COUNT_LEDGER_RE = re.compile(r"散文守卫自检断言数[：:]\s*\*\*(\d+)\*\*")


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
        # ⇒ ⇒ ⚠️ **「上一块」兜底只对表格行块生效** ⇒ ⇒ 作用域写成「所有块」
        # ⇒ ⇒ ⇒ 中文散文里「旧的实现只处理单引号。」这种**上一块**会把
        # ⇒ ⇒ 下一块的违规**整块放过** ⇒ ⇒ ⇒ **方向相反的回归**
        # ⇒ ⇒ ⇒ （核验员 P1-1 实测：新版 exit 0 / 旧版 exit 1）。
        is_table_row = block[0].strip().startswith("|")
        marked = (any(marker in blob for marker in NARROW_MARKERS)
                  or (is_table_row
                      and any(marker in prev_blob for marker in NARROW_MARKERS)))
        # ⇒ ⇒ ⚠️ **判据 ① 不加「必须在陈述规则」这个前置** ⇒ ⇒ 试过 ⇒ ⇒
        # ⇒ ⇒ ⇒ 「三引号」这种**表格行**里的触发实例就**抓不到了**
        # ⇒ ⇒ ⇒ （核验员 fix6 负对照：表格行含窄表述、上一块**无**标记
        # ⇒ ⇒ ⇒ ⇒ 必须报红）⇒ ⇒ ⇒ ⇒ 而它**本来就**是「把触发实例当规则
        # ⇒ ⇒ ⇒ ⇒ 写下来了」的形态 ⇒ ⇒ ⇒ ⇒ 判据 ① 的对象是
        # ⇒ ⇒ ⇒ ⇒ 「**窄表述字面形状**出现在散文里**且没有被声明为例外**」
        # ⇒ ⇒ ⇒ ⇒ ⇒ 合法写法是**补标记**（守卫的既定工作流：「要么补标记，
        # ⇒ ⇒ ⇒ ⇒ 要么把规则写准」）⇒ ⇒ ⇒ ⇒ 而不是**放宽判据**。
        is_rule_statement = (
            bool(RULE_LABEL_BOLD.search(blob))
            or bool(RULE_LABEL_STRUCTURE.search(blob))
            or bool(RULE_LABEL_RE.search(blob))
        )
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
        if not is_table_row:
            prev_blob = blob
    return problems


def check_exempt_region_limit(rel: str, text: str) -> list[str]:
    '''哨兵豁免区**数量**超限 ⇒ ⇒ 报红（守卫自己文件里）。

    ⇒ ⇒ 为什么要有这条：哨兵是**唯一**的豁免通道 ⇒ ⇒ 而它**可以任意新增**
    ⇒ ⇒ ⇒ 实测（核验员 P3-2）：在守卫自己文件里加一个哨兵区、把违规散文
    ⇒ ⇒ ⇒ 放进去 ⇒ ⇒ 守卫 **exit 0** ⇒ ⇒ 违规被**藏住** ⇒ ⇒ ⇒ 「豁免区
    ⇒ ⇒ ⇒ 内容无人核对」⇒ ⇒ ⇒ 给了**上限** ⇒ ⇒ ⇒ 多出来的那个必须有人
    ⇒ ⇒ ⇒ **明确改常量**并在台账**记账**（协同成本）⇒ ⇒ 而非「靠自觉」。
    '''
    if not rel.endswith(SELF_REL):
        return []
    regions = exempt_line_ranges(text)
    if len(regions) <= MAX_SELF_EXEMPT_REGIONS:
        return []
    return [
        f"{rel}: 守卫自己文件里有 **{len(regions)}** 个哨兵豁免区"
        f"（上限 **{MAX_SELF_EXEMPT_REGIONS}**）⇒ ⇒ 豁免区是**唯一**的豁免通道"
        f" ⇒ ⇒ 多出来的那个可能是用来**藏违规**的 ⇒ ⇒ 报红"
        f"（若确有正当理由 ⇒ ⇒ 改本文件里的 `MAX_SELF_EXEMPT_REGIONS`"
        f" ⇒ ⇒ 并在台账**记账**）"
    ]


def scan_documents(documents: list[tuple[str, str]]) -> list[str]:
    '''扫描一批 **(相对路径, 文本)** ⇒ ⇒ 返回问题列表。

    ⚠️⚠️ **main 与 `--self-test` 必须走同一条路径** ⇒ ⇒ 否则「**只测方法
    不测调用点**」⇒ ⇒ 变异掉 main 里的**接线点** ⇒ ⇒ 自检照样全绿 ⇒ ⇒ ⇒
    自检**没有牙齿** ⇒ ⇒ ⇒ 核验员 P2-2 实测：旧自检对 **4 条判据**无覆盖
    ⇒ ⇒ ⇒ （语料指针 / 表格行独立成块 / 哨兵形状 / 守卫自查自己）⇒ ⇒ ⇒
    ⇒ ⇒ 抽出本函数就是**为了让自检覆盖到接线点**。
    '''
    problems: list[str] = []
    for rel, text in documents:
        exempt_ranges = exempt_line_ranges(text) if rel.endswith(SELF_REL) else []
        problems += check_sentinel_shape(rel, text)
        problems += check_exempt_region_limit(rel, text)
        problems += check_text(rel, text, exempt_ranges)
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

def self_test() -> tuple[list[str], dict[str, int]]:
    '''在**合成文本**上证明「有牙齿」⇒ ⇒ 不依赖仓库里的任何文件。

    ⚠️ **每一条判据都必须有对应用例** ⇒ ⇒ 否则「有自检」≠「自检在跑」
    ⇒ ⇒ ⇒ **本轮补齐了核验员 P2-2 点名的 4 条无覆盖判据**
    ⇒ ⇒ ⇒ （语料指针 / 表格行独立成块 / 哨兵形状 / 守卫自查自己）
    ⇒ ⇒ ⇒ **且全部走 `scan_documents` 这条与 main 相同的路径** ⇒ ⇒
    ⇒ ⇒ ⇒ 否则「**只测方法不测调用点**」⇒ ⇒ 变异掉 main 的接线点 ⇒ ⇒
    ⇒ ⇒ ⇒ 自检照样全绿（核验员 P2-2 实测：旧自检对 4 条判据无覆盖）。

    ⇒ ⇒ **用例数由机器数** ⇒ ⇒ 断言无论通过与否都**累加** ⇒ ⇒ ⇒
    ⇒ ⇒ ⇒ 台账里那个数字**不许手写** ⇒ ⇒ ⇒ 它由 `main --self-test`
    ⇒ ⇒ ⇒ **自报** ⇒ ⇒ ⇒ 而台账里写的那个数字**由本守卫核对**
    ⇒ ⇒ ⇒ （见 `main` ⇒ ⇒ 差一个就报红 ⇒ ⇒ 「陈旧数字」这次**有人管**）。
    '''
    problems: list[str] = []
    counts = {"red": 0, "green": 0}

    def expect_red(name: str, text: str, keyword: str,
                   rel: str | None = None) -> None:
        counts["red"] += 1
        path = rel if rel is not None else f"synthetic:{name}"
        found = scan_documents([(path, text)])
        if not any(keyword in problem for problem in found):
            problems.append(
                f"自检失败：{name} **本应报红**（期望看到「{keyword}」）却仍然全绿"
                f" ⇒ ⇒ 本守卫**没有牙齿**"
            )

    def expect_green(name: str, text: str,
                     rel: str | None = None) -> None:
        counts["green"] += 1
        path = rel if rel is not None else f"synthetic:{name}"
        found = scan_documents([(path, text)])
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
    # ⇒ ⇒ **带标记的历史表述** ⇒ ⇒ 豁免（判据 ① 的标记机制）
    expect_green("marked_history", (
        "⇒ ⇒ **规则**：我原先写成「连续三个双引号」⇒ ⇒ 那**不是规则**。\n"
    ))
    # ⇒ ⇒ 正常表述**不该**被当成窄表述（「0 引号基线」不是触发实例）
    # ⇒ ⇒ ⚠️ 这条同时钉住「数量必须**整体**匹配」⇒ ⇒ 若把「十10」写成
    # ⇒ ⇒ ⇒ 字符类 ⇒ ⇒ 「1」「0」被**单独**算进类 ⇒ ⇒ 「0 引号」被命中
    # ⇒ ⇒ ⇒ ⇒ **本轮自己引入过的假阳性**（真实仓库多报一条）。
    expect_green("zero_quote", (
        "⇒ ⇒ **规则**：每条场景先跑一个 **0 引号基线** ⇒ ⇒ 那是**样本构造错了**。\n"
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
    # ⇒ ⇒ **触发实例的描述必须自带标记**（守卫的既定工作流：「要么补标记，
    # ⇒ ⇒ ⇒ 要么把规则写准」）⇒ ⇒ ⇒ 带标记 ⇒ 放过；**不带** ⇒ 报红
    # ⇒ ⇒ ⇒ ⇒ 后者就是核验员 fix6 的负对照（表格行 ⇒ 必须红）。
    expect_green("instance_row_marked", (
        "- 「只含**三个单引号** | ok | ok」（**触发实例**）⇒ 实测在 `$( )` "
        "内是 **FAIL**。\n"
    ))
    expect_red("instance_row_unmarked", (
        "- 「只含**三个单引号** | ok | ok」⇒ 实测在 `$( )` 内是 **FAIL**。\n"
    ), "窄表述")
    # ⇒ ⇒ 表格行里的窄表述、上一块**无**标记 ⇒ 必须红（核验员 fix6 负对照）
    expect_red("table_row_narrow_no_marker",
                "⇒ ⇒ 下表列出各种形状。\n"
                "| 形状 | bash 3.2 |\n"
                "|---|---|\n"
                "| `a 三引号 b` | FAIL |\n", "窄表述")
    # ⇒ ⇒ 表格行**引用**旧表行 ⇒ ⇒ 靠**上一块**的标记豁免（表格行块内加
    # ⇒ ⇒ ⇒ 标记会破坏 markdown 渲染 ⇒ ⇒ ⇒ 标记只能写在表格**上方**）
    expect_green("table_row_citation_prev_marker", (
        "⇒ ⇒ 同一个**错误规则**可以同时以**三种形态**留在仓库里 ⇒ ⇒\n"
        "| **P2-1** | 旧表两行仍是字面假值（`:4827` 五个双引号 / "
        "`:4828` 三个单引号 仍写 `ok`，实测 FAIL） | ✅ **确认** |\n"
    ))
    # ⇒ ⇒ 「上一块带标记」兜底**只对表格行生效** ⇒ ⇒ 表格行仍可豁免
    expect_green("table_prev_block_marker", (
        "⇒ ⇒ ⚠️ **下表是触发实例**，**不是规则** ⇒ ⇒\n"
        "| 形状 | bash 3.2 |\n"
        "|---|---|\n"
        "| `a 三引号 b` | FAIL |\n"
    ))
    # ⇒ ⇒ 规则标签与特征词**分散在不同行** ⇒ ⇒ 不误报（旧版假阳性）
    expect_green("table_rule_scattered", (
        "| 项 | 说明 |\n"
        "|---|---|\n"
        "| 标签 | **规则** |\n"
        "| 范围 | heredoc 在 `$( … )` 里的正文引号 |\n"
        f"| 指针 | 判据见 `{CORPUS_NAME}` |\n"
    ))

    # ── 负对照 ①：窄表述**变体**（数字 / 量词 / 全角 换写法）────
    expect_red("narrow_digit_variant",
                "⇒ ⇒ 规则：正文里不能出现连续 3 个双引号。\n", "窄表述")
    expect_red("narrow_trio_variant",
                "⇒ ⇒ 规则：正文里不能出现三连双引号。\n", "窄表述")
    expect_red("narrow_sandwich",
                "⇒ ⇒ 规则：正文里不能出现三双引号。\n", "窄表述")
    expect_red("narrow_ge3",
                "⇒ ⇒ 规则：正文里不能出现三个以上双引号。\n", "窄表述")
    expect_red("narrow_fullwidth",
                "⇒ ⇒ 规则：正文里不能出现３个双引号。\n", "窄表述")

    # ── 负对照 ②：规则标签的**各种写法**（P2-3：固定 5 元组会漏）────
    expect_red("plain_rule_label",
                "⇒ ⇒ 规则：`$( … )` 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")
    expect_red("plain_true_rule_label",
                "⇒ ⇒ 真规则：`$( … )` 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")
    expect_red("label_require",
                "⇒ ⇒ 规则要求：heredoc 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")
    expect_red("label_ascii_colon",
                "⇒ ⇒ 规则: heredoc 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")
    expect_red("label_the_rule",
                "⇒ ⇒ 按规则，heredoc 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")
    expect_red("label_below",
                "⇒ ⇒ 规则如下：heredoc 里的引号必须各自成对。\n"
                f"⇒ ⇒ 判据见 `{CORPUS_NAME}`。\n", "限定词")
    expect_red("label_english",
                "⇒ ⇒ Rule: heredoc 里的引号必须各自成对。\n"
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

    # ── 负对照 ⑤：**缺语料指针**（P2-2 点名的无覆盖判据）────────
    expect_red("rule_missing_pointer",
                "⇒ ⇒ **规则**：**词法上**在 `$( … )` 内的 heredoc，引号各自成对。\n",
                "指针")

    # ── 负对照 ⑥：「上一块带标记」**不得**放过散文块（P1-1 回归）──
    # ⇒ ⇒ ⚠️ 前块**必须含当前豁免词表里的词**（这里是「改为」）⇒ ⇒
    # ⇒ ⇒ 否则这条用例对「作用域」这个变量**无判别力** ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ （核验员 P2-1 实测：前块写成「旧的实现…」而裸「旧」**已被移出**
    # ⇒ ⇒ ⇒ ⇒ 豁免词表 ⇒ ⇒ ⇒ ⇒ ⇒ 前块**不含任何豁免词** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ 把作用域改回「所有块」的变异体**存活** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ *⇒ ⇒ **用例的有效性**本身也要被检验*）
    expect_red("prev_block_marker_prose",
                "我们把它改为单引号处理。\n"
                "\n"
                "⇒ ⇒ 规则：正文里不能出现连续 3 个双引号。\n", "窄表述")
    # ⇒ ⇒ **裸「旧」不再豁免**（豁免词表的**收紧**必须被钉住）⇒ ⇒
    # ⇒ ⇒ 前块写「旧的实现…」⇒ ⇒ 「旧」**不在**豁免词表里 ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ 散文块**不**享受上一块兜底 ⇒ ⇒ ⇒ 且块内**没有**豁免词 ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ 必须报红（而旧的词表里裸「旧」是豁免词 ⇒ ⇒ 这条会绿）
    expect_red("narrow_bare_old_not_a_marker",
                "旧的实现只处理单引号；现在写成「连续三个双引号」就不行。\n",
                "窄表述")
    # ── 正对照：豁免词表里的词**仍然**豁免（钉住词表的另一半）────
    # ⇒ ⇒ ⚠️ 每块**只带一个**豁免词 ⇒ ⇒ 否则删掉其中一个词**照样绿**
    # ⇒ ⇒ ⇒ ⇒ ⇒ 用例就**钉不住**那个词 ⇒ ⇒ ⇒ ⇒ ⇒（核验员 P2-2 的同类）
    expect_green("marked_old_writing", (
        "⇒ ⇒ **规则**：**旧写法**是「连续三个双引号」⇒ ⇒ 就这样。\n"
    ))
    expect_green("marked_narrow_rule", (
        "⇒ ⇒ **窄规则**写成「连续三个双引号」⇒ ⇒ 就这样。\n"
    ))
    # ⇒ ⇒ 「改为」这个豁免词也**单独**钉一条（核验员 P2-2：词表任何一词
    # ⇒ ⇒ ⇒ 都可能变成**没人查**的死词）
    expect_green("marked_changed_to", (
        "⇒ ⇒ **规则**：我们把它改为「连续三个双引号」⇒ ⇒ 就这样。\n"
    ))
    # ── 正对照：**偶数个**引号是**合法样本** ⇒ ⇒ 不该报红（P3-2）────
    expect_green("even_count_sample", (
        "⇒ ⇒ 我们构造了 10 个双引号的样本用于压测 ⇒ ⇒ 那是**合法样本**。\n"
    ))

    # ── 负对照 ⑦：表格行**各自成块** ⇒ 漂移行必须被抓（P2-2）────
    # ⇒ ⇒ ⚠️ 这张表**故意**把「词法上」与语料指针放在**别的行** ⇒ ⇒
    # ⇒ ⇒ 「整表当一块」的旧判据会**全绿** ⇒ ⇒ ⇒ 本用例对那个变异**有判别力**。
    expect_red("table_row_own_block",
                "| 项 | 说明 |\n"
                "|---|---|\n"
                "| **规则** | heredoc 里的引号各自成对 |\n"
                "| 限定 | **词法上**在 `$( … )` 的文本内 |\n"
                f"| 指针 | 判据见 `{CORPUS_NAME}` |\n", "限定词")

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
    expect_green("sentinel_block", sentinel_text, rel=SELF_REL)
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
    expect_red("sentinel_outside", outside, "窄表述", rel=SELF_REL)

    # ── 哨兵形状：两侧无空行 ⇒ 必须报红 ───────────────────────
    bad_sentinel = (
        "前置说明。\n"
        "# guard-exempt: begin\n"
        "X = 1\n"
        "# guard-exempt: end\n"
        "\n"
        "⇒ ⇒ 规则：正文里不能出现连续 3 个双引号。\n"
    )
    expect_red("sentinel_bad_shape", bad_sentinel, "两侧必须都是空行",
               rel=SELF_REL)

    # ── 哨兵区**数量上限**（P3-2：豁免区可被用来藏违规）──────────
    overflow = (
        "前置说明。\n\n# guard-exempt: begin\n\nX = 1\n\n"
        "# guard-exempt: end\n\n中间说明。\n\n# guard-exempt: begin\n\n"
        "Y = 2\n\n# guard-exempt: end\n\n末尾说明。\n\n"
        "# guard-exempt: begin\n\nZ = 3\n\n# guard-exempt: end\n\n"
        "（三个豁免区 ⇒ 超过上限 ⇒ 必须报红）\n"
    )
    expect_red("self_exempt_region_overflow", overflow, "哨兵豁免区",
               rel=SELF_REL)

    # ── 守卫**自查自己**（P2-2：无覆盖判据）────────────────────
    expect_red("self_scan_violation",
                "## 它**不**做什么\n"
                "\n"
                "⇒ ⇒ 规则：正文里不能出现连续 3 个双引号。\n",
                "窄表述", rel=SELF_REL)

    return problems, counts


# guard-exempt: end

def check_ledger_self_count(documents: list[tuple[str, str]],
                            expected: int) -> tuple[list[str], str | None]:
    '''台账里写的「散文守卫自检断言数」必须**等于**机器数 ⇒ ⇒ 否则报红。

    ⇒ ⇒ 为什么要有这条：台账里的数字是**手工维护**的 ⇒ ⇒ 加一条自检用例
    ⇒ ⇒ ⇒ 就得改一次 ⇒ ⇒ **忘了改**就是「陈旧的数字」⇒ ⇒ 而守卫自己是绿的
    ⇒ ⇒ ⇒ 没有任何东西会报红 ⇒ ⇒ ⇒ 核验员 P2-1 / P3-1 实测：台账写
    ⇒ ⇒ ⇒ 「**16** 个自检用例」，源码实测 **18** ⇒ ⇒ 三个数字**都数不上**
    ⇒ ⇒ ⇒ ⇒ 与本轮 V19 主题（「没找到 ≠ 没问题」「陈旧数字没人管」）同族
    ⇒ ⇒ ⇒ ⇒ 本条把那个数字变成**机器核对**的：差一个就红。

    ⇒ ⇒ **台账不在扫描范围里怎么办** ⇒ ⇒ ⇒ 不报红，但**明确说「没核对」**
    ⇒ ⇒ ⇒ （返回第二个值 ⇒ 调用方打印 ⚠️）⇒ ⇒ ⇒ 因为「台账**存在**」
    ⇒ ⇒ ⇒ 由**指针守卫**负责（它的 `require_counts_table=True` ⇒ ⇒
    ⇒ ⇒ ⇒ 表被改名 / 删除 ⇒ ⇒ 它就报红）⇒ ⇒ ⇒ 这里再报一次只是
    ⇒ ⇒ ⇒ ⇒ **重复扣分**；而**在合成探针仓库里**（只有 probe.md）⇒ ⇒
    ⇒ ⇒ ⇒ 本守卫**本来就不该**要求台账存在 ⇒ ⇒ ⇒ ⇒ 报红 = 假阳性。
    '''
    problems: list[str] = []
    ledger = None
    for rel, text in documents:
        if rel == LEDGER_REL:
            ledger = text
            break
    if ledger is None:
        return [], (
            f"⚠️ 扫描范围里**没有** {LEDGER_REL} ⇒ ⇒ 「自检断言数」这次"
            f"**没有核对**（台账的**存在性**由指针守卫负责）⇒ ⇒ 不假装检查过"
        )
    stated_list = SELF_COUNT_LEDGER_RE.findall(ledger)
    if not stated_list:
        return [f"{LEDGER_REL}: 台账里**找不到**「散文守卫自检断言数」⇒ ⇒ "
                f"那个数字是**手写**的 ⇒ ⇒ 没人核对 ⇒ ⇒ 报红"
                f"（补一行：散文守卫自检断言数：**{expected}**）"], None
    drifted = [value for value in stated_list if int(value) != expected]
    if drifted:
        return [f"{LEDGER_REL}: 台账里写的「散文守卫自检断言数」= "
                f"**{drifted[0]}**，而**机器数**是 **{expected}** ⇒ ⇒ "
                f"数字**已经漂了** ⇒ ⇒ 刷成实测值（否则下一个读它的人"
                f"会读到假数字）"], None
    return [], None


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
        problems, counts = self_test()
        if problems:
            print("❌ 自检失败：", file=sys.stderr)
            for problem in problems:
                print("   - " + problem, file=sys.stderr)
            return 1
        total = counts["red"] + counts["green"]
        print(f"✅ 自检通过：**{total}** 个断言"
              f"（{counts['red']} 负对照 + {counts['green']} 正对照）"
              f" 全部符合预期 ⇒ ⇒ 本守卫**有牙齿**"
              f"（用例数由**机器数**；台账里那个数字由本守卫**核对**）")
        return 0

    documents: list[tuple[str, str]] = []
    scanned = 0
    for rel in tracked_files(root):
        if not rel.endswith(SCAN_SUFFIXES):
            continue
        path = os.path.join(root, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        documents.append((rel, text))

    # ⇒ ⇒ **与 `--self-test` 走同一条路径**（`scan_documents`）⇒ ⇒
    # ⇒ ⇒ ⇒ 否则「只测方法不测调用点」⇒ ⇒ 变异掉这里的接线点 ⇒ ⇒
    # ⇒ ⇒ ⇒ 自检照样全绿（核验员 P2-2 实测：旧自检对 4 条判据无覆盖）。
    problems = scan_documents(documents)

    # ⇒ ⇒ **自检也要在检查模式下跑一遍** ⇒ ⇒ 否则「自检坏了但检查模式
    # ⇒ ⇒ ⇒ 照样是绿的」⇒ ⇒ ⇒ 而且台账里那个数字**没人数** ⇒ ⇒ ⇒ 同族。
    self_problems, counts = self_test()
    problems += [f"自检失败：{problem}" for problem in self_problems]
    total = counts["red"] + counts["green"]
    count_problems, skipped_note = check_ledger_self_count(documents, total)
    problems += count_problems
    if skipped_note:
        print(skipped_note, file=sys.stderr)

    if problems:
        print("❌ 规则的散文副本漂移了：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    print(f"✅ 散文副本检查通过：{scanned} 个已跟踪文件里，规则的散文副本"
          f"**都**带标记、**都**带「词法上」限定词 + 语料指针"
          f" ⇒ ⇒ 规则漂移由机器查，不再靠人记得"
          f"（自检 **{total}** 个断言全过；台账里那个数字**已核对**）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
