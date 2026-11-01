#!/usr/bin/env python3
"""Assert the three production canaries actually EXECUTED in a full-suite log.

ID-REVIEW-1049 第三轮 (2026-11-01): the independent verifier found that deleting
**three lines** (the baseline capture + both claims) leaves the production
safety net **OFF** while the whole suite stays **GREEN**:

    Executed 1436 tests, with 7 tests skipped and 0 failures
    ** TEST SUCCEEDED **

⇒ the three production canaries were `skipped` (the net was off) and the
suite was green ⇒ **exactly the shape this whole family is about**
("安全网关着" and "安全网开着" look identical in the report).

⇒ **Why an out-of-band script**: the audit that lives *inside* the test tree
reads the tree's **own** arming signals ⇒ a coordinated deletion of those
signals cannot be detected from inside the tree. ⇒ The arming state must be
asserted by something that is **not** part of what can be deleted.

⇒ ⇒ *「谁说自己做到了」与「做没做到」必须由**不同来源**回答* ——
and here the two sources are **the test tree** and **the log/this script**.

## What it checks (per full-suite log)

1. Each of the three production canaries has a `passed` line.
2. None of them has a `skipped` line (a skipped canary = the net is off).
3. The canary **audit** test has a `passed` line.

## Usage

    python3 Scripts/verify-production-canaries.py <test-log>

## Exit codes (⚠️ the three cases must stay distinguishable)

| code | meaning |
|---|---|
| **0** | armed — the three canaries and the audit all passed |
| **1** | the check **ran** and the safety net is **OFF** (a canary was skipped / did not pass) |
| **2** | the check **could not run** (usage error / the log is missing or unreadable) |

⚠️ Why 1 and 2 must not be conflated (auto-review P0, 2026-11-01): if a
**broken gate** (missing log, wrong path, a Python error) reports the same
code as "the safety net is off", then the real cause is **masked** — the
operator sees "canaries did not run" and goes hunting in the test tree while
the gate itself is the thing that broke.

⚠️ **Read-only**: it only reads the log file. It never touches the user's
preferences, the keychain, or the repository.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# The three production canaries — the only thing that catches "a test wrote
# the user's production domain". They live in `ZZZSuiteTeardownTests`.
PRODUCTION_CANARIES = (
    "testNoProductionPollution",
    "testProductionDataBlobsAreUnchanged",
    "testFirstLaunchFlagIsNeverChangedDuringTheSuite",
)

# The audit that proves the three canaries really ran (ID-REVIEW-1049).
AUDIT_TEST = ("ZZZTheCanariesWereNotDisarmedTests",
              "testTheProductionCanariesWereNotDisarmed")

CANARY_CLASS = "ZZZSuiteTeardownTests"


def outcomes(log: str, class_name: str, test_name: str) -> set[str]:
    """The outcomes (`passed` / `failed` / `skipped`) of one test case."""
    pattern = re.compile(
        r"Test Case '-\[ClipMemoryTests\.%s %s\]' (passed|failed|skipped)"
        % (re.escape(class_name), re.escape(test_name))
    )
    return set(pattern.findall(log))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        print("usage: verify-production-canaries.py <test-log>", file=sys.stderr)
        return 2

    log_path = Path(argv[1])
    if not log_path.exists():
        print(
            f"❌ **检查自己没跑起来**：找不到测试日志 {log_path} "
            "（这不是「安全网关着」，是闸门坏了）",
            file=sys.stderr,
        )
        return 2
    if not log_path.is_file():
        print(f"❌ **检查自己没跑起来**：{log_path} 不是文件", file=sys.stderr)
        return 2

    log = log_path.read_text(encoding="utf-8", errors="replace")
    problems: list[str] = []

    for test_name in PRODUCTION_CANARIES:
        seen = outcomes(log, CANARY_CLASS, test_name)
        if "skipped" in seen:
            problems.append(
                f"{CANARY_CLASS}.{test_name} 处于 **skipped** 状态 ⇒ "
                "生产域的「前后对比」没有执行 ⇒ **安全网是关着的**"
            )
        if "passed" not in seen:
            problems.append(
                f"{CANARY_CLASS}.{test_name} 没有 **passed** 记录 ⇒ "
                "它没有真正执行（或整个类没跑）⇒ **安全网是关着的**"
            )

    audit_class, audit_test = AUDIT_TEST
    if "passed" not in outcomes(log, audit_class, audit_test):
        problems.append(
            f"{audit_class}.{audit_test} 没有 **passed** 记录 ⇒ "
            "canary 审计没有执行 ⇒ **无法证明安全网是开着的**"
        )

    if problems:
        print("❌ 生产 canary 状态检查失败（ID-REVIEW-1049 第三轮）：", file=sys.stderr)
        for problem in problems:
            print(f"   - {problem}", file=sys.stderr)
        print(
            "\n   ⚠️ 排查顺序：\n"
            "   ① 另一个 ClipMemory 实例在跑吗？（.instance.lock 被持有 ⇒ "
            "canary 合法跳过 ⇒ 本次运行的**安全网确实是关着的** ⇒ 请关闭 App 后重跑）\n"
            "   ② `AAASuiteBootstrapTests` 的基线捕获 / `aaaBootstrapRan` / "
            "`didSnapshotProductionDomain` 还在吗？\n"
            "   ③ 是不是**窄跑**（`-only-testing:`）？窄跑没有基线 ⇒ canary 会跳过 ⇒ "
            "这条检查只对**全量跑**有意义。",
            file=sys.stderr,
        )
        return 1

    print("✅ 三个生产 canary 与 canary 审计均已 **passed**（安全网是开着的）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
