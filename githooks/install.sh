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

# Per user 2026-08-08 review: this MUST run BEFORE the existing-hook
# guard. The guard's early-exit (`exit 0` on existing .git/hooks/pre-commit)
# is intentional for first-time install — but on RE-runs (after
# pulling githooks/ changes), the guard skips the cp AND would also
# skip the git config below. Without the git config, the LOCAL hook
# is masked by global core.hooksPath = /Users/iryke/bin/git-hooks
# and the fix silently breaks. So: set core.hooksPath FIRST, then
# maybe overwrite the hook.
git config --local core.hooksPath .git/hooks

# Don't overwrite an existing local hook unless --force
if [ -f "$HOOK_DST" ] && [ "$1" != "--force" ]; then
    echo "⚠️  Hook already exists at $HOOK_DST (use --force to overwrite)"
    echo "   core.hooksPath already set to .git/hooks above"
    exit 0
fi

cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"

echo "✅ Installed pre-commit hook to $HOOK_DST"
echo "   Source: $HOOK_SRC"
echo "   Set local core.hooksPath = .git/hooks"
