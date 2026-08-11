#!/usr/bin/env bash
# rollback-release.sh — undo a broken vX.Y.Z release (REL-25, 2026-08-05).
#
# WHY: release.sh is designed to never overwrite an existing tag, so a bad
# release is not re-runnable. Manual rollback was scattered across docs and
# never scripted — and AI agents are exactly who gets this wrong (delete tag
# → re-push → stale run with the same tag-name branch, ID-BACKUP-0006).
#
# What it does, in order:
#   1. Sanity: repo clean, on main, VERSION is a valid semver.
#   2. Re-check the GitHub release title (guard: only roll back if it really
#      exists; refuse if the tag is the release commit of main — no, we roll
#      back the TAG + release page, NOT main's code history).
#   3. Delete the GitHub release (keeps the tag; assets removed with it).
#   4. Delete the local + remote tag (this is the deliberate part — the
#      re-push of a same-name tag triggers the stale-run trap; the operator
#      must re-run release.sh which does its own headSha verification).
#   5. Restore version in project.yml to PREV_VERSION (needs the previous
#      version as an argument; the script asks for it).
#   6. Remove the rolled-back <item> from appcast.xml and push main, then
#      purge the jsDelivr mirror of the stale feed.
#   7. Restore the Homebrew tap Cask to PREV_VERSION.
#   8. Print what is still manual (local brew cache).
#
# Steps 6 and 7 were manual echo reminders until 2026-08-11. That was the
# wrong default: release.yml pushes the appcast item and the tap Cask
# automatically, so a rollback that does not undo them leaves the feed
# advertising a version whose tarball 404s (Sparkle offers an update that
# cannot download) and leaves `brew upgrade --cask clipmemory` pointing at
# a deleted release. Rollback is also exactly when an operator is most
# rushed and least likely to work through a printed checklist.
#
# Usage:
#   Scripts/rollback-release.sh vX.Y.Z PREV_VERSION [--yes]
#
# Exit codes: 0 success / 1 gate failed or a remediation step failed
#             / 2 usage / 3 aborted by user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GH_OWNER_REPO="${GH_OWNER:-irykelee}/${GH_REPO:-clipmemory}"

die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "✅ $*"; }
log() { echo "→ $*"; }

valid_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

VERSION="${1:-}"; PREV="${2:-}"; AUTO_YES=0
for arg in "$@"; do [[ "$arg" == "--yes" ]] && AUTO_YES=1; done

[[ -n "$VERSION" && -n "$PREV" ]] || { echo "Usage: $0 vX.Y.Z PREV_VERSION [--yes]" >&2; exit 2; }
VERSION="${VERSION#v}"; PREV="${PREV#v}"
valid_semver "$VERSION" || die "invalid VERSION '$VERSION'"
valid_semver "$PREV"   || die "invalid PREV_VERSION '$PREV'"

cd "$PROJECT_DIR"

# --- Gate 1: clean tree + on main ---
[[ -z "$(git status --porcelain)" ]] || die "工作树不干净 — 先 commit/stash 再回滚"
[[ "$(git branch --show-current)" == "main" ]] || die "必须在 main 分支上回滚"

# --- Gate 2: release exists remotely ---
TITLE=$(gh api "repos/${GH_OWNER_REPO}/releases/tags/v${VERSION}" --jq .name 2>/dev/null || true)
[[ -n "$TITLE" && "$TITLE" != "null" ]] || die "GitHub release v${VERSION} 不存在 — 没有可回滚的发布（检查版本号）"
ok "确认 release v${VERSION} 存在: '$TITLE'"

# --- Confirm gate ---
# Mirrors release.sh:1144 (--verify-install + manual-step confirmation):
# only read /dev/tty when BOTH stdin is a tty AND /dev/tty exists. In
# agent sandboxes / CI runners, /dev/tty may exist but have no listener
# — a bare `read ... < /dev/tty` blocks forever instead of returning EOF
# (exit 137 / timeout). Guard the read so the script dies with exit 3
# (safe: destructive ops are NOT reached) instead of hanging when run
# non-interactively.
if [[ $AUTO_YES -eq 0 ]]; then
    echo "⚠️  即将：删除 GitHub release v${VERSION} + 本地/远端 tag v${VERSION}，"
    echo "   恢复 project.yml 到 v${PREV}，从 appcast.xml 移除 v${VERSION} 条目并 push main，"
    echo "   刷新 jsDelivr 镜像缓存，并把 tap Cask 改回 v${PREV}。"
    echo "   ⚠️  会写入远端：本仓库 main 分支 + homebrew-clipmemory tap 仓库。"
    if [[ -t 0 && -e /dev/tty ]]; then
        read -r -p "输入 yes 确认回滚: " CONFIRM < /dev/tty || CONFIRM=""
        [[ "$CONFIRM" == "yes" ]] || { echo "已中止"; exit 3; }
    else
        echo "❌ 非交互环境无法确认回滚 — 中止（--yes 可跳过，但需显式授权）" >&2
        exit 3
    fi
fi

# --- Step 3: delete GitHub release (keeps tag) ---
gh release delete "v${VERSION}" --yes || die "删除 GitHub release 失败"
ok "GitHub release v${VERSION} 已删除"

# --- Step 4: delete local + remote tag ---
git tag -d "v${VERSION}" >/dev/null 2>&1 || true
git push origin ":refs/tags/v${VERSION}" 2>/dev/null \
    && ok "远端 tag v${VERSION} 已删除" \
    || log "⚠️  远端 tag 删除失败（可能不存在或权限问题）— 手动执行: git push origin :refs/tags/v${VERSION}"

# --- Step 5: restore project.yml version ---
if [[ -f project.yml ]]; then
    sed -i '' -E "s|MARKETING_VERSION: \"[^\"]*\"|MARKETING_VERSION: \"${PREV}\"|" project.yml
    sed -i '' -E "s|CURRENT_PROJECT_VERSION: \"[^\"]*\"|CURRENT_PROJECT_VERSION: \"${PREV}\"|" project.yml
    ok "project.yml 已恢复 v${PREV}（记得 xcodegen generate 重新生成工程）"
fi

# Remediation steps below are best-effort and independent: one failure must
# not skip the others, and it must not be silent. Each records into FAILED
# so the operator gets a complete picture plus a non-zero exit, mirroring
# release.sh's REL-18 pattern (report everything, then fail).
FAILED=0
note_fail() { echo "❌ $*" >&2; FAILED=$((FAILED+1)); }

# --- Step 6: drop the rolled-back <item> from appcast.xml, push main ---
# release.yml already pushed this item. Left in place, Sparkle keeps
# offering v${VERSION} and the download 404s (the release was deleted in
# step 3).
# shellcheck source=./update_appcast.sh
source "${SCRIPT_DIR}/update_appcast.sh"

if [[ -f appcast.xml ]]; then
    log "从 appcast.xml 移除 v${VERSION} 条目..."
    # Rebase onto the remote first: release.yml pushed the appcast commit,
    # so a local main from before the release is behind and the push below
    # would be rejected.
    if ! git pull --ff-only origin main --quiet; then
        note_fail "git pull --ff-only origin main 失败 — appcast 未修改；手动: git pull 后重跑本脚本"
    elif ! remove_appcast_item appcast.xml "$VERSION"; then
        note_fail "remove_appcast_item 失败（appcast 可能格式异常）— 手动检查 appcast.xml"
    elif git diff --quiet -- appcast.xml; then
        ok "appcast.xml 无 v${VERSION} 条目（已是干净状态）"
    else
        git add appcast.xml
        git commit -q -m "chore: drop appcast item for v${VERSION} (rolled back) [skip ci]"
        if git push origin main; then
            ok "appcast.xml 已移除 v${VERSION} 条目并 push 到 main"
            # jsDelivr caches the feed for up to 7 days (max-age=604800), so
            # without an explicit purge the mirror keeps serving the stale
            # item to exactly the users who rely on the fallback channel.
            if curl -sf --max-time 30 "https://purge.jsdelivr.net/gh/irykelee/clipmemory@main/appcast.xml" >/dev/null; then
                ok "jsDelivr 镜像缓存已刷新"
            else
                note_fail "jsDelivr purge 失败 — 手动: curl https://purge.jsdelivr.net/gh/irykelee/clipmemory@main/appcast.xml"
            fi
        else
            note_fail "push main 失败（appcast 改动已 commit 在本地）— 手动: git push origin main"
        fi
    fi
else
    note_fail "appcast.xml 不存在于仓库根 — 跳过 appcast 回滚（异常，请手动确认）"
fi

# --- Step 7: restore the tap Cask to PREV ---
# Regenerated from the same template release.yml uses, so the result is
# byte-identical to what a real v${PREV} release would have produced.
log "恢复 tap Cask 到 v${PREV}..."
PREV_SHA=$(gh api "repos/${GH_OWNER_REPO}/releases/tags/v${PREV}" \
    --jq '.assets[] | select(.name=="ClipMemory.tar.gz") | .digest' 2>/dev/null \
    | sed 's/^sha256://' || true)

if [[ -z "$PREV_SHA" ]]; then
    note_fail "取不到 v${PREV} 的 tarball sha256（release 或资产不存在？）— tap Cask 未恢复，手动改 homebrew-clipmemory/Casks/clipmemory.rb"
elif [[ ! -f "${SCRIPT_DIR}/cask-template.rb" ]]; then
    note_fail "找不到 ${SCRIPT_DIR}/cask-template.rb — tap Cask 未恢复"
else
    TAP_TMP=$(mktemp -d)
    trap 'rm -rf "$TAP_TMP"' EXIT
    if ! git clone --quiet --depth 1 "https://github.com/irykelee/homebrew-clipmemory.git" "$TAP_TMP/tap-repo" 2>/dev/null; then
        note_fail "clone tap 仓库失败 — 手动改 homebrew-clipmemory/Casks/clipmemory.rb 回 v${PREV}"
    else
        mkdir -p "$TAP_TMP/tap-repo/Casks"
        sed -e "s/@VERSION@/${PREV}/" -e "s/@SHA256@/${PREV_SHA}/" \
            "${SCRIPT_DIR}/cask-template.rb" > "$TAP_TMP/tap-repo/Casks/clipmemory.rb"
        if git -C "$TAP_TMP/tap-repo" diff --quiet -- Casks/clipmemory.rb; then
            ok "tap Cask 已是 v${PREV}（无需改动）"
        else
            git -C "$TAP_TMP/tap-repo" add Casks/clipmemory.rb
            git -C "$TAP_TMP/tap-repo" commit -q -m "chore: roll back clipmemory to v${PREV}"
            if git -C "$TAP_TMP/tap-repo" push origin main 2>/dev/null; then
                ok "tap Cask 已恢复到 v${PREV} (sha256: ${PREV_SHA})"
            else
                note_fail "push tap 仓库失败（可能缺少推送权限）— 手动: 在 homebrew-clipmemory 把 clipmemory.rb 改回 v${PREV} / ${PREV_SHA}"
            fi
        fi
    fi
fi

# --- Step 8: what is still manual ---
echo ""
echo "ℹ️  仍需手动处理："
echo "   1. Homebrew 本地缓存 — brew update && brew reinstall --cask clipmemory 回到 v${PREV}"
echo "   2. 重新发布请重跑 release.sh（它会做 headSha 校验防 stale run）"
echo "   3. 已装 v${VERSION} 的用户不会自动降级 — 视严重程度决定是否公告"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo "❌ 回滚完成，但 ${FAILED} 个补救步骤失败（见上方 ❌）— tag/release 已删除，" >&2
    echo "   请按提示手动收尾后再重新发布。" >&2
    exit 1
fi
ok "回滚脚本完成（appcast / jsDelivr / tap Cask 均已自动处理）"
