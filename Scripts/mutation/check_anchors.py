#!/usr/bin/env python3
'''ID-REVIEW-1049 第十轮 c：变异 harness 的**锚点清单**必须完整（便宜的 CI 前置检查）。

## 它守的是什么

`Scripts/mutation/mutate.py` 的每条变异都靠一段**锚点文本**（anchor）定位
要改的源码。⇒ ⇒ 源码一改，锚点可能**不再存在** ⇒ ⇒ harness 会
`ANCHOR MISSING … — skipped` ⇒ ⇒ **那条变异就被悄悄少测了一条**。

⚠️ **第十一轮实测**：这条路径**原本不进终局判定**（VERDICT 只数
caught / survived / not_proven / catcher_mismatch / restore_drift）⇒ ⇒
锚点漂移 ⇒ `VERDICT caught=0 …` + **exit 0** ⇒ ⇒ 「51 条全红」可以
**无声地**变成「49 条全红」⇒ ⇒ **没有任何东西报红**。
⇒ ⇒ 那正是本族的「**跳过 ≠ 通过**」：工具把「这条我没测」记成了
「这条没问题」。

⇒ ⇒ **本脚本把这件事搬到 CI**：**不需要 build、不需要跑测试**
⇒ ⇒ 只要 51 条变异的锚点**都还在** ⇒ ⇒ 「51 条」这个数字就**仍然成立**
⇒ ⇒ 一旦有锚点漂移 ⇒ ⇒ **立刻报红** ⇒ ⇒ 台账里的数字不会悄悄过期。

⇒ ⇒ **清单本身也被锁住**（`EXPECTED_MUTATION_COUNT` + id 清单的 sha256）
⇒ ⇒ 增删变异**必须**同步改这里 ⇒ ⇒ **协同成本**（与 canary-gate-locks、
引号语料的 sha256 锁**同款**）⇒ ⇒ 否则「少了一条」也会静默。

## ⚠️ 它**不**做什么

* **不**证明变异仍然「测的是它声称的东西」⇒ ⇒ 锚点**在**只说明
  「这段文本还在」⇒ ⇒ **语义漂移**（锚点还在、但那一行已经不再是要改的
  地方）**仍然要靠真跑 harness 才能发现**。
* **不**跑测试、不 build ⇒ ⇒ 它是**前置检查**，**不是** harness 的替代品。
* **不**证明「51 条都真的被抓住」⇒ ⇒ 那件事只有真跑 harness 才知道。
* **只读**：它只读仓库里的源码文件 ⇒ 不碰用户的偏好设置 / 钥匙串 / 剪贴板。

## 用法

    python3 Scripts/mutation/check_anchors.py

## 退出码

| code | meaning |
|---|---|
| **0** | 全部锚点都在、清单与锁一致 |
| **1** | 有锚点缺失 / 清单漂移（⇒ 「51 条全红」这句话**对不上**） |
| **2** | 检查自己没跑起来（读不到 harness）⇒ 绝不冒充「干净」 |
'''

from __future__ import annotations

import hashlib
import os
import sys
import types

# ⚠️⚠️ **不要让 Python 写 `.pyc`** ⇒ 本脚本是**只读**检查，不该在仓库里留缓存。
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
MUTATE_PATH = os.path.join(HERE, "mutate.py")

# ⚠️ **锁在清单的外面**（与引号语料的 sha256 锁同款）：改变异清单 ⇒ 必须同时
#   改这里 ⇒ ⇒ 「少了一条 / 多了一条」不会静默。
EXPECTED_MUTATION_COUNT = 51
EXPECTED_MUTATION_IDS_SHA256 = (
    "5b3cd31baa26afd7dcddc8e7f2f09f497bfe73887e4a1cf0ba28f1c89a69ac50"
)


def load_mutate():
    '''加载变异 harness。

    ⚠️⚠️ **必须绕开 `.pyc` 缓存** ⇒ ⇒ 否则本脚本可能读到**过期字节码**。

    ⇒ ⇒ 实测（第十一轮，**本脚本自己的缺陷**）：Python 的字节码缓存用
    「**mtime + size**」判定有效性 ⇒ ⇒ 把 `N51` 改成 `N99` 再 `git checkout`
    还原 ⇒ ⇒ **长度相同** + **同一秒** ⇒ ⇒ `.pyc` 被判为**仍然有效**
    ⇒ ⇒ 本脚本读到的是**改动前**的代码 ⇒ ⇒ **报出来的结论是关于旧代码的**
    ⇒ ⇒ **假绿**（而且是「工具骗自己」那族的：工具说的和磁盘上的不是一回事）。

    ⇒ ⇒ 修法：**不用 import 机制** ⇒ 直接 `compile()` + `exec()` 源码
    ⇒ ⇒ 每次都读**当前**文件 ⇒ ⇒ 零缓存。
    '''
    if not os.path.exists(MUTATE_PATH):
        print(f"❌ 读不到变异 harness：{MUTATE_PATH}", file=sys.stderr)
        return None
    try:
        with open(MUTATE_PATH, encoding="utf-8") as fh:
            source = fh.read()
    except OSError as exc:
        print(f"❌ 读不到变异 harness：{exc}", file=sys.stderr)
        return None
    namespace = {"__name__": "cm_mutate", "__file__": MUTATE_PATH}
    try:
        # ⚠️ 顶层会跑 harness 自己的「重复锚点常量」自守卫 ⇒ ⇒ 这里也一并生效。
        exec(compile(source, MUTATE_PATH, "exec"), namespace)  # noqa: S102
    except Exception as exc:  # noqa: BLE001  # pylint: disable=broad-except
        print(f"❌ 变异 harness 加载失败：{exc}", file=sys.stderr)
        return None
    return types.SimpleNamespace(namespace)


def main() -> int:
    module = load_mutate()
    if module is None:
        return 2

    repo = module.REPO
    mutations = module.MUTATIONS
    ids = sorted(entry[0] for entry in mutations)
    digest = hashlib.sha256("\n".join(ids).encode("utf-8")).hexdigest()

    problems: list[str] = []

    if len(ids) != EXPECTED_MUTATION_COUNT:
        problems.append(
            f"变异条数是 **{len(ids)}**，锁里写的是 **{EXPECTED_MUTATION_COUNT}**"
            f" ⇒ 清单漂移 ⇒ 「{EXPECTED_MUTATION_COUNT} 条全红」这句话**对不上**"
            f" ⇒ ⇒ 增删变异**必须**同步改本脚本的 EXPECTED_MUTATION_COUNT"
            f" 与 EXPECTED_MUTATION_IDS_SHA256"
        )
    if digest != EXPECTED_MUTATION_IDS_SHA256:
        problems.append(
            f"变异 id 清单的 sha256 是 **{digest}**，锁里写的是 "
            f"**{EXPECTED_MUTATION_IDS_SHA256}** ⇒ 清单漂移"
            f"（当前 ids：{ids}）"
        )

    missing: list[str] = []
    checked = 0
    for entry in mutations:
        mid, label = entry[0], entry[1]
        for rel, old, _new in entry[2]:
            path = os.path.join(repo, rel)
            checked += 1
            try:
                with open(path, encoding="utf-8") as fh:
                    content = fh.read()
            except OSError as exc:
                missing.append(f"{mid}：读不到 {rel}（{exc.strerror}）")
                continue
            if old not in content:
                missing.append(f"{mid}：{rel} 里找不到锚点（{label}）")

    if missing:
        problems.append(
            f"**{len(missing)}** 条变异的目标锚点**不在源码里** ⇒ ⇒ "
            f"harness 会 `ANCHOR MISSING — skipped` ⇒ ⇒ **那些变异根本没被测**"
            f" ⇒ ⇒ 「{len(ids)} 条全红」这句话**对不上**"
        )
        problems.extend("    - " + item for item in missing)

    if problems:
        print("❌ 变异锚点前置检查失败：", file=sys.stderr)
        for problem in problems:
            print("   " + problem, file=sys.stderr)
        return 1

    print(f"✅ 变异锚点前置检查通过：{len(ids)} 条变异 / {checked} 个锚点"
          f"**全部还在**源码里（id 清单 sha256 已锁）"
          f" ⇒ ⇒ 「{len(ids)} 条全红」这个数字**仍然成立**")
    return 0


if __name__ == "__main__":
    sys.exit(main())
