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

# 1. Extract all -only-testing:ClipMemoryTests/X from tsan.yml
FILTER_CLASSES=$(grep -E "^\s*-only-testing:ClipMemoryTests/" "$WORKFLOW" \
                   | sed -E 's|.*/||; s|[[:space:]]*\\$||' \
                   | sort -u)

[[ -n "$FILTER_CLASSES" ]] || { echo "❌ No -only-testing entries found in $WORKFLOW"; exit 1; }

# Class-name match: `(^| )(final )?class X` followed (same line) by
# `XCTestCase`. Same-line requirement prevents matching commented-out
# declarations or non-test classes that happen to share a name.
# `.*XCTestCase` (not `:[[:space:]]*XCTestCase`) tolerates `@MainActor
# XCTestCase` and similar attribute decorations.
CLASS_RE="(final )?class ([A-Za-z0-9]+).*XCTestCase"

# 2. Verify each class exists as a real XCTestCase somewhere in
# Tests/ClipMemoryTests/. -only-testing matches by CLASS NAME, not file
# name, so we grep all test files (a class can live in a differently
# named file — e.g. NetworkMonitorProtocolTests is declared in
# NetworkMonitorTests.swift after the P1-7 refactor).
FAILS=0
declare -a MISSING=() CLASS_FILES=()
for cls in $FILTER_CLASSES; do
    # grep -l returns the filename containing a match. Escape `$` in
    # class names to avoid regex backref interpretation; class names
    # here are alphanumeric so no escaping needed in practice.
    file=$(grep -rlE "(final )?class ${cls}\b.*XCTestCase" "$TESTS_DIR" 2>/dev/null | head -1 || true)
    if [[ -z "$file" ]]; then
        MISSING+=("$cls")
        FAILS=$((FAILS+1))
    else
        CLASS_FILES+=("$file")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "❌ tsan.yml filter references ${#MISSING[@]} non-existent test class(es):"
    for m in "${MISSING[@]}"; do
        echo "   - ClipMemoryTests/$m"
    done
    echo "   No (final )class ${MISSING[0]} : XCTestCase found in any Tests/ClipMemoryTests/*.swift."
    echo "   → cdda2a6 (PR #86) was the same failure: NetworkMonitorTests"
    echo "     was renamed to NetworkMonitorProtocolTests; tsan.yml kept the"
    echo "     old name; 6 tests silently stopped running under TSan."
    echo "   Fix: either rename the class back, or update tsan.yml to the new name."
fi

# 3. Count tests in the listed classes and compare to SUBSET_EXPECTED.
# Static grep estimate (matches Scripts/test-count.sh). Authoritative
# count comes from xcodebuild test; this catches gross drift only.
# Class-level counting: each class's test functions are counted in
# the file where the class is declared. (Two test classes sharing a
# file would each be counted against that file; if the test code is
# in an extension in a separate file, that file isn't searched —
# tsan tests are currently file-local so this is fine in practice.)
declare -a CLASS_NAMES=() CLASS_COUNTS=()
ACTUAL_COUNT=0
for cls in $FILTER_CLASSES; do
    # Find the file declaring the class (XCTestCase, same-line).
    file=$(grep -rlE "(final )?class ${cls}\b.*XCTestCase" "$TESTS_DIR" 2>/dev/null | head -1 || true)
    if [[ -z "$file" ]]; then
        # Already reported as missing above; don't double-count.
        CLASS_NAMES+=("$cls")
        CLASS_COUNTS+=("?")
        continue
    fi
    # grep -c returns "0" + exit 1 on zero matches; `|| true` suppresses
    # exit 1 so we can read "0" cleanly. `tr -d '\n'` defends against
    # any spurious newlines from grep -c (none observed, defensive).
    n=$(grep -cE "^[[:space:]]*func test[A-Za-z0-9_]+" "$file" 2>/dev/null || true)
    n=${n:-0}
    # Strip any stray whitespace/newlines.
    n=$(echo "$n" | tr -d '[:space:]')
    n=${n:-0}
    ACTUAL_COUNT=$((ACTUAL_COUNT + n))
    CLASS_NAMES+=("$cls")
    CLASS_COUNTS+=("$n")
done

if [[ "$ACTUAL_COUNT" != "$EXPECTED_COUNT" ]]; then
    echo "❌ Test count drift: SUBSET_EXPECTED=${EXPECTED_COUNT}, actual=${ACTUAL_COUNT}"
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

echo "✅ tsan.yml filter OK: $(echo "$FILTER_CLASSES" | wc -l | tr -d ' ') classes, ${ACTUAL_COUNT} tests (expected ${EXPECTED_COUNT})"