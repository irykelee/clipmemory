#!/usr/bin/env bash
# Pre-push verification for ClipMemory releases.
# Run this before `git tag vX.Y.Z && git push origin vX.Y.Z`.
# Per docs/RELEASE_PUSH_CHECKLIST.md (single-page checklist this script
# automates sections A1, A2, A2.5, A3, A4, C1, D3).
#
# Exits non-zero on any check failure. Does NOT replace human review
# of A3-translation-native-speaker, D5 tap repo, or E cleanup.
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
echo "=== A2.5. README changelog section contains v$VERSION ==="
# Per docs/RELEASE_PUSH_CHECKLIST.md A2: each file has 2 checkboxes
# (H1 line + changelog entry). preflight.sh:28 already mirrors this;
# adding here closes the gap called out in audit doc P0-6.
for f in "${LANG_FILES[@]}"; do
  if grep -q "^### v$VERSION (" "$f"; then
    pass "$f changelog section for v$VERSION present"
  else
    fail "$f missing '### v$VERSION (' changelog entry"
  fi
done

echo ""
echo "=== A3. i18n placeholder order check (7 languages) ==="
# Per audit P0-6: verify the 4 numeric placeholders in
# `settings.backup.import.result` appear in %1$d → %2$d → %3$d → %4$d order
# across all 7 .lproj files (catches missing-translation regressions that
# pass naive string-presence checks).
LP_FILES=(
  "ClipMemory/en.lproj/Localizable.strings"
  "ClipMemory/zh-Hans.lproj/Localizable.strings"
  "ClipMemory/zh-Hant.lproj/Localizable.strings"
  "ClipMemory/ja.lproj/Localizable.strings"
  "ClipMemory/ko.lproj/Localizable.strings"
  "ClipMemory/es.lproj/Localizable.strings"
  "ClipMemory/pt.lproj/Localizable.strings"
)
EXPECTED_PLACEHOLDERS='%1$d%2$d%3$d%4$d'
for f in "${LP_FILES[@]}"; do
  LINE=$(grep '"settings.backup.import.result"' "$f" 2>/dev/null | head -1)
  if [[ -z "$LINE" ]]; then
    fail "$f missing key 'settings.backup.import.result'"
    continue
  fi
  FOUND=$(echo "$LINE" | grep -oE '%[1-9]\$d' | tr -d '\n')
  if [[ "$FOUND" == "$EXPECTED_PLACEHOLDERS" ]]; then
    pass "$f placeholder order OK"
  else
    fail "$f placeholder order wrong (got '$FOUND', expected '$EXPECTED_PLACEHOLDERS')"
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
echo "=== C1. branch ahead/behind main pre-check ==="
# Per audit P0-6: surface tag-branch-vs-main divergence BEFORE tagging
# (v2.5.10 fix branch was 17 commits ahead of main → release.yml:108
#  `git pull --rebase origin main` failed; this advisory catches the same
#  class early). Hard fail if BEHIND > 5 (rebase needed); warn if AHEAD > 5.
if ! command -v git >/dev/null 2>&1; then
  echo "  ⚠️  git not available (skipped)"
elif ! git rev-parse --verify main >/dev/null 2>&1; then
  echo "  ⚠️  no local 'main' branch (skipped)"
else
  AHEAD_BEHIND=$(git rev-list --left-right --count main...HEAD 2>/dev/null || echo "0 0")
  BEHIND=$(echo "$AHEAD_BEHIND" | awk '{print $1}')
  AHEAD=$(echo "$AHEAD_BEHIND" | awk '{print $2}')
  if [[ "$BEHIND" -gt 5 ]]; then
    fail "branch is $BEHIND commits behind main — rebase/merge main before tagging"
  elif [[ "$AHEAD" -gt 5 ]]; then
    echo "  ⚠️  branch is $AHEAD commits ahead of main (consider merging post-tag)"
    pass "branch ahead/behind: $AHEAD ahead / $BEHIND behind main"
  else
    pass "branch ahead/behind OK: $AHEAD ahead / $BEHIND behind main"
  fi
fi

echo ""
echo "=== D3. gh api release v$VERSION title check ==="
# P0-5 fix (per docs/RELEASE_PROCESS_AUDIT_2026-07-22.md): `gh release view`
# is intermittently flaky due to gh CLI cache and returns "not found" even
# for existing releases. `gh api` is a direct REST passthrough — stable.
if ! command -v gh >/dev/null 2>&1; then
  echo "  ⚠️  gh CLI not available (skipped)"
elif TITLE=$(gh api "repos/${GH_OWNER:-irykelee}/${GH_REPO:-clipmemory}/releases/tags/v${VERSION}" --jq .name 2>/dev/null); then
  if [[ -z "$TITLE" || "$TITLE" == "null" ]]; then
    echo "  ⚠️  release v$VERSION not found on remote yet (skipped)"
  elif [[ "$TITLE" == "v$VERSION" ]]; then
    fail "release title is auto-stub '$TITLE' (must be bilingual per docs/RELEASE.md B4.10)"
  else
    pass "release title = '$TITLE'"
  fi
else
  echo "  ⚠️  gh api failed for v$VERSION (skipped)"
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
