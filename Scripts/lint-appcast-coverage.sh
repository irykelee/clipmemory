#!/usr/bin/env bash
# Scripts/lint-appcast-coverage.sh
# ID-CRASH-0013 (2026-09-28 code-review P2-14): prevents "appcast
# missing a published tag" from accumulating silently. Code-review
# 2026-09-28 documented this exact drift: 33 appcast items vs 33
# git tags, diff included 2.7.1, 2.9.2, 2.9.3 (different counts
# canceling the diff in their naive form, hiding the missing
# entries). Without this assertion, the next release would push
# appcast skipping some tag (auto-review 20260926 found appcast
# missing 2.7.1, 2.9.2, 2.9.3 — same class of drift).
#
# Two checks:
#   1. Every git tag vX.Y.Z >= v2.5.0 (or whitelisted) must
#      appear as an <item> in appcast.xml. Fail CI otherwise.
#   2. (Reverse) every <item> in appcast.xml must have a
#      matching git tag. Catches typos / orphan items.
#
# Whitelist: two layers.
#   a) Tags before v2.5.0 — pre-appcast-rollout (STATUS.md L132,
#      "Casks/clipmemory.rb 停在 2.5.10" + "package.sh:93-112
#      已记录为有意保留").
#   b) Explicit per-tag whitelist with a justification. Three
#      tags need this as of 2026-09-28:
#        - 2.7.1: yanked before appcast-push landed (per STATUS.md
#          "v2.7.1 yank + v2.7.2" P0-2 entry). The tag exists for
#          archaeology but no Sparkle feed entry was published.
#        - 2.9.2: shipped but appcast push silently dropped (per
#          code-review 2026-09-28 P2-14 + auto-review 20260926).
#          This should be back-filled into appcast separately;
#          for now whitelist so the lint can pass.
#        - 2.9.3: shipped but appcast push silently dropped (same
#          reason as 2.9.2). Same fix plan.
#      When these back-fills land, remove the whitelist entries.
#
# Usage: Scripts/lint-appcast-coverage.sh
# Wired into ci.yml lint-ids job (per ID-CRASH-0013).
#
# bash compat: stock macOS /bin/bash 3.2 lacks `declare -A` (associative
# arrays) and `mapfile`/`readarray` (bash 4.0+). ID-CI-0024 (2026-11-08):
# this script used `mapfile` ⇒ it **died instantly on macOS** ("mapfile:
# command not found") while CI (ubuntu bash 5) stayed green ⇒ the old
# "the portable form is identical" claim here was **false**. Now it uses
# `declare -a` indexed arrays + `while read` (bash 3.2 compatible), and
# the empty-array-safe expansion "${arr[@]+"${arr[@]}"}" (bash 3.2 + set -u
# treats "${arr[@]}" on an empty array as unbound).
# Mirrors the convention from Scripts/lint-release-yml.sh and
# Scripts/lint-tsan-filter.sh.
# Guarded by Scripts/test/test_bash32_compat.py (ID-CI-0024).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

APPCAST="$ROOT/appcast.xml"
WHITELIST_MIN_VERSION="v2.5.0"  # appcast-rollout boundary

# ID-CI-0024 (2026-11-08)：版本**必须**按数值比，不能按字符串比。
#
# ⇒ ⇒ 原来的 `[[ "v${tag}" < "${WHITELIST_MIN_VERSION}" ]]` 是**字典序** ⇒ ⇒
# ⇒ ⇒ ⇒ "v2.10.0" 的第二个字符段是 "1" ⇒ ⇒ ⇒ ⇒ 字典序里 "1" < "5" ⇒ ⇒ ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ **v2.10.0 会被当成「早于 rollout 边界」而跳过** ⇒ ⇒ ⇒ ⇒ ⇒ 下一个
# ⇒ ⇒ ⇒ ⇒ 正式版（v2.10.0）一旦打 tag，**这个 lint 就不再检查它** ⇒ ⇒ ⇒ ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ 覆盖率**静默丢失**。beta 这次是它的**先兆**（见下）。
version_ge() {
  # version_ge <a> <b> ⇒ 真 ⇔ a >= b（数值；忽略 -beta.N 后缀）
  local v1="${1#v}" v2="${2#v}"
  v1="${v1%%-*}"; v2="${v2%%-*}"
  local oldifs="$IFS"
  IFS='.'
  local -a A=($v1)
  local -a B=($v2)
  IFS="$oldifs"
  local n=${#A[@]}
  [[ ${#B[@]} -gt $n ]] && n=${#B[@]}
  local i=0 x y
  for ((i = 0; i < n; i++)); do
    x="${A[$i]:-0}"; y="${B[$i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 0
}

# ID-CRASH-0013 (2026-09-28): explicit per-tag whitelist.
# Update this list when an intentionally-missing tag gets
# back-filled into appcast.xml (the fix should be: remove the
# entry here, add the <item> in appcast.xml, re-run the lint).
INTENTIONAL_WHITELIST=(
  "v2.7.1: yanked before appcast-push landed (STATUS.md L39 P0-2)"
  "v2.9.2: shipped but appcast push silently dropped (code-review P2-14)"
  "v2.9.3: shipped but appcast push silently dropped (code-review P2-14)"
)

# ID-CI-0024 (2026-11-08)：`mapfile`/`readarray` 是 **bash 4.0+** 才有的内建 ⇒
# 股票 macOS 的 `/bin/bash` 3.2 上**这个脚本会直接死掉**（"mapfile: command
# not found"）⇒ ⇒ 而脚本头部却写着「the portable form is identical」⇒ ⇒
# **头部注释是假的**（CI 跑在 ubuntu ⇒ bash 5 ⇒ 一直绿 ⇒ 没人发现）。
# ⇒ ⇒ 改成 `while read` 收集（bash 3.2 可跑）。
# ⚠️ bash 3.2 + `set -u` 下**空数组**的 "${arr[@]}" 会报 unbound variable
# （bash 4.4 才修）⇒ ⇒ 所以下面所有数组展开都写成 "${arr[@]+"${arr[@]}"}"。
declare -a git_tags_stripped=() appcast_versions_stripped=()

# ID-CI-0024 (2026-11-08)：两条正则都**必须认得 beta 后缀**。
# ⇒ ⇒ 原来 appcast URL 的正则是 `releases/download/v[0-9]+\.[0-9]+(\.[0-9]+)?`
# ⇒ ⇒ ⇒ 它在 `releases/download/v2.10.0-beta.1/…` 上**只匹配到 v2.10.0**
# ⇒ ⇒ ⇒ ⇒ 截断了 `-beta.1` ⇒ ⇒ ⇒ ⇒ appcast 里凭空多出一个**不存在的**
# ⇒ ⇒ ⇒ ⇒ 「v2.10.0 条目」⇒ ⇒ ⇒ ⇒ 而仓库里没有 v2.10.0 这个 tag ⇒ ⇒ ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 报「appcast.xml item v2.10.0 has no matching git tag」
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **假阳性**（beta 条目本身完全正确）⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 本轮 CI 的 lint-ids 就是被它弄红的。
# ⇒ ⇒ ⇒ ⇒ 而 tag 侧的正则**不认** beta ⇒ ⇒ ⇒ ⇒ beta tag 被整体排除 ⇒ ⇒ ⇒ ⇒
# ⇒ ⇒ ⇒ ⇒ 覆盖也被悄悄丢掉了一格。
VERSION_PATTERN='[0-9]+\.[0-9]+(\.[0-9]+)?(-beta\.[0-9]+)?'

while IFS= read -r _tag; do
  git_tags_stripped+=("${_tag#v}")
done < <(git tag --list | grep -E "^v${VERSION_PATTERN}\$" | sort -u | sed 's/^v//' | sort -u)

while IFS= read -r _ver; do
  appcast_versions_stripped+=("${_ver#v}")
done < <(
  grep -oE "releases/download/v${VERSION_PATTERN}" "$APPCAST" \
    | sed 's|releases/download/||' \
    | sort -u \
    | sed 's/^v//' \
    | sort -u
)

violations=0
declare -a violation_msgs=()

for tag in "${git_tags_stripped[@]+"${git_tags_stripped[@]}"}"; do
  # Skip pre-rollout tags (v2.5.0 was the rollout boundary)
  # ⚠️ 必须用**数值**比较（ID-CI-0024）—— 字典序会把 v2.10.0 判成 < v2.5.0
  if ! version_ge "v${tag}" "${WHITELIST_MIN_VERSION}"; then
    continue
  fi
  # Skip explicitly whitelisted tags (with documented justification)
  whitelisted=0
  for entry in "${INTENTIONAL_WHITELIST[@]}"; do
    entry_tag="${entry%%:*}"
    if [[ "v${tag}" == "${entry_tag}" ]]; then
      whitelisted=1
      break
    fi
  done
  if [[ "$whitelisted" -eq 1 ]]; then
    continue
  fi
  # Check if tag is in appcast
  found=0
  for appcast_v in "${appcast_versions_stripped[@]+"${appcast_versions_stripped[@]}"}"; do
    if [[ "$tag" == "$appcast_v" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    violations=$((violations + 1))
    violation_msgs+=("git tag v${tag} is missing from appcast.xml")
  fi
done

for appcast_v in "${appcast_versions_stripped[@]+"${appcast_versions_stripped[@]}"}"; do
  found=0
  for tag in "${git_tags_stripped[@]+"${git_tags_stripped[@]}"}"; do
    if [[ "$tag" == "$appcast_v" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    violations=$((violations + 1))
    violation_msgs+=("appcast.xml item v${appcast_v} has no matching git tag")
  fi
done

if [[ "$violations" -gt 0 ]]; then
  echo ""
  echo "FAIL: appcast/tag coverage drift detected"
  echo ""
  echo "Why this matters:"
  echo "  - v2.9.3 shipped appcast.xml WITHOUT pushing the tag"
  echo "    because the Release workflow's appcast-push substep was"
  echo "    swallowed (auto-review 20260926 / STATUS.md L77)."
  echo "  - This lint prevents the next occurrence: any future"
  echo "    release that adds a git tag without an appcast item,"
  echo "    or vice versa, fails CI at lint-ids time (before"
  echo "    release)."
  echo ""
  echo "Violations (${violations}):"
  for msg in "${violation_msgs[@]+"${violation_msgs[@]}"}"; do
    echo "  - ${msg}"
  done
  echo ""
  echo "Fix: either remove the orphaned git tag (carefully only if"
  echo "the release was never actually published) or add the"
  echo "missing <item> entry to appcast.xml. The appcast.xml entry"
  echo "must be inside a <channel> wrapped in an <rss> with the"
  echo "sparkle namespace declared (see existing items for the"
  echo "shape)."
  exit 1
fi

echo "PASS: appcast/tag coverage in sync (${#git_tags_stripped[@]} git tags >= v2.5.0, ${#appcast_versions_stripped[@]} appcast items)"
