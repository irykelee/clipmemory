#!/usr/bin/env python3
"""ID-REVIEW-1049 第十四轮 e：`Scripts/generate_stringsdict.py` 的回归测试。

## 为什么改写（第十四轮 e 实测）

本脚本**从来没有在 CI 里跑过**（孤儿测试）⇒ ⇒ 于是它在仓库里**烂掉了**：它断言
「on-disk 的 `.stringsdict` 必须与生成器输出**逐字相同**」⇒ ⇒ 而 on-disk 的 7 个文件
是**有意保留的空壳**（复数机制 2026-07-25 已退役）⇒ ⇒ 生成器却还在产出**已退役**的
`%#@count@` 机制 ⇒ ⇒ ⇒ 于是这个测试**长期失败**，而它的失败信息恰好在说
「**跑一下生成器**」⇒ ⇒ ⇒ ⇒ **那会把退役的机制写回 7 个语言** ⇒ ⇒ ⇒ ⇒ **回归**。

⇒ ⇒ 所以两边一起改：
1. **生成器**现在只产出「退役空壳」（用途：让 Xcode 工程里的 `.stringsdict` 引用
   继续有效）⇒ ⇒ 旧的复数生成逻辑保留未删（留作机制复盘的证据）⇒ ⇒ 不再被写出路径调用。
2. **本测试**改成守护**真不变量**：① on-disk 的 7 个文件是**合法但为空**的 plist；
   ② 生成器输出与 on-disk **逐字相同**（⇒ ⇒ 「跑一下生成器」重新变成**安全**的建议）；
   ③ 生成器输出**不含**任何 `%#@count@` / `NSStringPluralRuleType`（⇒ ⇒ 地雷已拆
   **且**被守住）。

Run: python3 Scripts/test/test_generate_stringsdict.py
Exit 0 = PASS, non-zero = FAIL
"""
import pathlib
import plistlib
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
sys.path.insert(0, str(REPO_ROOT / "Scripts"))

from generate_stringsdict import LOCALE_CATEGORIES, SHELL_XML, generate_for_locale  # noqa: E402

failures: list[str] = []


def strip_xml_comments(raw: str) -> str:
    """剥掉 XML 注释 ⇒ ⇒ 检查**内容**而不是**说明文字**
    （退役说明里**就写着** `%#@count@` ⇒ ⇒ 不剥会误伤自己）。
    """
    out, i = [], 0
    while True:
        start = raw.find("<!--", i)
        if start < 0:
            out.append(raw[i:])
            break
        out.append(raw[i:start])
        end = raw.find("-->", start)
        if end < 0:
            break
        i = end + 3
    return "".join(out)


def check(cond: bool, msg: str) -> None:
    if not cond:
        failures.append(msg)


def main() -> int:
    # ① on-disk 的 7 个文件：**存在** + **合法 plist** + **为空**（退役后的形态）
    for locale in sorted(LOCALE_CATEGORIES):
        path = REPO_ROOT / "ClipMemory" / f"{locale}.lproj" / "Localizable.stringsdict"
        check(path.exists(), f"{locale}: {path} missing")
        if not path.exists():
            continue
        raw = path.read_text(encoding="utf-8")
        try:
            parsed = plistlib.loads(raw.encode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{locale}: stringsdict is not a valid plist: {exc}")
            continue
        check(parsed == {}, f"{locale}: stringsdict is not empty ⇒ 复数机制可能被"
                            f"写回来了（退役于 2026-07-25）")
        content = strip_xml_comments(raw)
        check("NSStringPluralRuleType" not in content,
              f"{locale}: stringsdict 含 NSStringPluralRuleType ⇒ 退役机制被写回来了")
        check("%#@count@" not in content,
              f"{locale}: stringsdict 含 %#@count@ ⇒ 退役机制被写回来了")

    # ② 生成器输出 == on-disk（逐字）⇒ ⇒ 「跑一下生成器」是**安全**的建议
    for locale in sorted(LOCALE_CATEGORIES):
        path = REPO_ROOT / "ClipMemory" / f"{locale}.lproj" / "Localizable.stringsdict"
        if not path.exists():
            continue
        generated = generate_for_locale(locale, [])
        check(generated == path.read_text(encoding="utf-8"),
              f"{locale}: 生成器输出与 on-disk **不同字** ⇒ ⇒ 「跑一下生成器」"
              f"会把内容改掉 ⇒ ⇒ 而那正是本轮要拆掉的地雷")

    # ③ 生成器输出**不含**退役机制
    shell_content = strip_xml_comments(SHELL_XML)
    check("NSStringPluralRuleType" not in shell_content,
          "生成器输出含 NSStringPluralRuleType ⇒ 退役机制会被写回 7 个语言")
    check("%#@count@" not in shell_content,
          "生成器输出含 %#@count@ ⇒ 退役机制会被写回 7 个语言")

    if failures:
        print(f"\n{len(failures)} check(s) FAILED")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("✅ PASS：stringsdict 7 个语言都是**退役空壳**（合法 plist、无复数条目），"
          "且生成器输出与 on-disk **逐字相同** ⇒ 「跑一下生成器」是安全的建议")
    sys.exit(0)


if __name__ == "__main__":
    main()
