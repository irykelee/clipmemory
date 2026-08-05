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
#   6. Print what was NOT done: appcast.xml / tap Cask / Homebrew cache
#      must be fixed manually (release.yml already pushed those).
#
# Usage:
#   Scripts/rollback-release.sh vX.Y.Z PREV_VERSION [--yes]
#
# Exit codes: 0 success / 1 gate failed / 2 usage / 3 aborted by user.
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
    echo "⚠️  即将：删除 GitHub release v${VERSION} + 本地/远端 tag v${VERSION}"
    echo "   并恢复 project.yml 到 v${PREV}。"
    echo "   ⚠️  appcast.xml / tap Cask 已被 release.yml 推送到 main/远端，"
    echo "      本脚本不会自动修复它们——回滚后需要手动处理。"
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

# --- Step 6: what is NOT done ---
echo ""
echo "⚠️  回滚完成，但以下需要手动处理："
echo "   1. appcast.xml（release.yml 已推送到 main）— 若 v${VERSION} 条目已入，需移除"
echo "   2. tap Cask（homebrew-clipmemory）— 若版本已更新，需改回 v${PREV}"
echo "   3. Homebrew 本地缓存 — brew untap / 重装回 v${PREV}"
echo "   4. 重新发布请重跑 release.sh v${PREV}（它会做 headSha 校验防 stale run）"
echo ""
ok "回滚脚本完成（部分手动项见上）"
