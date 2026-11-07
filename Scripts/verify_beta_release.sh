#!/usr/bin/env bash
# ID-BETA-0001：**beta 发版的端到端验收**（把 docs/BETA_CHANNEL.md §六 的清单机械化）
#
# 用法：
#     bash Scripts/verify_beta_release.sh v2.10.0-beta.1
#     bash Scripts/verify_beta_release.sh v2.10.0-beta.1 --appcast /path/to/appcast.xml
#     bash Scripts/verify_beta_release.sh --self-test
#
# 它验四件事（每件都有**可复算的证据**）：
#   ① appcast 里**确实有**这个 beta 条目，且带 `<sparkle:channel>beta</sparkle:channel>`
#   ② 该条目的 `<sparkle:version>` = 完整版本，`<sparkle:shortVersionString>` = base 版本
#   ③ **稳定条目仍在**（beta 不是替换，是新增）
#   ④ GitHub Release 标了 **prerelease**，且 **Homebrew tap 没有**被改成 beta 版本
#      ⇒ ⇒ ⇒ ⇒ 「brew 用户不该拿到 beta」这条保证**可验证**
#
# 退出码：0 = 全部通过；1 = 有检查没过；2 = 环境/输入问题（⇒ 不假装检查过）

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_REPO="${GH_REPO:-irykelee/clipmemory}"
TAP_REPO="${TAP_REPO:-irykelee/homebrew-clipmemory}"

FAILS=0
fail() { echo "  ❌ $*"; FAILS=$((FAILS + 1)); }
ok()   { echo "  ✅ $*"; }
note() { echo "ℹ️  $*"; }

# ── 纯函数：从 appcast XML 里取出「某个通道的所有条目」 ──────────────────
# ⇒ ⇒ 抽成纯函数 ⇒ ⇒ 单元可测（--self-test 用合成夹具）
beta_items() {
    # 用 python 解析（避免 grep 处理多行 XML 的坑）
    python3 - "$1" "$2" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
channel = sys.argv[2]
items = re.findall(r"<item>(.*?)</item>", xml, re.S)
for it in items:
    m = re.search(r"<sparkle:channel>(.*?)</sparkle:channel>", it, re.S)
    if m and m.group(1).strip() == channel:
        ver = re.search(r"<sparkle:version>(.*?)</sparkle:version>", it, re.S)
        short = re.search(r"<sparkle:shortVersionString>(.*?)</sparkle:shortVersionString>", it, re.S)
        print(f"{ver.group(1).strip() if ver else ''}\t{short.group(1).strip() if short else ''}")
PY
}

default_items() {
    python3 - "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
items = re.findall(r"<item>(.*?)</item>", xml, re.S)
for it in items:
    if not re.search(r"<sparkle:channel>", it):
        ver = re.search(r"<sparkle:version>(.*?)</sparkle:version>", it, re.S)
        print(ver.group(1).strip() if ver else "")
PY
}

self_test() {
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    local appcast="$WORK_DIR/appcast.xml"
    cat > "$appcast" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>Version 2.10.0-beta.1</title>
      <sparkle:shortVersionString>2.10.0</sparkle:shortVersionString>
      <sparkle:version>2.10.0-beta.1</sparkle:version>
      <sparkle:channel>beta</sparkle:channel>
    </item>
    <item>
      <title>Version 2.9.6</title>
      <sparkle:shortVersionString>2.9.6</sparkle:shortVersionString>
      <sparkle:version>2.9.6</sparkle:version>
    </item>
  </channel>
</rss>
EOF
    local out; out=$(beta_items "$appcast" beta)
    if [[ "$out" == "2.10.0-beta.1"$'\t'"2.10.0" ]]; then
        ok "合成夹具：beta 条目解析出（版本 / shortVersion）"
    else
        fail "合成夹具解析不对：$out"
    fi
    local stable; stable=$(default_items "$appcast")
    if [[ "$stable" == "2.9.6" ]]; then
        ok "合成夹具：稳定条目（无 channel）与 beta 条目**分开**解析"
    else
        fail "合成夹具：稳定条目解析不对：$stable"
    fi
    if [[ $FAILS -eq 0 ]]; then
        echo "✅ 自检通过：appcast 的 beta / 稳定条目解析**可复算**"
        return 0
    fi
    echo "❌ 自检失败：$FAILS 处"
    return 1
}

# ── 主流程 ────────────────────────────────────────────────────────────
VERSION=""
APPCAST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-test) self_test; exit $? ;;
        --appcast)
            APPCAST="${2:-}"
            [[ -n "$APPCAST" ]] || { echo "❌ --appcast 后面要跟路径" >&2; exit 2; }
            shift 2 ;;
        v*)          VERSION="${1#v}"; shift ;;
        *)           echo "❌ 未知参数：$1" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "用法：$0 vX.Y.Z-beta.N [--appcast <路径>]" >&2
    exit 2
fi
BASE_VERSION="${VERSION%%-beta.*}"
case "$VERSION" in
    *-beta.*) ;;
    *) echo "❌ 这不是 beta 版本号：${VERSION}（应形如 2.10.0-beta.1）" >&2; exit 2 ;;
esac

echo "=== beta 发版验收：v${VERSION} ==="

# ① appcast
if [[ -z "$APPCAST" ]]; then
    APPCAST="$(mktemp -t cm-appcast).xml"
    if ! gh api "repos/${API_REPO}/contents/appcast.xml" -q '.content' 2>/dev/null \
        | base64 -d > "$APPCAST" 2>/dev/null; then
        echo "❌ 取不到 appcast.xml（gh api 失败？⇒ ⇒ 不假装检查过）" >&2
        exit 2
    fi
    note "appcast 取自 ${API_REPO} 的 main"
fi

items=$(beta_items "$APPCAST" beta)
if [[ -z "$items" ]]; then
    fail "appcast 里**没有** channel=beta 的条目 ⇒ ⇒ 这次 beta 根本没进 beta 通道"
else
    ok "appcast 里有 channel=beta 的条目"
    if echo "$items" | grep -q "^${VERSION}"; then
        ok "beta 条目的 version = ${VERSION}"
    else
        fail "appcast 的 beta 条目里没有 ${VERSION}（现有：$(echo "$items" | tr '\n' ' '))"
    fi
    if echo "$items" | grep "^${VERSION}" | grep -q "$(printf '\t')${BASE_VERSION}$"; then
        ok "beta 条目的 shortVersionString = ${BASE_VERSION}（Sparkle 显示用）"
    else
        fail "beta 条目的 shortVersionString 不是 ${BASE_VERSION}"
    fi
fi

# ③ 稳定条目仍在
if [[ -n "$(default_items "$APPCAST")" ]]; then
    ok "稳定条目仍在（beta 是新增，不是替换）"
else
    fail "稳定条目**不见了** ⇒ ⇒ beta 不该影响默认通道"
fi

# ④ GitHub Release 标 prerelease
if gh api "repos/${API_REPO}/releases/tags/v${VERSION}" -q '.prerelease' 2>/dev/null | grep -q true; then
    ok "GitHub Release 标了 prerelease"
else
    fail "GitHub Release **没**标 prerelease（⇒ ⇒ 会被当成正式版）"
fi

# ④ tap 没有被改成 beta
if gh api "repos/${TAP_REPO}/contents/Casks/clipmemory.rb" -q '.content' 2>/dev/null \
    | base64 -d 2>/dev/null | grep -q "version \"${VERSION}\""; then
    fail "Homebrew tap 的 Cask 指向了 ${VERSION} ⇒ ⇒ **brew 用户会拿到 beta**"
else
    ok "Homebrew tap 未指向 beta 版本（brew 用户拿不到 beta）"
fi

echo ""
if [[ $FAILS -eq 0 ]]; then
    echo "✅ beta 发版验收全部通过（v${VERSION}）"
    exit 0
fi
echo "❌ ${FAILS} 项验收未过"
exit 1
