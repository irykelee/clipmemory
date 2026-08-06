#!/usr/bin/env bash
# release.sh — one-command release orchestrator for ClipMemory.
#
# Self-contained: the retired Scripts/{preflight,pre_push_verify,
# pre_push_main_sync,safe_push}.sh were inlined here (2026-07-25
# consolidation) — this is now the ONLY push/release tool in Scripts/.
# Automates docs/RELEASE.md B1–B3:
#
#   Phase 0  preflight gates      semver + version-increment check, tool
#                                 checks (git/gh/python3/xcodegen/xcodebuild),
#                                 clean tree, on main, derive PREV_VERSION
#   Phase 1  version + docs (B1)  bump project.yml → xcodegen → draft
#                                 docs/release-notes/vX.Y.Z.md from git log
#                                 (human edit gate) → extract README changelog
#                                 section → sync_readme.py (LLM translate,
#                                 needs README_SYNC_API_KEY/DEEPSEEK_API_KEY)
#                                 → run_preflight [--tests]
#   Phase 2  commit + push (B2)   stage release files → chore(release) commit
#                                 → confirm gate → sync_main_with_origin +
#                                 push main → run_pre_push_verify →
#                                 annotated tag → push tag
#   Phase 3  pipeline + verify    gh run watch release.yml for the tag →
#   (B3)                          post-release verify (title/body/assets/
#                                 appcast/tap sha) → print remaining manual
#                                 steps (B4.12: brew upgrade + STATUS.md)
#
# What it deliberately does NOT do:
#   - build/sign/package locally (release.yml owns that — CI has the certs)
#   - modify package.sh / sync_readme.py / release.yml (CI calls those)
#   - B2.5 branch protection (one-time) or B4.12 memory/status updates
#
# Usage:
#   Scripts/release.sh vX.Y.Z [--yes] [--skip-tests] [--dry-run]
#                                [--skip-readme-sync] [--verify-install]
#
#   --yes              non-interactive: skip the notes-edit and push-confirm gates
#   --skip-tests       run_preflight without the full xcodebuild test suite
#   --dry-run          Phase 0 checks + print previews of every generated file
#                      and every mutating step; touches nothing on disk or remote
#   --skip-readme-sync 逃生门 (2026-08-05, release-ux-doors): skip the
#                      sync_readme.py 7-language README sync AND the matching
#                      README preflight checks. Only for when the 7 READMEs are
#                      already hand-synced, or this release intentionally does
#                      not touch the README changelog. User takes over the
#                      "README state is correct" responsibility.
#   --verify-install   发布后硬验证门 (2026-08-05, release-ux-doors): after the
#                      release pipeline passes, locally `brew install/upgrade`
#                      the cask and verify CFBundleShortVersionString +
#                      codesign TeamIdentifier. Fails exit 1 (release is already
#                      live — do NOT re-run the script; fix manually).
#
# ⚠️ AI Agent 使用须知（REL-24, 2026-08-04 — 反复出错的防护）：
#   本脚本的 gate 是为「人」设计的（open -e 编辑器 + read -p 确认）。
#   AI agent 运行本脚本时，以下规则是硬性的：
#   1. 禁止用 --yes 跳过 notes edit gate，除非用户明确说「用 --yes」。
#      --yes 会把未润色的 git log 草稿直接作为最终 release notes 发布——
#      草稿是开发视角，不是用户视角（2026-08-04 教训：MiniMax 照搬 git log
#      发布，6 条 Logo 反复过程全进 notes）。
#   2. generate_release_notes 产出的 draft 必须由「人」润色后才能 commit。
#      AI 可以生成/润色，但最终确认必须经过用户（release-notes-chinese-first
#      feedback 规则：AI 生成可作为 final，但需用户过目）。
#   3. 任何 read -p 确认 gate 必须停下等用户输入，不能模拟回车 / 注入 yes。
#   4. 推荐流程：先 --dry-run 看完整计划 → 用户确认 → 再正式跑（无 --yes，
#      每个 gate 停住等用户）。
#   5. AI 在 gate 之外的辅助判断（git 分析、文件归属）同样可能出错——
#      涉及「是否合入 main」「哪些文件要提交」的结论，用 git 内容等价性
#      验证（--grep 工单 ID），不能只看 hash 是否在 main 里（PR squash 后
#      hash 必不同）。
#
# Sources cleanly (defines pure functions) when `source`'d from tests.
#
# Exit codes:
#   0  success
#   1  a gate/verification failed
#   2  usage error
#   3  aborted by user at a confirm gate
#   *  gh run watch / git push exit codes pass through
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GH_OWNER_REPO="${GH_OWNER:-irykelee}/${GH_REPO:-clipmemory}"
# REL-22 (2026-08-02 review): the tap repo used to be hardcoded below, so
# GH_OWNER didn't override it. Mirror the GH_OWNER_REPO pattern; the raw
# URL is composed from TAP_REPO (fallback channel only — gh api is primary,
# see gh_fetch_main_file).
TAP_REPO="${GH_OWNER:-irykelee}/${GH_TAP_REPO:-homebrew-clipmemory}"
TAP_RAW_URL="https://raw.githubusercontent.com/${TAP_REPO}/main/Casks/clipmemory.rb"

README_FILES=(
    "README.md"
    "docs/lang/README_EN.md"
    "docs/lang/README_ZH-HANT.md"
    "docs/lang/README_JA.md"
    "docs/lang/README_KO.md"
    "docs/lang/README_ES.md"
    "docs/lang/README_PT.md"
)

log()  { echo "→ $*"; }
ok()   { echo "✅ $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# --- Pure functions (testable) ---

# Strict semver X.Y.Z (no pre-release/build suffix — release.yml tags are vX.Y.Z).
valid_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# version_gt A B — exit 0 iff A is semver-greater than B.
# awk because macOS ships BSD sort (no `sort -V`).
version_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".");
        if (na != 3 || nb != 3) exit 1;
        for (i = 1; i <= 3; i++) {
            if (x[i] + 0 > y[i] + 0) exit 0;
            if (x[i] + 0 < y[i] + 0) exit 1;
        }
        exit 1;  # equal is not greater
    }'
}

# latest_tag_version — highest vX.Y.Z tag in the current repo, or empty.
# Zero-pads each component so plain `sort` orders semver correctly.
latest_tag_version() {
    git tag -l 'v*' | sed 's/^v//' \
        | awk -F. 'NF == 3 { printf "%08d.%08d.%08d %s\n", $1, $2, $3, $0 }' \
        | sort | tail -1 | cut -d' ' -f2
}

# classify_commit SUBJECT — echoes "highlights" | "fixes" | "other".
# Conventional-commit mapping: feat/perf are user-visible gains, fix is a
# bug repair, everything else (docs/chore/ci/refactor/test/style) is 其他.
classify_commit() {
    local subject="$1"
    local type
    type=$(echo "$subject" | sed -E 's/^([a-z]+)(\([^)]*\))?!?:.*/\1/')
    case "$type" in
        feat|perf) echo "highlights" ;;
        fix)       echo "fixes" ;;
        *)         echo "other" ;;
    esac
}

# strip_commit_prefix SUBJECT — "fix(ocr): log on fallback" → "log on fallback".
strip_commit_prefix() {
    echo "$1" | sed -E 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//'
}

# generate_release_notes VERSION PREV OUTFILE
# Drafts docs/release-notes/vX.Y.Z.md per docs/release-notes-template.md.
# Bullets come from `git log vPREV..HEAD` subjects (English commit messages);
# the 中文 section carries the same text with a polish marker — the human
# edit gate in main() exists precisely to turn this draft into the shipped
# bilingual notes (RELEASE.md B4.10: notes must not ship as a stub).
#
# REL-24 (2026-08-04): churn collapsing. A theme that went through several
# iterations in the same release window (e.g. the Logo placement churn
# ID-VIEW-0017..0024) must surface as ONE final-state bullet, not the whole
# back-and-forth. churn_theme() maps a subject to a canonical theme key;
# churn_final() maps that key to the final-state user-facing description.
# If a subject's theme was already emitted, the later (final) version
# REPLACES the earlier one instead of appending.
churn_theme() {
    local s="$1"
    case "$s" in
        *[Ll]ogo*|*[Ss]idebar\ search*|*[Ss]earch\ box*|*search\ into\ sidebar*) echo "brand-layout" ;;
        *[Ss]ettings*[Ww]indow*|[Ss]ettings\ tab*) echo "settings-window" ;;
        *) echo "" ;;
    esac
}
churn_final() {
    local theme="$1"
    case "$theme" in
        brand-layout)
            echo "品牌 Logo 与侧边栏搜索样式统一，工具栏回归清爽" ;;
        settings-window)
            echo "设置窗口居中显示" ;;
    esac
}
generate_release_notes() {
    local version="$1" prev="$2" outfile="$3"
    local range date today
    date=$(date +%F)
    if [[ -n "$prev" ]]; then range="v${prev}..HEAD"; else range="HEAD"; fi

    # REL-24: associative array theme_key → emitted line (final state wins).
    declare -A emitted_lines=()
    local highlights="" fixes="" others="" subject bucket line theme
    while IFS= read -r subject; do
        [[ -z "$subject" ]] && continue
        # Skip release bookkeeping commits — they describe the last release,
        # not this one.
        case "$subject" in
            chore\(release\):*|chore:\ appcast*) continue ;;
        esac
        bucket=$(classify_commit "$subject")
        # REL-24: churn collapse — if this subject is part of a known
        # multi-iteration theme, replace the earlier emitted line with the
        # final-state description instead of appending another bullet.
        theme=$(churn_theme "$subject")
        if [[ -n "$theme" ]]; then
            # REL-24: only the FINAL occurrence of a churn theme emits a
            # bullet. If this theme already emitted its final-state line
            # (in any bucket), skip — the last occurrence of the theme in
            # git log order is the final state, so later matches are the
            # true final; earlier matches were removed below. To keep the
            # final state correct, we always update the emitted line to the
            # CURRENT subject's final description, but never emit twice.
            final_desc=$(churn_final "$theme")
            old_line="${emitted_lines[$theme]:-}"
            if [[ -n "$old_line" ]]; then
                highlights="${highlights//$old_line/}"
                fixes="${fixes//$old_line/}"
                others="${others//$old_line/}"
            fi
            line="- **${final_desc}**"
            emitted_lines[$theme]="$line"
            case "$bucket" in
                highlights) highlights+="$line"$'\n' ;;
                fixes)      fixes+="$line"$'\n' ;;
                other)      others+="$line"$'\n' ;;
            esac
            continue
        fi
        # REL-27 (2026-08-05): auto-fill a default user-facing description
        # instead of the bare `<一句话：用户得到什么>` placeholder. The draft
        # still needs human polish (the commit subject is developer-view),
        # but this gives the editor a usable starting point per bucket —
        # much less work than writing every line from scratch.
        local subject_desc
        subject_desc=$(strip_commit_prefix "$subject")
        case "$bucket" in
            highlights) line="- **${subject_desc}** — 新增/改进：${subject_desc}，详见下方说明" ;;
            fixes)      line="- **${subject_desc}** — 修复：${subject_desc} 相关问题" ;;
            other)      line="- **${subject_desc}** — ${subject_desc}" ;;
        esac
        case "$bucket" in
            highlights) highlights+="$line"$'\n' ;;
            fixes)      fixes+="$line"$'\n' ;;
            other)      others+="$line"$'\n' ;;
        esac
    done < <(git log --format='%s' "$range" 2>/dev/null || true)

    [[ -z "$highlights" ]] && highlights="- <本版本主要更新>"$'\n'
    [[ -z "$fixes" ]] && fixes=""
    [[ -z "$others" ]] && others=""

    {
        # CN-first: 中文标题在前 / English title after (per memory
        # feedback/release-notes-chinese-first.md, 2026-07-30).
        echo "# 剪忆 ClipMemory v${version} — <中文标题> / <English Title>"
        echo ""
        echo "**发布日期 / Release Date**: ${date}"
        echo "**类型 / Type**: Patch | Minor | Major release"
        echo ""
        echo "## 中文"
        echo ""
        echo "<!-- 草稿由 Scripts/release.sh 从 git log 生成：请润色为用户视角描述，"
        echo "     每条写清「用户得到什么」而非「改了什么」（docs/release-notes-template.md）-->"
        echo ""
        echo "### 主要更新 (Highlights)"
        echo ""
        printf '%s\n' "$highlights"
        if [[ -n "$fixes" ]]; then
            echo "### 修复 (Fixes)"
            echo ""
            printf '%s\n' "$fixes"
        fi
        if [[ -n "$others" ]]; then
            echo "### 其他 (Other)"
            echo ""
            printf '%s\n' "$others"
        fi
        echo "### 升级提示 (Upgrade Note)"
        echo ""
        echo "- v2.4.0 起带自动升级模块（Sparkle）的版本：等 App 内自动更新，或 \`brew upgrade --cask clipmemory\`"
        echo ""
        echo "## English"
        echo ""
        echo "### Highlights"
        echo ""
        printf '%s\n' "$highlights"
        if [[ -n "$fixes" ]]; then
            echo "### Fixes"
            echo ""
            printf '%s\n' "$fixes"
        fi
        echo "### Upgrade Note"
        echo ""
        echo "- Versions with the auto-update module (Sparkle, v2.4.0+): wait for in-app auto-update, or run \`brew upgrade --cask clipmemory\`"
        echo ""
        echo "## 安装 / Install"
        echo ""
        echo '```bash'
        echo "# Homebrew Cask"
        echo "brew tap irykelee/clipmemory"
        echo "brew trust irykelee/clipmemory"
        echo "brew install --cask clipmemory"
        echo ""
        echo "# Manual download"
        echo "# https://github.com/${GH_OWNER_REPO}/releases/download/v${version}/ClipMemory.tar.gz"
        echo '```'
        echo ""
        echo "> **首次打开若提示「Apple 无法验证…」/ If macOS blocks the first launch with \"Apple cannot verify…\"**：这是 macOS 对未公证应用的常规拦截，不是病毒。右键点 App →「打开」→ 再点「打开」；或 系统设置 → 隐私与安全性 →「仍要打开」。仅需操作一次。/ This is the standard prompt for non-notarized apps, not malware. Right-click the app → **Open** → **Open** again; or System Settings → Privacy & Security → **Open Anyway**. Only needed once."
    } > "$outfile"
}

# validate_release_notes NOTES_FILE VERSION
# Mirrors release.yml's Pre-release verify step so a bad notes file fails
# locally instead of after the tag push.
validate_release_notes() {
    local notes="$1" version="$2"
    [[ -f "$notes" ]] || { echo "release notes missing: $notes" >&2; return 1; }
    grep -qE '^## 中文' "$notes"    || { echo "$notes missing '## 中文' header" >&2; return 1; }
    grep -qE '^## English' "$notes" || { echo "$notes missing '## English' header" >&2; return 1; }
    head -1 "$notes" | grep -q "v${version}" \
        || { echo "$notes H1 does not contain v${version}" >&2; return 1; }
    # REL-19 (2026-08-02 review): the subtitle/commit-message parsing cuts the
    # H1 at the "—" em-dash; if a human edit drops it, the WHOLE H1 leaks into
    # COMMIT_MSG and the re-run detection (`git log -1 == COMMIT_MSG`)
    # false-positives "没有可提交的改动". Fail here with a clear fix pointer.
    head -1 "$notes" | grep -q '—' \
        || { echo "$notes H1 must contain '—' (em-dash) between version and title — e.g. '# 剪忆 ClipMemory v${version} — 中文标题 / English Title'" >&2; return 1; }
    # Catch an unedited draft: template placeholders must not ship.
    if grep -qE '<English Title>|<一句话：用户得到什么>|<本版本主要更新>' "$notes"; then
        echo "$notes still contains draft placeholders — edit before continuing" >&2
        return 1
    fi
    return 0
}

# notes_subtitle NOTES_FILE — H1 text after the "—" em-dash.
# REL-19 (2026-08-02 review): extract_readme_changelog and Phase 2's
# COMMIT_MSG both derive from the H1; this is the single shared em-dash cut
# so the two call sites can't drift (the changelog call site additionally
# strips the " / English" half at its own end).
notes_subtitle() {
    head -1 "$1" | sed -E 's/^#[^—]*—[[:space:]]*//'
}

# gh_fetch_main_file REPO PATH — print a file's content from the repo's main
# branch. REL-16 (2026-08-02 review): raw.githubusercontent.com is
# unreachable in some restricted networks while api.github.com (authenticated)
# works, so the authenticated gh api channel is tried first and the bare
# raw curl is the fallback — now bounded by --max-time 15 (a bare `curl -sf`
# could hang the whole verify step indefinitely).
gh_fetch_main_file() {
    local repo="$1" path="$2"
    if gh api "repos/${repo}/contents/${path}" --jq .content 2>/dev/null | base64 -d; then
        return 0
    fi
    curl -sf --max-time 15 "https://raw.githubusercontent.com/${repo}/main/${path}"
}

# appcast_item_block VERSION — stdin: appcast.xml; stdout: the <item>…</item>
# block whose sparkle:shortVersionString is VERSION (empty when absent).
# REL-17 (2026-08-02 review): the edSignature check used to grep the whole
# feed, so an OLD signed item let a NEW unsigned item pass verification.
appcast_item_block() {
    awk -v v="$1" '
        /<item>/ { initem = 1; buf = "" }
        initem { buf = buf $0 "\n" }
        /<\/item>/ {
            if (initem && index(buf, "<sparkle:shortVersionString>" v "</sparkle:shortVersionString>")) printf "%s", buf
            initem = 0
        }'
}

# extract_readme_changelog NOTES_FILE VERSION OUTFILE
# Builds the zh-Hans changelog block that sync_readme.py propagates to all
# 7 READMEs. Format follows the existing README convention:
#   ### vX.Y.Z (YYYY-MM-DD) — <一句话>
#   - **bullet** — ...
#   - 完整 changelog: <release url>
# Bullets: first 5 `- ` lines of the 中文 section (README convention is
# 3-5 user-facing entries, RELEASE.md B1.2).
extract_readme_changelog() {
    local notes="$1" version="$2" outfile="$3"
    local date subtitle
    date=$(date +%F)
    # Subtitle: H1 text after " — ", Chinese half before " / " (fall back to
    # the whole remainder when there is no slash). Em-dash cut is the shared
    # notes_subtitle() (REL-19); the slash strip is changelog-specific.
    subtitle=$(notes_subtitle "$notes" | sed -E 's|[[:space:]]*/.*$||')
    [[ -z "$subtitle" ]] && subtitle="<一句话总结>"

    {
        echo "### v${version} (${date}) — ${subtitle}"
        echo ""
        # Only the 中文 section: from '## 中文' up to (not incl.) '## English'.
        awk '/^## 中文/{f=1; next} /^## English/{f=0} f && /^- /' "$notes" \
            | head -5
        echo "- 完整 changelog: https://github.com/${GH_OWNER_REPO}/releases/tag/v${version}"
    } > "$outfile"
}

# verify_release_remote VERSION — post-release verification (local mirror of
# release.yml's P0-3 step + B3.8/B3.9 asset checks). Prints one line per
# check; returns non-zero if any check fails.
verify_release_remote() {
    local version="$1"
    local fails=0
    local api="repos/${GH_OWNER_REPO}/releases/tags/v${version}"

    vfail() { echo "  ❌ $*"; fails=$((fails + 1)); }
    vok()   { echo "  ✅ $*"; }

    echo "=== Post-release verification for v${version} ==="

    # 1. Release exists, title is bilingual (not the auto-stub tag name).
    local title body
    if title=$(gh api "$api" --jq .name 2>/dev/null) && [[ -n "$title" && "$title" != "null" ]]; then
        if [[ "$title" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            vfail "release title is auto-stub '$title'"
        else
            vok "release title: '$title'"
        fi
    else
        vfail "release v${version} not found via gh api"
        return 1
    fi

    # 2. Bilingual body.
    body=$(gh api "$api" --jq .body 2>/dev/null || echo "")
    echo "$body" | grep -qE '^## 中文'    && vok "body has '## 中文'"    || vfail "body missing '## 中文'"
    echo "$body" | grep -qE '^## English' && vok "body has '## English'" || vfail "body missing '## English'"

    # 3. Required assets (RELEASE.md B3.8).
    local asset
    for asset in "ClipMemory.tar.gz" "appcast.xml"; do
        if gh api "$api" --jq ".assets[] | select(.name == \"${asset}\") | .name" 2>/dev/null | grep -q .; then
            vok "asset ${asset} attached"
        else
            vfail "asset ${asset} missing"
        fi
    done

    # 4. appcast.xml on main carries the new item with an EdDSA signature.
    # REL-16: authenticated gh api first, raw curl as bounded fallback.
    # REL-17: the edSignature grep is scoped to THIS version's <item> block —
    # a feed-wide grep let an old signed item cover a new unsigned one.
    local appcast
    if appcast=$(gh_fetch_main_file "$GH_OWNER_REPO" appcast.xml); then
        if echo "$appcast" | appcast_item_block "$version" | grep -q 'sparkle:edSignature="[^"]\+"'; then
            vok "appcast.xml has v${version} item with edSignature"
        else
            vfail "appcast.xml missing v${version} item or edSignature"
        fi
    else
        vfail "could not fetch appcast.xml from main"
    fi

    # 5. Tap-repo Cask version + sha256 match the release tarball digest (B3.9).
    local cask tap_ver tap_sha asset_sha
    if cask=$(gh_fetch_main_file "$TAP_REPO" Casks/clipmemory.rb); then
        tap_ver=$(echo "$cask" | sed -nE 's/^[[:space:]]*version "([^"]+)".*/\1/p' | head -1)
        tap_sha=$(echo "$cask" | sed -nE 's/^[[:space:]]*sha256 "([^"]+)".*/\1/p' | head -1)
        asset_sha=$(gh api "$api" --jq '.assets[] | select(.name == "ClipMemory.tar.gz") | .digest' 2>/dev/null | sed 's/^sha256://')
        [[ "$tap_ver" == "$version" ]] \
            && vok "tap Cask version = ${version}" \
            || vfail "tap Cask version '$tap_ver' != ${version}"
        if [[ -n "$asset_sha" && "$tap_sha" == "$asset_sha" ]]; then
            vok "tap Cask sha256 matches release asset digest"
        else
            vfail "tap Cask sha256 ($tap_sha) != asset digest ($asset_sha)"
        fi
    else
        vfail "could not fetch tap Cask ($TAP_REPO)"
    fi

    if [[ $fails -gt 0 ]]; then
        echo "❌ ${fails} post-release check(s) failed — see docs/RELEASE_PUSH_CHECKLIST.md §D3 for manual fixes"
        return 1
    fi
    echo "✅ All post-release checks passed."
    return 0
}

# verify_install VERSION — 2026-08-05 (release-ux-doors): --verify-install 硬验证门。
# 发布流水线全绿后，在本机实际安装 cask 并核验版本号 + codesign TeamIdentifier，
# 确认「用户实际会拿到的东西」可用。失败返回 1（release 已在 GitHub 上 live，
# 不要重跑脚本——按输出指引手动处理）。
verify_install() {
    local version="$1"
    local app_path="/Applications/ClipMemory.app"
    local expected_team installed team
    expected_team=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM: "([^"]+)".*/\1/p' "$PROJECT_DIR/project.yml" | head -1)
    [[ -n "$expected_team" ]] || { echo "❌ 无法从 project.yml 解析 DEVELOPMENT_TEAM" >&2; return 1; }

    echo "== 本机安装验证: v${version} =="

    # 1. brew install / upgrade。先 brew update 让 tap 的最新 cask 可见——
    #    release.yml 刚更新 tap，本地 brew 索引可能滞后，直接 upgrade 会
    #    误报「已是最新」。update 失败（如网络）不阻塞，继续尝试 upgrade，
    #    版本不符由下面的核验兜底捕获。
    brew update 2>&1 | tail -1 || true
    if [[ -d "$app_path" ]]; then
        brew upgrade --cask clipmemory 2>&1 | tail -3 || true
    else
        brew install --cask clipmemory 2>&1 | tail -3 || true
    fi

    # 2. 版本核验
    installed=$(defaults read "${app_path}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
    if [[ -z "$installed" ]]; then
        echo "❌ 安装验证失败: 读取 ${app_path} 版本失败（App 未安装？）" >&2
        echo "   手动处理: brew install --cask clipmemory 后重验; release 已在 GitHub 上，不要重跑本脚本" >&2
        return 1
    fi
    if [[ "$installed" != "$version" ]]; then
        # 注意：$version 后紧跟全角（ → 必须用 ${version} 花括号界定变量名，
        # 否则 bash 5.3 (zh_CN locale) 会把全角首字节 0xEF 拼进变量名报
        # "version\xEF: unbound variable"（REL-26 同族 bug）。
        echo "❌ 安装验证失败: 本机版本 ${installed} != 发布版本 ${version}（tap 可能未同步，稍后 brew update && brew upgrade 重试）" >&2
        echo "   手动处理: brew update && brew upgrade --cask clipmemory; release 已在 GitHub 上，不要重跑本脚本" >&2
        return 1
    fi
    ok "本机 ClipMemory 版本 = ${version}"

    # 3. 签名核验：codesign TeamIdentifier 必须匹配 project.yml DEVELOPMENT_TEAM
    team=$(codesign -dv "$app_path" 2>&1 | sed -nE 's/^[[:space:]]*TeamIdentifier=([^ ]+)$/\1/p' | head -1)
    if [[ -n "$team" && "$team" == "$expected_team" ]]; then
        ok "签名 TeamIdentifier = ${team}（匹配 project.yml）"
    else
        echo "❌ 安装验证失败: TeamIdentifier='${team:-（空）}' != 期望 '${expected_team}'" >&2
        echo "   手动处理: 检查 cask 来源与签名; release 已在 GitHub 上，不要重跑本脚本" >&2
        return 1
    fi
    echo "✅ 安装验证通过"
}

# --- Inlined push/preflight tooling (2026-07-25 consolidation) ---
# The retired Scripts/{preflight,pre_push_verify,pre_push_main_sync,safe_push}.sh
# live on below as functions — same checks, same failure semantics.

# sync_main_with_origin — was pre_push_main_sync.sh (+ safe_push.sh wrapper).
# Keeps local main usable before any push: skip when in sync, allow the
# normal "local ahead of origin" push case, fast-forward when local is
# behind, refuse divergence with a clear error.
sync_main_with_origin() {
    [[ -z "$(git status --porcelain)" ]] || { echo "✗ 工作树不干净 — commit 或 stash 后再同步" >&2; return 1; }
    git fetch origin main --quiet
    local local_ref remote_ref
    local_ref=$(git rev-parse main 2>/dev/null || echo "missing")
    remote_ref=$(git rev-parse origin/main)
    if [[ "$local_ref" == "missing" ]]; then
        git branch main "$remote_ref"
        return 0
    fi
    [[ "$local_ref" == "$remote_ref" ]] && return 0
    # Normal push: remote is ancestor of local (single-author, local work on top).
    git merge-base --is-ancestor "$remote_ref" "$local_ref" && return 0
    # Local is behind: safe fast-forward (the v2.5.10/v2.5.11 ship-delay fix).
    if git merge-base --is-ancestor "$local_ref" "$remote_ref"; then
        git checkout main >/dev/null 2>&1
        git merge --ff-only "$remote_ref" >/dev/null
        return 0
    fi
    echo "✗ local main 与 origin/main 分叉 — 先解决分叉再推送（见 docs/RELEASE_PUSH_CHECKLIST.md）" >&2
    return 2
}

# check_project_version VERSION — was preflight.sh §1 + pre_push_verify.sh A1.
# project.yml 的 MARKETING_VERSION 与 CURRENT_PROJECT_VERSION 必须都等于目标版本。
check_project_version() {
    local version="$1" marketing build
    marketing=$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
    build=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
    [[ "$marketing" == "$version" ]] || { echo "  ❌ MARKETING_VERSION='$marketing'（期望 ${version}）"; return 1; }
    [[ "$build" == "$version" ]] || { echo "  ❌ CURRENT_PROJECT_VERSION='$build'（期望 ${version}）"; return 1; }
    return 0
}

# check_readmes VERSION — was preflight.sh §2 + pre_push_verify.sh A2/A2.5.
# 7+1 个 README 的 H1 标题与 changelog 段都必须含目标版本。
check_readmes() {
    local version="$1" f fails=0
    for f in "${README_FILES[@]}"; do
        head -1 "$f" | tr -d '\r' | grep -q "v$version" \
            || { echo "  ❌ $f 标题缺 v$version"; fails=$((fails + 1)); }
        grep -q "^### v$version (" "$f" \
            || { echo "  ❌ $f changelog 缺 '### v$version ('"; fails=$((fails + 1)); }
    done
    return $fails
}

# check_readme_dedup VERSION — DOC-0002 prevention (2026-08-02 v2.7.7 audit,
# shipped fix in sync_readme.py strip_extra_headings()). Runtime 防已经在
# insert_section 去 LLM 输出杂散 heading;这个 preflight 防止 (a) 已 ship 的
# stale dup 漏到 release commit (b) 未来 release 注入路径旁路 sync_readme.py
check_readme_dedup() {
    local version="$1" f count fails=0
    for f in "${README_FILES[@]}"; do
        count=$(grep -c "^### v${version} (" "$f" 2>/dev/null) || true
        count=${count:-0}
        [[ "$count" -gt 1 ]] \
            && { echo "  ❌ $f 有 ${count} 个 '### v${version} (' heading (预期 ≤ 1,DOC-0002 类缺陷复发)"; fails=$((fails + 1)); }
    done
    return $fails
}

# check_glossary_consistency — DOC-0003 prevention (2026-08-02 v2.7.7 audit).
# 跨语种 Trash 术语污染。canonical map 见 sync_readme.py:50 GLOSSARY dict。
# 当前 preflight 覆盖最常见的 3 类污染 (zh-Hans / zh-Hant / en);更广 Lang
# 覆盖 (ja/ko/es/pt) 靠 sync_readme.py 重跑 diff,不在 preflight 里硬黑名单
# (避免误伤合理 narrative 例外如 en 介绍 "X 翻译: Trash in ja = ごみ箱")。
#
# NEW-6 (2026-08-06 review): v2.7.9 added the Gitee mirror channel
# without extending this gate. The plan's zh-Hant used 映像 (disk image
# semantics) but the app's own strings and other docs use 鏡像
# (software mirror). The gate now also catches mirror-term drift so
# future channels/mirrors don't reintroduce the same mismatch.
# Canonical mirror map lives in sync_readme.py GLOSSARY["镜像"].
check_glossary_consistency() {
    local fails=0
    if grep -q "垃圾桶" "README.md" 2>/dev/null; then
        echo "  ❌ README.md (zh-Hans) 出现 '垃圾桶' (应只用 '回收站')"
        fails=$((fails + 1))
    fi
    if grep -q "回收站" "docs/lang/README_ZH-HANT.md" 2>/dev/null; then
        echo "  ❌ README_ZH-HANT.md 出现 '回收站' (应只用 '垃圾桶')"
        fails=$((fails + 1))
    fi
    if grep -qi "Recycle Bin" "docs/lang/README_EN.md" 2>/dev/null; then
        echo "  ❌ README_EN.md 出现 'Recycle Bin' (应只用 'Trash')"
        fails=$((fails + 1))
    fi
    # NEW-6 mirror gate: zh-Hant files must use 鏡像 for software mirror
    # (映像 = disk image, different semantic). Catch 映像 in zh-Hant
    # contexts where 鏡像 is the established term (mirrors / Gitee /
    # jsDelivr settings UI).
    if grep -nE '映像\s*[\(（]?\s*(Gitee|jsDelivr|鏡像)|(Gitee|jsDelivr)\s*[\)）]?\s*映像' \
        "docs/lang/README_ZH-HANT.md" 2>/dev/null | grep -v "鏡像" >/dev/null; then
        echo "  ❌ docs/lang/README_ZH-HANT.md 出现 '映像' 用于 Gitee/jsDelivr 镜像 (应改 '鏡像')"
        fails=$((fails + 1))
    fi
    if grep -nE '映像\s*[\(（]?\s*(Gitee|jsDelivr|鏡像)|(Gitee|jsDelivr)\s*[\)）]?\s*映像' \
        "ClipMemory/zh-Hant.lproj/Localizable.strings" 2>/dev/null | grep -v "鏡像" >/dev/null; then
        echo "  ❌ ClipMemory/zh-Hant.lproj/Localizable.strings 出现 '映像' 用于 Gitee/jsDelivr 镜像 (应改 '鏡像')"
        fails=$((fails + 1))
    fi
    return $fails
}

# check_cask_template — was preflight.sh §3 + pre_push_verify.sh A4 (P0-4).
# 本地 Cask 是 reference-only 模板（live Cask 由 release.yml 写到 tap repo）：
# 只查存在 + Ruby 语法，不做版本/sha 对齐（本地 SDK ≠ CI SDK，对齐必然假阳性）。
check_cask_template() {
    [[ -f Casks/clipmemory.rb ]] || { echo "  ❌ Casks/clipmemory.rb 缺失"; return 1; }
    command -v ruby >/dev/null 2>&1 || { echo "  ⚠️  ruby 不可用，跳过 Cask 语法检查"; return 0; }
    ruby -c Casks/clipmemory.rb >/dev/null 2>&1 \
        || { echo "  ❌ Casks/clipmemory.rb Ruby 语法错误"; return 1; }
    return 0
}

# check_i18n_placeholders — was pre_push_verify.sh A3.
# settings.backup.import.result 的 %1$d→%2$d→%3$d→%4$d 顺序在 7 个 .lproj 一致。
check_i18n_placeholders() {
    local f line found fails=0
    local expected='%1$d%2$d%3$d%4$d'
    for f in ClipMemory/{en,zh-Hans,zh-Hant,ja,ko,es,pt}.lproj/Localizable.strings; do
        line=$(grep '"settings.backup.import.result"' "$f" 2>/dev/null | head -1)
        if [[ -z "$line" ]]; then
            echo "  ❌ $f 缺 key 'settings.backup.import.result'"
            fails=$((fails + 1))
            continue
        fi
        found=$(echo "$line" | grep -oE '%[1-9]\$d' | tr -d '\n')
        [[ "$found" == "$expected" ]] \
            || { echo "  ❌ $f 占位符顺序错误（'$found'，期望 '$expected'）"; fails=$((fails + 1)); }
    done
    return $fails
}

# check_xcodegen_sync — was preflight.sh §4（含 H-5 日志保留修复）。
# 校验的不变量是「pbxproj 可由 project.yml 重现」，而不是「pbxproj 与 HEAD
# 无差异」——发版时版本号 bump 本来就会产生与 HEAD 的差异（那是 release
# commit 的内容），按 HEAD 比较会把每次发版都误判为不同步。
check_xcodegen_sync() {
    command -v xcodegen >/dev/null 2>&1 || { echo "  ❌ xcodegen 未安装"; return 1; }
    local pbx=ClipMemory.xcodeproj/project.pbxproj before after xlog
    before=$(shasum -a 256 "$pbx" | awk '{print $1}')
    xlog=$(mktemp -t clipmemory-preflight.XXXXXX)
    if ! xcodegen generate >"$xlog" 2>&1; then
        echo "  ❌ xcodegen generate 失败（log: ${xlog}）" >&2
        sed 's/^/    /' "$xlog" >&2
        rm -f "$xlog"
        return 1
    fi
    rm -f "$xlog"
    after=$(shasum -a 256 "$pbx" | awk '{print $1}')
    [[ "$before" == "$after" ]] \
        || { echo "  ❌ project.pbxproj 与 project.yml 不同步（xcodegen generate 后有变化）"; return 1; }
    return 0
}

# check_swiftlint — was preflight.sh §5：改动过的 swift 文件无新增 error。
# REL-8 (2026-07-24 audit): (a) swiftlint 缺失必须失败而不是放行——preflight
# 是发布闸门，跳过等于没有 lint 检查；(b) porcelain 输出按 NUL 解析，
# awk '{print $2}' 对带空格文件名和重命名条目会切错路径。
check_swiftlint() {
    command -v swiftlint >/dev/null 2>&1 \
        || { echo "  ❌ swiftlint 未安装（brew install swiftlint）— preflight 无法放行"; return 1; }
    local changed=() xy rec
    while IFS= read -r -d '' rec; do
        xy=${rec:0:2}
        rec=${rec:3}
        # REL-21 (2026-08-02 review): deleted files (` D` / `D `) were passed
        # to swiftlint, which then failed on a nonexistent path — skip them.
        [[ $xy == *D* ]] && continue
        [[ $rec == *.swift ]] && changed+=("$rec")
        # 重命名条目在 -z 模式下占两条记录（新路径 + 原路径），吃掉第二条
        if [[ $xy == *R* ]]; then IFS= read -r -d '' _ || true; fi
    done < <(git status --porcelain -z -- '*.swift')
    [[ ${#changed[@]} -eq 0 ]] && return 0
    if swiftlint lint --quiet "${changed[@]}" 2>&1 | grep -q ': error:'; then
        echo "  ❌ swiftlint 有 error（${changed[*]}）"
        return 1
    fi
    return 0
}

# check_branch_drift — was pre_push_verify.sh C1：HEAD 落后 main >5 硬失败，
# 领先 >5 只警告（发版分支通常领先）。
check_branch_drift() {
    local ahead_behind behind ahead
    ahead_behind=$(git rev-list --left-right --count main...HEAD 2>/dev/null || echo "0 0")
    behind=$(echo "$ahead_behind" | awk '{print $1}')
    ahead=$(echo "$ahead_behind" | awk '{print $2}')
    if [[ "$behind" -gt 5 ]]; then
        echo "  ❌ 分支落后 main $behind 个 commit — 先 rebase/merge 再打 tag"
        return 1
    fi
    [[ "$ahead" -gt 5 ]] && echo "  ⚠️  分支领先 main $ahead 个 commit（tag 后记得合并）"
    return 0
}

# run_preflight VERSION [--tests] — was preflight.sh：打 tag 前的机械检查全集。
run_preflight() {
    local version="$1" with_tests="${2:-}" fails=0
    echo "== preflight: v${version} =="
    check_project_version "$version" && ok "project.yml 双版本号 = $version" || fails=$((fails + 1))
    if [[ ${SKIP_README_SYNC:-0} -eq 1 ]]; then
        # 2026-08-05 (release-ux-doors): --skip-readme-sync 逃生门 — 用户显式
        # 声明 README 状态正确（已手动同步或本次有意不更新 changelog），
        # preflight 相应跳过 README 检查，避免逃生门失效。
        log "⏭ 跳过 README 标题/changelog 检查（--skip-readme-sync）"
        log "⏭ 跳过 README 重复 heading 检查（--skip-readme-sync）"
    else
        check_readmes "$version" && ok "7+1 README 标题 + changelog" || fails=$((fails + 1))
        check_readme_dedup "$version" && ok "7+1 README 无重复 v${version} heading（DOC-0002 防复发）" || fails=$((fails + 1))
    fi
    check_glossary_consistency && ok "Trash 术语无跨语种污染（DOC-0003 防复发）" || fails=$((fails + 1))
    check_cask_template && ok "Cask 模板语法（reference-only）" || fails=$((fails + 1))
    check_xcodegen_sync && ok "project.pbxproj 与 project.yml 同步" || fails=$((fails + 1))
    check_swiftlint && ok "swiftlint 改动文件无 error" || fails=$((fails + 1))
    if [[ "$with_tests" == "--tests" ]]; then
        echo "== 全量测试 =="
        rm -rf /tmp/clipmemory-preflight.xcresult
        if xcodebuild test -scheme ClipMemory -destination 'platform=macOS' \
             -resultBundlePath /tmp/clipmemory-preflight.xcresult >/tmp/preflight-tests.log 2>&1; then
            xcrun xcresulttool get test-results summary --path /tmp/clipmemory-preflight.xcresult \
                | grep -E 'passedTests|failedTests' | head -2
            ok "全量测试通过"
            # REL-M13 (2026-08-03): anti-silence guard — verify the two canary
            # test classes actually ran. If a future change removes or renames
            # them, the test suite would pass with a dead canary (ZZZ's
            # class tearDown would never fire). This check is defense-in-depth;
            # the canary passing is still the ground-truth signal.
            for canary_class in AAASuiteBootstrapTests ZZZSuiteTeardownTests; do
                if grep -q "Test Suite '${canary_class}'" /tmp/preflight-tests.log; then
                    ok "canary ${canary_class} ran"
                else
                    echo "  ❌ canary ${canary_class} 未执行（canary 套件静默死亡）"
                    fails=$((fails + 1))
                fi
            done
        else
            echo "  ❌ 全量测试失败（见 /tmp/preflight-tests.log）"
            fails=$((fails + 1))
        fi
    fi
    return $fails
}

# run_pre_push_verify VERSION — was pre_push_verify.sh：打 tag 前的第二道检查
# （与 run_preflight 部分重叠是有意的——两道独立关卡，对应 RELEASE.md B1.3/B2）。
run_pre_push_verify() {
    local version="$1" fails=0
    echo "== pre-push verify: v${version} =="
    check_project_version "$version" && ok "project.yml 版本 = tag" || fails=$((fails + 1))
    if [[ ${SKIP_README_SYNC:-0} -eq 1 ]]; then
        log "⏭ 跳过 README 标题/changelog 检查（--skip-readme-sync）"
        log "⏭ 跳过 README 重复 heading 检查（--skip-readme-sync）"
    else
        check_readmes "$version" && ok "README 标题 + changelog" || fails=$((fails + 1))
        check_readme_dedup "$version" && ok "README 无重复 v${version} heading（DOC-0002 防复发）" || fails=$((fails + 1))
    fi
    check_glossary_consistency && ok "Trash 术语无跨语种污染（DOC-0003 防复发）" || fails=$((fails + 1))
    check_i18n_placeholders && ok "i18n 占位符顺序（7 语言）" || fails=$((fails + 1))
    check_cask_template && ok "Cask 模板语法" || fails=$((fails + 1))
    check_branch_drift && ok "分支领先/落后 main 在阈值内" || fails=$((fails + 1))
    return $fails
}

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

# --- Main body: only runs when executed, not sourced ---
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    VERSION=""
    AUTO_YES=0
    SKIP_TESTS=0
    DRY_RUN=0
    SKIP_README_SYNC=0
    VERIFY_INSTALL=0

    for arg in "$@"; do
        case "$arg" in
            --yes)               AUTO_YES=1 ;;
            --skip-tests)        SKIP_TESTS=1 ;;
            --dry-run)           DRY_RUN=1 ;;
            --skip-readme-sync)  SKIP_README_SYNC=1 ;;
            --verify-install)    VERIFY_INSTALL=1 ;;
            -h|--help)    usage 0 ;;
            v?*.?*.?*)    VERSION="$arg" ;;
            *)            echo "Unknown argument: $arg" >&2; usage 2 ;;
        esac
    done

    VERSION="${VERSION#v}"
    if ! valid_semver "$VERSION"; then
        echo "Usage: $0 vX.Y.Z [--yes] [--skip-tests] [--dry-run] [--skip-readme-sync] [--verify-install]" >&2
        exit 2
    fi

    cd "$PROJECT_DIR"

    # ============ REL-24: --yes 安全护栏 ============
    # --yes 会跳过 notes edit gate 和 push-confirm gate，把未润色的草稿直接
    # 发布。非 TTY 环境（AI agent 调用、CI 脚本）下 --yes 尤其危险——AI 会
    # 用 --yes 绕过需要人工判断的步骤（2026-08-04 教训）。
    # 护栏：非 TTY 且 --yes 时，必须同时显式设置 RELEASE_AGENT_CONFIRM=yes
    # 才算授权（由用户显式声明「用 --yes 发布」），否则直接拒绝。
    if [[ $AUTO_YES -eq 1 && ! -t 0 && "${RELEASE_AGENT_CONFIRM:-}" != "yes" ]]; then
        die "--yes 在非交互环境（TTY 检测到 AI/脚本调用）下被拒绝。
    本脚本的 --yes 会把未润色的 release notes 草稿直接发布，需要人工判断。
    如果你是用户本人确认要 --yes 发布，请显式设置环境变量：
      RELEASE_AGENT_CONFIRM=yes Scripts/release.sh v${VERSION} --yes
    否则不要用 --yes —— 用 --dry-run 先看计划，正式跑时不带 --yes（每个
    gate 会停下等你确认）。"
    fi
    if [[ $AUTO_YES -eq 1 && -t 0 ]]; then
        # 交互终端里的 --yes：打印警告，但保留（用户在自己终端敲的命令）。
        echo "⚠️  --yes 已设置：将跳过 notes edit gate 和 push-confirm gate。"
        echo "     确认 release notes 已人工润色（docs/release-notes/v${VERSION}.md）后再继续。"
    fi

    # ============ Phase 0: preflight gates ============
    echo "=== Phase 0: 前置校验 (v${VERSION}) ==="

    for tool in git gh python3 xcodegen xcodebuild; do
        command -v "$tool" >/dev/null 2>&1 || die "$tool 未安装或不在 PATH"
    done
    gh auth status >/dev/null 2>&1 || die "gh 未登录 — 先跑 gh auth login"
    ok "工具链 OK (git/gh/python3/xcodegen/xcodebuild + gh auth)"

    # 允许的脏文件集合：本版本 release notes（可预置）+ Phase 1 的全部产物
    # （版本 bump / pbxproj regen / 7 README）——失败重跑时工作树就处于这个
    # 中间态，Phase 1 的各步幂等（bump 同版本、sync_readme 先去重再插入、
    # notes 已存在则沿用），preflight 会重新校验内容正确性。
    # REL-20 (2026-08-02 review): also exempt the staged state `M ` — a rerun
    # after the产物 was `git add`ed (but not yet committed) false-positived
    # 「工作树不干净」.
    NOTES="docs/release-notes/v${VERSION}.md"
    ALLOWED_RE='^( M|M |\?\?) (project\.yml|ClipMemory\.xcodeproj/project\.pbxproj|README\.md|docs/lang/README_[A-Za-z-]+\.md|docs/release-notes/v'"$VERSION"'\.md)$'
    DIRTY=$(git status --porcelain | grep -vE "$ALLOWED_RE" || true)
    if [[ -n "$DIRTY" ]]; then
        echo "❌ 工作树不干净（存在 release 产物以外的改动）— commit 或 stash 后再发版" >&2
        echo "$DIRTY" >&2
        exit 1
    fi
    ok "工作树检查通过（release 产物豁免）"

    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    [[ "$BRANCH" == "main" ]] || die "当前分支是 '$BRANCH' — 发版必须从 main 切 tag（先 git checkout main）"
    ok "在 main 分支"

    # REL-15 (2026-08-02 review): --prune-tags so a tag deleted on the remote
    # doesn't linger locally and fool the increment check / existence check
    # below with a stale ref (requires git ≥2.17, ubiquitous by now).
    git fetch origin main --tags --prune-tags --quiet

    PREV_VERSION=$(latest_tag_version || true)
    if [[ -n "$PREV_VERSION" ]]; then
        version_gt "$VERSION" "$PREV_VERSION" \
            || die "版本 $VERSION 必须大于最新 tag v${PREV_VERSION}（递增校验失败）"
        ok "版本递增 OK: v$PREV_VERSION → v$VERSION"
        # REL-25 (2026-08-05 review): rapid re-release (e.g. 2 days after
        # the last tag) is often a sign of an AI agent churning on a release
        # that should have been fixed in-place. Soft warning only — the
        # version-increment check already passed; this is a human signal.
        # Guard: if the tag date can't be resolved (e.g. shallow clone), skip
        # silently rather than crash the release.
        PREV_TAG_DATE=$(git log -1 --format=%cs "v${PREV_VERSION}" 2>/dev/null || true)
        if [[ -n "$PREV_TAG_DATE" && "$PREV_TAG_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            PREV_EPOCH=$(date -j -f "%Y-%m-%d" "$PREV_TAG_DATE" +%s 2>/dev/null || true)
            if [[ -n "$PREV_EPOCH" ]]; then
                DAYS_SINCE=$(( ($(date +%s) - PREV_EPOCH) / 86400 ))
                if [[ "$DAYS_SINCE" -lt 3 ]]; then
                    printf "⚠️  距上次发布 v%s（%s）仅 %s 天 — 若这是 AI 反复尝试发同一次发布，请先确认这次真的修好了再继续\n" "$PREV_VERSION" "$PREV_TAG_DATE" "$DAYS_SINCE"
                fi
            fi
        fi
    else
        log "仓库还没有任何 tag — 作为首次发版处理"
    fi

    git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null 2>&1 \
        && die "tag v${VERSION} 已存在 — 不会覆盖（先 git tag -d v${VERSION} 并确认远端）"
    ok "tag v${VERSION} 不存在冲突"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo ""
        echo "=== DRY-RUN: 以下为预览，不落盘、不推送 ==="
        # REL-24: dry-run 是 AI agent 的推荐第一步——先看完整计划再决定是否
        # 正式执行。AI 必须把下面的预览输出完整呈现给用户，不能自己直接
        # 决定继续正式跑。
        echo "（REL-24：AI agent 使用本脚本时，先 --dry-run 把以下预览呈现给"
        echo " 用户确认，再正式执行；不要在 dry-run 后自动继续。）"
        TMP_NOTES=$(mktemp -t clipmemory-release-notes.XXXXXX.md)
        TMP_CHANGELOG=$(mktemp -t clipmemory-readme-changelog.XXXXXX.md)
        generate_release_notes "$VERSION" "$PREV_VERSION" "$TMP_NOTES"
        extract_readme_changelog "$TMP_NOTES" "$VERSION" "$TMP_CHANGELOG"
        echo ""
        echo "----- 将生成 $NOTES -----"
        cat "$TMP_NOTES"
        echo ""
        echo "----- 将传给 sync_readme.py 的 README changelog 段 -----"
        cat "$TMP_CHANGELOG"
        rm -f "$TMP_NOTES" "$TMP_CHANGELOG"
        echo ""
        echo "----- 其后将执行 -----"
        if [[ ${SKIP_README_SYNC:-0} -eq 1 ]]; then
            SYNC_STEP="⏭ 跳过 python3 Scripts/sync_readme.py（--skip-readme-sync）"
        else
            SYNC_STEP="python3 Scripts/sync_readme.py --version ${VERSION} --changelog <段>（需 README_SYNC_API_KEY/DEEPSEEK_API_KEY）"
        fi
        if [[ ${VERIFY_INSTALL:-0} -eq 1 ]]; then
            VERIFY_STEP="10. （--verify-install）brew install/upgrade clipmemory + 版本/签名验证"
        else
            VERIFY_STEP=""
        fi
        cat <<EOF
  1. project.yml MARKETING_VERSION/CURRENT_PROJECT_VERSION → ${VERSION} + xcodegen generate
  2. （人工 gate）编辑 $NOTES 后校验双语章节
  3. ${SYNC_STEP}
  4. run_preflight $( [[ $SKIP_TESTS -eq 0 ]] && echo --tests )（内联检查：版本/README/Cask/xcodegen/lint/测试）
  5. commit: chore(release): v${VERSION} — <一句话>（project.yml + pbxproj + 7 README + release notes）
  6. sync_main_with_origin + git push origin main
  7. run_pre_push_verify（内联检查：版本/README/i18n 占位符/Cask/分支漂移）
  8. git tag -a v${VERSION} + git push origin v${VERSION}
  9. gh run watch release.yml → verify_release_remote ${VERSION}
${VERIFY_STEP}
EOF
        echo ""
        echo "✅ DRY-RUN 完成 — 未做任何修改"
        exit 0
    fi

    # ============ Phase 1: 版本与文档 (RELEASE.md B1) ============
    echo ""
    echo "=== Phase 1: 版本与文档 ==="

    # 1. Bump project.yml (both version fields stay in lockstep, B1.1).
    sed -i '' -E "s|MARKETING_VERSION: \"[^\"]*\"|MARKETING_VERSION: \"${VERSION}\"|" project.yml
    sed -i '' -E "s|CURRENT_PROJECT_VERSION: \"[^\"]*\"|CURRENT_PROJECT_VERSION: \"${VERSION}\"|" project.yml
    xcodegen generate
    ok "project.yml → v${VERSION}，xcodegen 已重新生成"

    # 2. Draft release notes, then the human edit gate (B4.10: notes are
    #    authored bilingual, never shipped as a stub). --yes keeps the draft
    #    as-is and only runs the structural validation.
    if [[ ! -f "$NOTES" ]]; then
        generate_release_notes "$VERSION" "$PREV_VERSION" "$NOTES"
        log "已生成草稿 ${NOTES}（来自 v${PREV_VERSION:-∅}..HEAD 的 git log）"
    else
        log "$NOTES 已存在 — 沿用现有文件"
    fi
    if [[ $AUTO_YES -eq 0 ]]; then
        ${EDITOR:-open -e} "$NOTES" || true
        read -r -p "编辑并保存 $NOTES 后按 Enter 继续（Ctrl-C 中止）..."
    fi
    validate_release_notes "$NOTES" "$VERSION" || die "release notes 校验失败 — 按 docs/release-notes-template.md 补全后重跑"
    ok "release notes 双语章节 + 无占位符"

    # 3+4. README changelog section → 7-language sync (B1.2).
    # Key resolution mirrors sync_readme.py: env first, then the macOS
    # Keychain item `clipmemory-readme-sync` (one-time setup:
    # security add-generic-password -U -s clipmemory-readme-sync -a deepseek -w <key>).
    if [[ ${SKIP_README_SYNC:-0} -eq 1 ]]; then
        log "⏭ 已跳过 README 7 语言同步（--skip-readme-sync 逃生门）— 确认 7 个 README 已含 v${VERSION} changelog，或本次发版有意不更新 README"
    else
        if [[ -z "${README_SYNC_API_KEY:-${DEEPSEEK_API_KEY:-}}" ]] && \
           ! security find-generic-password -s clipmemory-readme-sync -w >/dev/null 2>&1; then
            die "缺少 README_SYNC_API_KEY（或 DEEPSEEK_API_KEY 或 Keychain 项 clipmemory-readme-sync）— sync_readme.py 需要 LLM 翻译 6 语种 changelog；
     设置后重跑，或参考 Scripts/sync_readme.py 头部注释换兼容 provider"
        fi
        TMP_CHANGELOG=$(mktemp -t clipmemory-readme-changelog.XXXXXX.md)
        trap 'rm -f "$TMP_CHANGELOG"' EXIT
        extract_readme_changelog "$NOTES" "$VERSION" "$TMP_CHANGELOG"
        python3 "$SCRIPT_DIR/sync_readme.py" --version "$VERSION" --changelog "$TMP_CHANGELOG"
        ok "7 个 README 标题 + changelog 已同步（git diff --stat 可在提交前核对）"
    fi

    # 5. Mechanical gates incl. full tests (B1.3). CI runs tests again, but a
    #    red suite must stop the release BEFORE the tag exists.
    if [[ $SKIP_TESTS -eq 1 ]]; then
        run_preflight "$VERSION" || die "preflight 未过 — 修完再跑"
    else
        run_preflight "$VERSION" --tests || die "preflight（含全量测试）未过 — 修完再跑"
    fi

    # ============ Phase 2: 提交与推送 (RELEASE.md B2) ============
    echo ""
    echo "=== Phase 2: 提交与推送 ==="

    # REL-19: shared em-dash cut (validate_release_notes guarantees the H1
    # contains "—", so this can no longer leak the whole H1 into COMMIT_MSG).
    SUBTITLE=$(notes_subtitle "$NOTES")
    COMMIT_MSG="chore(release): v${VERSION} — ${SUBTITLE}"

    git add project.yml ClipMemory.xcodeproj/project.pbxproj \
            "${README_FILES[@]}" "$NOTES"
    if git diff --cached --quiet; then
        # 重跑场景：Phase 1 产物已被上一次运行提交过——HEAD 就是 release
        # commit 时跳过提交直接续跑，否则才是真的没改动。
        if [[ "$(git log -1 --format=%s)" == "$COMMIT_MSG" ]]; then
            log "release commit 已存在（上次运行已提交）— 跳过提交续跑"
            SKIP_COMMIT=1
        else
            die "没有可提交的 release 改动（版本号/README 未变化？）"
        fi
    fi

    if [[ $AUTO_YES -eq 0 ]]; then
        git diff --cached --stat
        echo ""
        read -r -p "即将提交并推送 main + tag v${VERSION} 到 GitHub。输入 yes 确认: " CONFIRM
        [[ "$CONFIRM" == "yes" ]] || { echo "已中止"; exit 3; }
    fi

    # Global pre-commit hook's advisory section needs a pty in non-TTY
    # environments (RELEASE.md A4) — answering y only confirms "not a real
    # credential". Hard-reject (secret) sections are never bypassed.
    # NOTE: use bounded printf, NOT `yes y` — yes dies by SIGPIPE when script
    # exits, and pipefail would turn a successful commit into a script kill.
    if [[ "${SKIP_COMMIT:-0}" -eq 1 ]]; then
        :
    elif [[ -t 0 ]]; then
        git commit -m "$COMMIT_MSG"
    else
        printf 'y\n%.0s' {1..20} | script -q /dev/null git commit -m "$COMMIT_MSG"
    fi
    ok "release commit: $COMMIT_MSG"

    # Push main through the divergence guard, then prove the refs match
    # (2026-07-24 push-diagnostic: tag must be cut on a synced main).
    sync_main_with_origin || die "main 与 origin/main 同步失败 — 按上面提示处理分叉"
    git push origin main
    [[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]] \
        || die "push 后 main != origin/main — 中止（参考 docs/superpowers/audits/2026-07-24-push-diagnostic.md）"
    ok "main 已推送且与 origin/main 一致"

    run_pre_push_verify "$VERSION" || die "pre-push verify 未过 — 修完再跑"

    git tag -a "v${VERSION}" -m "chore(release): v${VERSION} — ${SUBTITLE}"
    sync_main_with_origin || die "main 与 origin/main 同步失败"
    git push origin "v${VERSION}"
    ok "tag v${VERSION} 已推送 — release.yml 已触发"

    # ============ Phase 3: 流水线监控与发布后验证 (RELEASE.md B3) ============
    echo ""
    echo "=== Phase 3: 流水线监控与发布后验证 ==="

    # The tag-push event surfaces as a run whose branch is the tag name; give
    # the API a moment to register it before polling.
    #
    # REL-14 (2026-08-02 review): verify the polled run's headSha against the
    # tag's commit. When a tag is deleted and re-pushed, the OLD run keeps the
    # same tag-name branch, so before the new run registers this loop used to
    # grab the stale (failed) run and watch the wrong pipeline (ID-BACKUP-0006
    # incident). Mismatch → discard and keep polling; `^{commit}` dereferences
    # the annotated tag to its commit.
    RUN_ID=""
    for _ in $(seq 1 12); do
        RUN_ID=$(gh run list --workflow=release.yml --branch "v${VERSION}" \
                 --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)
        if [[ -n "$RUN_ID" ]]; then
            RUN_SHA=$(gh run view "$RUN_ID" --json headSha --jq .headSha 2>/dev/null || true)
            TAG_SHA=$(git rev-parse "v${VERSION}^{commit}" 2>/dev/null || true)
            if [[ -n "$RUN_SHA" && -n "$TAG_SHA" && "$RUN_SHA" != "$TAG_SHA" ]]; then
                log "run ${RUN_ID} 的 headSha 与 v${VERSION} 的 commit 不符（tag 删了重推残留的旧 run）— 继续等待新 run 注册"
                RUN_ID=""
            fi
        fi
        [[ -n "$RUN_ID" ]] && break
        sleep 5
    done
    [[ -n "$RUN_ID" ]] || die "60s 内未找到 v${VERSION} 的 Release workflow run（若 tag 被删过重推，--branch 列表里的旧 run 会被 headSha 校验过滤，确认新 run 是否注册）— 用 gh run list --workflow=release.yml 手动确认"

    log "watch Release workflow run ${RUN_ID}（构建/测试/打包/签名/发布/tap，约 10-20 min）..."
    gh run watch "$RUN_ID" --exit-status --interval 30 \
        || die "Release workflow 失败 — 排查: gh run view ${RUN_ID} --log-failed"
    ok "Release workflow 成功"

    # REL-25 (2026-08-05 review): `gh run watch --exit-status` proves the
    # whole workflow exited 0, but if release.yml ever passes `--skip-tests`
    # (or the test job is non-blocking), a red test suite could still ship.
    # Explicitly check the release.yml run's test job conclusion.
    TEST_JOB=$(gh run view "$RUN_ID" --json jobs --jq '.jobs[] | select(.name | test("test|Test")) | .conclusion' 2>/dev/null | head -1)
    if [[ -n "$TEST_JOB" ]]; then
        if [[ "$TEST_JOB" == "success" ]]; then
            ok "release.yml test job: success"
        else
            die "release.yml test job conclusion = '${TEST_JOB:-unknown}' — 测试未全绿，但 release 已发布！不要重跑脚本；手动排查后决定是否回滚（见 RELEASE_PUSH_CHECKLIST §D3）"
        fi
    else
        log "⚠️  release.yml 无 test job（或查询失败）— 无法确认测试状态，发布后请手动验证"
    fi

    # REL-18 (2026-08-02 review): under set -e a bare failing call killed the
    # script here, so the "剩余手动步骤" below never printed on verify failure.
    # Explicit if/else: failure keeps exit 1 but says the release IS already
    # live on GitHub and where to dig; success prints the remaining steps.
    if verify_release_remote "$VERSION"; then
        if [[ ${VERIFY_INSTALL:-0} -eq 1 ]]; then
            echo ""
            echo "=== 安装验证（--verify-install）==="
            if verify_install "$VERSION"; then
                :
            else
                echo "❌ 安装验证失败 — release 已 live，不要重跑本脚本；按上方指引手动处理" >&2
                exit 1
            fi
        fi
        echo ""
        echo "🚀 v${VERSION} 发布完成。剩余手动步骤（RELEASE.md B4.12）："
        echo "   1. brew upgrade --cask clipmemory 本机升级验证 + 首启确认"
        echo "   2. 更新 ~/.claude/projects/-Users-iryke/memory/clipmemory/MEMORY.md 与 ~/Documents/STATUS.md"
        echo "   3. 写 ~/Documents/session-resume/ 会话记录"
        # REL-25 (2026-08-05 review): the three manual steps above were printed
        # but never confirmed — a release could complete with stale memory/STATUS
        # and the next session would have no idea. Add a confirm gate so the
        # operator (human or AI) explicitly acknowledges each one. Non-TTY
        # (AI agent) auto-prints and continues — the memory update is the AI's
        # own job, and blocking here would deadlock the agent mid-release.
        echo ""
        echo "--- 手动步骤确认 (B4.12) ---"
        for step in "brew upgrade --cask clipmemory 并首启验证" "更新 MEMORY.md 与 ~/Documents/STATUS.md" "写 ~/Documents/session-resume/ 记录"; do
            if [[ -t 0 && -e /dev/tty ]]; then
                read -r -p "  已完成: $step ? (y/N) " CONFIRM_STEP < /dev/tty
                [[ "$CONFIRM_STEP" == "y" || "$CONFIRM_STEP" == "Y" ]] \
                    || echo "  ⚠️  未确认: $step — 记得补做"
            else
                echo "  ⏭  非交互环境跳过确认（请记得补做）: $step"
            fi
        done
        echo "✅ v${VERSION} 发布流程完整结束"
    else
        echo "" >&2
        echo "❌ 发布后验证未过，但 release 已在 GitHub 上 — 不要重跑本脚本（版本号/tag 已占用）" >&2
        echo "   手动排查: gh run view ${RUN_ID}；逐项对照 docs/RELEASE_PUSH_CHECKLIST.md §D3 修复后手动重验" >&2
        exit 1
    fi
fi
