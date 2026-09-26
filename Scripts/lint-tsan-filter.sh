#!/usr/bin/env bash
# Scripts/lint-tsan-filter.sh
# ID-CI-0010 (2026-09-26): prevents the "class rename → stale
# -only-testing filter" bug class. tsan.yml:39 + :69-77 enumerate
# 9 test classes to run under TSan. The cdda2a6 (PR #86) commit
# renamed NetworkMonitorTests → NetworkMonitorProtocolTests
# without updating tsan.yml; the stale filter then matched 0
# tests for that class, dropping 6 race-prone tests from TSan
# coverage silently. ID-CI-0007 (a4f87e2) fixed the immediate
# symptom; this script prevents the next occurrence.
#
# Two failure modes:
#   1. Filter references a class that doesn't exist in
#      Tests/ClipMemoryTests/ (class rename / file delete)
#   2. Test function count in the listed classes doesn't
#      match SUBSET_EXPECTED in tsan.yml:39 (drift)
#
# SUBSET_EXPECTED is read from tsan.yml:39 — single source of
# truth. Don't hardcode the number anywhere else (CLAUDE.md
# ID-TEST-0002).
#
# Scans both .github/workflows/tsan.yml (TSan subset) and
# Scripts/regenerate-snapshots.sh (snapshot regen subset) for
# -only-testing entries. Add new scan files to SCAN_FILES if
# another shell invocation references -only-testing.
#
# Usage: Scripts/lint-tsan-filter.sh
# Wired into ci.yml lint-ids job (per ID-CI-0010).
#
# bash compat: stock macOS /bin/bash 3.2 lacks `declare -A`,
# so per-class counts use parallel arrays. CI (ubuntu bash 5)
# has associative arrays but the parallel-array form is portable.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

WORKFLOW="$ROOT/.github/workflows/tsan.yml"
[[ -f "$WORKFLOW" ]] || { echo "❌ $WORKFLOW not found"; exit 1; }

TESTS_DIR="$ROOT/Tests/ClipMemoryTests"
[[ -d "$TESTS_DIR" ]] || { echo "❌ $TESTS_DIR not found"; exit 1; }

# 0. Read SUBSET_EXPECTED from tsan.yml — single source of truth.
EXPECTED_COUNT=$(grep -E "^\s*SUBSET_EXPECTED:" "$WORKFLOW" \
                   | head -1 \
                   | sed -E "s/.*SUBSET_EXPECTED:[[:space:]]*'([0-9]+)'.*/\1/")
[[ -n "$EXPECTED_COUNT" ]] || { echo "❌ Could not parse SUBSET_EXPECTED from $WORKFLOW (expected format: SUBSET_EXPECTED: '94')"; exit 1; }

# Files to scan for -only-testing entries. tsan.yml is the main one;
# regenerate-snapshots.sh has 4 snapshot test class refs that could
# rot the same way (auto-review P2 #5 follow-up, 2026-09-26). Add
# new files here as they appear — single edit, both files get checked.
SCAN_FILES=(
    "$WORKFLOW"
    "$ROOT/Scripts/regenerate-snapshots.sh"
)

FAILS=0

# 1. For each scanned file: extract -only-testing:ClipMemoryTests/X
# and verify each class exists as a real XCTestCase somewhere.
for file in "${SCAN_FILES[@]}"; do
    [[ -f "$file" ]] || { echo "❌ $file not found (skipped)"; continue; }
    FILTER_CLASSES=$(grep -E "^\s*-only-testing:ClipMemoryTests/" "$file" \
                       | sed -E 's|.*/||; s|[[:space:]]*\\$||' \
                       | sort -u)
    [[ -z "$FILTER_CLASSES" ]] && continue

    declare -a MISSING_IN_FILE=()
    for cls in $FILTER_CLASSES; do
        file_match=$(grep -rlE "(final )?class ${cls}\b.*XCTestCase" "$TESTS_DIR" 2>/dev/null | head -1 || true)
        if [[ -z "$file_match" ]]; then
            MISSING_IN_FILE+=("$cls")
            FAILS=$((FAILS+1))
        fi
    done

    if [[ ${#MISSING_IN_FILE[@]} -gt 0 ]]; then
        rel="${file#$ROOT/}"
        echo "❌ ${rel}: ${#MISSING_IN_FILE[@]} non-existent test class(es) referenced:"
        for m in "${MISSING_IN_FILE[@]}"; do
            echo "   - ClipMemoryTests/$m"
        done
        echo "   No (final )class ${m} : XCTestCase found in any Tests/ClipMemoryTests/*.swift."
        echo "   → cdda2a6 (PR #86) was the same failure: NetworkMonitorTests"
        echo "     was renamed to NetworkMonitorProtocolTests; tsan.yml kept the"
        echo "     old name; 6 tests silently stopped running under TSan."
        echo "   Fix: either rename the class back, or update $rel to the new name."
    fi
done

# 2. TSan-specific count check (only meaningful for tsan.yml, not
# regenerate-snapshots.sh which doesn't have a fixed expected count).
declare -a CLASS_NAMES=() CLASS_COUNTS=()
ACTUAL_COUNT=0
FILTER_CLASSES=$(grep -E "^\s*-only-testing:ClipMemoryTests/" "$WORKFLOW" \
                   | sed -E 's|.*/||; s|[[:space:]]*\\$||' \
                   | sort -u)
for cls in $FILTER_CLASSES; do
    file=$(grep -rlE "(final )?class ${cls}\b.*XCTestCase" "$TESTS_DIR" 2>/dev/null | head -1 || true)
    if [[ -z "$file" ]]; then
        CLASS_NAMES+=("$cls")
        CLASS_COUNTS+=("?")
        continue
    fi
    n=$(grep -cE "^[[:space:]]*func test[A-Za-z0-9_]+" "$file" 2>/dev/null || true)
    n=${n:-0}
    n=$(echo "$n" | tr -d '[:space:]')
    n=${n:-0}
    ACTUAL_COUNT=$((ACTUAL_COUNT + n))
    CLASS_NAMES+=("$cls")
    CLASS_COUNTS+=("$n")
done

if [[ "$ACTUAL_COUNT" != "$EXPECTED_COUNT" ]]; then
    echo "❌ tsan.yml test count drift: SUBSET_EXPECTED=${EXPECTED_COUNT}, actual=${ACTUAL_COUNT}"
    echo "   Both come from the same single source (tsan.yml:39)."
    echo "   Subsets listed: $(echo "$FILTER_CLASSES" | wc -l | tr -d ' ') classes"
    echo "   Per-class breakdown:"
    for i in "${!CLASS_NAMES[@]}"; do
        printf "     %-50s %s\n" "${CLASS_NAMES[$i]}:" "${CLASS_COUNTS[$i]}"
    done
    echo "   Fix: update SUBSET_EXPECTED in tsan.yml:39 to match the actual count."
    FAILS=$((FAILS+1))
fi

if [[ $FAILS -gt 0 ]]; then
    echo ""
    echo "❌ $FAILS lint-tsan-filter check(s) FAILED"
    exit 1
fi

echo "✅ all -only-testing filters OK: $(echo "$FILTER_CLASSES" | wc -l | tr -d ' ') classes in tsan.yml, ${ACTUAL_COUNT} tests (expected ${EXPECTED_COUNT}); regenerate-snapshots.sh filter also verified"