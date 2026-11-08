#!/usr/bin/env bash
#
# Scripts/lint-readme-glossary.sh — DOC-0003：每个 README 只许出现**自己语种**的
# 「回收站」词，不许出现别国语言的那个。
#
# ID-CI-0024 (2026-11-08)：这个检查以前**从来没有真正运行过**。
#
#   它原来内联在 .github/workflows/ci.yml 的 build-and-test 台阶里，用
#   `declare -A EXPECTED_TRASH=(["README.md"]="回收站" …)`。那个台阶跑在
#   **macos-latest** ⇒ 系统的 `/bin/bash` 是 **3.2** ⇒ **没有关联数组** ⇒
#   bash 3.2 把 `["README.md"]` 当**算术表达式**解析 ⇒ 语法错误 ⇒
#   **7 个元素被静默丢弃**（`declare` 整体仍返回 0 ⇒ `set -e` 抓不到）⇒
#   数组为空 ⇒ 两个 `for file in "${!EXPECTED_TRASH[@]}"` 循环**一次都不跑**
#   ⇒ 台阶照样打印「✅ Trash glossary consistent across all 7 locales」
#   ⇒ ⇒ **假绿**（查了 0 个文件，却声称查了 7 个）。
#
#   证据（不是推测）：同一段代码
#     - `/bin/bash`（3.2）：`FILES_CHECKED=0 FAILS=0` ⇒ 空转
#     - `/opt/homebrew/bin/bash`（5.3）：`FILES_CHECKED=7 FAILS=1` ⇒ **抓到了
#       README.md 里真实的英文术语污染**（"Trash tab"）
#   ⇒ ⇒ 差异**全在 shell 版本**，不在检查逻辑 ⇒ ⇒ **两个坑叠在一起**：
#   ① 检查没跑 ② 它本该抓到的真违规也确实存在。
#
# bash 3.2 兼容（与 Scripts/lint-appcast-coverage.sh / lint-release-yml.sh /
# lint-tsan-filter.sh 同一约定）：
#   - 不用 `declare -A` / `declare -g` / `mapfile` / `${var,,}`
#   - 清单用 **竖线分隔的文本文件**（文件与期望词**相邻** ⇒ 不会像平行数组
#     那样错位；也不用 tab，避免 YAML/编辑器把它吃掉）
#   - `while … read` 走**重定向**（不是管道）⇒ 计数不丢
#
# 三条**不变量**（防「假绿」复发）：
#   A. 清单不能为空 ⇒ 空清单 = 循环零次 = 必须报错，不是通过
#   B. 清单里的每个文件必须**存在** ⇒ 文件被改名/删掉 = 报错，不是跳过
#   C. 仓库里的每个 README（根 README.md + docs/lang/README_*.md）必须在
#      清单里 ⇒ **少扫了** = 报错（新语种必须显式声明自己的「回收站」词）
#
# 用法：
#   Scripts/lint-readme-glossary.sh                      # 检查仓库
#   Scripts/lint-readme-glossary.sh --root DIR --manifest FILE
#   Scripts/lint-readme-glossary.sh --self-test          # 合成语料自检
#
# seam（供自检用）：
#   CM_GLOSSARY_ROOT      仓库根（默认 git toplevel）
#   CM_GLOSSARY_MANIFEST  清单文件（默认内嵌的 7 行）
#
set -euo pipefail

ROOT_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

ALL_CJK="回收站 垃圾桶 ごみ箱 휴지통"
ALL_WESTERN="Trash Papelera Lixeira"

# ---- 默认清单：7 个语种（根 README 是简体中文）--------------------------
print_default_manifest() {
  cat <<'EOF'
README.md|回收站
docs/lang/README_ZH-HANT.md|垃圾桶
docs/lang/README_EN.md|Trash
docs/lang/README_JA.md|ごみ箱
docs/lang/README_KO.md|휴지통
docs/lang/README_ES.md|Papelera
docs/lang/README_PT.md|Lixeira
EOF
}

# 清单里有没有这个文件（精确比较第 1 列，不用正则 ⇒ 路径里的 `.` 不会被当通配）
manifest_has_file() {
  local manifest="$1" key="$2"
  awk -F'|' -v k="$key" '$1 == k { found = 1 } END { exit(found ? 0 : 1) }' "$manifest"
}

# ---- 核心检查 ----------------------------------------------------------
# 用法：check_glossary <manifest> <root>
# 打印 ❌ 行；返回 0 = 干净，1 = 有违规 / 有不变量被破坏
check_glossary() {
  local manifest="$1" root="$2"
  local checked=0 fails=0
  local file expected term pattern cand

  while IFS='|' read -r file expected; do
    [[ -n "$file" ]] || continue
    checked=$((checked + 1))

    # 不变量 B：清单里的文件必须存在（否则 grep 会静默跳过 ⇒ 假绿）
    if [[ ! -f "$root/$file" ]]; then
      echo "❌ manifest lists '$file' but that file does not exist (跳过了检查 = 假绿, ID-CI-0024)"
      fails=$((fails + 1))
      continue
    fi

    for term in $ALL_CJK; do
      if [[ "$term" != "$expected" ]] && grep -qF "$term" "$root/$file" 2>/dev/null; then
        echo "❌ $file contains foreign Trash term '$term' (expected '$expected' for this locale)"
        fails=$((fails + 1))
      fi
    done

    for term in $ALL_WESTERN; do
      if [[ "$term" != "$expected" ]]; then
        # 词边界代理：避免命中 TrashStore / moveToTrash / trash.json 这类标识符
        pattern="(^|[^A-Za-z0-9_.])${term}([^A-Za-z0-9_.]|$)"
        if grep -qiE "$pattern" "$root/$file" 2>/dev/null; then
          echo "❌ $file contains foreign Trash term '$term' as standalone word (expected '$expected')"
          fails=$((fails + 1))
        fi
      fi
    done

    if grep -qiF "Recycle Bin" "$root/$file" 2>/dev/null; then
      echo "❌ $file contains legacy 'Recycle Bin' annotation (should use local Trash term)"
      fails=$((fails + 1))
    fi
  done < "$manifest"

  # 不变量 A：清单为空 = 循环零次 = 假绿 ⇒ 必须报错
  if [[ "$checked" -eq 0 ]]; then
    echo "❌ manifest is empty — the check would run zero times and pass vacuously (ID-CI-0024)"
    fails=$((fails + 1))
  fi

  # 不变量 C：仓库里的每个 README 都必须在清单里（少扫了 = 假绿）
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    if ! manifest_has_file "$manifest" "$cand"; then
      echo "❌ $cand is a README in this repo but is NOT in the manifest (少扫了 = 假绿, ID-CI-0024)"
      fails=$((fails + 1))
    fi
  done < <(
    if [[ -f "$root/README.md" ]]; then echo "README.md"; fi
    if [[ -d "$root/docs/lang" ]]; then
      find "$root/docs/lang" -maxdepth 1 -type f -name 'README_*.md' 2>/dev/null | while IFS= read -r p; do
        echo "${p#"$root/"}"
      done
    fi
  )

  if [[ "$fails" -eq 0 ]]; then
    echo "✅ Trash glossary consistent across all ${checked} locales (zh-Hans/zh-Hant/en/ja/ko/es/pt)"
    return 0
  fi
  echo "❌ README Trash glossary check FAILED (${fails} problem(s), ${checked} file(s) checked)"
  return 1
}

# ---- 自检 --------------------------------------------------------------
# 用**合成语料**证明每条规则真的会报红（含「假绿」那几条）。
# 关键：自检用 /bin/bash 跑（macOS 上就是 **3.2**）⇒ 与 CI 的真实 shell 一致。
selftest() {
  # ⚠️ `tmp` 必须是**全局**的：EXIT trap 在函数栈退出后才跑 ⇒ 用局部变量
  # 会在 trap 里变成 unbound variable（并把退出码改成 1）
  SELFTEST_TMP="$(mktemp -d)"
  local tmp="$SELFTEST_TMP"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT

  local sb="${CM_SELFTEST_BASH:-}"
  if [[ -z "$sb" ]]; then
    if [[ -x /bin/bash ]]; then sb=/bin/bash; else sb="${BASH:-bash}"; fi
  fi

  local passes=0
  local fixture="$tmp/fx"

  # 造一份「干净」的两语种语料
  build_fixture() {
    rm -rf "$fixture"
    mkdir -p "$fixture/docs/lang"
    printf '# 中文\n回收站可以恢复条目。\n' > "$fixture/README.md"
    printf '# English\nTrash items can be restored.\n' > "$fixture/docs/lang/README_EN.md"
  }

  expect_exit() {
    local want="$1" label="$2"
    shift 2
    local got=0
    if "$sb" "$0" "$@" > "$tmp/out.txt" 2>&1; then got=0; else got=$?; fi
    if [[ "$got" -eq "$want" ]]; then
      passes=$((passes + 1))
      echo "  ✅ $label (exit=$got)"
    else
      echo "  ❌ $label — expected exit $want, got $got"
      cat "$tmp/out.txt"
      return 1
    fi
  }

  local man="$tmp/manifest.txt"
  printf 'README.md|回收站\ndocs/lang/README_EN.md|Trash\n' > "$man"

  # ⚠️ 注意：`${sb}` 的花括号**不是**多余的 —— 后面的 `）` 是多字节字符，
  # 写成 `$sb）` 会让 bash 把变量名解析成 `sb）` ⇒ unbound variable
  # （本项目已踩 4 次，见 Scripts/test/test_shell_multibyte_var_boundary.py）
  echo "== lint-readme-glossary.sh 自检（shell=${sb}）=="

  build_fixture
  expect_exit 0 "干净语料通过" --root "$fixture" --manifest "$man"

  build_fixture
  printf '回收站可以恢复。垃圾桶页签也支持多选。\n' >> "$fixture/README.md"
  expect_exit 1 "中文 README 里的外文词被抓住" --root "$fixture" --manifest "$man"

  build_fixture
  printf 'Trash items can be restored. 回收站也在用。\n' >> "$fixture/docs/lang/README_EN.md"
  expect_exit 1 "英文 README 里的外文词被抓住" --root "$fixture" --manifest "$man"

  build_fixture
  printf 'Papelera is the Spanish word.\n' >> "$fixture/docs/lang/README_EN.md"
  expect_exit 1 "独立成词的西文术语被抓住" --root "$fixture" --manifest "$man"

  build_fixture
  printf 'TrashStore and moveToTrash are identifiers.\n' >> "$fixture/docs/lang/README_EN.md"
  expect_exit 0 "标识符里的 Trash 不算污染" --root "$fixture" --manifest "$man"

  build_fixture
  printf 'Recycle Bin was the old name.\n' >> "$fixture/README.md"
  expect_exit 1 "遗留 'Recycle Bin' 被抓住" --root "$fixture" --manifest "$man"

  # ↓↓↓ ID-CI-0024 的直接回归守卫：空清单必须报错，不能假绿 ↓↓↓
  : > "$tmp/empty.txt"
  build_fixture
  expect_exit 1 "空清单报错（不空转通过）" --root "$fixture" --manifest "$tmp/empty.txt"

  # 清单里的文件不存在 ⇒ 报错（不能静默跳过）
  printf 'README.md|回收站\ndocs/lang/README_MISSING.md|Trash\n' > "$tmp/missing.txt"
  build_fixture
  expect_exit 1 "清单里的文件不存在时报错" --root "$fixture" --manifest "$tmp/missing.txt"

  # 仓库里的 README 没进清单 ⇒ 报错（少扫了）
  build_fixture
  printf '# Français\nCorbeille.\n' > "$fixture/docs/lang/README_FR.md"
  expect_exit 1 "清单漏掉的 README 报错（少扫了）" --root "$fixture" --manifest "$man"

  echo "== 自检结果：${passes}/9 =="
  [[ "$passes" -eq 9 ]]
}

# ---- 入口 --------------------------------------------------------------
ROOT_ARG="${CM_GLOSSARY_ROOT:-$ROOT_DEFAULT}"
MANIFEST_ARG="${CM_GLOSSARY_MANIFEST:-}"
SELFTEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_ARG="$2"
      shift 2
      ;;
    --manifest)
      MANIFEST_ARG="$2"
      shift 2
      ;;
    --self-test)
      SELFTEST=1
      shift
      ;;
    -h|--help)
      echo "usage: $0 [--root DIR] [--manifest FILE] [--self-test]"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo "usage: $0 [--root DIR] [--manifest FILE] [--self-test]" >&2
      exit 2
      ;;
  esac
done

if [[ "$SELFTEST" -eq 1 ]]; then
  selftest
  exit $?
fi

if [[ -z "$MANIFEST_ARG" ]]; then
  MANIFEST_ARG="$(mktemp)"
  trap 'rm -f "$MANIFEST_ARG"' EXIT
  print_default_manifest > "$MANIFEST_ARG"
fi

check_glossary "$MANIFEST_ARG" "$ROOT_ARG"
