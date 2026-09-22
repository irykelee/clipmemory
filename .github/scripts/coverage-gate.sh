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
#   coverage-gate.sh path/to/*.xcresult               # check vs script default threshold
#   COVERAGE_THRESHOLD=50 coverage-gate.sh path/to/*.xcresult
#
# Exit: 0 = pass (coverage >= threshold); 1 = coverage below threshold,
#       parse failure, missing tool, or non-numeric threshold/value.
#
# Threshold notes: script default is 30%; ci.yml env overrides this to
# 2% because the empirical baseline measured on 2026-09-22 was 2.578%
# (see git log for the P2-17 audit history). The 30% default is the
# aspirational target once intentional coverage work ships; until then
# the lower CI override keeps the gate non-blocking.
#
# Fail-closed by design: missing tools (xcrun/python3/awk) cause a
# hard failure with a GitHub Actions ::error:: annotation, per the
# REL precedent ("swiftlint missing must FAIL, not pass") and the
# E-39b601 anti-silence tradition. Float comparison uses awk rather
# than bc so the gate cannot silently pass when bc is unavailable.
set -uo pipefail

# --- Tool canary (REL precedent / E-39b601: missing tools must FAIL, not pass) ---
command -v xcrun >/dev/null 2>&1 || { echo "::error::xcrun not found (required to parse xcresult)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "::error::python3 not found (required to parse coverage JSON)"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "::error::awk not found (required for float comparison)"; exit 1; }

THRESHOLD="${COVERAGE_THRESHOLD:-30}"  # default 30% per audit brief; ci.yml overrides
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
# awk handles decimal comparison universally (no bc dependency).
# Exits 0 when total < threshold (FAIL) so the `if` branch fires.
if awk -v total="$TOTAL" -v threshold="$THRESHOLD" 'BEGIN { exit (total < threshold) ? 0 : 1 }'; then
  echo "::error::Coverage ${TOTAL}% below threshold ${THRESHOLD}%"
  exit 1
fi
exit 0
