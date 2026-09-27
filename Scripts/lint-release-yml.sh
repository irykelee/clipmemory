#!/usr/bin/env bash
# Scripts/lint-release-yml.sh
# ID-CI-0011 (2026-09-27): prevents the "release.yml Run tests
# fail-open" bug class. The 149906d commit (ID-RELEASE-0003) added
# `|| true` to the Run tests step as a one-release workaround for
# an unverified v2.9.3 CI failure. Three problems compounded:
#
#   1. The `|| true` was unconditional (no `if: github.ref_name == 'v2.9.4'`
#      guard, no expiry, no tracking issue) → silently inherited by
#      v2.9.5+ every future tag.
#   2. GH Actions macOS default shell is `bash -e {0}` with NO
#      `pipefail` — so `xcodebuild test | tee log` already returns
#      tee's exit 0. The `|| true` was dead code; the actual fail-open
#      came from tee's accident. A future `shell: bash` declaration
#      would silently flip the behavior without any test catching it.
#   3. release.sh:1147 has a `gh run watch --exit-status` guard that
#      `die`s on non-zero — it relies on the test step being
#      fail-closed. With the swallow, that guard silently stops
#      catching test regressions; release.sh was not updated.
#
# ID-CI-0005 (e897f30, 2026-09-26) deliberately restored fail-closed
# over `continue-on-error: true` with a 33-line justification at
# release.yml:148-186. 149906d undid that 19 hours later with a
# 3-line comment claiming scope was "for this one release" — but
# nothing in code enforced that. da3cc6a reverted 149906d; this
# script prevents the next `|| true` re-introduction.
#
# Two failure modes:
#   1. `|| true` anywhere on the same logical line as `xcodebuild test`,
#      `tee`, or `2>&1` in release.yml — fail-open via pipefail bypass.
#   2. `continue-on-error: true` inside a `Run tests` step — explicit
#      fail-open that disables Scripts/release.sh:1147's downstream
#      guard.
#
# The fix in release.yml:148-186 (fail-closed justification) must
# remain present and non-empty; this script does NOT enforce that
# textually (it would be a comment-level check, brittle). What it
# does enforce: the code below those comments cannot silently
# disable fail-closed behavior.
#
# Usage: Scripts/lint-release-yml.sh
# Wired into ci.yml lint-ids job (per ID-CI-0011).
#
# bash compat: stock macOS /bin/bash 3.2 lacks `declare -A`,
# uses parallel arrays. CI (ubuntu bash 5) is more permissive but
# the portable form is identical.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

WORKFLOW="$ROOT/.github/workflows/release.yml"
[[ -f "$WORKFLOW" ]] || { echo "❌ $WORKFLOW not found"; exit 1; }

violations=0
line_numbers=()

# 1. Detect `|| true` after `xcodebuild test` / `tee` / `2>&1`.
#    Use grep -n to capture line numbers for actionable errors.
#    Pattern: command-ending `|| true` (the typical fail-open swallow).
#
#    We grep for `|| true` on the same line as one of the risk
#    triggers (xcodebuild / tee / 2>&1). Single-line `|| true`
#    with no preceding risk trigger is out of scope (e.g. a
#    `cleanup || true` after a successful step is fine).
echo "Scanning $WORKFLOW for fail-open patterns..."

# Map: line numbers where risk trigger AND `|| true` co-occur.
# grep -n prints "N:content". Use awk to find lines that have
# BOTH a trigger AND `|| true`.
while IFS=: read -r lineno content; do
  has_trigger=0
  if [[ "$content" == *"xcodebuild test"* ]] \
     || [[ "$content" == *"tee "* ]] \
     || [[ "$content" == *"2>&1"* ]]; then
    has_trigger=1
  fi
  has_swallow=0
  if [[ "$content" == *"|| true"* ]]; then
    has_swallow=1
  fi
  if [[ "$has_trigger" -eq 1 && "$has_swallow" -eq 1 ]]; then
    violations=$((violations + 1))
    line_numbers+=("$lineno")
  fi
done < <(grep -n "|| true" "$WORKFLOW" || true)

if [[ "$violations" -gt 0 ]]; then
  echo ""
  echo "❌ FAIL: fail-open patterns detected in $WORKFLOW"
  echo ""
  echo "Violations (line numbers): ${line_numbers[*]}"
  echo ""
  echo "Why this matters:"
  echo "  - `xcodebuild test ... || true` swallows test failures silently."
  echo "  - `... | tee ... || true` only works because GH Actions macOS"
  echo "    default shell has no \`pipefail\`; the swallow is tee's"
  echo "    accident, not `|| true`'s function."
  echo "  - Scripts/release.sh:1147 \`gh run watch --exit-status\`"
  echo "    depends on test step being fail-closed to catch regressions."
  echo ""
  echo "Historical lesson (ID-CI-0011):"
  echo "  - 149906d added `|| true` as a v2.9.4-only workaround, but"
  echo "    the comment claimed scope was unconditional and no `if:`"
  echo "    guard, no expiry, no tracking issue were added."
  echo "  - da3cc6a reverted 149906d. This script prevents the next"
  echo "    commit from reintroducing the same swallow."
  echo ""
  echo "Fix: remove the `|| true`. If a specific release needs a"
  echo "fail-open step, add an explicit `if: github.ref_name == 'vX.Y.Z'`"
  echo "guard + tracking issue + expiry, then revisit this lint."
  exit 1
fi

# 2. Detect `continue-on-error: true` inside the Run tests step
#    (release.yml:187-193). The grep window is bounded to the step
#    body using awk — we look for `continue-on-error: true` between
#    `- name: Run tests` and the next `- name:` or end of jobs:.
#
#    This catches the v2.9.2-era pattern (1f646d5) that ID-CI-0005
#    deliberately removed. If you genuinely need a non-fatal step,
#    use `if: failure()` on a *separate* step instead.
run_tests_continue_error=$(awk '
  /^- name: Run tests/ { in_step = 1; next }
  in_step && /^- name:/ { in_step = 0 }
  in_step && /continue-on-error:[[:space:]]*true/ { print FILENAME ":" NR ":" $0; found = 1 }
  END { exit (found ? 0 : 1) }
' "$WORKFLOW" || true)

if [[ -n "$run_tests_continue_error" ]]; then
  echo ""
  echo "❌ FAIL: \`continue-on-error: true\` detected inside the Run tests step"
  echo ""
  echo "$run_tests_continue_error"
  echo ""
  echo "Why this matters:"
  echo "  - This is the v2.9.2-era pattern (1f646d5) that ID-CI-0005"
  echo "    removed on 2026-09-26 (e897f30). Reintroducing it"
  echo "    re-opens the same fail-open hole."
  echo "  - Scripts/release.sh:1147 \`gh run watch --exit-status\`"
  echo "    guard silently stops catching test regressions."
  echo ""
  echo "Fix: remove \`continue-on-error: true\` from the Run tests step."
  exit 1
fi

echo "✅ PASS: $WORKFLOW has no fail-open patterns in Run tests step"
exit 0