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

1. 扫出台账里所有 `§50.N` 与 `§50.N.M` 形式的**节指针**。
2. 台账里**必须存在**对应的**节标题**（`#### 50.N.M …` 或 `## 50.N …`）。
   ⇒ 指向不存在的节 ⇒ **报红**。
3. 指针**必须唯一**：同一个**完整编号**在台账里**只能有一个**节标题
   ⇒ ⇒ 否则「指向」是**歧义**的 ⇒ 读者不知道跳哪 ⇒ **报红**。
4. 每个被指向的节**必须真的被指向** ⇒ ⇒ 「写了但没人引」不是错误
   （台账允许有孤立的节）⇒ ⇒ **不报**。⚠️ 只报**坏指针**，不报**孤儿节**
   ⇒ ⇒ 避免守卫变成「逼你删内容」。

## ⚠️ 三条**判据陷阱**（本守卫第一版全部踩了 ⇒ 写在这里免得再踩）

1. **层级前缀不算歧义** ⇒ `### 50.12` 与 `#### 50.12.5b` **不是**歧义 ——
   指针 `§50.12` 指的是**那个层级**的节，`§50.12.5b` 指的是**子节** ⇒ ⇒
   判据必须比**完整编号**，**不是**比前缀。
2. **跨文件引用不是本台账的指针** ⇒ 「`docs/SWIFT6_MIGRATION.md` §8」里的
   `§8` 指的是**另一个文件**的节 ⇒ ⇒ 本台账里当然找不到 ⇒ ⇒
   **误报** ⇒ ⇒ 必须排除「`§` 前面紧邻着另一个文件名/路径」的引用。
3. **`## 42.` 与 `### 42.4b` 不算歧义** ⇒ 同一条指针 `§42` 指的是**顶层节**
   ⇒ ⇒ 编号**完全相同**才算歧义。

## 它**不**做什么

* **不**校验台账里的**数字**（那是 §50.22.3 那条线的事：判据的机器可读出处）。
* **不**校验散文内容的**对错** ⇒ ⇒ **散文规则仍可能写错**
  （那是 V15 的残余，§50.22.7 第 3 条已如实记录）。
* **只读**：它只读台账这一个文件 ⇒ 对用户环境**零副作用**。

## 退出码

| code | meaning |
|---|---|
| **0** | 干净（所有指针都指向真实且唯一的节） |
| **1** | 有坏指针（指向不存在 / 指向歧义） |
| **2** | 守卫自己没跑起来（台账读不到）⇒ 绝不冒充「干净」 |
'''

from __future__ import annotations

import os
import re
import sys

LEDGER_REL = os.path.join("docs", "skips-ledger.md")

# 「§50.22.4」/「§50.22」/「§50.22.4 的新维度」⇒ 抓编号本体
# ⚠️ 编号后面可能跟**字母**（`42.4b`、`50.12.5b`）⇒ 必须**一起抓**，
#    否则 `42.4b` 会被截成 `42` ⇒ 与 `## 42.` 撞成「歧义」⇒ **误报**。
POINTER = re.compile(r"§\s*(\d+(?:\.\d+)*[a-z]?)")
# 节标题：`#### 50.22.4 标题` 或 `## 50.20 标题` ⇒ 同样要吃字母后缀。
# ⚠️ 层级要覆盖 **2–5** 级：台账里确实有 `##### 39.7.1`（五级）⇒
#    只认 2–4 级会把它当「不存在的节」⇒ **误报**。
HEADING = re.compile(r"^#{2,5}\s+(\d+(?:\.\d+)*[a-z]?)\b")
# ⚠️ **编号不在标题开头**的顶层节：台账里写的是
#    `## ID-REVIEW-1038（2026-10-27）：…` ⇒ 它的子节是 `### 38.1` ⇒
#    ⇒ 指针 `§38` 指向的是**这一族**（38.x），而**族根**没有 `## 38.` 这种标题。
#    ⇒ 判据：**该族至少有一个子节标题** ⇒ 指针有效。
HEADING_ANYWHERE = re.compile(r"^#{2,5}\s.*?\b(\d+(?:\.\d+)*[a-z]?)\b")
# ⚠️ **跨文件引用**：`docs/SWIFT6_MIGRATION.md` §8 ⇒ 那个 `§8` 不属于本台账。
#   判据：`§` 前面**紧邻**着「一个路径样式的 token」⇒ 排除。
#   （实测第一版没有这条 ⇒ 把 8 处**别的文件**的引用误报成断链。）
CROSS_FILE = re.compile(r"[\w./-]+\.(?:md|swift|sh|py|yml|yaml|json|txt)\`?\s*§")


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print("用法：test_ledger_section_pointers.py <repo-root>", file=sys.stderr)
        return 2
    root = args[0]
    if not os.path.isdir(root):
        print(f"❌ 仓库目录不存在：{root}", file=sys.stderr)
        return 2
    path = os.path.join(root, LEDGER_REL)
    if not os.path.exists(path):
        print(f"❌ 台账读不到：{LEDGER_REL}", file=sys.stderr)
        return 2
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    # 1. 收集节标题（编号 → 出现次数 + 行号）
    headings: dict[str, list[int]] = {}
    for lineno, line in enumerate(lines, 1):
        match = HEADING.match(line)
        if match:
            headings.setdefault(match.group(1), []).append(lineno)
    # **族根**集合：`38` 族（`### 38.1` …）⇒ 指针 `§38` 有效。
    family_numbers = {n.split(".")[0] for n in headings}

    problems: list[str] = []
    checked = 0
    skipped_cross_file = 0
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
        for match in POINTER.finditer(probe):
            number = match.group(1)
            if (number, lineno) in seen:
                continue
            seen.add((number, lineno))
            # ⚠️ **层级前缀不算歧义** ⇒ 判据必须比**完整编号**。
            #   （`### 50.12` 与 `#### 50.12.5b` 是两个不同的节，不是歧义。）
            locations = headings.get(number)
            if locations is None:
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
                    skipped_cross_file += 1
            elif len(locations) > 1:
                problems.append(
                    f"{LEDGER_REL}:{lineno}: 指针 §{number} 指向**{len(locations)} 个**"
                    f"节标题（行 {', '.join(str(x) for x in locations)}）⇒ 指向**歧义**"
                )
            checked += 1

    if problems:
        print("❌ 台账指针检查发现断链：", file=sys.stderr)
        for problem in problems:
            print("   - " + problem, file=sys.stderr)
        return 1

    print(f"✅ 台账 {LEDGER_REL}：{checked} 处节指针**全部**指向真实且唯一的节"
          f"（共 {len(headings)} 个节标题；{skipped_cross_file} 处指向**别的编号体系**"
          f" ⇒ 已跳过）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
