#!/usr/bin/env bash
# Pre-push verification for ClipMemory releases.
# Run this before `git tag vX.Y.Z && git push origin vX.Y.Z`.
# Per docs/RELEASE_PUSH_CHECKLIST.md (single-page checklist this script
# automates sections A1, A2-H1-only, A4, D3-stub-detection).
#
# Exits non-zero on any check failure. Does NOT replace human review
# of A2 changelog sections, A3 translation, or D5 tap repo.
#
# Usage: ./Scripts/pre_push_verify.sh vX.Y.Z [expected_prev_version]
#   example: ./Scripts/pre_push_verify.sh v2.5.7 v2.5.6

set -euo pipefail

VERSION="${1:-}"
PREV_VERSION="${2:-}"

# Strip leading 'v' if present (allow both v2.5.7 and 2.5.7 as arg)
VERSION="${VERSION#v}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 vX.Y.Z [expected_prev_version]" >&2
  exit 2
fi

fail() { echo "  ❌ $*"; FAILS=$((FAILS+1)); }
pass() { echo "  ✅ $*"; }
FAILS=0

echo "=== A1. project.yml version check ==="
MARKETING=$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
if [[ "$MARKETING" == "$VERSION" ]]; then
  pass "MARKETING_VERSION = $VERSION"
else
  fail "MARKETING_VERSION is '$MARKETING', expected '$VERSION'"
fi
if [[ "$BUILD" == "$VERSION" ]]; then
  pass "CURRENT_PROJECT_VERSION = $VERSION"
else
  fail "CURRENT_PROJECT_VERSION is '$BUILD', expected '$VERSION'"
fi

echo ""
echo "=== A2. 8 README files H1 version line ==="
LANG_FILES=(
  "README.md"
  "docs/lang/README_EN.md"
  "docs/lang/README_ZH-HANT.md"
  "docs/lang/README_JA.md"
  "docs/lang/README_KO.md"
  "docs/lang/README_ES.md"
  "docs/lang/README_PT.md"
)
# ZH-HANS version of file 1 is the "root" — check that it has a Chinese
# release-notes section.
# The 7 langs share the same file content pattern: H1 vX.Y.Z.

for f in "${LANG_FILES[@]}"; do
  H1=$(head -1 "$f" | tr -d '\r')
  if [[ "$H1" == *"v$VERSION"* ]]; then
    pass "$f H1 = '$H1'"
  else
    fail "$f H1 = '$H1' (expected to contain v$VERSION)"
  fi
done

echo ""
echo "=== A4. Casks/clipmemory.rb version check ==="
CASK_VERSION=$(awk -F'"' '/version "/ {print $2; exit}' Casks/clipmemory.rb)
if [[ "$CASK_VERSION" == "$VERSION" ]]; then
  pass "Casks/clipmemory.rb version = $VERSION"
else
  fail "Casks/clipmemory.rb version = '$CASK_VERSION' (expected '$VERSION')"
fi

echo ""
echo "=== D3. gh release view v$VERSION title check ==="
if command -v gh >/dev/null 2>&1; then
  if gh release view "$VERSION" >/dev/null 2>&1; then
    TITLE=$(gh release view "$VERSION" --json name -q '.name' 2>/dev/null || \
           gh release view "$VERSION" 2>&1 | grep '^title:' | awk '{print $2}')
    if [[ "$TITLE" == "v$VERSION" ]]; then
      fail "release title is auto-generated stub '$TITLE' (per docs/RELEASE.md B4.10: must be bilingual)"
    else
      pass "release title = '$TITLE' (looks bilingual / human-authored)"
    fi
  else
    echo "  ⚠️  release $VERSION not found on remote yet (skipped)"
  fi
else
  echo "  ⚠️  gh CLI not available (skipped)"
fi

echo ""
if [[ "$FAILS" -eq 0 ]]; then
  echo "✅ All automated checks pass.  Manual sections (A2 changelog, A3 translation,"
  echo "   D5 tap repo, E cleanup) still need human review per checklist."
  exit 0
else
  echo "❌ $FAILS check(s) failed.  See checklist docs/RELEASE_PUSH_CHECKLIST.md."
  exit 1
fi
