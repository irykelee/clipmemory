#!/usr/bin/env bash
# safe_push.sh — wrapper that runs pre_push_main_sync.sh before `git push`.
#
# Why this exists (v2.5.11 ship review): core.hooksPath is set globally to
# /Users/iryke/bin/git-hooks (the system pre-commit hook), so wiring
# pre_push_main_sync.sh as a repo-local pre-push hook would break the
# existing 3-check pre-commit. This wrapper is the alternative.
#
# Three ways to use it:
#   1. Run directly:  bash Scripts/safe_push.sh origin main
#   2. Add as a git alias (one-time per machine):
#        git config alias.push '!f() { bash Scripts/safe_push.sh "$@"; }; f'
#      Then `git push origin main` automatically runs pre-push sync first.
#      To undo: git config --unset alias.push
#   3. Add as a Makefile target (not present yet — add when more wrappers exist)
#
# What it does:
#   1. Runs Scripts/pre_push_main_sync.sh — fast-forwards local main to
#      origin/main when safe (the v2.5.10 / v2.5.11 ship delay root cause),
#      or refuses with recovery steps when local has unpushed work.
#   2. Forwards all args to `git push` (so `bash Scripts/safe_push.sh origin v2.5.11`
#      pushes the v2.5.11 tag).
#
# Exit codes:
#   0  — sync succeeded (or no-op) + push succeeded
#   1  — sync detected dirty working tree (refused)
#   2  — sync detected diverged local main (refused, recovery needed)
#   *  — anything else = `git push` exit code
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/pre_push_main_sync.sh"

# All checks passed — forward to git push.
exec git push "$@"