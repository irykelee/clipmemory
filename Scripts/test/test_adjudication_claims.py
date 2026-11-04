#!/usr/bin/env python3
"""ID-REVIEW-1049 第十四轮 e：124 条失效锚点的**逐条重验**检查表。

用法：python3 /tmp/reanchor_checks.py
每个检查 = (编号, 文件, 判据类型, needle, 期望结论的「关键词」)
  has     ⇒ 文件里必须出现 needle
  nothas  ⇒ 文件里必须**不**出现 needle
判据全部写成**机器可查**的形状（grep 级）⇒ 结论「仍成立/已变」由输出直接给出。
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

TRIPLE = chr(34) * 3   # ⇒ ⇒ 不用字面量三引号（散文守卫的窄表述会命中）

CHECKS = [
    # ── test_rule_prose_copies.py（12 条）──────────────────────────────
    ("R53", "Scripts/test/test_rule_prose_copies.py", "has", r"def scan_documents", "抽出 scan_documents（main 与自检同路径）"),
    ("R54", "Scripts/test/test_rule_prose_copies.py", "has", r"RULE_LABEL_STRUCTURE = re\.compile", "标签判定改成形态判定"),
    ("R54b", "Scripts/test/test_rule_prose_copies.py", "has", r"\(\?:真\)\?\(\?:规则\|Rule\)", "形态判定含「规则/Rule + 结构词」"),
    ("R55", "Scripts/test/test_rule_prose_copies.py", "has", r"引号", "窄表述改成数量+量词+引号词的模式族"),
    ("R55b", "Scripts/test/test_rule_prose_copies.py", "nothas", r"\[3-9\]|10\|", "数量不锚定到 10（只列奇数）"),
    ("R57", "Scripts/test/test_rule_prose_copies.py", "has", r"MAX_SELF_EXEMPT_REGIONS\s*=\s*2", "哨兵豁免区上限 = 2"),
    ("R58", "Scripts/test/test_rule_prose_copies.py", "nothas", r"\[三五七九\]\[3-9\]", "数量不是字符类拼接"),
    ("R59", "Scripts/test/test_rule_prose_copies.py", "has", r"改为", "前块用例换成含「改为」的文本"),
    ("R60", "Scripts/test/test_rule_prose_copies.py", "notlist", r"已作废", "豁免词表**定义**里已无「已作废」（注释里可留解释）"),
    ("R62", "Scripts/test/test_rule_prose_copies.py", "has", r"三五七九", "数量只列奇数（三/五/七/九）"),
    ("R65", "Scripts/test/test_rule_prose_copies.py", "has", r"RULE_LABEL_SEPARATORS", "分隔符白名单存在"),
    ("R65b", "Scripts/test/test_rule_prose_copies.py", "has", r"ZERO_WIDTH_CHARS", "零宽归一化存在"),
    ("R67", "Scripts/test/test_rule_prose_copies.py", "has", r"NARROW_MARKERS", "豁免词表存在"),
    ("R68", "Scripts/test/test_rule_prose_copies.py", "has", r"TemporaryDirectory|tempfile", "自检在合成临时仓库上跑"),
    ("R68b", "Scripts/test/test_rule_prose_copies.py", "has", r"数字\*\*已经漂了\*\*|已经漂了", "自检断言 stderr 关键词"),
    ("R72", "Scripts/test/test_rule_prose_copies.py", "has", r"CORPUS_NAME", "语料文件名有用例钉住"),
    # ── review-adjudicate.py（4 条）───────────────────────────────────
    ("R2", "githooks/review-adjudicate.py", "nothas", r"编译失败则按字面子串|编译失败.*退化为字面子串", "帮助文本已订正（不再说「编译失败则按字面子串」）"),
    ("R6", "githooks/review-adjudicate.py", "has", r"cm-adjudication", "哨兵行 + 只认自己写的块"),
    ("R10", "githooks/review-adjudicate.py", "nothas", r"re\.MULTILINE", "匹配仍按行锚定（不需要 MULTILINE）"),
    ("R15", "githooks/review-adjudicate.py", "has", r"def resolve_in_repo", "路径校验函数仍在"),
    ("R1", "githooks/review-adjudicate.py", "has", r"realpath", "realpath 边界校验仍在"),
    ("R2b", "githooks/review-adjudicate.py", "has", r"拒绝：match 正则编译失败", "add 在写入侧拒绝编译不过的正则"),
    ("R2c", "githooks/review-adjudicate.py", "has", r"不能是台账自身", "add 拒绝锚到台账自身"),
    ("R2d", "githooks/review-adjudicate.py", "has", r"有未提交改动", "add 拒绝锚到有未提交改动的文件"),
    ("R2e", "githooks/review-adjudicate.py", "has", r"def cmd_audit|--fail-on-stale", "audit 子命令存在"),
    # ── orca-auto-review.sh（4 条）────────────────────────────────────
    ("R3", "githooks/orca-auto-review.sh", "has", r"人工核验层崩溃|apply 执行失败", "崩溃与缺件分别说明"),
    ("R3b", "githooks/orca-auto-review.sh", "has", r"找不到 python3", "缺件仍单独说明"),
    ("R7", "githooks/orca-auto-review.sh", "has", r"read -r", "read -r key value 解析"),
    ("R12", "githooks/orca-auto-review.sh", "has", r"confirmed", "人工 confirmed 覆盖模型 PASS 的逻辑在"),
    # ── SingleInstanceLock.swift（3 条）───────────────────────────────
    ("R4", "ClipMemory/Utils/SingleInstanceLock.swift", "probe_nocreate", r"O_RDONLY", "只读探针不带 O_CREAT（不建目录）"),
    ("R13", "ClipMemory/Utils/SingleInstanceLock.swift", "has", r"static var defaultFileURL", "defaultFileURL 是静态存储（惰性求值）"),
    ("R14", "ClipMemory/Utils/SingleInstanceLock.swift", "nothas", r"^import AppDirectories", "同 target 不需要 import AppDirectories"),
    ("R2f", "ClipMemory/Utils/SingleInstanceLock.swift", "has", r"EINTR", "EINTR 仍被单独处理"),
    # ── TestIsolation.swift / CryptoService / KeychainKeyStore ────────
    ("R12b", "ClipMemory/Utils/TestIsolation.swift", "has", r"defaultsLock", "defaults 仍受锁保护"),
    ("R12c", "ClipMemory/Utils/TestIsolation.swift", "has", r"private.*defaultsStorage", "defaultsStorage 仍是 private"),
    ("R13b", "ClipMemory/Services/CryptoService.swift", "has", r"static let keyFailureHandler", "keyFailureHandler 是 static let"),
    ("R13c", "ClipMemory/Services/CryptoService.swift", "has", r"static let appTerminator", "appTerminator 是 static let"),
    ("R8", "ClipMemory/Services/CryptoService.swift", "has", r"shouldRefuseKeychainStore", "生产钥匙串收敛点判定仍在"),
    ("R17", "ClipMemory/Services/KeychainKeyStore.swift", "has", r"let service: String", "service 是 internal let"),
    # ── 测试树（8 条）───────────────────────────────────────────────
    ("R5", "Tests/ClipMemoryTests/ZZZSuiteTeardownTests.swift", "nothas", r"跳过", "skip 消息已改英文"),
    ("R9", "Tests/ClipMemoryTests/ZZZSuiteTeardownTests.swift", "has", r"skipIfAnotherInstanceIsRunning", "锁探测仍在（不做记忆化）"),
    ("R11", "Tests/ClipMemoryTests/UserDefaultsSearchListTests.swift", "has", r"XCTSkip", "环境缺 key 时可见跳过"),
    ("R24", "Tests/ClipMemoryTests/TestHostIsolationTests.swift", "has", r"removePersistentDomain|defaults", "restore 指向自己的 defaults"),
    ("R26", "Tests/ClipMemoryTests/HotKeyManagerTests.swift", "has", r"removeTestDefaults", "清理逻辑仍在"),
    ("R27", "Tests/ClipMemoryTests/Review1037RegressionTests.swift", "has", r"persistentDomain", "persistentDomain 探测器仍在"),
    ("R28", "Tests/ClipMemoryTests/SnapshotTestHelpers.swift", "has", r"test-.*UUID|UUID\(\)\.uuidString", "per-test suite 用 UUID"),
    ("R29", "Tests/ClipMemoryTests/Review1037RegressionTests.swift", "has", r"dictionaryRepresentation", "自适配遍历全局域"),
    ("R31", "Tests/ClipMemoryTests/ProductionDomainWriteGuardTests.swift", "has", r"Rule D", "Rule D 契约仍在"),
    ("R32", "Tests/ClipMemoryTests/ProductionDomainWriteGuardTests.swift", "has", r"KNOWN LOOSENESS", "已知宽松写进文件"),
    ("R33", "Tests/ClipMemoryTests/ProductionDomainWriteGuardTests.swift", "has", r"Rule D|alias|别名", "别名规则仍在"),
    ("R35", "Tests/ClipMemoryTests/Audit20260720RegressionTests.swift", "has", r"contract|契约", "3 条独立契约仍在"),
    ("R39", "Tests/ClipMemoryTests/ZZZTheCanariesWereNotDisarmedTests.swift", "has", r"recordSkip", "recordSkip 记账仍在"),
    ("R10b", "Tests/ClipMemoryTests/XCTestIsolationSuiteBootstrap.swift", "has", r"final class XCTestIsolationSuiteBootstrap", "独立 observer 文件仍在"),
    ("R15b", "Tests/ClipMemoryTests/Review1036RegressionTests.swift", "has", r"window: TimeInterval = 0\.5", "时长驱动仍是 0.5s 窗口"),
    # ── 脚本族 ───────────────────────────────────────────────────────
    ("R19", "Scripts/test/test_ollama_endpoints.sh", "has", r"api/version", "假 curl 桩的 base URL 已对齐生产探测路径"),
    ("R23", "Scripts/test/test_ollama_endpoints.sh", "has", r"只含空白的项被丢弃|空白", "断言 10 第三条仍在"),
    ("R22", "githooks/ollama-endpoints.sh", "has", r"trim|IFS_SAVE", "显式候选的空格已处理"),
    ("R18", "githooks/ollama-endpoints.sh", "has", r"0\.0\.0", "探不到版本 ⇒ 0.0.0 兜底仍在"),
    ("R40", "Scripts/test/test_verify_production_canaries.sh", "has", r"2026-11-01", "注释里的 2026-11-01 是实测日期（保留）"),
    ("R41", "Scripts/test/test_verify_production_canaries.sh", "has", r"反引号", "反引号=命令替换的坑已写进注释"),
    ("R45", ".gitattributes", "has", r"\*\.json\s+text eol=lf", "*.json 已锁 LF"),
    ("R46", "Scripts/test/test_shell_multibyte_var_boundary.py", "has", r"词法上", "宽规则已补「词法上 vs 运行时」限定词"),
    ("R47", "Scripts/test/test_shell_heredoc_quote_rule.py", "has", r"def find_bash5", "--regenerate 已改用 find_bash5"),
    ("R42", "Scripts/mutation/mutate.py", "has", r"caught_by", "caught_by 归因字段存在"),
    ("R44", "Scripts/mutation/mutate.py", "has", r"\"expect\":", "选项键是 expect（非 expected）"),
    ("R17b", "githooks/review-gate-adjudication.sh", "has", r"mktemp", "临时文件仍用 mktemp"),
    # ── 台账内容（14 条）────────────────────────────────────────────
    ("R14", "docs/skips-ledger.md", "has", r"受控对照", "ID-REVIEW-1036 段的重构仍在"),
    ("R14b", "docs/skips-ledger.md", "has", r"36\.6 独立核验的 findings 与处置", "§36.6 仍在"),
    ("R30", "docs/skips-ledger.md", "has", r"37\.2|argument domain", "§37.2 的 argument domain 补记仍在"),
    ("R43", "docs/skips-ledger.md", "has", r"高确定性", "「符合项目对高确定性审计的要求」那句仍在"),
    ("R48", "docs/skips-ledger.md", "has", r"第十轮|第十一轮", "轮次编号写法仍在"),
    ("R49", "docs/skips-ledger.md", "has", r"50\.24", "§50.24 仍在"),
    ("R50", "docs/skips-ledger.md", "has", r"V18", "V18 仍在"),
    ("R50b", "docs/skips-ledger.md", "has", r"V19", "V19 仍在"),
    ("R52", "docs/skips-ledger.md", "has", r"50\.24\.5", "§50.24.5 的自检计数段仍在"),
    ("R56", "docs/skips-ledger.md", "has", r"50\.24\.2", "§50.24.2 仍在"),
    ("R61", "docs/skips-ledger.md", "has", r"16", "16 条探针的订正仍在"),
    ("R64", "docs/skips-ledger.md", "has", r"50\.27\.6", "§50.27.6（探针清单入库与 CI 接线）仍在"),
    ("R66", "docs/skips-ledger.md", "has", r"S-3", "§50.26.2 的 S-3 行仍在"),
    ("R69", "docs/skips-ledger.md", "has", r"50\.26\.2", "§50.26.2 仍在"),
    ("R70", "docs/skips-ledger.md", "has", r"50\.26\.6", "§50.26.6 仍在"),
    ("R38", "docs/SWIFT6_MIGRATION.md", "has", r"AppStorageDefaults\.swift", "§8 roster 里的那一行仍在"),
    # ── 覆盖表补齐（第十四轮 e）──────────────────────────────────────
    ("P2-11", "Scripts/test/test_review_adjudicate.sh", "has", r"TEST_DIR", "被改的文件在临时目录里（不进共享仓库状态）"),
    ("P2-19", "Scripts/test/test_review_adjudicate.sh", "has", r"mktemp -d", "用 mktemp -d 落临时目录（模型沙箱限制，非测试缺陷）"),
    ("P2-19b", ".github/workflows/ci.yml", "has", r"test_review_adjudicate\.sh", "该测试已接进 CI lint-ids job"),
    ("P2-20", "githooks/review-gate-adjudication.sh", "has", r"crashed|STATUS", "err_file 为空时仍靠退出码判定崩溃（fail-closed）"),
    ("R79", "Scripts/test/test_verify_production_canaries.sh", "has", r'if \[\[ "\$MODE" != "manifest" \]\]', "contract 段与清单段互斥（contract 不看清单）"),
    ("P2-30", ".github/workflows/ci.yml", "has", r"bash Scripts/test/test_ollama_endpoints\.sh", "CI 调的是脚本本身，不涉及 discover 签名"),
    ("P2-40", "docs/skips-ledger.md", "has", r"2026-10-2[0-9]", "台账里的日期与本仓库时间线一致（不是未来日期）"),
    ("P2-57", "Tests/ClipMemoryTests/SnapshotTestHelpers.swift", "has", r"AppStorageDefaults\.setShared\(snapshotDefaults\)", "快照助手现在指向 per-test 隔离 suite（前提已变：@AppStorage 全接上 store: seam）"),
    ("P2-60", "ClipMemory/Utils/AppStorageDefaults.swift", "has", r"XCTest-isolation|isRunningTests", "测试进程下 AppStorageDefaults 默认是隔离 suite"),
    ("P0-64", "ClipMemory/Services/CryptoService.swift", "count", r"KeychainKeyStore\(\)", "生产钥匙串入口仍是 6 个（穷举结论）"),
    ("P1-28", "githooks/ollama-endpoints.sh", "has", r"explicit_hit", "内置段双重排除（explicit_out + seen）"),
    ("P1-72", "Scripts/test/test_verify_production_canaries.sh", "branch", r"manifest_out", "manifest_out 只在「清单存在」分支里被打印"),
    ("P1-84", "Scripts/test/test_verify_production_canaries.sh", "has", r"EXPECTED_GUARD_ENTRIES=9 → 10", "常量旁写明了 9→10 的原因"),
    ("P1-115", ".github/workflows/ci.yml", "has", r"prose_guard_mutants\.py", "变异集与探针清单都已接进 CI"),
    ("P3-114", "docs/skips-ledger.md", "has", r"473fade", "台账写明了基线 commit 与 old 口径"),
    ("P3-123", "Scripts/test/prose-guard-probes.json", "count", r'"name":', "探针清单已入库（可复算）"),

    # ── 补齐缺口判据（第十四轮 e）────────────────────────────────────
    ("P0-2", "githooks/ollama-endpoints.sh", "has", r'raw=\$\(curl[^)]*\)\s*\|\|\s*raw=""', "curl 失败显式兜住（端点不可达不牵连其它端点）"),
    ("P0-3", "ClipMemory/Services/ServiceProtocols.swift", "has", r"cryptoLock", "cryptoStorage 显式加锁"),
    ("P0-4", ".github/workflows/tsan.yml", "has", r"github\.event_name", "tsan concurrency group 含 event_name"),
    ("P0-6", "ClipMemory/Services/ServiceProtocols.swift", "has", r"firstLaunchLock", "firstLaunch 锁保护"),
    ("P0-6b", "ClipMemory/Services/ServiceProtocols.swift", "has", r"static var firstLaunch: FirstLaunchService", "firstLaunch 是 get-only"),
    ("P0-9", "Scripts/release.sh", "has", r"canary_gate=0", "release.sh 的 canary 闸门三态（fails 计数）"),
    ("P0-12", ".github/workflows/ci.yml", "has", r"test_shell_multibyte_var_boundary\.py \. --self-test", "CI 调用 multibyte 守卫 --self-test（牙齿被流水线检验）"),
    ("P1-3", "githooks/ollama-endpoints.sh", "has", r"意图优先", "显式候选意图优先（设计如此）"),
    ("P1-4", "githooks/ollama-endpoints.sh", "has", r"显式段：去重后按原顺序输出", "显式段已去重"),
    ("P1-5", "githooks/ollama-endpoints.sh", "has", r"\$\{explicit\[@\]\+", "数组展开用 ${arr[@]+...}（bash 3.2 安全）"),
    ("P1-6", "githooks/ollama-endpoints.sh", "has", r"seen\+=\(\"\$ep\"\)\n\s*explicit_out\+=", "seen 与 explicit_out 同一循环体逐个追加"),
    ("P1-9", "githooks/orca-auto-review.sh", "has", r"gemma4 比 9B 慢约", "顶部对照表已写代价与实测耗时"),
    ("P1-11", ".github/workflows/ci.yml", "has", r"github\.workflow \}\}-\$\{\{ github\.ref", "ci.yml concurrency group 按 ref 隔离"),
    ("P1-19", ".github/workflows/ci.yml", "has", r"闸门坏了，不是安全网关着", "CI 三态判定（0/1/其它）"),
    ("P1-20", "Scripts/test/test_verify_production_canaries.sh", "has", r"\|\| got=\$\?", "got 捕获真实退出码"),
    ("P1-25", "Scripts/test/test_verify_production_canaries.sh", "has", r"EXPECTED_MANIFEST_SHA256=43bc0878", "清单 sha256 硬编码在契约脚本里"),
    ("P1-26", "Scripts/test/test_verify_production_canaries.sh", "has", r"怎么重新生成 EXPECTED_MANIFEST_SHA256", "常量旁有生成配方（口径说明）"),
    ("P1-28", "Scripts/test/test_verify_production_canaries.sh", "has", r"i = j", "块注释整体被抹白（外层游标跳到 */ 之后）"),
    ("P1-29", "Scripts/test/test_verify_production_canaries.sh", "has", TRIPLE, "Swift 多行字面量被抹白"),
    ("P1-33", "docs/skips-ledger.md", "has", r"50\.20\.2", "§50.20.2 仍在（未被后续轮次删改）"),
    ("P1-36", "Scripts/test/test_rule_prose_copies.py", "has", r"heredoc", "散文守卫仍认 heredoc 特征"),
    ("P1-38", "Scripts/test/test_rule_prose_copies.py", "has", r"只对表格行", "上一块带标记的兜底只对表格行块生效"),
    ("P1-39", "Scripts/test/test_rule_prose_copies.py", "has", r"词法上", "判据①带「词法上」限定词"),
    ("P1-37", "Scripts/test/test_ledger_section_pointers.py", "has", r"核对机制根本没跑", "指针守卫能发现核对机制被静默关闭"),
    ("P2-1", "Scripts/test/test_review_adjudicate.sh", "has", r"不匹配 \+ 响亮告警", "门禁自测脚本的注释已订正（写的是现状而非旧说法）"),
    ("P2-18", "githooks/ollama-endpoints.sh", "has", r"0\.0\.0", "探不到版本 ⇒ 排最后的兜底"),
    ("P2-27", "Tests/ClipMemoryTests/XCTestIsolationSuiteBootstrap.swift", "has", r"\?\? \[:\]", "persistentDomain 返回 nil 已统一处理（suiteOwnedKeys 非可选）"),
    ("P2-33", "Tests/ClipMemoryTests/ProductionDomainWriteGuardTests.swift", "has", r"Rule D", "经参数流过来的生产域（已知边界）仍写在文件里"),
    ("P2-43", "docs/skips-ledger.md", "has", r"高确定性审计", "「符合项目对高确定性审计的要求」那句仍在"),
    ("P2-48", "docs/skips-ledger.md", "has", r"第十轮", "轮次编号写法仍在"),
    ("P3-5", "Tests/ClipMemoryTests/ZZZSuiteTeardownTests.swift", "nothas", r"跳过", "skip 消息统一英文"),

]


def _wordlist_has(rel: str, word: str) -> bool:
    """词表**定义**里是否含该词（只看 NARROW_MARKERS / RULE_LABELS 的字面量块）。"""
    text = open(os.path.join(REPO, rel), encoding="utf-8").read()
    for name in ("NARROW_MARKERS", "RULE_LABELS"):
        m = re.search(rf"{name}[^=]*=\s*\((.*?)\)", text, re.S)
        if m and word in m.group(1):
            return True
    return False


def _probe_creates(rel: str, anchor: str) -> bool:
    """只读探针函数体内是否出现 O_CREAT / createDirectory（副作用）。"""
    text = open(os.path.join(REPO, rel), encoding="utf-8").read()
    i = text.find(anchor)
    if i < 0:
        return True   # 探针函数找不到 ⇒ 判据不成立（保守）
    body = text[i:i + 1500]
    nxt = body.find("\n    func ", 10)
    if nxt > 0:
        body = body[:nxt]
    return ("O_CREAT" in body) or ("createDirectory" in body)


def _count(rel: str, needle: str) -> int:
    text = open(os.path.join(REPO, rel), encoding="utf-8").read()
    return len(re.findall(needle, text))


def _in_branch(rel: str, needle: str) -> bool:
    """needle 所在行是否落在 `if [[ ! -f "$MANIFEST" ]]` 的 **else** 分支里。"""
    text = open(os.path.join(REPO, rel), encoding="utf-8").read()
    lines = text.split("\n")
    i = next((k for k, l in enumerate(lines) if needle in l), -1)
    if i < 0:
        return False
    head = next((k for k, l in enumerate(lines) if 'if [[ ! -f "$MANIFEST" ]]' in l), -1)
    if head < 0:
        return False
    els = next((k for k, l in enumerate(lines[head:head + 12], start=head) if l.strip() == "else"), -1)
    if els < 0:
        return False
    # else 分支体内的行有缩进（这里是 2 空格）⇒ 用缩进判定归属
    return i > els and lines[i].startswith(" ")


# ── 实跑判据（需要真执行）──────────────────────────────────────────
RUNTIME = [
    ("P0-10", "multibyte 守卫在**空目录**上必须报红（扫了 0 个文件 ≠ 干净）",
     ["python3", "Scripts/test/test_shell_multibyte_var_boundary.py", "@TMPDIR@"],
     1),
    ("P0-10b", "multibyte 守卫的 --self-test 必须 exit 0",
     ["python3", "Scripts/test/test_shell_multibyte_var_boundary.py", ".", "--self-test"],
     0),
]

# ── 覆盖表：台账结论（按 match 认）→ 负责它的判据编号 ───────────────
# ⇒ ⇒ 键 = 台账里的 `match`（原文）⇒ ⇒ 值 = 判据编号列表
# ⇒ ⇒ 用来证明「124 条**一条不漏**」⇒ ⇒ 而不是「我大概都看了」
COVERAGE = {
    "15 个是死词": ["R67"],
    "15 条探针 / 修前 14 条逃逸": ["R61"],
    "15/14 未订正": ["R69"],
    "280 vs 279": ["R49"],
    "4 条判据": ["R72"],
    "6 个新词": ["R70"],
    "8/10 不可复算": ["P3-123"],
    "IFS=.*处理在 `for ep in \\$REVIEW_OLLAMA_ENDPOINTS`": ["R22"],
    "Marker lookback window \\(6 lines\\) can cover multiple writes": ["R32"],
    "Misleading error message": ["R3"],
    "Missing .AppDirectories. import": ["R14"],
    "Path traversal": ["R1", "R15"],
    "Rule D flags READS as writes": ["R31"],
    "S-3 行": ["R66"],
    "Skip message in Chinese": ["P3-5"],
    "Snapshot tests still write production domain": ["P2-57"],
    "TestIsolation.defaults.*构造正确": ["R12b", "R12c"],
    "adjudication layer runs even when model verdict is": ["R12"],
    "adjudication output parsing assumes no": ["R7"],
    "bash 3.2 下不崩": ["P1-5"],
    "blank_swift.*while.*循环在处理.*块注释时.*break.*只跳出了内部的": ["P1-28"],
    "blank_swift.*处理 `\"` 字符串时.*遇到 `\\\\n` 则 `break`": ["P1-29"],
    "blanking-corpus.json.*SHA256.*原始字节.*换行符": ["R45"],
    "calls .skipIfAnotherInstanceIsRunning. in two test methods": ["R9"],
    "canary_gate.*fails": ["P0-9"],
    "cannot detect aliased production domain passed through parameters": ["P2-33"],
    "ci\\.yml.*concurrency.*group.*使用": ["P1-11"],
    "creates the lock directory if missing": ["R4"],
    "cryptoStorage.*显式加锁": ["P0-3"],
    "curl` 模拟脚本逻辑过于脆弱": ["R19"],
    "default parameter uses .SingleInstanceLock.defaultFileURL": ["R13"],
    "defaultsStorage.*defaultsLock.*保护下": ["R12b", "R12c"],
    "depends on system global .AppleLanguages": ["R11"],
    "distinction between V18": ["R50", "R50b"],
    "ensure the \"teeth\" of the guard": ["P0-12"],
    "event_name.*逻辑偏差": ["P0-4"],
    "existential box": ["P0-3"],
    "expected_guard_entries.*从 9 增加到 10.*并未明确标注": ["P1-84"],
    "firstLaunch.*锁保护逻辑正确": ["P0-6", "P0-6b"],
    "from 279 to 280": ["R49"],
    "keyFailureHandler.*appTerminator.*let": ["R13b", "R13c"],
    "makeTestDefaults.*suiteName.*隔离性": ["R28"],
    "manifest_out.*未定义": ["P1-72"],
    "mktemp 调用未处理 TMPDIR 未设置": ["P2-20"],
    "moving heredoc out of": ["P1-33"],
    "must be manually verified against the actual number": ["R49"],
    "not recognized": ["P0-10", "P0-10b"],
    "old 口径未定义": ["P3-114"],
    "omitted one of these to escape detection": ["P1-36"],
    "persistentDomain.*返回 nil": ["P2-27"],
    "recordSkip": ["R39"],
    "regenerate.*跨机不稳定": ["R47"],
    "removeTestDefaults\\(testDefaults\\)": ["R26"],
    "run_gate.*got.*变量初始化为": ["P1-20"],
    "scanned == 0": ["P0-10", "P0-10b"],
    "scanned` is 0": ["P0-10", "P0-10b"],
    "skips-ledger.*argument domain.*false positives": ["R30"],
    "skips-ledger.*勘误.*误导": ["R14"],
    "strip_previous_adjudication. is fragile": ["R6"],
    "structurally vacuous on default install": ["R35"],
    "table was renamed or missing": ["P1-37"],
    "temporal paradox if the document is ever archived or viewed out of context": ["P2-48"],
    "testSuiteLookupFallsThroughToTheGlobalDomain.*XCTSkipIf": ["R29"],
    "testSuiteLookupFallsThroughToTheGlobalDomain.*dictionaryRepresentation.*trapKey": ["R29"],
    "test_review_adjudicate.sh. test 5 modifies shared repo state": ["P2-11"],
    "test_review_adjudicate\\.sh": ["P2-1", "R2"],
    "treats .EINTR": ["R2f"],
    "vacuous on default install": ["R35"],
    "without .re.MULTILINE": ["R10"],
    "上一块带标记即豁免": ["P1-38"],
    "不准确的错误提示": ["P1-20"],
    "人工核验层不可用": ["R3", "R3b"],
    "仍可能在某些极端复杂的编译器行为下产生误报": ["R42"],
    "仍漏 3 类换写法": ["R55", "R55b"],
    "使用 .mktemp -d. 落盘到 /tmp": ["P2-19", "P2-19b"],
    "依然依赖于": ["R10b"],
    "修复逻辑正确，避免了 Shell 在双引号内解析反引号导致的命令替换问题": ["R41"],
    "内置端点的处理逻辑存在重复尝试风险": ["P1-28"],
    "去重逻辑存在冗余且潜在风险": ["P1-4"],
    "双重保险": ["R8"],
    "哨兵豁免可被用来": ["R57"],
    "固定 5 元组枚举": ["R54", "R54b"],
    "复算为 9": ["R56"],
    "如果某些 View 是在.*之前就创建好的": ["P2-60"],
    "宽规则残留": ["R46"],
    "对 3 条判据无覆盖": ["R53"],
    "属于未来时间": ["P2-40"],
    "应确保 .mutation/mutate.py. 的 .expected. 字段与本轮新增的 .caught_by. 逻辑完全对齐": ["R44"],
    "必须同步更新此 SHA256": ["P1-25"],
    "恢复逻辑现在正确指向了": ["R24"],
    "扩大了捕获范围": ["P1-19"],
    "探不到版本.*硬编码为 `0.0.0`": ["P2-18"],
    "接线点": ["R68", "R68b"],
    "收紧判据会把": ["P1-39"],
    "数量写成字符类": ["R58"],
    "文档与实现一致性": ["P1-9"],
    "无法核实这 4 个点在现有代码实现中是否确实对应 4 个缺乏 XCTest 闸门的访问点": ["P0-64"],
    "时长驱动.*Duration-based.*伪绿": ["R15b"],
    "显式候选端点的去重逻辑存在严重缺陷": ["P1-6"],
    "显式候选端点（`explicit`）的排序逻辑存在缺陷": ["P1-3"],
    "标记为.*private.*与文档中提到的.*19 declarations": ["R38"],
    "正常计数表述": ["R62"],
    "此逻辑能有效识别出生产身份的 Store": ["R17"],
    "测试覆盖不足": ["R23"],
    "由于上述 P1 类逻辑缺陷": ["P1-6", "P1-9"],
    "端点不可达.*不得牵连其它端点": ["P0-2"],
    "符合项目对高确定性审计的要求": ["P2-43"],
    "第一版变异集也是": ["P1-115"],
    "缺乏上下文说明": ["P1-26"],
    "脚本本身崩溃或返回非预期值": ["P1-20"],
    "脚本注释中的 `2026-11-01` 日期可能为笔误或超前预测": ["R40"],
    "自检\\**没有\\**钉住 P1-1 的修法": ["R59"],
    "自检用例计数与源码不符": ["R52"],
    "被审两提交的 CI 是红的|本轮自己新增的守卫 step 在 GitHub macOS runner 上失败": ["R47"],
    "规则标签的形态判定": ["R65", "R65b"],
    "豁免词表 `NARROW_MARKERS` 被改动": ["R60"],
    "账本计数与实测一致性": ["R64"],
    "路径穿越修复与自指修复未包含在本次提交的 diff 窗口": ["R15"],
    "这符合逻辑": ["P1-19"],
    "需确保 .contract. 模式下的 .grep. 逻辑不会因为 .manifest. 的变动而产生干扰": ["R79"],
    "需确认 CI 工作流.*是否已同步更新以适配新的 `discover` 函数签名": ["P2-30"],
    "需确认该语法在仓库其他脚本.*中的使用是否一致": ["P1-5"],
}

def main() -> int:
    bad = []
    for cid, rel, kind, needle, desc in CHECKS:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            bad.append((cid, rel, desc, "文件不存在"))
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if kind == "count":
            n = _count(rel, needle)
            ok = n > 0
            if not ok:
                bad.append((cid, rel, desc, f"计数为 0（{needle!r}）"))
            continue
        if kind == "branch":
            ok = _in_branch(rel, needle)
            if not ok:
                bad.append((cid, rel, desc, f"不在 else 分支里（{needle!r}）"))
            continue
        if kind == "notlist":
            ok = not _wordlist_has(rel, needle)
        elif kind == "probe_nocreate":
            ok = not _probe_creates(rel, needle)
        else:
            hit = re.search(needle, text, re.M) is not None
            ok = hit if kind == "has" else (not hit)
        if not ok:
            bad.append((cid, rel, desc, f"判据不成立（{kind} {needle!r}）"))
    # ── 实跑判据 ───────────────────────────────────────────────────
    import subprocess
    import tempfile
    for cid, desc, cmd, want in RUNTIME:
        real = [c.replace("@TMPDIR@", tempfile.mkdtemp(prefix="cm-empty-")) if c == "@TMPDIR@" else c
                for c in cmd]
        proc = subprocess.run(real, cwd=REPO, capture_output=True, text=True, timeout=300)
        if proc.returncode != want:
            bad.append((cid, "（实跑）", desc, f"期望 exit {want}，实得 {proc.returncode}"))

    # ── 覆盖表：无孤儿（每条台账结论都有判据），且判据编号都存在 ───────
    known = {c[0] for c in CHECKS} | {c[0] for c in RUNTIME}
    ledger_matches = set()
    for line in open(os.path.join(REPO, "githooks/review-adjudication.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        ledger_matches.add(json.loads(line)["match"])
    for key in COVERAGE:
        if key not in ledger_matches:
            bad.append(("COVKEY", "（覆盖表）", key[:60], "覆盖表的键在台账里**不存在**（逐字比对失败）"))
    for key, ids in COVERAGE.items():
        missing = [i for i in ids if i not in known]
        if missing:
            bad.append(("COV-" + key[:20], "（覆盖表）", f"{key} ⇒ {missing}", "覆盖表引用了不存在的判据编号"))

    print(f"静态判据 {len(CHECKS)} 条 + 实跑判据 {len(RUNTIME)} 条"
          f" + 覆盖表 {len(COVERAGE)} 条结论 ⇒ 不成立 {len(bad)} 条")
    for cid, rel, desc, why in bad:
        print(f"  ❌ {cid}  {rel}  —— {desc}：{why}")
    if not bad:
        print("✅ 全部判据在**当前**文件里仍然成立")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
