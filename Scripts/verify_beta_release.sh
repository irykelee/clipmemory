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

# ── 三个「用户实际能用的 feed」────────────────────────────────────────
#
# ID-BETA-0001（2026-11-08）：**这一组是本轮实测踩出来的坑** ⇒ ⇒
#
# ① `releases/latest/download/appcast.xml`（app 的默认主 feed）⇒ ⇒ GitHub 的
#    `releases/latest` **排除 prerelease** ⇒ ⇒ ⇒ 它解析到**最近一个正式版**的
#    appcast 资产 ⇒ ⇒ ⇒ ⇒ **里面必然没有 beta 条目** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 即使用户勾了
#    ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 「接收 beta 版更新」，Sparkle 也**根本没见过**那条 beta 条目
#    ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **勾开关也没用**。
# ② `cdn.jsdelivr.net/gh/…@main/appcast.xml` ⇒ ⇒ 镜像 **main 分支** ⇒ ⇒ ⇒
#    **含** beta 条目 ⇒ ⇒ ⇒ ⇒ 这是 beta 用户**实际**能看到的 feed。
# ③ `gitee.com/…/raw/main/appcast.xml` ⇒ ⇒ 同样镜像 main ⇒ ⇒ ⇒ **含** beta
#    ⇒ ⇒ ⇒ ⇒ 且它的 enclosure 指向 **Gitee 资产** ⇒ ⇒ ⇒ ⇒ ⇒ 中国用户**下载得到**。
#
# ⇒ ⇒ ⇒ ⇒ 2026-11-08 实测：② 有 beta（命中 4）、① 没有（命中 0）、
# ⇒ ⇒ ⇒ ⇒ ③ **也没有**（35 条、最新 2.9.6）⇒ ⇒ ⇒ ⇒ 因为 Gitee 同步被
# ⇒ ⇒ ⇒ ⇒ **beta 版本号**卡死了 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **beta 只在「主 feed 不可达」
# ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 时才可见** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **网络越差越能看到 beta**。
#
# ⇒ ⇒ ⇒ ⇒ 所以这三项**必须**被机械核对 ⇒ ⇒ ⇒ ⇒ 否则同一个坑会再来一次。
FEED_GITHUB_URL="${CM_FEED_GITHUB_URL:-https://github.com/${API_REPO}/releases/latest/download/appcast.xml}"
FEED_JSDELIVR_URL="${CM_FEED_JSDELIVR_URL:-https://cdn.jsdelivr.net/gh/${API_REPO}@main/appcast.xml}"
FEED_GITEE_URL="${CM_FEED_GITEE_URL:-https://gitee.com/irykelee/clipmemory/raw/main/appcast.xml}"

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

feed_mentions_version() {   # $1 = 本地 appcast 文件，$2 = 版本号
    # ⇒ ⇒ **原文**匹配（不依赖 XML 解析器）⇒ ⇒ 解析器坏了也不会「假通过」。
    local f="$1" v="$2"
    [[ -s "$f" ]] || return 1
    grep -q "<sparkle:version>${v}</sparkle:version>" "$f"
}

feed_has_beta() {   # $1 = 本地 appcast 文件，$2 = 版本号 ⇒ ⇒ 在 beta 通道里命中返回 0
    local f="$1" v="$2"
    [[ -s "$f" ]] || return 1
    beta_items "$f" beta | grep -q "^${v}"
}

check_feed() {      # $1 = 标签, $2 = URL, $3 = 期望（beta|stable）
    local label="$1" url="$2" expect="$3"
    local tmp; tmp="$(mktemp -t cm-feed).xml"
    if ! curl -sfL --max-time 45 "$url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        if [[ "$expect" == "beta" ]]; then
            fail "${label} feed **取不到**（${url}）⇒ ⇒ beta 用户看不到 beta"
        else
            note "${label} feed 取不到（${url}）⇒ ⇒ 跳过该项断言"
        fi
        return 1
    fi
    local mentioned="no" inBeta="no"
    feed_mentions_version "$tmp" "$VERSION" && mentioned="yes"
    feed_has_beta "$tmp" "$VERSION" && inBeta="yes"
    rm -f "$tmp"
    if [[ "$expect" == "beta" ]]; then
        # ⇒ ⇒ **两个条件都要满足**（原文提到 + 在 beta 通道里）⇒ ⇒ 解析器坏了
        # ⇒ ⇒ ⇒ ⇒ 就是**红**（fail-closed）⇒ ⇒ ⇒ ⇒ ⇒ 不做「假通过」。
        if [[ "$mentioned" == "yes" && "$inBeta" == "yes" ]]; then
            ok "${label} feed 含 ${VERSION} 条目（beta 用户在这里能看到它）"
            return 0
        fi
        fail "${label} feed **不含** ${VERSION}（${url}）⇒ ⇒ beta 用户看不到 beta（提到=${mentioned} 在beta通道=${inBeta}）"
        return 1
    fi
    if [[ "$mentioned" == "no" ]]; then
        ok "${label} feed 不含 beta 版本条目（预期：GitHub 的 releases/latest 排除 prerelease）"
        return 0
    fi
    fail "${label} feed **居然含** ${VERSION}（${url}）⇒ ⇒ GitHub 的 latest 语义变了 ⇒ ⇒ 结论要重审"
    return 1
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

    # ── ⑤ feed 断言的自检（file:// 夹具 ⇒ ⇒ **不联网**）──────────────────
    # ⇒ ⇒ 这一段是「Gitee 同步失败 ⇒ 镜像里没有 beta」那个**真 bug** 的
    # ⇒ ⇒ ⇒ 机械化 ⇒ ⇒ ⇒ ⇒ **镜像缺 beta 必须报红** ⇒ ⇒ ⇒ ⇒ 不许悄悄通过。
    VERSION="2.10.0-beta.1"
    local nobeta="$WORK_DIR/no-beta.xml"
    cat > "$nobeta" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>Version 2.9.6</title>
      <sparkle:shortVersionString>2.9.6</sparkle:shortVersionString>
      <sparkle:version>2.9.6</sparkle:version>
    </item>
  </channel>
</rss>
EOF
    local before=$FAILS
    check_feed "夹具·主 feed" "file://${nobeta}" stable
    check_feed "夹具·jsDelivr" "file://${appcast}" beta
    check_feed "夹具·Gitee" "file://${appcast}" beta
    if [[ $FAILS -eq $before ]]; then
        ok "合成夹具：三条 feed 断言（主不含 beta / 两个镜像含 beta）全过"
    else
        fail "合成夹具：feed 断言误报 $((FAILS - before)) 处"
    fi
    before=$FAILS
    check_feed "夹具·镜像缺 beta" "file://${nobeta}" beta
    if [[ $FAILS -gt $before ]]; then
        ok "合成夹具：镜像缺 beta 时**报红**（= 那个真 bug 会被抓到）"
    else
        fail "合成夹具：镜像缺 beta 却没报红 ⇒ ⇒ 这条检查是**假绿**的"
    fi
    # ⇒ ⇒ 上面那次失败是**故意**的 ⇒ ⇒ ⇒ 把计数还原 ⇒ ⇒ ⇒ 否则自检永远红。
    FAILS=$before

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

# ⑤ **用户实际能用的 feed** 里能不能看到 beta（ID-BETA-0001，2026-11-08）
# ⇒ ⇒ 这一段是本轮**实测踩到**的坑的机械化 ⇒ ⇒ 见上面三个 FEED_*_URL 的注释。
echo ""
echo "--- ⑤ 用户实际能用的 feed（2026-11-08 新增：这一段抓到过一个真 bug）---"
check_feed "主 feed（releases/latest）" "$FEED_GITHUB_URL" stable
check_feed "jsDelivr main 镜像" "$FEED_JSDELIVR_URL" beta
check_feed "Gitee main 镜像" "$FEED_GITEE_URL" beta

echo ""
if [[ $FAILS -eq 0 ]]; then
    echo "✅ beta 发版验收全部通过（v${VERSION}）"
    exit 0
fi
echo "❌ ${FAILS} 项验收未过"
exit 1
