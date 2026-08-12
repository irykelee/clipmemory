#!/usr/bin/env bash
# Scripts/lint-audit-ids.sh
# L18 enforcement: audit finding references must use ID-DOMAIN-NNNN format.
# Catches: [HIGH-N] [MEDIUM-N] [LOW-N] / H-N / M-N / L-N in commit messages,
# added lines in changed files, and PR body.
# Exit: 0 = pass, 1 = violation, 2 = bad invocation.
#
# Usage:
#   lint-audit-ids.sh                 # check commits since main + staged/working changes
#   lint-audit-ids.sh --base main     # check commits since main
#   lint-audit-ids.sh --staged        # check staged changes only
#   lint-audit-ids.sh --diff <ref>    # check changes from <ref> to HEAD
#   lint-audit-ids.sh --files <path>  # check specific file/dir
#
# Allow list (when ID-DOMAIN-NNNN is co-located, we accept):
#   - Lines that also contain ID-[A-Z]+-[0-9]{4}
#   - Files: CLAUDE.md (intentional H-/M- ledger references),
#            docs/superpowers/audits/* (historical audit references),
#            feedback/* (L18 retro correction itself)
set -uo pipefail

VIOLATIONS=0
BASE="main"
MODE="all"
TARGET_FILES=()

print_help() {
  sed -n '2,15p' "$0"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --staged) MODE="staged"; shift ;;
    --diff) MODE="diff"; DIFF_TARGET="$2"; shift 2 ;;
    --files) MODE="files"; shift; TARGET_FILES=("$@"); break ;;
    -h|--help) print_help ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Patterns that indicate non-standard audit ID reference.
# These are the formats used in 2026-08-12 audit report (H-1..H-6, M-1..M-8, L-1..L-15).
# We allow ID-DOMAIN-NNNN (4 digits), so the regex below excludes those lines.
BAD_PATTERN='\[?(HIGH|MEDIUM|LOW)\]?-[0-9]+\]?'
GOOD_PATTERN='ID-[A-Z]+-[0-9]{4}'

# Allow-list: files where non-standard ID references are intentional historical record.
is_allowlisted() {
  # Compare both basename and tail-match for absolute paths.
  local basename="${1##*/}"
  local tail="${1#*/Users/iryke/Projects/ClipMemory/}"
  local abs_tail="${1#${HOME}/.claude/projects/-Users-iryke-Projects-ClipMemory/}"
  case "$basename" in
    CLAUDE.md) return 0 ;;
  esac
  case "$tail" in
    CLAUDE.md) return 0 ;;
    docs/superpowers/audits/*) return 0 ;;
    Scripts/lint-audit-ids.sh) return 0 ;;
  esac
  case "$abs_tail" in
    memory/*) return 0 ;;  # Memory files document retro corrections
    memory/feedback/*) return 0 ;;
  esac
  return 1
}

check_line() {
  local source="$1" line="$2"
  # Skip lines that already contain a valid ID-DOMAIN-NNNN
  if echo "$line" | grep -qE "$GOOD_PATTERN"; then
    return 0
  fi
  # Skip lines that don't match the bad pattern at all
  if ! echo "$line" | grep -qE "$BAD_PATTERN"; then
    return 0
  fi
  # Match found, no valid ID co-located → violation
  echo "  ✗ $source"
  echo "    line: $line"
  VIOLATIONS=$((VIOLATIONS + 1))
}

check_file() {
  local file="$1" label="$2"
  is_allowlisted "$file" && return 0
  case "$file" in
    *.md|*.swift|*.yml|*.yaml|*.sh|*.txt) ;;
    *) return 0 ;;
  esac
  while IFS= read -r line; do
    check_line "$label: $file" "$line"
  done < "$file"
}

echo "=== L18 audit-ID lint ==="
echo "Mode: $MODE  Base: $BASE"
echo ""

# Mode 1: check commits in range
if [ "$MODE" = "all" ] || [ "$MODE" = "diff" ]; then
  RANGE="${DIFF_TARGET:-$BASE}..HEAD"
  echo "--- Commits in $RANGE ---"
  while IFS=$'\t' read -r commit subject body; do
    [ -z "$commit" ] && continue
    check_line "commit $commit subject" "$subject"
    [ -n "$body" ] && while IFS= read -r body_line; do
      check_line "commit $commit body" "$body_line"
    done <<< "$body"
  done < <(git log --pretty=format:'%H%x09%s%x09%b' "$RANGE")
  echo ""
  # Also check files changed in the range (--diff mode must catch both commits AND files)
  echo "--- Files changed in $RANGE ---"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    is_allowlisted "$file" && continue
    case "$file" in
      *.md|*.swift|*.yml|*.yaml|*.sh|*.txt) ;;
      *) continue ;;
    esac
    while IFS= read -r added_line; do
      check_line "diff: $file" "$added_line"
    done < <(git diff --no-color "$RANGE" -- "$file" | grep -E '^\+' | grep -vE '^\+\+\+')
  done < <(git diff --name-only "$RANGE")
  echo ""
fi

# Mode 2: check staged changes
if [ "$MODE" = "all" ] || [ "$MODE" = "staged" ]; then
  echo "--- Staged changes ---"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    while IFS= read -r added_line; do
      check_line "staged: $file" "$added_line"
    done < <(git diff --cached --no-color -- "$file" | grep -E '^\+' | grep -vE '^\+\+\+')
  done < <(git diff --cached --name-only)
  echo ""
fi

# Mode 3: check working tree changes (uncommitted)
if [ "$MODE" = "all" ]; then
  echo "--- Working tree changes ---"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    while IFS= read -r added_line; do
      check_line "working: $file" "$added_line"
    done < <(git diff --no-color -- "$file" | grep -E '^\+' | grep -vE '^\+\+\+')
  done < <(git diff --name-only)
  echo ""
fi

# Mode 4: check specific files
if [ "$MODE" = "files" ]; then
  echo "--- Specific files ---"
  for file in "${TARGET_FILES[@]}"; do
    [ -f "$file" ] || continue
    check_file "$file" "explicit"
  done
  echo ""
fi

echo "=== Summary ==="
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "FAIL: $VIOLATIONS L18 ID-format violation(s) found"
  echo ""
  echo "Audit finding references must use ID-DOMAIN-NNNN format (e.g., ID-STORE-0015)."
  echo "Old formats [HIGH-N] / M-N / L-N are forbidden by project L18 enforcement."
  echo ""
  echo "Remediation:"
  echo "  1. Replace [HIGH-1] → ID-STORE-0015 (or whatever ID-DOMAIN-NNNN maps to)"
  echo "  2. See ~/.claude/projects/-Users-iryke-Projects-ClipMemory/memory/feedback/audit-2026-08-12-id-renumbering.md"
  echo "     for full mapping table (6 HIGH + 8 MEDIUM + 15 LOW)"
  echo ""
  exit 1
fi
echo "PASS: All audit-ID references use ID-DOMAIN-NNNN format"
exit 0
