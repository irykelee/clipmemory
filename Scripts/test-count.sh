#!/usr/bin/env bash
# Scripts/test-count.sh
# ID-TEST-0002 (2026-08-16 audit LOW §13 fix): single source of truth
# for the ClipMemory test count, replacing the inconsistent hard-coded
# numbers previously scattered across release notes (788 / 884 / 885
# / 899 / 903 / 907 — each was correct at the moment it was written
# but went stale immediately after the next commit). The audit cited
# the drift as a documentation consistency defect: "三处不一致" with no
# automatic validation gate.
#
# Two modes:
#   ./Scripts/test-count.sh              # static estimate from grep
#   ./Scripts/test-count.sh --run        # exact count from xcodebuild
#
# Static estimate counts `func testXxx` declarations in the test
# target. This is an approximation (XCTest discovery also sees tests
# in extensions / parameterized cases / @objc selectors), so treat
# the estimate as a sanity check rather than an authoritative number.
# Run with --run for the authoritative count after a green build.
#
# Release notes should NOT hard-code the number — reference this
# script as the source of truth instead.
set -uo pipefail

estimate() {
    grep -rE "^[[:space:]]*func test[A-Za-z0-9_]+" Tests/ClipMemoryTests \
        | grep -v "//" \
        | wc -l \
        | tr -d ' '
}

run_xcodebuild() {
    # xcodebuild test prints `Executed N tests, with M failures ...` once
    # per suite AND once for the aggregate `Test Suite 'All tests'`.
    # The aggregate line is the authoritative number — pick the LAST
    # matching line so we get the summary, not a per-suite count.
    xcodebuild \
        -scheme ClipMemory \
        -configuration Debug \
        -destination 'platform=macOS' \
        test 2>&1 \
        | grep -E "Executed [0-9]+ tests" \
        | tail -1 \
        | sed -E "s/.*Executed ([0-9]+) tests.*/\1/"
}

case "${1:-estimate}" in
    --run)
        run_xcodebuild
        ;;
    --help|-h)
        sed -n '2,25p' "$0"
        exit 0
        ;;
    *)
        estimate
        ;;
esac