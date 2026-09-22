#!/usr/bin/env bash
# .github/scripts/coverage-gate.sh
# P1-AUDIT-2026-09-22 (P2-17): parse xcresult bundle for line coverage
# and gate on minimum threshold. Reads from env vars set by CI workflow.
#
# Source of audit finding: docs/review/code-review-2026-09-21.md §二 17.
# Bug: no coverage gate; root `default.profraw` floats free; test-count
# threshold (ci.yml blind-spot-6) defends "too few tests" but not
# "too thin tests".
#
# Usage:
#   coverage-gate.sh path/to/*.xcresult               # check vs default 30%
#   COVERAGE_THRESHOLD=50 coverage-gate.sh path/to/*.xcresult
#
# Exit: 0 = pass (coverage ≥ threshold), 1 = coverage below threshold or
#       parse failure, 2 = bad invocation.
#
# Threshold choice: 30% per audit brief (current baseline; deliberately
# conservative to avoid false positives; bump in next audit batch after
# intentional coverage work). Empirical measurement of this repo on
# 2026-09-22 reports ~2.6% line coverage — see .superpowers/sdd/.../task-1-report.md
# "Concerns" for the gap between stated baseline and measured baseline.
set -uo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-30}"  # 30% baseline per audit (P2-17)
XCRESULT_PATH="${1:?usage: coverage-gate.sh path/to/*.xcresult}"

# xcrun xccov view --report --json emits {"lineCoverage": 0.XX, ...}
# where lineCoverage is a fraction 0..1; multiply by 100 to get a percentage.
TOTAL=$(xcrun xccov view --report --json "$XCRESULT_PATH" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['lineCoverage'] * 100)" 2>/dev/null)

if [ -z "$TOTAL" ]; then
  echo "::error::Could not parse coverage from $XCRESULT_PATH"
  exit 1
fi

echo "Coverage: ${TOTAL}% (threshold: ${THRESHOLD}%)"
# bc is available on macOS GitHub-hosted runners (which is the only runner
# that can run xcrun); use shell comparison after a bc-based float compare.
if [ "$(echo "$TOTAL < $THRESHOLD" | bc)" = "1" ]; then
  echo "::error::Coverage $TOTAL% below threshold $THRESHOLD%"
  exit 1
fi
exit 0