#!/bin/bash
# githooks/install.sh — install the tracked pre-commit hook into .git/hooks/.
#
# Run once per fresh checkout. After this, .git/hooks/pre-commit is
# a regular file (not symlinked) so local edits don't drift from
# the tracked githooks/pre-commit; re-run this script after pulling
# changes to githooks/pre-commit to update.
#
# Usage:
#   ./githooks/install.sh
#
# Why not symlink: .git/hooks/ symlinks work but get surprising on
# git operations that touch .git/ (some versions of git reset --hard
# clear symlinks). A regular file copy is boring but safe.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$REPO_ROOT/githooks/pre-commit"
HOOK_DST="$REPO_ROOT/.git/hooks/pre-commit"

if [ ! -f "$HOOK_SRC" ]; then
    echo "❌ Source hook not found at $HOOK_SRC"
    exit 1
fi

# Don't overwrite an existing local hook unless --force
if [ -f "$HOOK_DST" ] && [ "$1" != "--force" ]; then
    echo "⚠️  Hook already exists at $HOOK_DST (use --force to overwrite)"
    exit 0
fi

cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"

# Per user 2026-08-08 review: local .git/hooks/ alone is masked by
# global core.hooksPath. Set the LOCAL core.hooksPath so the local
# hook takes precedence over the global one. (Without this, the
# fix silently breaks on fresh clones — the global mask would still
# win.)
git config --local core.hooksPath .git/hooks

echo "✅ Installed pre-commit hook to $HOOK_DST"
echo "   Source: $HOOK_SRC"
echo "   Set local core.hooksPath = .git/hooks"
