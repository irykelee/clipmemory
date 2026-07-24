#!/usr/bin/env bash
# v2.5.11 ship review: local main often diverges from origin/main
# (28 unsquashed commits vs 1 squash) because we squash-merge PRs and
# then never rebase the local branch. The divergence then causes
# `git push origin main` to fail with "fetch first" and FF-merges
# from release branches to fail too — adding 5-10 min of manual
# recovery to every release.
#
# Run this BEFORE `git push origin main` or `git push origin vX.Y.Z`:
#   bash Scripts/pre_push_main_sync.sh            # interactive auto-FF when safe
#   bash Scripts/pre_push_main_sync.sh --auto      # same, no prompts
#
# It fetches origin/main, compares the local ref, and either:
#   - skips (already in sync)
#   - auto fast-forwards local main to origin/main (when local is ancestor)
#   - refuses with clear recovery instructions (when local has unpushed work)
#
# core.hooksPath is set globally to a system hooks dir, so wiring this
# as a repo-local pre-push hook would break the existing 3-check
# pre-commit. Run this manually before every push instead.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ working tree dirty — commit or stash before pre-push check"
    git status --short
    exit 1
fi

git fetch origin main --quiet

LOCAL=$(git rev-parse main 2>/dev/null || echo "missing")
REMOTE=$(git rev-parse origin/main)

if [[ "$LOCAL" == "missing" ]]; then
    echo "→ local 'main' branch missing — creating from origin/main"
    git branch main "$REMOTE"
    echo "✓ local main now = origin/main"
    exit 0
fi

if [[ "$LOCAL" == "$REMOTE" ]]; then
    echo "✓ local main = origin/main (no divergence)"
    exit 0
fi

# Normal push: remote is ancestor of local — user has local commits to push.
# This is the intended flow for a single-author repo with squash-merge:
# main tracks origin/main but has extra work on top.
if git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
    LOCAL_SHORT=$(git rev-parse --short "$LOCAL")
    REMOTE_SHORT=$(git rev-parse --short "$REMOTE")
    echo "→ local main ($LOCAL_SHORT) is ahead of origin/main ($REMOTE_SHORT)"
    echo "→ normal push scenario — allowing to proceed"
    exit 0
fi

# Try fast-forward: local is ancestor of remote → safe to FF
if git merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
    LOCAL_SHORT=$(git rev-parse --short "$LOCAL")
    REMOTE_SHORT=$(git rev-parse --short "$REMOTE")
    echo "→ local main ($LOCAL_SHORT) is ancestor of origin/main ($REMOTE_SHORT)"
    echo "→ fast-forwarding local main to origin/main (this is the v2.5.11 + v2.5.10 race fix)"
    git checkout main
    git merge --ff-only "$REMOTE"
    echo "✓ local main now = origin/main"
    exit 0
fi

# Diverged — local has unpushed work. Refuse + give recovery options.
LOCAL_SHORT=$(git rev-parse --short "$LOCAL")
REMOTE_SHORT=$(git rev-parse --short "$REMOTE")
echo "✗ local main ($LOCAL_SHORT) diverged from origin/main ($REMOTE_SHORT)"
echo ""
echo "  local main is NOT an ancestor of origin/main — fast-forward impossible."
echo "  This means local main has commits not yet on origin/main. Usually"
echo "  you don't want this (single-author repo, squash-merge workflow):"
echo "  main should be a pure mirror of origin/main."
echo ""
echo "  Recommended fix (single-author + squash-merge): delete local main"
echo "  so future 'git checkout main' recreates it from origin/main."
echo ""
echo "  Recovery steps:"
echo "    1. Make sure your actual work is on a feature branch:"
echo "         git branch -a | grep -v HEAD  # list all branches"
echo "         # any commit on local main should also be on a feature branch"
echo "    2. Delete the local main ref (Xcode and other tools will re-fetch"
echo "       it from origin/main next time):"
echo "         git update-ref -d refs/heads/main"
echo "    3. Re-create main from origin:"
echo "         git checkout main"
echo "    4. Verify:"
echo "         bash Scripts/pre_push_main_sync.sh"
echo ""
echo "  If you really do have intentional local main commits, cherry-pick"
echo "  them to a feature branch first, THEN delete local main."
echo ""
echo "  Refusing to push until this is resolved."
exit 2
