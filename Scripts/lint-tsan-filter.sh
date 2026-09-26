#!/usr/bin/env bash
# Scripts/lint-tsan-filter.sh
# ID-CI-0010 (2026-09-26): prevents the "class rename → stale
# -only-testing filter" bug class. tsan.yml:69-77 enumerates
# 9 test classes to run under TSan. The cdda2a6 (PR #86) commit
# renamed NetworkMonitorTests to NetworkMonitorProtocolTests
# without updating tsan.yml; the stale filter then matched 0
# tests for that class, dropping 6 race-prone tests from TSan
# coverage silently. ID-CI-0007 (a4f87e2) fixed the immediate
# symptom; this script prevents the next occurrence.
#
# Two failure modes:
#   1. Filter references a class that doesn't exist in
#      Tests/ClipMemoryTests/ (class rename / file delete)
#   2. Test function count in the listed classes doesn't
#      match the hardcoded subset count in tsan.yml (drift)
#
# Usage: Scripts/lint-tsan-filter.sh [--diff <base>]
#   default: scan current working tree
#   --diff <base>: only consider files changed since <base>
#
# Wired into ci.yml lint-ids job (per ID-CI-0010).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

WORKFLOW="$ROOT/.github/workflows/tsan.yml"
[[ -f "$WORKFLOW" ]] || { echo "❌ $WORKFLOW not found"; exit 1; }

TESTS_DIR="$ROOT/Tests/ClipMemoryTests"
[[ -d "$TESTS_DIR" ]] || { echo "❌ $TESTS_DIR not found"; exit 1; }

# Hardcoded baseline. Must match SUBSET_EXPECTED in tsan.yml job env.
# Update both together when adding/removing a race-prone test class.
EXPECTED_COUNT=94

# 1. Extract all -only-testing:ClipMemoryTests/X from tsan.yml
FILTER_CLASSES=$(grep -E "^\s*-only-testing:ClipMemoryTests/" "$WORKFLOW" \
                   | sed -E 's|.*/||; s|[[:space:]]*\\$||' \
                   | sort -u)

[[ -n "$FILTER_CLASSES" ]] || { echo "❌ No -only-testing entries found in $WORKFLOW"; exit 1; }

# 2. Verify each class is declared somewhere in Tests/ClipMemoryTests/.
# IMPORTANT: -only-testing matches by CLASS NAME, not file name. A class
# can live in a different-named file (e.g. NetworkMonitorProtocolTests
# is declared in NetworkMonitorTests.swift after the cdda2a6 P1-7 refactor).
# So we grep all test files for the class declaration, not just the
# file with the matching name.
FAILS=0
declare -a MISSING=()
for cls in $FILTER_CLASSES; do
    # `class X:` or `final class X:` or `class X : XCTestCase, ...` — any
    # whitespace and any class kind. Must be followed by a word boundary
    # so e.g. `ClipboardMonitorTests` doesn't accidentally match
    # `ClipboardMonitorSkipWindowTests`.
    if grep -rqE "(^| |\t)(final )?class ${cls}\b" "$TESTS_DIR"; then
        continue
    fi
    MISSING+=("$cls")
    FAILS=$((FAILS+1))
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "❌ tsan.yml filter references ${#MISSING[@]} non-existent class(es):"
    for m in "${MISSING[@]}"; do
        echo "   - ClipMemoryTests/$m"
    done
    echo "   Class declaration not found in any Tests/ClipMemoryTests/*.swift."
    echo "   → cdda2a6 (PR #86) was the same failure: NetworkMonitorTests"
    echo "     was renamed to NetworkMonitorProtocolTests; tsan.yml kept the"
    echo "     old name; 6 tests silently stopped running under TSan."
    echo "   Fix: either rename the class back, or update tsan.yml to the new name."
fi

# 3. Count tests in the listed classes and compare to expected.
# Note: a class may be declared in a different-named file, so we count
# via the same grep-based class-match. This is a static estimate; the
# authoritative count comes from xcodebuild test.
ACTUAL_COUNT=0
declare -A CLASS_COUNT=()
for cls in $FILTER_CLASSES; do
    # Find the file that declares the class (any class kind: class/final
    # class; must be followed by `: XCTestCase` for test classes). Use
    # grep -l (list filenames) and pick the first match.
    file=$(grep -rlE "(^| |\t)(final )?class ${cls}\b.*:[[:space:]]*XCTestCase" "$TESTS_DIR" 2>/dev/null | head -1 || true)
    if [[ -z "$file" ]]; then
        # Class not found at all — skip count, already reported above
        continue
    fi
    n=$(grep -cE "^[[:space:]]*func test[A-Za-z0-9_]+" "$file" 2>/dev/null || echo 0)
    n=${n:-0}
    ACTUAL_COUNT=$((ACTUAL_COUNT + n))
    CLASS_COUNT[$cls]=$n
done

if [[ "$ACTUAL_COUNT" != "$EXPECTED_COUNT" ]]; then
    echo "❌ Test count drift: expected ${EXPECTED_COUNT}, actual ${ACTUAL_COUNT}"
    echo "   tsan.yml SUBSET_EXPECTED=${EXPECTED_COUNT} (job-level env)"
    echo "   Subsets listed: $(echo "$FILTER_CLASSES" | wc -l | tr -d ' ') classes"
    echo "   Per-class breakdown:"
    for cls in $FILTER_CLASSES; do
        printf "     %-50s %s\n" "$cls:" "${CLASS_COUNT[$cls]:-?}"
    done
    echo "   Fix: update SUBSET_EXPECTED in tsan.yml env (and the assertion"
    echo "   step's SUBSET_EXPECTED env) to match the actual count."
    FAILS=$((FAILS+1))
fi

if [[ $FAILS -gt 0 ]]; then
    echo ""
    echo "❌ $FAILS lint-tsan-filter check(s) FAILED"
    exit 1
fi

echo "✅ tsan.yml filter OK: $(echo "$FILTER_CLASSES" | wc -l | tr -d ' ') classes, ${ACTUAL_COUNT} tests (expected ${EXPECTED_COUNT})"