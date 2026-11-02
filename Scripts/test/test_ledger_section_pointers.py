#!/usr/bin/env python3
'''ID-REVIEW-1049 第十轮：台账**内部指针**的有效性守卫。

## 它守的是什么

台账 `docs/skips-ledger.md` 里到处是「见 §50.22.4」「见 §50.20.2」这类
**节指针**。⇒ ⇒ 这些指针是**数据的一部分**：

* 指向**不存在**的节 ⇒ 读者**跳不到**目标 ⇒ 那一段论证就**断链**了
  ⇒ ⇒ 而且它**看起来完全正常**（一行文字而已）⇒ ⇒
  这正是本族的 **V14**（「指向」与**样本**不同源 ⇒ 真测量变成假结论）
  在**指针**上的化身。
* 指向**存在**但**标题对不上**的节 ⇒ 同上 ⇒ 而且更难发现（编号对、内容偏）。

⇒ ⇒ **审核门反复提的正是这件事**（2026-11-02 第十轮 P1：
「确保在后续文档更新中，该引用不会因为章节编号变动而失效」）
⇒ ⇒ 但**散文提醒**挡不住编号漂移 ⇒ ⇒ 所以要**机械检查**。

## 判据

1. 扫出台账里所有 `§` **后接整块 token** 的位置 ⇒ ⇒ 判「它是不是节指针」。
2. **不是**节指针的（`§N.M` 这种**占位符**、`§ID-REVIEW-1037` 这种**案例编号**）
   ⇒ 跳过（它们不以数字开头）。
3. 是节指针、但**形状不认识**的 ⇒ ⇒ **报红** ⇒ ⇒ 不**装作检查过**。
4. 形状认识的 ⇒ 台账里**必须存在**对应的**节标题**
   （`#### 50.N.M …` 或 `## 50.N …`）⇒ ⇒ 指向不存在的节 ⇒ **报红**。
5. 指针**必须唯一**：同一个**完整编号**在台账里**只能有一个**节标题
   ⇒ ⇒ 否则「指向」是**歧义**的 ⇒ 读者不知道跳哪 ⇒ **报红**。
6. 「**节号-列表项号**」形态（`§44.7-1`）⇒ ⇒ 指的是**该节内部的编号列表项**
   ⇒ ⇒ 判据：该节存在 **且** 它下面**真的有**第 N 项。
7. 每个被指向的节**必须真的被指向** ⇒ ⇒ 「写了但没人引」不是错误
   （台账允许有孤立的节）⇒ ⇒ **不报**。⚠️ 只报**坏指针**，不报**孤儿节**
   ⇒ ⇒ 避免守卫变成「逼你删内容」。
8. **重复节编号**本身就是问题（不要求「有指针指向它」）⇒ ⇒ 报红。

## ⚠️ 判据陷阱（本守卫第一版踩过 ⇒ 写在这里免得再踩）

1. **层级前缀不算歧义** ⇒ `### 50.12` 与 `#### 50.12.5b` **不是**歧义 ——
   指针 `§50.12` 指的是**那个层级**的节，`§50.12.5b` 指的是**子节** ⇒ ⇒
   判据必须比**完整编号**，**不是**比前缀。
2. **跨文件引用不是本台账的指针** ⇒ 「`docs/SWIFT6_MIGRATION.md` §8」里的
   `§8` 指的是**另一个文件**的节 ⇒ ⇒ 本台账里当然找不到 ⇒ ⇒
   **误报** ⇒ ⇒ 必须排除「`§` 前面紧邻着另一个文件名/路径」的引用。
3. **`## 42.` 与 `### 42.4b` 不算歧义** ⇒ 同一条指针 `§42` 指的是**顶层节**
   ⇒ ⇒ 编号**完全相同**才算歧义。
4. **正则只抓「认识的形状」⇒ ⇒ 静默漏检** ⇒ ⇒ 第十一轮实测：台账里有
   **12** 处 `§44.7-N` 形态（节内列表项）**根本没被检查** ⇒ ⇒
   ⇒ 改成「**抓整块 token**」+「**不认识就报红**」⇒ ⇒ 形状再变也会**举手**。
5. **列表项的归属必须跟最近的标题走** ⇒ ⇒ 第十一轮实测：非编号标题
   （`#### 50.22.8 追加：…`）下面的列表项**曾经**被算到**上一个**编号节头上
   ⇒ ⇒ §38.8 因此**多认**了 4/5/6/7 四项 ⇒ ⇒ `§38.8-7` 会被**判成有效**
   ⇒ ⇒ 修正：遇到**非编号标题**就把归属**清空**。
6. **「跳过」必须是**可见**的** ⇒ ⇒ 第十一轮实测：有 **7** 处 `§8`（指向
   `SWIFT6_MIGRATION.md`）因为「族 8 在本台账不存在」而被**放过** ⇒ ⇒
   **结论对、机制错**（不是被「跨文件判定」救下的）⇒ ⇒ 现在**逐条列出**。

## 用法

    python3 Scripts/test/test_ledger_section_pointers.py .            # 比对（默认）
    python3 Scripts/test/test_ledger_section_pointers.py . --self-test

`--self-test` 在**合成台账**上注入 7 种坏指针，断言每一种**都报红**，
并断言占位符 / 案例编号 / 尾随标点**都不误报** ⇒ ⇒ 证明「有牙齿」
⇒ ⇒ **不依赖仓库里任何文件被改动** ⇒ ⇒ 可以**每次 CI 都跑**。

⚠️ **本守卫曾经「有自检但从不执行」** ⇒ ⇒ 兄弟守卫
`test_shell_heredoc_quote_rule.py --self-test` 就是这样：自检能力写了，
**CI 从未调用** ⇒ ⇒ 「存在」≠「有牙」⇒ ⇒ 现在两个自检都接进 CI。

## 它**不**做什么

* **不**校验台账里的**数字**（那是 §50.22.3 那条线的事：判据的机器可读出处）。
* **不**校验散文内容的**对错** ⇒ ⇒ **散文规则仍可能写错**
  （那是 V15 的残余，§50.22.7 第 3 条已如实记录）。
* **只读**：它只读台账这一个文件 ⇒ 对用户环境**零副作用**。

## 退出码

| code | meaning |
|---|---|
| **0** | 干净（所有指针都指向真实且唯一的节） |
| **1** | 有坏指针（指向不存在 / 指向歧义 / 形状不认识） |
| **2** | 守卫自己没跑起来（用法错误 / 台账读不到）⇒ 绝不冒充「干净」 |
'''

from __future__ import annotations

import os
import re
import sys

LEDGER_REL = os.path.join("docs", "skips-ledger.md")

# 「§」后面**整块 token**（一直吃到分隔符为止）⇒ ⇒ 而不是「只抓认识的形状」。
# ⚠️⚠️ **为什么不能只抓认识的形状**：正则不认识 ⇒ **静默漏检**
#    （漏掉的指针**永远不会被检查**）⇒ ⇒ 这是本族最危险的形状之一。
#    ⇒ ⇒ 第十一轮的修法：**抓整块** + **不认识就报红** ⇒ ⇒
#    ⇒ 形状再变（多字母后缀、新分隔符…）也会**举手**，而不是**装作没看见**。
#    （实测：台账里有 **12** 处 `§44.7-N` 形态**根本没被检查**。）
TOKEN = re.compile(r"§\s*([0-9A-Za-z][0-9A-Za-z.\-]*)")
# 「认识的」节号形状：数字 + 可选小数链 + 可选**单个**字母后缀 + 可选 `-列表项号`。
# ⚠️ 单个字母：实测台账里的节号后缀**最多一个字母**（`N.Nb` / `N.Nc` / `N.N.Nb`）
#    ⇒ ⇒ 出现两个字母（如 `50.22.6ab`）就是**新形状** ⇒ ⇒ 会被**报红**（而不是
#    ⇒ ⇒ 被截成 `50.22.6a` 去查一个**别的**节 ⇒ 静默错判）。
KNOWN_NUMBER = re.compile(r"\d+(?:\.\d+)*[a-z]?(?:-\d+)?")
# 节标题：`#### 50.22.4 标题` 或 `## 50.20 标题` ⇒ 同样要吃字母后缀。
# ⚠️ 层级要覆盖 **2–5** 级：台账里确实有 `##### 39.7.1`（五级）⇒
#    只认 2–4 级会把它当「不存在的节」⇒ **误报**。
# ⚠️ 字母后缀吃**任意个**（`[a-z]*`）⇒ 与 `KNOWN_NUMBER` 的单个字母**故意不一致**：
#    标题侧**多认**（注册成更长的编号）⇒ 指针侧**不认识** ⇒ ⇒ 报红
#    ⇒ ⇒ 两者**不会**在「截断后恰好撞上」时静默通过。
HEADING = re.compile(r"^#{2,5}\s+(\d+(?:\.\d+)*[a-z]*)\b")
# **任意**标题（用来判定「列表项归属该清空」）。
ANY_HEADING = re.compile(r"^#{1,6}\s")
# ⚠️ **跨文件引用**：`docs/SWIFT6_MIGRATION.md` §8 ⇒ 那个 `§8` 不属于本台账。
#   判据：`§` 前面**紧邻**着「一个路径样式的 token」⇒ 排除。
#   （实测第一版没有这条 ⇒ 把 8 处**别的文件**的引用误报成断链。）
CROSS_FILE = re.compile(r"[\w./-]+\.(?:md|swift|sh|py|yml|yaml|json|txt)\`?\s*§")

MAX_REPORTED_SKIPS = 20


def check_ledger(lines: list[str]) -> tuple[list[str], int, list[tuple[int, str, str]], int]:
    '''核心判据（**纯函数**）⇒ ⇒ `--self-test` 可以直接调用它。

    返回 (问题列表, 已检查指针数, 被跳过的指针列表, 节标题去重数)。
    '''
    # 1. 收集节标题（编号 → 出现次数 + 行号）
    headings: dict[str, list[int]] = {}
    for lineno, line in enumerate(lines, 1):
        match = HEADING.match(line)
        if match:
            headings.setdefault(match.group(1), []).append(lineno)
    # **族根**集合：`38` 族（`### 38.1` …）⇒ 指针 `§38` 有效。
    family_numbers = {n.split(".")[0] for n in headings}

    # 2. **节内编号列表项**：台账里 `### 44.7 …` 下面就是 `1.` / `2.` / `3.` …
    #    ⇒ 指针 `§44.7-1` 指的是**那个列表项**（不是节标题）⇒ ⇒ 要单独认。
    #    ⇒ 收集「每个节标题下面出现的 `N.` 列表项编号」。
    #    ⚠️⚠️ **归属必须跟最近的标题走**：遇到**非编号标题**（`#### 50.22.8 追加：…`）
    #    ⇒ 必须把归属**清空** ⇒ ⇒ 否则那些列表项会被算到**上一个**编号节头上
    #    ⇒ ⇒ §38.8 因此**多认**了 4/5/6/7 ⇒ ⇒ `§38.8-7` 会被**判成有效**（假阴性）。
    list_items: dict[str, set[int]] = {}
    current: str | None = None
    for line in lines:
        heading_match = HEADING.match(line)
        if heading_match:
            current = heading_match.group(1)
            list_items.setdefault(current, set())
            continue
        if ANY_HEADING.match(line):
            # **非编号标题** ⇒ 它下面的列表项**不属于任何编号节** ⇒ 归属清空。
            current = None
            continue
        if current is None:
            continue
        item = re.match(r"^\s*(?:~~)?(\d+)\.\s", line)
        if item:
            list_items[current].add(int(item.group(1)))

    problems: list[str] = []
    checked = 0
    skipped: list[tuple[int, str, str]] = []
    seen: set[tuple[str, int]] = set()

    # ⚠️ **重复编号本身就是问题**（不要求「有指针指向它」）——
    #   读者按编号跳转时**无法确定跳哪个** ⇒ 即使此刻没人引用它，
    #   它也是一颗**定时炸弹**（下一个人加一个 `§50.22.5` 指针就会踩到）。
    #   ⇒ ⇒ 先于指针检查报出来。
    for number, locations in sorted(headings.items()):
        if len(locations) > 1:
            problems.append(
                f"{LEDGER_REL}: 节编号 {number} 出现**{len(locations)} 次**"
                f"（行 {', '.join(str(x) for x in locations)}）⇒ 编号**不唯一**"
                f" ⇒ 按编号跳转无法确定跳到哪"
            )
    for lineno, line in enumerate(lines, 1):
        if HEADING.match(line):
            # 标题行里的编号是**定义**，不是引用 ⇒ 跳过
            continue
        # ⚠️ **跨文件引用**要排除：`docs/X.md` §8 ⇒ 那个 `§8` 属于别的文件。
        #   做法：把「路径样式 token + §」的那些位置**挖空**，剩下的才是本台账指针。
        probe = CROSS_FILE.sub(lambda m: " " * len(m.group(0)), line)
        for match in TOKEN.finditer(probe):
            raw = match.group(1)
            # 尾部可能粘着句号 / 连字符（`§44.` / `§44.7-`）⇒ 去掉再判形状。
            number = raw.rstrip(".-")
            if not number:
                continue
            if not number[0].isdigit():
                # **不是节指针**：`§N.M`（占位符）/ `§ID-REVIEW-1037`（案例编号）
                # ⇒ ⇒ 跳过（**不**报红：它们本来就不是指针 ⇒ 报红是误报）。
                continue
            if not KNOWN_NUMBER.fullmatch(number):
                # ⚠️⚠️ **形状不认识** ⇒ ⇒ **报红**，不**装作检查过**。
                #   （实测：这一条抓到过「`§44.7-N` 形态根本没被检查」的静默漏检。）
                problems.append(
                    f"{LEDGER_REL}:{lineno}: 指针 §{raw} 的**形态无法识别**"
                    f" ⇒ 守卫**不知道该怎么查它** ⇒ 不假装检查过"
                    f"（认识的形状：数字 + 小数链 + 可选单字母后缀 + 可选 `-列表项号`）"
                )
                continue
            if (number, lineno) in seen:
                continue
            seen.add((number, lineno))
            # ⚠️ **层级前缀不算歧义** ⇒ 判据必须比**完整编号**。
            #   （`### 50.12` 与 `#### 50.12.5b` 是两个不同的节，不是歧义。）
            locations = headings.get(number)
            if locations is None:
                # ⚠️ **「节号-列表项号」形态**（`§44.7-1`）⇒ 指的是**节内部**的
                #   编号列表项 ⇒ 判据：该节存在 **且** 它下面真的有第 N 项。
                if "-" in number:
                    head, _, item_text = number.rpartition("-")
                    if head in headings:
                        items = list_items.get(head, set())
                        if item_text.isdigit() and int(item_text) in items:
                            checked += 1
                            continue
                        problems.append(
                            f"{LEDGER_REL}:{lineno}: 指针 §{number} 指向 §{head} "
                            f"的**第 {item_text} 项**，但该节下面没有这一项"
                            f"（该节有：{sorted(items) or '（无编号列表项）'}）"
                            f" ⇒ 读者跳不到 ⇒ 断链"
                        )
                        continue
                    problems.append(
                        f"{LEDGER_REL}:{lineno}: 指针 §{number} 指向**不存在的节**"
                        f" ⇒ 读者跳不到 ⇒ 那一段论证断链"
                    )
                    continue
                # ⚠️ **族根**：台账的顶层节常常写成
                #   `## ID-REVIEW-1038（…）` ⇒ 没有 `## 38.` 这种标题，
                #   但它的子节是 `### 38.1` ⇒ ⇒ 指针 `§38` 指的是**这一族**。
                #   ⇒ 判据：**不含 `.` 的**指针可以指向族根（族里有子节即可）。
                #   ⚠️⚠️ **含 `.` 的指针必须精确存在** —— 否则 `§50.99` 会被
                #   「50 族里有 50.1…50.22」判成「族根有效」而**放过**
                #   （实测踩过：守卫在真实断链上**报绿** ⇒ 假绿 ⇒ 整个守卫无意义）。
                family = number.split(".")[0]
                family_titles = [n for n in headings if n.split(".")[0] == family]
                if "." not in number and family_titles:
                    checked += 1
                    continue
                # 该编号可能压根不是本台账的节号（如 §8 来自别的文件）⇒ 跳过。
                # ⚠️ 但如果本台账里**有同族**（如 39.x 存在而 39.7.1 不存在）
                #   ⇒ 那就是**真断链**（子节号写错了）⇒ 必须报。
                if family in family_numbers:
                    problems.append(
                        f"{LEDGER_REL}:{lineno}: 指针 §{number} 指向**不存在的节**"
                        f" ⇒ 读者跳不到 ⇒ 那一段论证断链"
                    )
                else:
                    skipped.append((lineno, number, line.strip()[:70]))
            elif len(locations) > 1:
                problems.append(
                    f"{LEDGER_REL}:{lineno}: 指针 §{number} 指向**{len(locations)} 个**"
                    f"节标题（行 {', '.join(str(x) for x in locations)}）⇒ 指向**歧义**"
                )
            checked += 1

    return problems, checked, skipped, len(headings)


# ---------------------------------------------------------------------------
# `--self-test`：在**合成台账**上证明「有牙齿」⇒ ⇒ 不依赖仓库里的任何文件。
# ---------------------------------------------------------------------------

SYNTHETIC_LEDGER = """\
# 合成台账（`--self-test` 用）⇒ ⇒ 不依赖仓库里的任何文件。

### 38.8 标题

1. 这一项**属于** §38.8。

#### 追加：非编号标题（下面那一项**不属于**任何编号节）

2. 这一项属于**非编号**标题 ⇒ ⇒ 不该被算进 §38.8。

### 44.7 标题

1. 第一项。
2. 第二项。

### 50.22 标题

#### 50.22.4 子节

有效指针：§50.22.4、§50.22、§38.8-1、§44.7-1、§44.7-2。
不是指针：§N.M（占位符）、§ID-REVIEW-1037（案例编号）。
尾随标点：§44.、§44.7-。
"""

# (名称, 台账文本, 期望报出的**关键词**或 None=必须保持干净)
SELF_TEST_CASES: list[tuple[str, str, str | None]] = [
    ("不存在的节号",
     SYNTHETIC_LEDGER.replace("§50.22.4、", "§50.99、", 1),
     "指向**不存在的节**"),
    ("子节号写错",
     SYNTHETIC_LEDGER.replace("§50.22.4、", "§50.22.55、", 1),
     "指向**不存在的节**"),
    ("重复节标题",
     SYNTHETIC_LEDGER + "\n### 44.7 复制品\n",
     "编号**不唯一**"),
    ("节内列表项不存在",
     SYNTHETIC_LEDGER.replace("§44.7-1", "§44.7-99", 1),
     "但该节下面没有这一项"),
    ("节内列表项的节不存在",
     SYNTHETIC_LEDGER.replace("§44.7-1", "§44.99-1", 1),
     "指向**不存在的节**"),
    ("指针形状不认识",
     SYNTHETIC_LEDGER.replace("§50.22.4、", "§50.22.6ab、", 1),
     "**形态无法识别**"),
    ("列表项归属串位（被算到上一个编号节）",
     SYNTHETIC_LEDGER.replace("§38.8-1", "§38.8-2", 1),
     "但该节下面没有这一项"),
]


def self_test() -> list[str]:
    '''在合成台账上注入坏指针 ⇒ 断言**每一类都报红** ⇒ 证明「有牙齿」。'''
    problems: list[str] = []
    base_problems, base_checked, _, _ = check_ledger(SYNTHETIC_LEDGER.split("\n"))
    if base_problems:
        problems.append(
            "自检失败：合成台账**本应干净**，却报出 "
            f"{len(base_problems)} 处问题 ⇒ 判据本身有问题："
            + base_problems[0]
        )
    if base_checked <= 0:
        problems.append(
            "自检失败：合成台账里**一个指针都没检查**（checked=0）"
            " ⇒ 本守卫**什么都没做**却报绿 ⇒ 不算通过"
        )
    for name, text, expected in SELF_TEST_CASES:
        found, _checked, _, _ = check_ledger(text.split("\n"))
        if not found:
            problems.append(
                f"自检失败：注入「{name}」之后**仍然全绿** ⇒ 本守卫**没有牙齿**"
            )
            continue
        if expected and not any(expected in problem for problem in found):
            problems.append(
                f"自检失败：注入「{name}」后报了 {len(found)} 处问题，"
                f"但**没有一条**包含「{expected}」⇒ 报的不是**这一类**问题"
                f" ⇒ 判据与自检对不上：{found[0]}"
            )
    return problems


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    unknown = flags - {"--self-test"}
    if unknown:
        print(f"❌ 未知参数：{' '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    if len(args) != 1:
        print(
            "用法：test_ledger_section_pointers.py <repo-root> [--self-test]",
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
        print(f"✅ 自检通过：{len(SELF_TEST_CASES)} 类坏指针**全部报红**；"
              f"占位符 / 案例编号 / 尾随标点**全部不误报**"
              f"（⇒ 本守卫有牙齿）")
        return 0

    path = os.path.join(root, LEDGER_REL)
    if not os.path.exists(path):
        print(f"❌ 台账读不到：{LEDGER_REL}", file=sys.stderr)
        return 2
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    problems, checked, skipped, heading_count = check_ledger(lines)

    if problems:
        print("❌ 台账指针检查发现断链：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    print(f"✅ 台账 {LEDGER_REL}：{checked} 处节指针**全部**指向真实且唯一的节"
          f"（共 {heading_count} 个节标题；{len(skipped)} 处指向**别的编号体系**"
          f" ⇒ 已跳过）")
    if skipped:
        # ⚠️ **跳过项必须可见** ⇒ ⇒ 否则「跳过」就是**看不见的放行**。
        print("   ⓘ 已跳过的指针（**不在本台账、也不属于任何本台账族** ⇒ 判为别的编号体系）：")
        for lineno, number, context in skipped[:MAX_REPORTED_SKIPS]:
            print(f"      - L{lineno}: §{number}  |  {context}")
        if len(skipped) > MAX_REPORTED_SKIPS:
            print(f"      … 另有 {len(skipped) - MAX_REPORTED_SKIPS} 处未逐条列出")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
