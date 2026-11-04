#!/usr/bin/env python3
'''ID-REVIEW-1049 第十三轮：散文副本守卫的**变异集入库**（审核门 P1）。

## 为什么要有这个脚本

⇒ ⇒ 上一轮（第十二轮 b）在台账里写了一句「散文守卫 **19** 个变异体全部变红」
⇒ ⇒ ⇒ 而那套变异集**只存在于 `/tmp`** ⇒ ⇒ ⇒ ⇒ **第三方无法复现** ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ **CI 也不跑** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **那句话等于没说** ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

⇒ ⇒ **散文守卫**与 Swift 那套 harness（`Scripts/mutation/mutate.py`）**形态不同**：
⇒ ⇒ ⇒ ⇒ 散文守卫是 **Python**，它的「被测对象」是**判据本身** ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 而 Swift harness 测的是**生产域污染** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 它**做**什么

⇒ ⇒ 对散文副本守卫（`Scripts/test/test_rule_prose_copies.py`）逐条施加
⇒ ⇒ ⇒ **一处源码改动**（变异）⇒ ⇒ ⇒ ⇒ 然后跑**两种模式**：

| 模式 | 命令 | 抓什么 |
|---|---|---|
| **自检** | `… --self-test` | 判据**有没有牙齿**（用例是不是真的在跑） |
| **检查** | `… <repo-root>` | 在**真实仓库**上会不会出假阳性 / 假阴性 |

⇒ ⇒ **任一模式变红 ⇒ 那条变异被抓** ⇒ ⇒ ⇒ ⇒ 否则 ⇒ ⇒ ⇒ ⇒ **存活** ⇒ ⇒ ⇒ ⇒
⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 三条**纪律**（都来自本族踩过的坑）

1. **锚点必须唯一命中** ⇒ ⇒ 命中 **0 次** 或 **≥2 次** ⇒ ⇒ **立刻报红**
   ⇒ ⇒ ⇒ ⇒ （不是「跳过」）⇒ ⇒ ⇒ ⇒ ⇒ *「跳过」不是「失败」*（第十一轮）⇒ ⇒ ⇒
2. **必须断言改动真的落地** ⇒ ⇒ 替换后**逐字比对** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
   ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ *「变异存活」⇒ ⇒ 第一个该被怀疑的是**变异自己***（第十二轮）
3. **基线必须先证明是绿的** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
   ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ *否则「全部变红」可能只是**基线本来就红***

## ⛔ **没有「等价豁免」**（第十四轮，核验员 P2-2）

⇒ ⇒ 旧版有个自由字典 `EQUIVALENT_MUTATIONS` ⇒ ⇒ ⇒ ⇒ 加一行就能把**真存活**
⇒ ⇒ ⇒ ⇒ 洗成「等价」⇒ ⇒ ⇒ ⇒ harness 照样 exit 0 ⇒ ⇒ ⇒ ⇒ ⇒ **实测复现**：
⇒ ⇒ ⇒ ⇒ 一条真存活 + 一条「等价」登记 ⇒ ⇒ ⇒ ⇒ harness 打出「**23** 条全部被抓
⇒ ⇒ ⇒ ⇒ （等价 **2** 条）」且 **exit 0** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

⇒ ⇒ 改成「用探针语料做机器证明」之后**仍然有洞**⇒ ⇒ ⇒ ⇒ 实测那条「分隔符
⇒ ⇒ ⇒ ⇒ 白名单加一个仓库里**不出现**的字符」的变异 ⇒ ⇒ ⇒ ⇒ 语料上判定
⇒ ⇒ ⇒ ⇒ **一致** ⇒ ⇒ ⇒ ⇒ 等价证明照样成立 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

⇒ ⇒ ⇒ ⇒ *「同一把尺子」量出来的只能是那把尺子能量得到的东西* ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

⇒ ⇒ ⇒ ⇒ 现在的规则：**存活一律报红** ⇒ ⇒ ⇒ ⇒ 没有豁免入口 ⇒ ⇒ ⇒ ⇒ 等价变异
⇒ ⇒ ⇒ ⇒ （原 PG11）**移出**本清单 ⇒ ⇒ ⇒ ⇒ 它证明不了任何东西 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒

⇒ ⇒ ⇒ ⇒ `--self-test` 把这件事钉成**永久回归用例**（4 条断言）⇒ ⇒ ⇒ ⇒ ⇒ ⇒

## 它**不**做什么

* **不**改仓库里的任何文件 ⇒ ⇒ 变异只落在**临时目录**里 ⇒ ⇒ ⇒
* **不**跑 Swift 测试 / 不 build ⇒ ⇒ 它只跑 Python ⇒ ⇒ ⇒ 秒级
* **不**判断散文副本**对不对** ⇒ ⇒ 那是散文守卫自己的活

## 用法

    python3 Scripts/mutation/prose_guard_mutants.py            # 跑变异集（先跑自检）
    python3 Scripts/mutation/prose_guard_mutants.py --self-test  # 只跑自检

## 退出码

| code | meaning |
|---|---|
| **0** | 每条变异**都被抓**（且基线是绿的、且自检全过） |
| **1** | 有变异**存活** / 锚点漂移 / 基线不绿 / 自检不过 ⇒ ⇒ 绝不冒充「有牙齿」 |
| **2** | 检查自己没跑起来 ⇒ ⇒ 绝不冒充「干净」 |
'''

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# ⚠️⚠️ **不要让 Python 写 `.pyc`** ⇒ 本脚本只写临时目录，不该在仓库里留缓存。
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
GUARD_REL = os.path.join("Scripts", "test", "test_rule_prose_copies.py")
GUARD_SRC = os.path.join(REPO, GUARD_REL)

# 探针清单（**只读**）⇒ 只用于**解释**「这条变异为什么没被抓住」
# ⇒ ⇒ ⇒ ⇒ **不能**用来豁免「存活」⇒ ⇒ ⇒ ⇒ 理由见下面「为什么没有等价豁免」。
PROBE_CORPUS = os.path.join(REPO, "Scripts", "test", "prose-guard-probes.json")

# ⚠️ **锁在清单的外面**（与 `check_anchors.py`、引号语料的 sha256 锁同款）：
#   增删变异**必须**同步改这里 ⇒ ⇒ 「少了一条」不会静默。
EXPECTED_MUTATION_COUNT = 24
EXPECTED_MUTATION_IDS_SHA256 = (
    "5749066a401f1e00c461e5d4d53d98c9635458697ed7d1f31cf71f3e4af2c9cd"
)

# ⚠️⚠️⚠️ **本文件没有「等价豁免表」，也永远不允许有** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
# ⇒ ⇒ 第十四轮（核验员 P2-2）实测：旧版有个自由字典 `EQUIVALENT_MUTATIONS`
# ⇒ ⇒ ⇒ ⇒ 加一行就能把**真存活**洗成「等价」⇒ ⇒ ⇒ ⇒ harness 照样 exit 0 ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ 改成「用探针语料做机器证明」之后**仍然有洞**⇒ ⇒ ⇒ ⇒ 实测那条
# ⇒ ⇒ ⇒ ⇒ 「分隔符白名单加一个仓库里**不出现**的字符」的变异 ⇒ ⇒ ⇒ ⇒ 语料上
# ⇒ ⇒ ⇒ ⇒ 判定**一致** ⇒ ⇒ ⇒ ⇒ 等价证明照样成立 ⇒ ⇒ ⇒ ⇒ 真存活仍被洗绿 ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ *「同一把尺子」量出来的只能是那把尺子能量得到的东西* ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 现在的规则：**存活一律报红** ⇒ ⇒ ⇒ ⇒ 没有豁免入口 ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 等价变异（原 PG11）**移出**本清单 ⇒ ⇒ ⇒ ⇒ 它证明不了
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 任何东西 ⇒ ⇒ ⇒ ⇒ 留在集里只会稀释「N 条全红」这个数字 ⇒ ⇒

# (id, 说明, 锚点原文, 替换后的原文)
MUTATIONS: list[tuple[str, str, str, str]] = [
    # ── 规则标签：形态判定 ────────────────────────────────────────
    ("PG01", "加粗标签判定被摘掉",
     "bool(RULE_LABEL_BOLD.search(blob))", "False"),
    ("PG02", "结构词判定被摘掉",
     "bool(RULE_LABEL_STRUCTURE.search(blob))", "False"),
    ("PG03", "裸 `RULE` 词判标签被摘掉",
     "or bool(RULE_LABEL_RE.search(blob))", "or False"),
    ("PG04", "标签的**可见分隔符**白名单被摘掉",
     'RULE_LABEL_STRUCTURE = re.compile(\n'
     '    r"(?:真)?(?:规则|Rule)\\s*["\n'
     '    + re.escape(RULE_LABEL_SEPARATORS)\n'
     '    + r"]*\\s*(?:是|为|：|:|要求|如下|说|，|,)"\n'
     ')',
     'RULE_LABEL_STRUCTURE = re.compile(\n'
     '    r"(?:真)?(?:规则|Rule)\\s*(?:是|为|：|:|要求|如下|说|，|,)"\n'
     ')'),
    # ── 限定词 / 语料指针 ─────────────────────────────────────────
    ("PG05", "限定词被改成永不命中的值",
     'QUALIFIERS = ("词法", "lexical")', 'QUALIFIERS = ("词法ZZZ",)'),
    ("PG06", "语料文件名常量被改值",
     'CORPUS_NAME = "shell-heredoc-quote-corpus.json"',
     'CORPUS_NAME = "shell-heredoc-quote-corpus-WRONG.json"'),
    ("PG07", "语料指针判定被摘掉",
     'if CORPUS_NAME not in blob and "CORPUS_NAME" not in blob:',
     "if False:"),
    ("PG08", "台账机器数核对被伪造成恒真",
     "stated_list = SELF_COUNT_LEDGER_RE.findall(ledger)",
     "stated_list = [str(expected)]"),
    # ── 窄表述模式族 ──────────────────────────────────────────────
    ("PG09", "窄表述**模式族**整条被删",
     '        r"(?:[三五七九]|[3579]|[３５７９])"\n'
     '        r"\\s*(?:个|连|重)?\\s*(?:以上)?\\s*(?:连续)?\\s*(?:双\\s*|单\\s*)?引号"\n'
     "    ),\n", ""),
    ("PG10", "窄表述数量被放宽到「三~十」（还原 P3-2 假阳性）",
     'r"(?:[三五七九]|[3579]|[３５７９])"',
     'r"(?:[三四五六七八九十]|[3-9]|10|[３-９]|１０)"'),
    # ⇒ ⇒ **原 PG11（窄表述第二条模式被删）已移出本清单** ⇒ ⇒ ⇒ ⇒ 它是**等价
    # ⇒ ⇒ ⇒ 变异**（第二条模式 `[三3３]\s*引号` 被第一条模式族**完全覆盖**）⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ 它**证明不了任何东西** ⇒ ⇒ ⇒ ⇒ ⇒ 本文件**不设**等价豁免通道 ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 「证明不了任何东西」的变异**不该**留在「有判别力的变异集」⇒ ⇒
    # ── 豁免词表 ──────────────────────────────────────────────────
    ("PG12", "豁免词表里「窄表述」被删（逐词反证必须抓到）",
     '    "窄表述", "窄规则", "不是规则", "订正",',
     '    "窄规则", "不是规则", "订正",'),
    ("PG13", "豁免词表里 `deprecat` 被删",
     '    "作废", "deprecat",', '    "作废",'),
    ("PG14", "判据①的标记豁免恒为真",
     "        marked = (any(marker in blob for marker in NARROW_MARKERS)\n"
     "                  or (is_table_row\n"
     "                      and any(marker in prev_blob for marker in NARROW_MARKERS)))",
     "        marked = True"),
    ("PG15", "「上一块带标记」兜底作用域放宽到所有块（还原 P1-1 回归）",
     "        marked = (any(marker in blob for marker in NARROW_MARKERS)\n"
     "                  or (is_table_row\n"
     "                      and any(marker in prev_blob for marker in NARROW_MARKERS)))",
     "        marked = (any(marker in blob for marker in NARROW_MARKERS)\n"
     "                  or any(marker in prev_blob for marker in NARROW_MARKERS))"),
    # ── 块切分 / 哨兵 ─────────────────────────────────────────────
    ("PG16", "表格行不再各自成块",
     '        if stripped.startswith("|"):\n'
     '            # ⇒ ⇒ **表格行单独成块** ⇒ ⇒ 否则「整张表」会被当成**一个**\n'
     '            # ⇒ ⇒ 散文块 ⇒ ⇒ 表头 + 每一行一起被判定 ⇒ ⇒ 表头里没有的\n'
     '            # ⇒ ⇒ 词也会被算进去（实测：两张表的**表头行**被误判成\n'
     '            # ⇒ ⇒ 「在陈述规则」）⇒ ⇒ ⇒ **表格行的语义单位就是一行**。\n'
     "            if current:\n"
     "                blocks.append((start, current))\n"
     "                current = []\n"
     "            blocks.append((lineno, [line]))\n"
     "            continue\n", ""),
    ("PG17", "引用块不再与前块合并（承重变异）",
     '        if current and not nxt.startswith(">"):',
     "        if current:"),
    ("PG18", "哨兵**未配对**判定被摘掉",
     "    if stripped == EXEMPT_BEGIN and not any(",
     "    if False and not any("),
    ("PG19", "哨兵**两侧空行**判定被摘掉",
     "        if not (prev_blank and next_blank):", "        if False:"),
    ("PG20", "哨兵豁免区**数量上限**被放宽",
     "MAX_SELF_EXEMPT_REGIONS = 2", "MAX_SELF_EXEMPT_REGIONS = 99"),
    # ── 零宽归一化 ────────────────────────────────────────────────
    ("PG21", "零宽 / 格式字符归一化被摘掉",
     'blob = normalize_text("\\n".join(block))', 'blob = "\\n".join(block)'),
    # ── 接线点（`main` 里那两处）──────────────────────────────────
    ("PG22", "main() 的**扫描接线点**被摘掉",
     "    problems = scan_documents(documents)", "    problems = []"),
    ("PG23", "main() 的**台账计数接线点**被摘掉",
     "    count_problems, skipped_note = check_ledger_self_count(documents, total)",
     "    count_problems, skipped_note = [], None"),
    # ── `scan_documents` 里的接线点 ───────────────────────────────
    ("PG24", "scan_documents 不再调用 check_text",
     "        problems += check_text(rel, text, exempt_ranges)",
     "        problems += []"),
    ("PG25", "scan_documents 不再调用 check_sentinel_shape",
     "        problems += check_sentinel_shape(rel, text)", "        problems += []"),
]


def _run_guard(guard_path: str, cwd: str, args: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            [sys.executable, guard_path, *args],
            capture_output=True, text=True, timeout=180, cwd=cwd,
        )
    except subprocess.TimeoutExpired:
        return 2, "TIMEOUT"
    return proc.returncode, (proc.stdout + proc.stderr)


def _materialize(source: str, workdir: str, tag: str) -> str:
    '''把（可能已变异的）守卫源码写到**临时目录**的同名相对路径上。'''
    target_dir = os.path.join(workdir, tag, os.path.dirname(GUARD_REL))
    os.makedirs(target_dir, exist_ok=True)
    path = os.path.join(target_dir, os.path.basename(GUARD_REL))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(source)
    return path


def _load_guard(source: str, path: str) -> dict:
    """加载守卫**源码**并取它的命名空间（**只读**，不写仓库、不写 .pyc）。

    ⇒ ⇒ `__name__` 设成别的值 ⇒ ⇒ 守卫的 `main()` **不会**被触发。
    """
    namespace: dict = {"__name__": "cm_guard_probe", "__file__": path}
    exec(compile(source, path, "exec"), namespace)  # noqa: S102
    return namespace


def _corpus_diff(base_src: str, mut_src: str) -> str | None:
    """在**探针语料**上比对「变更前 / 变更后」的守卫判定。

    ⇒ ⇒ **只用于解释**（存活时告诉人「它在语料上看起来没有差异」）⇒ ⇒
    ⇒ ⇒ **不是**等价证明 ⇒ ⇒ 语料覆盖不到的差异它**看不见**⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    ⇒ ⇒ ⇒ ⇒ ⇒ *「同一把尺子」量出来的只能是那把尺子能量得到的东西* ⇒ ⇒ ⇒
    ⇒ ⇒ ⇒ ⇒ 返回 None（语料上无差异）或差异说明。
    """
    try:
        with open(PROBE_CORPUS, encoding="utf-8") as fh:
            probes = json.load(fh).get("probes") or []
    except (OSError, ValueError) as exc:
        return f"读不到探针语料（{exc}）"
    if not probes:
        return "探针语料是空的"
    base = _load_guard(base_src, GUARD_SRC)
    mut = _load_guard(mut_src, GUARD_SRC)
    for probe in probes:
        text = probe.get("text", "")
        before = base["scan_documents"]([("probe.md", text)])
        after = mut["scan_documents"]([("probe.md", text)])
        if before != after:
            return (f"探针 `{probe.get('name')}` 上判定**不同**"
                    f"（变更前 {len(before)} 条 / 变更后 {len(after)} 条）")
    return None


def _run_set(mutations, original: str, workdir: str, repo: str):
    """对每条变异跑「自检 + 检查」两种模式 ⇒ ⇒ 返回 rows。

    ⇒ ⇒ rows 每项 = (id, label, verdict, detail)；
    ⇒ ⇒ verdict ∈ {caught, 存活, ANCHOR, NO-OP, BROKEN}。
    ⇒ ⇒ ⚠️ **没有「等价」这一档** ⇒ ⇒ 存活**一律**是失败 ⇒ ⇒ ⇒⇒
    ⇒ ⇒ ⇒⇒ ⇒ 洗绿入口**不存在** ⇒ ⇒ ⇒⇒ ⇒ 核验员 P2-2 那条攻击**无处下手**
    """
    rows: list[tuple[str, str, str, str]] = []
    for mid, label, old, new in mutations:
        hits = original.count(old)
        if hits != 1:
            rows.append((mid, label, "ANCHOR", f"命中 {hits} 次（要求恰好 1 次）"))
            continue
        mutated = original.replace(old, new, 1)
        # ⇒ ⇒ ⚠️ **断言改动真的落地** ⇒ ⇒ 否则「存活」可能只是
        # ⇒ ⇒ ⇒ 「锚点没匹配上」⇒ ⇒ ⇒ ⇒ ⇒ *变异没跑起来 ≠ 守卫没牙齿*
        if mutated == original:
            rows.append((mid, label, "NO-OP", "替换后内容没变"))
            continue
        path = _materialize(mutated, workdir, mid)
        self_code, _self_out = _run_guard(path, workdir, [".", "--self-test"])
        repo_code, _repo_out = _run_guard(path, workdir, [repo])
        if self_code == 2 or repo_code == 2:
            rows.append((mid, label, "BROKEN",
                         f"守卫自己没跑起来（{self_code}/{repo_code}）"))
            continue
        if self_code != 0 or repo_code != 0:
            rows.append((mid, label, "caught",
                         f"自检 {self_code} / 检查 {repo_code}"))
            continue
        # ⇒ ⇒ **存活** ⇒ ⇒ 没有豁免通道 ⇒ ⇒ 一定是失败 ⇒ ⇒ ⇒⇒
        diff = _corpus_diff(original, mutated)
        if diff is None:
            extra = ("⚠️ 在探针语料上判定**一致** ⇒ ⇒ 它**也许**是等价变异"
                     " ⇒ ⇒ 但语料覆盖不到的差异**证明不了**⇒ ⇒ ⇒ ⇒ ⇒ "
                     "它证明不了任何东西 ⇒ ⇒ ⇒ ⇒ 请把它**移出**本清单并记账")
        else:
            extra = f"⚠️ 在探针语料上判定**不同**（{diff}）⇒ ⇒ 它**不是**等价变异"
        rows.append((mid, label, "存活",
                     "两种模式都绿 ⇒ ⇒ ⚠️ **先怀疑变异本身**"
                     "（等价？只改了行号？），**再怀疑守卫**（补用例）" + extra))
    return rows


def _summarize(rows):
    """把 rows 汇总成 (caught, survived, broken, problems) ⇒ 判定只有这一处。"""
    caught = survived = broken = 0
    for _mid, _label, verdict, _detail in rows:
        if verdict == "caught":
            caught += 1
        elif verdict == "存活":
            survived += 1
        else:
            broken += 1
    problems: list[str] = []
    if survived:
        problems.append(
            f"**{survived}** 条变异**存活**（两种模式都绿）⇒ ⇒ 散文守卫对它们"
            f"**没有牙齿** ⇒ ⇒ 要么补用例，要么**移出**本清单（证明不了任何东西的"
            f"变异不该留在「有判别力的变异集」里）⇒ ⇒ ⇒ ⇒ **没有等价豁免通道**"
        )
    if broken:
        problems.append(
            f"**{broken}** 条变异**没能判定**（锚点漂移 / 替换无效 / 守卫自己崩了）"
            f" ⇒ ⇒ 「{len(MUTATIONS)} 条全红」这句话**对不上** ⇒ ⇒ 绝不冒充通过"
        )
    return caught, survived, broken, problems


def main() -> int:
    if not os.path.exists(GUARD_SRC):
        print(f"❌ 读不到散文守卫：{GUARD_SRC}", file=sys.stderr)
        return 2
    # ⇒ ⇒ **先跑自检** ⇒ ⇒ ⇒ ⇒ 「存活一律报红」+「洗绿入口不存在」这两条
    # ⇒ ⇒ ⇒ ⇒ 每次跑 harness 都被**当场验一遍** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    if _self_test() != 0:
        return 1
    with open(GUARD_SRC, encoding="utf-8") as fh:
        original = fh.read()

    ids = sorted(entry[0] for entry in MUTATIONS)
    digest = hashlib.sha256("\n".join(ids).encode("utf-8")).hexdigest()
    problems: list[str] = []
    if len(ids) != EXPECTED_MUTATION_COUNT:
        problems.append(
            f"变异条数是 **{len(ids)}**，锁里写的是 **{EXPECTED_MUTATION_COUNT}**"
            f" ⇒ ⇒ 清单漂移 ⇒ ⇒ 增删变异**必须**同步改本文件的"
            f" EXPECTED_MUTATION_COUNT 与 EXPECTED_MUTATION_IDS_SHA256"
        )
    if digest != EXPECTED_MUTATION_IDS_SHA256:
        problems.append(
            f"变异 id 清单的 sha256 是 **{digest}**，锁里写的是 "
            f"**{EXPECTED_MUTATION_IDS_SHA256}** ⇒ ⇒ 清单漂移"
        )

    workdir = tempfile.mkdtemp(prefix="cm-prose-mutants-")
    try:
        # ── **基线**：先证明「没变异时是绿的」⇒ ⇒ 否则「全红」没有意义 ──
        base_path = _materialize(original, workdir, "baseline")
        base_self, base_self_out = _run_guard(base_path, workdir, [".", "--self-test"])
        base_repo, base_repo_out = _run_guard(base_path, workdir, [REPO])
        if base_self != 0 or base_repo != 0:
            problems.append(
                f"**基线不绿**（自检 exit {base_self} / 检查 exit {base_repo}）"
                f" ⇒ ⇒ 「全部变红」可能只是**基线本来就红** ⇒ ⇒ 先修基线"
            )
            print(base_self_out, file=sys.stderr)
            print(base_repo_out, file=sys.stderr)

        rows = _run_set(MUTATIONS, original, workdir, REPO)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print(f"{'id':<6}{'verdict':<10}{'mutation':<48}detail")
    print("-" * 110)
    for mid, label, verdict, detail in rows:
        print(f"{mid:<6}{verdict:<10}{label:<48}{detail}")

    caught, survived, broken, summary_problems = _summarize(rows)
    problems.extend(summary_problems)

    if problems:
        print("❌ 散文守卫变异集检查失败：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    print(f"✅ 散文守卫变异集：**{caught}** 条**全部被抓**（共 {len(MUTATIONS)} 条）"
          f" ⇒ ⇒ 判据**有牙齿** ⇒ ⇒ 「{caught} 条全红」这句话**可复现**"
          f"（CI 跑的就是这个脚本）")
    return 0


def _self_test() -> int:
    """自检：证明「存活**一律**报红」且「洗绿入口**结构性不存在**」。

    ⇒ ⇒ ⇒ ⇒ 四条断言（第十四轮新增 ⇒ ⇒ 核验员 P2-2 的**永久回归用例**）⇒ ⇒
    ⇒ ⇒ ⇒ ⇒ ① **真存活但不等价**的变异（分隔符白名单加一个仓库里**不出现**的
    # ⇒ ⇒ ⇒ ⇒ 字符）⇒ ⇒ 它**真存活** ⇒ ⇒ 必须判「存活」⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ② 它在**探针语料**上判定**一致** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 这就是
    # ⇒ ⇒ ⇒ ⇒ 「语料尺子不够」的**机器证据**⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ③ **真等价**的变异（原 PG11 形态）⇒ ⇒ 必须同样判「存活」⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 即「等价」**不是**豁免理由 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    # ⇒ ⇒ ⇒ ⇒ ④ 模块里**不存在**「变异 id → 理由」的映射 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 洗绿
    # ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 入口**结构性不存在** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    """
    problems: list[str] = []
    if not os.path.exists(GUARD_SRC):
        print(f"❌ 读不到散文守卫：{GUARD_SRC}", file=sys.stderr)
        return 2
    with open(GUARD_SRC, encoding="utf-8") as fh:
        original = fh.read()

    sep_line = next(
        (line for line in original.splitlines()
         if line.startswith("RULE_LABEL_SEPARATORS = ")), "")
    eq_line = next(
        (line for line in original.splitlines() if "三3３" in line), "")
    if not sep_line or not eq_line:
        print("❌ 自检找不到构造用的锚点（守卫源码结构变了？）", file=sys.stderr)
        return 2

    # ⇒ ⇒ 把 `×` **插进字符串字面量里面**（不是追加在后面 ⇒ 那会让语法崩）
    sep_idx = sep_line.rfind('"')
    sep_mutated = sep_line[:sep_idx] + "×" + sep_line[sep_idx:]

    syn_live = ("SYN1", "真存活但不等价（分隔符白名单加一个仓库里不出现的字符）",
                sep_line, sep_mutated)
    syn_equiv = ("SYN2", "真等价（原 PG11 形态：删掉被第一条模式族完全覆盖的模式）",
                 eq_line, "")

    workdir = tempfile.mkdtemp(prefix="cm-prose-mutants-self-")
    try:
        rows = _run_set([syn_live, syn_equiv], original, workdir, REPO)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    verdicts = {mid: verdict for mid, _label, verdict, _detail in rows}
    for mid, what in (("SYN1", "真存活但不等价"), ("SYN2", "真等价")):
        if verdicts.get(mid) != "存活":
            problems.append(
                f"{mid}（{what}）必须判「存活」，实测「{verdicts.get(mid)}」"
                f" ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒"
            )
    caught, survived, _broken, summary_problems = _summarize(rows)
    if survived < 2 or not summary_problems:
        problems.append(
            f"含存活的变异集**必须**整体报红 ⇒ ⇒ 实测 survived={survived} / "
            f"problems={len(summary_problems)} ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒"
        )
    if caught:
        problems.append(f"自检用的两条合成变异**不该**被判「被抓」（caught={caught}）")

    diff = _corpus_diff(original, original.replace(sep_line, sep_mutated, 1))
    if diff is not None:
        problems.append(
            f"SYN1 在探针语料上判定**不同**（{diff}）⇒ ⇒ ⇒ ⇒ ⇒ 「语料尺子不够」"
            f"这条**机器证据**不成立 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒"
        )

    for name, value in list(globals().items()):
        if (isinstance(value, dict) and value
                and all(isinstance(key, str) and re.fullmatch(r"[A-Z]+\d+", key)
                        for key in value)):
            problems.append(
                f"模块里存在「变异 id → 理由」的映射 `{name}` ⇒ ⇒ ⇒ ⇒ 它能吸收"
                f"真存活 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒"
            )

    if problems:
        print("❌ 散文守卫变异集**自检**失败：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1
    print("✅ 变异集自检：**存活一律报红** + **洗绿入口结构性不存在**（4 条断言全过）")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        sys.exit(_self_test())
    sys.exit(main())
