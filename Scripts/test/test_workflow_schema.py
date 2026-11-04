#!/usr/bin/env python3
"""GitHub Actions workflow 的**静态 schema 守卫**（纯文本级，不依赖 PyYAML）。

背景（ID-REVIEW-1049 第十四轮，CI run `41587954678`）：`fetch-depth: 0` 被写成了
**step 级键**（应为 `with:` 的子键）⇒ ⇒ workflow schema 非法 ⇒ ⇒ GitHub 直接判定
「This run likely failed because of a workflow file issue」⇒ ⇒ **0 秒失败**，而
**YAML 本身能 parse** ⇒ ⇒ 「能 parse」≠「schema 合法」。

⇒ ⇒ 所以本守卫**不**用 YAML 解析器（那正好会把非法 schema 放过去）⇒ ⇒ 改成
**按缩进扫文本 + 递归建树**：每个 step / job / workflow 的**同级键**必须落在白名单里。

本守卫只查**键的形状**（静态、只读、不联网）：
  1. step 级出现**白名单外**的键（例：`fetch-depth:` 直接挂在 step 下）；
  2. step 有 `with:` 却没有 `uses:` / `run:`；
  3. step 同时有 `run:` 和 `uses:`；
  4. **同一个 job 内**重名 step（⇒ 后者覆盖前者，前者永远不跑且无人察觉）；
  5. job 级出现白名单外的键；
  6. workflow 级出现白名单外的键。

用法：
  python3 Scripts/test/test_workflow_schema.py            # 查 .github/workflows/
  python3 Scripts/test/test_workflow_schema.py --self-test # 自检（合成夹具）
退出码：0 = 通过；1 = 查出问题；2 = **没检查**（缺文件 ⇒ 不假装检查过）。
"""
import os
import re
import sys

WORKFLOW_DIR = os.path.join(".github", "workflows")

# 各层允许出现的键（GitHub Actions 官方 schema 的子集）。
STEP_KEYS = {
    "name", "id", "if", "uses", "run", "with", "env",
    "working-directory", "shell", "timeout-minutes", "continue-on-error",
}
JOB_KEYS = {
    "name", "runs-on", "needs", "permissions", "if", "environment",
    "concurrency", "container", "services", "strategy", "defaults", "env",
    "outputs", "steps", "timeout-minutes", "continue-on-error",
    "uses", "with", "secrets",
}
WORKFLOW_KEYS = {
    "name", "on", "env", "defaults", "concurrency", "jobs", "permissions",
    "run-name",
}

_BLOCK_SCALAR = re.compile(r"(?:\||>)[-+]?\d*$")


def scan(lines):
    """把 YAML 文本扫成 [(indent, is_seq, key, value)]；块标量正文被跳过。"""
    entries = []
    skip_indent = None
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if skip_indent is not None:
            if indent > skip_indent:
                continue
            skip_indent = None
        is_seq = stripped.startswith("- ")
        body = stripped[2:].strip() if is_seq else stripped
        if is_seq:
            indent += 2
        if ":" not in body:
            continue
        key, _, value = body.partition(":")
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        entries.append((indent, is_seq, key, value))
        if _BLOCK_SCALAR.search(value) and not value.strip("|>").strip():
            skip_indent = indent
    return entries


def build(entries, index, indent):
    """递归建树。

    返回 (node, next_index)。
    node = {"kind": "map", "pairs": [(key, value, child_or_None)]}
         | {"kind": "seq", "items": [{"pairs": [...]}, ...]}
    """
    if index < len(entries) and entries[index][1] and entries[index][0] == indent:
        items = []
        while index < len(entries) and entries[index][1] and entries[index][0] == indent:
            # ⚠️ scan() 里已经把序列项的缩进 +2 了（`- name:` 的键列）⇒ ⇒
            # 它的**同级 map 键**记录下来的缩进**就是** indent ⇒ ⇒ 这里不能再 +2
            # （多 +2 一次 ⇒ ⇒ 键全被丢掉 ⇒ ⇒ step 层整层检查静默失效）。
            item_indent = indent
            pairs = [(entries[index][2], entries[index][3])]
            index += 1
            while (index < len(entries) and not entries[index][1]
                   and entries[index][0] == item_indent):
                pairs.append((entries[index][2], entries[index][3]))
                index += 1
            built = [[key, value, None] for key, value in pairs]
            # 子块（缩进更深）属于**最后一个「空值键」**（例：`- name: x` + `with:`）。
            if index < len(entries) and entries[index][0] > item_indent:
                target = None
                for pos in range(len(built) - 1, -1, -1):
                    if built[pos][1] == "":
                        target = pos
                        break
                if target is not None:
                    child, index = build(entries, index, entries[index][0])
                    built[target][2] = child
            items.append({"pairs": [tuple(item) for item in built]})
        return {"kind": "seq", "items": items}, index

    pairs = []
    while (index < len(entries) and not entries[index][1]
           and entries[index][0] == indent):
        key, value = entries[index][2], entries[index][3]
        index += 1
        child = None
        # ⚠️ 子块**可能是序列**（`steps:` 后面就是 `- name: …`）⇒ ⇒ 不能只认 map。
        if index < len(entries) and entries[index][0] > indent:
            child, index = build(entries, index, entries[index][0])
        pairs.append((key, value, child))
    return {"kind": "map", "pairs": pairs}, index


def _children(node, key):
    for name, _value, child in node.get("pairs", []):
        if name == key:
            return child
    return None


def _keys(node):
    return [name for name, _value, _child in node.get("pairs", [])]


def check_text(text):
    """检查一段 workflow 文本 ⇒ 返回问题列表。"""
    entries = scan(text.splitlines())
    if not entries:
        return []
    root, _ = build(entries, 0, entries[0][0])
    problems = []

    for key in _keys(root):
        if key not in WORKFLOW_KEYS:
            problems.append(f"workflow 级出现非法键：{key}")

    jobs = _children(root, "jobs")
    if jobs and jobs.get("kind") == "map":
        for job_name, _value, job_node in jobs["pairs"]:
            if job_node is None:
                continue
            for key in _keys(job_node):
                if key not in JOB_KEYS:
                    problems.append(f"job `{job_name}` 级出现非法键：{key}")
            steps = _children(job_node, "steps")
            if not steps or steps.get("kind") != "seq":
                continue
            seen = {}
            for item in steps["items"]:
                keys = _keys(item)
                for key in keys:
                    if key not in STEP_KEYS:
                        problems.append(
                            f"job `{job_name}` 的 step 级出现非法键：{key}"
                            "（像 `fetch-depth:` 这种必须放进 `with:` 的子键）"
                        )
                if "with" in keys and "uses" not in keys and "run" not in keys:
                    problems.append(
                        f"job `{job_name}` 的 step 有 `with:` 却没有 `uses:` / `run:`"
                    )
                if "run" in keys and "uses" in keys:
                    problems.append(f"job `{job_name}` 的 step 同时有 `run:` 和 `uses:`")
                label = None
                for key, value, _child in item["pairs"]:
                    if key in ("name", "uses", "run") and value:
                        label = value
                        break
                if label:
                    if label in seen:
                        problems.append(
                            f"job `{job_name}` 内**重名 step**：`{label[:60]}`"
                        )
                    else:
                        seen[label] = True
    return problems


def check_repo(root="."):
    directory = os.path.join(root, WORKFLOW_DIR)
    if not os.path.isdir(directory):
        print(f"❌ 找不到 {directory} ⇒ **未检查**（不假装检查过）", file=sys.stderr)
        return 2, []
    names = sorted(n for n in os.listdir(directory) if n.endswith((".yml", ".yaml")))
    if not names:
        print(f"❌ {directory} 里没有 workflow ⇒ **未检查**", file=sys.stderr)
        return 2, []
    problems = []
    for name in names:
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        problems.extend(f"{name}: {item}" for item in check_text(text))
    if problems:
        print(f"❌ workflow schema 守卫：{len(names)} 个 workflow 文件，"
              f"{len(problems)} 个非法项")
        for item in problems:
            print(f"    {item}")
        return 1, problems
    print(f"✅ workflow schema 守卫：{len(names)} 个 workflow 文件，0 个非法项")
    return 0, problems


SELF_TEST_CASES = [
    (
        "非法 step 级键（fetch-depth 直接挂在 step 下）",
        "name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - name: checkout\n        uses: actions/checkout@v4\n        fetch-depth: 0\n",
        1,
    ),
    (
        "with: 没有 uses:/run:",
        "name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - name: x\n        with:\n          a: b\n",
        1,
    ),
    (
        "run: 与 uses: 并存",
        "name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - name: x\n        uses: actions/checkout@v4\n        run: echo hi\n",
        1,
    ),
    (
        "同 job 内重名 step",
        "name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - name: same\n        run: echo a\n      - name: same\n        run: echo b\n",
        1,
    ),
    (
        "job 级非法键",
        "name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    fetch-depth: 0\n"
        "    steps:\n      - name: x\n        run: echo hi\n",
        1,
    ),
    (
        "workflow 级非法键",
        "name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - name: x\n        run: echo hi\nbadkey: 1\n",
        1,
    ),
    (
        "正常 workflow（不得误报）",
        "name: ci\non: push\npermissions:\n  contents: read\njobs:\n  build:\n"
        "    runs-on: ubuntu-latest\n    steps:\n      - name: checkout\n"
        "        uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n"
        "      - name: run\n        run: echo hi\n",
        0,
    ),
    (
        "多 job + 块标量（不得误报）",
        "name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - name: script\n        run: |\n          echo hi\n          key: not-a-step-key\n"
        "  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: y\n        run: echo y\n",
        0,
    ),
]


def self_test():
    failures = 0
    for label, text, expected in SELF_TEST_CASES:
        found = check_text(text)
        if len(found) == expected:
            print(f"✅ {label}")
        else:
            failures += 1
            print(f"❌ {label}：期望 {expected} 个问题，实得 {len(found)} ⇒ {found}")
    print(f"自检断言数：{len(SELF_TEST_CASES)}")
    if failures:
        print(f"❌ workflow schema 守卫自检有 {failures} 项失败", file=sys.stderr)
        return 1
    print("✅ workflow schema 守卫自检全部通过")
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()
    code, _problems = check_repo(".")
    return code


if __name__ == "__main__":
    sys.exit(main())
