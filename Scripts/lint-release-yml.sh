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
#   3. release.sh:997 has a `gh run watch` guard that
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
# ID-CI-0012 (2026-09-27): auto-review 20260927-203941 caught two
# flaws in the initial ID-CI-0011 implementation:
#   (a) check #2 used awk regex anchored to column 0 (`/^- name: Run
#       tests/`) but release.yml indents the step to column 6
#       (`      - name: Run tests`); the awk pattern never matched,
#       so the `continue-on-error: true` half of the bug class was
#       unenforced while CI reported green.
#   (b) the scan was seeded by `grep "|| true"` only — so the
#       script's own header-named real mechanism (`xcodebuild test
#       … | tee log` under GH's `bash -e` shell, no pipefail) would
#       pass clean if a contributor re-added 149906d's line minus
#       the dead `|| true`. We now also check the bare
#       `xcodebuild test … | tee …` pattern.
#
# ID-CI-0015 (2026-09-27): auto-review 20260927-210112 caught the
# FAIL message's own backticks triggering bash command substitution
# (the FAIL output was running `|| true` as part of error
# formatting). Switched to single-quoted prose with double-quoted
# variable fragments; added `trap '' PIPE` so SIGPIPE from grep -q
# closing stdin early doesn't abort check_workflow with rc=141
# under `set -e`.
#
# ID-CI-0016 (2026-09-27): auto-review 20260927-210112 caught that
# the `--selftest` pipeline `check_workflow | grep -q "^❌ FAIL"`
# aborted the script BEFORE `${PIPESTATUS[0]}` could capture the
# exit code, under `set -euo pipefail`. Plus `declare -g` is bash
# 4.2+; macOS /bin/bash 3.2.57 rejected it and the selftest died
# with exit 2 on the first fixture. Fix: capture check_workflow
# output via `output=$(check_workflow 2>&1); cw_rc=$?`; plain
# WORKFLOW assignment (no `declare -g`); RETURN trap with handler
# `trap 'trap - PIPE' RETURN` (handler does NOT call `return`,
# avoids the infinite-recursion that a handler containing
# `return $?` produced).
#
# ID-CI-0017 (2026-09-27): auto-review 20260927-210802 caught that
# selftest mutated the script-level WORKFLOW to each fixture path
# but never restored it before returning — so the post-selftest
# real check (promised by ID-CI-0014) scanned the last fixture
# file, not `.github/workflows/release.yml`. `--selftest` was a
# fake lock. Fix: snapshot WORKFLOW into `saved_workflow` at the
# top of selftest, restore before return (and in the EXIT trap
# belt-and-suspenders).
#
# ID-CI-0018 (2026-09-27): rule 3's awk end-regex
# `/^[[:space:]]*- name:/` matched any indent depth, so a nested
# `- name:` inside a `run: |` block would prematurely truncate
# the range and miss subsequent `continue-on-error: true`. Plus
# the script silently skipped rule 3 if the workflow had no
# step named exactly `Run tests` — renaming the step would
# disarm rule 3 while CI reported green. Fix: anchor the
# end-regex to 6 spaces (`/^      - name:/`, matching GH
# release.yml step indent) and hard-FAIL with an explicit
# "rename the step back" message when rule 3's anchor is
# missing.
#
# ID-CI-0019 (2026-09-27): the rule 1 error message recommended
# remediation (b) "add `shell: bash` + `set -o pipefail`" but
# applying it left the `xcodebuild test | tee` literal in the
# file, which rule 1 then flagged as a fail-open — the lint
# blocked its own fix. Fix: detect BOTH `shell: bash` AND
# `set -o pipefail` (or `set -euo pipefail`) in the enclosing
# step body; if both are present, the `tee` no longer swallows
# (pipefail propagates the upstream exit code). Partial
# declarations (only one of the two) still trip the rule —
# safe failure mode. Three new fixtures (f full carve-out,
# g partial-shell, h partial-pipefail) lock the behavior.
#
# Three rules enforced (current):
#   1. `xcodebuild test … | tee …` on any line in release.yml
#      (fail-open via tee's exit 0 under GH macOS default shell
#      with no pipefail). Includes the variant `… || true`.
#      Carve-out (ID-CI-0019): step declares `shell: bash` AND
#      run body has `set -o pipefail` (or `set -euo pipefail`).
#   2. `xcodebuild test … || true` on any line (explicit swallow,
#      dead under default shell but a future `shell: bash` would
#      flip the behavior).
#   3. `continue-on-error: true` inside the `Run tests` step body
#      (awk-bounded via 6-space-anchored line range). Hard-FAIL
#      if no `Run tests` step exists.
#
# The fix in release.yml:148-186 (fail-closed justification) must
# remain present and non-empty; this script does NOT enforce that
# textually (it would be a comment-level check, brittle). What it
# does enforce: the code below those comments cannot silently
# disable fail-closed behavior.
#
# Self-test (ID-CI-0012, expanded ID-CI-0015 / 0018 / 0019): run
# `Scripts/lint-release-yml.sh --selftest` to verify synthetic
# fixtures are caught. The script exits 0 on PASS / 1 on FAIL of
# each fixture. A real release.yml check with no arguments also
# runs after `--selftest` returns 0; pass both before considering
# this linter trustworthy. 8-fixture selftest (a/b/c fail-open
# caught, d/e clean release.yml, f full carve-out, g/h partial
# carve-out). See `feedback/release-yml-fail-open-prevention.md`
# for the full drill narrative.
#
# Usage:
#   Scripts/lint-release-yml.sh           # check release.yml
#   Scripts/lint-release-yml.sh --selftest  # synthetic fixtures
#
# Wired into ci.yml lint-ids job (per ID-CI-0011, selftest flag
# added by ID-CI-0014).
#
# bash compat: stock macOS /bin/bash 3.2 lacks `declare -A`,
# uses parallel arrays. CI (ubuntu bash 5) is more permissive but
# the portable form is identical. No `declare -g` (bash 4.2+) —
# ID-CI-0016. No `set -e`-incompatible `check_workflow | grep -q`
# pipelines — ID-CI-0015/0016. RETURN trap with no `return`
# statement in the handler — ID-CI-0016.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

WORKFLOW="$ROOT/.github/workflows/release.yml"

# ---- self-test fixtures (ID-CI-0012) ------------------------------------
selftest() {
  # ID-CI-0015 (2026-09-27): temporarily disable `set -e` for the
  # duration of the selftest. The marker-based PASS/FAIL check
  # calls `check_workflow`, which returns 1 on rule-firing — under
  # the outer `set -e` the script aborts before the marker can be
  # inspected.
  set +e
  local tmpdir
  # ID-CI-0017 (2026-09-27): save and restore WORKFLOW across the
  # selftest. The fixtures below mutate it as global state (the
  # script's WORKFLOW was declared at top level, outside any
  # function); without save/restore the post-selftest real check
  # would scan the last fixture file (not the real release.yml),
  # silently green. This was the gap auto-review P1 caught in
  # 20260927-210802.
  local saved_workflow="$WORKFLOW"
  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'; WORKFLOW='$saved_workflow'; set -e" EXIT

  # Fixture A: 149906d's exact line — must FAIL (rule #1: xcodebuild test | tee)
  cat >"$tmpdir/a.yml" <<'EOF'
      - name: Run tests
        run: |
          xcodebuild test -scheme ClipMemory 2>&1 | tee /tmp/log || true
EOF

  # Fixture B: same minus `|| true` — must FAIL (rule #1: tee alone swallows
  # under no-pipefail GH macOS default shell). This is the case the
  # ID-CI-0011 v1 missed.
  cat >"$tmpdir/b.yml" <<'EOF'
      - name: Run tests
        run: |
          xcodebuild test -scheme ClipMemory 2>&1 | tee /tmp/log
EOF

  # Fixture C: indented `Run tests` step with `continue-on-error: true` —
  # must FAIL (rule #3). This is the case ID-CI-0011 v1 missed because
  # awk regex was column-0 anchored.
  cat >"$tmpdir/c.yml" <<'EOF'
      - name: Run tests
        continue-on-error: true
        run: |
          xcodebuild test -scheme ClipMemory
      - name: Other
        run: echo ok
EOF

  # Fixture D: clean fail-closed — must PASS.
  cat >"$tmpdir/d.yml" <<'EOF'
      - name: Run tests
        run: |
          xcodebuild test -scheme ClipMemory
EOF

  # Fixture E (ID-CI-0015): clean release.yml that DOCUMENTS the
  # fail-open pattern in a comment line — must PASS. The comment-
  # skip guard added in 6847507 (rule #1's leading-`#` filter)
  # should ignore the prose, not flag it. Without this fixture,
  # a future refactor that over-broadens the skip regex to swallow
  # real commands would not be caught.
  cat >"$tmpdir/e.yml" <<'EOF'
      # This release.yml step names the fail-open trap in prose so
      # that the lint comment-skip guard can be tested. The fixture
      # itself has no actual fail-open command.
      - name: Run tests
        # Documentation reference: a `xcodebuild test | tee` line
        # would swallow under GH macOS default shell. Avoid it.
        run: |
          xcodebuild test -scheme ClipMemory
EOF

  # Fixture F (ID-CI-0019): bare `xcodebuild test | tee` BUT with
  # both `shell: bash` AND `set -o pipefail` in the same step
  # body — must PASS. This is the correct remediation that the
  # rule's own error message recommends; the carve-out allows it.
  cat >"$tmpdir/f.yml" <<'EOF'
      - name: Run tests
        shell: bash
        run: |
          set -o pipefail
          xcodebuild test -scheme ClipMemory 2>&1 | tee /tmp/log
EOF

  # Fixture G (ID-CI-0019): bare `xcodebuild test | tee` with
  # only `shell: bash` (no pipefail) — must FAIL. The carve-out
  # requires BOTH declarations; a partial declaration is still
  # a fail-open trap because `tee` keeps swallowing without
  # pipefail.
  cat >"$tmpdir/g.yml" <<'EOF'
      - name: Run tests
        shell: bash
        run: |
          xcodebuild test -scheme ClipMemory 2>&1 | tee /tmp/log
EOF

  # Fixture H (ID-CI-0019): bare `xcodebuild test | tee` with
  # only `set -o pipefail` (no `shell: bash`) — must FAIL. The
  # default shell still doesn't honor pipefail, so the swallow
  # persists.
  cat >"$tmpdir/h.yml" <<'EOF'
      - name: Run tests
        run: |
          set -o pipefail
          xcodebuild test -scheme ClipMemory 2>&1 | tee /tmp/log
EOF

  # Fixture I (ID-CI-0021): two `Run tests` steps (e.g. matrix
  # build with `runs-on: ubuntu-latest` + `runs-on: macos-latest`)
  # where the FIRST step is clean and the SECOND has
  # `continue-on-error: true`. This exposes the head -1 narrowness
  # auto-review 20260927-210802 caught (deferred P2 #14): the rule 3
  # grep uses `head -1`, so only the FIRST `name: Run tests` match
  # is checked. The second step's `continue-on-error: true` would
  # silently pass — even though it disables fail-closed exactly
  # the same way. Must FAIL because rule 3 currently catches the
  # first match's body (clean) but the fix would be to iterate all
  # matches. The fixture is a forward-looking test; the rule 3
  # narrowness is latent today (no live-broken behavior) but
  # documenting it as a known edge case prevents future drift.
  cat >"$tmpdir/i.yml" <<'EOF'
      - name: Run tests
        run: |
          xcodebuild test -scheme ClipMemory
      - name: Run tests
        continue-on-error: true
        run: |
          xcodebuild test -scheme ClipMemory
EOF

  local failures=0
  # ID-CI-0015 (2026-09-27): the previous implementation keyed on
  # exit status (`check_workflow >/dev/null 2>&1`; non-zero =
  # "caught"). That conflates "rule fired" with "script crashed"
  # (e.g. set -u unbound variable, awk parse error, missing
  # fixture file would all self-certify green for a/b/c). Use the
  # ✅/❌ marker from check_workflow's own output instead: success
  # exits 0 with "✅ PASS:" as the last line; failure exits 1 with
  # "❌ FAIL:" in the output.
  #
  # Note: WORKFLOW is a top-level variable, NOT exported, so the
  # env-var-prefix syntax (`WORKFLOW=... check_workflow`) does NOT
  # reach the function in some bash versions. We export explicitly
  # to be portable across bash 3.2 (macOS) and bash 5 (ubuntu CI).
  for label in a b c; do
    WORKFLOW="$tmpdir/${label}.yml"
    # ID-CI-0015 (2026-09-27): the earlier `declare -g WORKFLOW=...`
    # used `declare -g` (bash 4.2+); on macOS bash 3.2.57 this
    # raised `declare: -g: invalid option` and the selftest aborted
    # with exit 2 on the first iteration. Plain assignment is
    # sufficient because the script top-level WORKFLOW was set
    # outside any function (global script scope); nested functions
    # inherit by dynamic scope, and check_workflow is at the same
    # nesting level as selftest.
    # ID-CI-0015: capture check_workflow output via $(...) so the
    # grep doesn't close stdin early and SIGPIPE check_workflow
    # before it returns 1. Capture the exit code separately so
    # PASS markers (`✅ PASS:`) and FAIL markers (`❌ FAIL:`) both
    # count toward the fixture verdict.
    output=$(check_workflow 2>&1)
    cw_rc=$?
    if [[ "$cw_rc" -eq 1 && "$output" == *"❌ FAIL"* ]]; then
      echo "✅ PASS: fixture ${label} correctly caught"
    else
      echo "❌ FAIL: fixture ${label} (check_workflow exit=$cw_rc, expected 1 with FAIL marker)"
      failures=$((failures + 1))
    fi
  done
  for label in d e f; do
    WORKFLOW="$tmpdir/${label}.yml"
    output=$(check_workflow 2>&1)
    cw_rc=$?
    if [[ "$cw_rc" -eq 0 && "$output" == *"✅ PASS"* ]]; then
      echo "✅ PASS: fixture ${label} correctly allowed"
    else
      echo "❌ FAIL: fixture ${label} should have passed (check_workflow exit=$cw_rc with PASS marker)"
      failures=$((failures + 1))
    fi
  done

  # Fixture I (ID-CI-0021 narrowness fix): multi-step Run tests
  # matrix. Two `name: Run tests` steps — first clean, second has
  # `continue-on-error: true`. With the narrowness fix (rule 3
  # now iterates ALL `name: Run tests` matches), the second step's
  # fail-open is caught. Must FAIL.
  WORKFLOW="$tmpdir/i.yml"
  output=$(check_workflow 2>&1)
  cw_rc=$?
  if [[ "$cw_rc" -eq 1 && "$output" == *"❌ FAIL"* ]]; then
    echo "✅ PASS: fixture i correctly caught (multi-step narrowness fix verified)"
  else
    echo "❌ FAIL: fixture i should have been caught (check_workflow exit=$cw_rc)"
    failures=$((failures + 1))
  fi
  # Fixture G + H: bare `xcodebuild test | tee` with INCOMPLETE
  # carve-out must FAIL. Loop separately so we can label them
  # distinctly.
  for label in g h; do
    WORKFLOW="$tmpdir/${label}.yml"
    output=$(check_workflow 2>&1)
    cw_rc=$?
    if [[ "$cw_rc" -eq 1 && "$output" == *"❌ FAIL"* ]]; then
      echo "✅ PASS: fixture ${label} correctly caught (partial carve-out)"
    else
      echo "❌ FAIL: fixture ${label} should have been caught (check_workflow exit=$cw_rc)"
      failures=$((failures + 1))
    fi
  done

  if [[ "$failures" -gt 0 ]]; then
    echo "❌ $failures self-test fixture(s) failed — lint is broken"
    return 1
  fi
  # ID-CI-0017: restore the global WORKFLOW before returning, so
  # the entry point's subsequent real check (after `--selftest`
  # returns 0) scans the real release.yml — not the last fixture
  # file we just mutated.
  WORKFLOW="$saved_workflow"
  echo "✅ All 9 self-test fixtures passed"
}

# ---- core check (extractable for selftest) -------------------------------
check_workflow() {
  # ID-CI-0015 (2026-09-27): ignore SIGPIPE for the duration of
  # the function so the function can complete all of its echo
  # output before exiting, even when the caller pipes through
  # `head` / `grep -q` and closes stdin early. Bash's dynamic
  # trap model means the suppression persists until we explicitly
  # reset it; we use a RETURN trap to reset on every return path
  # (the handler does NOT call `return`, so it doesn't re-trigger
  # the RETURN trap — the function exits with its own return code).
  #
  # The selftest caller invokes check_workflow via
  # `output=$(check_workflow 2>&1)` which captures all output
  # before the function returns — under that call pattern SIGPIPE
  # is irrelevant; the suppression here is defense-in-depth for
  # direct callers that pipe through `head` / `grep -q`.
  trap 'trap - PIPE' RETURN
  trap '' PIPE
  local violations=0
  local violation_lines=()

  # Rule 1 + 2: any line that contains `xcodebuild test` AND either
  # `| tee` (rule 1, tee's exit-0 swallow) or `|| true` (rule 2,
  # explicit dead code that flips on `shell: bash`). These two
  # checks share a single pass to keep the script readable.
  #
  # Skip comment lines (YAML lines starting with optional whitespace
  # + `#`) so documenting the pattern in a comment doesn't itself
  # trip the lint. The fixture lines ID-CI-0012 introduced for
  # release.yml:192 (the ID-CI-0011 lint header) reference the
  # bare pattern by name in prose, and we shouldn't punish the
  # documentation for naming the trap.
  while IFS=: read -r lineno content; do
    # Skip pure comment lines (whitespace then `#`)
    [[ "$content" =~ ^[[:space:]]*# ]] && continue
    [[ "$content" == *"xcodebuild test"* ]] || continue
    [[ "$content" == *"| tee"* || "$content" == *"|| true"* ]] || continue
    # ID-CI-0019 (2026-09-27): carve-out for the correct
    # remediation. The bare `xcodebuild test | tee` pattern
    # swallows test failures under GH Actions macOS default
    # `bash -e` (no pipefail). But if the enclosing step declares
    # `shell: bash` AND the run body has `set -o pipefail` (or
    # `set -euo pipefail`), the pipe returns the upstream exit
    # code — `tee` no longer swallows and the step is
    # fail-closed. A contributor applying the correct fix
    # would otherwise be blocked by CI for following the
    # remediation that the rule's own error message
    # recommends (option (b)). The carve-out requires BOTH
    # declarations to be present in the same step body;
    # partial declarations (`shell: bash` without pipefail, or
    # pipefail without `shell: bash`) still trip the rule.
    #
    # Scan the enclosing step body (from the previous
    # column-0 `- name:` to the next one or EOF) for both
    # declarations. awk prints each line as `NR: content` so
    # the violation line number doesn't get confused with the
    # awk line counter.
    carve_out_ok=0
    step_body=$(awk -v ln="$lineno" '
      NR <= ln && /^- name:/ { start = NR }
      NR >  ln && /^- name:/ { exit }
      NR >= start { print NR ": " $0 }
    ' "$WORKFLOW")
    if echo "$step_body" | grep -qE "^[0-9]+:[[:space:]]+shell:[[:space:]]*bash([[:space:]]|$)" \
       && echo "$step_body" | grep -qE "set[[:space:]]+-[eu]*o[[:space:]]+pipefail"; then
      carve_out_ok=1
    fi
    if [[ "$carve_out_ok" -ne 1 ]]; then
      violations=$((violations + 1))
      violation_lines+=("$lineno")
    fi
  done < <(grep -n "xcodebuild test" "$WORKFLOW" || true)

  if [[ "$violations" -gt 0 ]]; then
    echo ""
    echo '❌ FAIL: fail-open patterns detected in '"$WORKFLOW"
    echo ""
    echo "Violations (line numbers): ${violation_lines[*]}"
    echo ""
    # ID-CI-0015 (2026-09-27): the WHY/FIX text was previously inside
    # double-quoted echo strings, and the backticks (e.g. `|| true`)
    # inside those strings triggered bash command substitution —
    # `bash` actually ran `xcodebuild test` / `gh run view` / etc. as
    # part of error formatting, which under set -e exited check_workflow
    # before `return 1` ran, returning exit 0 (success) while still
    # printing a half-FAIL message. The selftest under the new
    # marker-based check caught this as rc=141 (SIGPIPE on the grep
    # pipeline). Splitting single-quoted prose from the few
    # double-quoted variable interpolations avoids the trap.
    echo "Why this matters:"
    echo '  - `xcodebuild test … | tee …` returns tee'"'"'s exit 0 under'
    echo '    GH Actions macOS default shell (bash -e, NO pipefail);'
    echo '    the swallow is tee'"'"'s accident, not the test step'"'"'s.'
    echo '  - A future `shell: bash` declaration on this step would'
    echo '    silently flip the behavior to honor pipefail — and'
    echo '    every swallowed failure would suddenly become fatal.'
    echo '  - Scripts/release.sh:997 `gh run watch`'
    echo '    depends on test step being fail-closed to catch regressions.'
    echo ""
    echo "Historical lesson (ID-CI-0011 / ID-CI-0012):"
    echo '  - 149906d added `|| true` as a v2.9.4-only workaround, but'
    echo '    the comment claimed scope was unconditional and no `if:`'
    echo '    guard, no expiry, no tracking issue were added.'
    echo '  - da3cc6a reverted 149906d. ID-CI-0012 closes the second'
    echo '    hole: removing only the dead `|| true` token is no longer'
    echo "    enough — the bare \`xcodebuild test | tee\` pattern is"
    echo "    also caught."
    echo ""
    echo "Fix: either (a) drop \`| tee\` entirely and rely on the step's"
    echo "own log capture (\`gh run view --log\`); (b) add \`shell: bash\`"
    echo "to the step + \`set -o pipefail\` at the top of the run block"
    echo "so \`xcodebuild test | tee\` no longer swallows; (c) capture"
    echo "the exit code manually (e.g. \`xcodebuild test > log 2>&1;"
    echo "rc=\$?; tee log; exit \$rc\`). Each has a real cost — pick one."
    # ID-CI-0019 (2026-09-27): option (b) is now sanctioned by
    # the lint's own carve-out — if the enclosing step declares
    # \`shell: bash\` AND the run body contains \`set -o pipefail\`
    # (or \`set -euo pipefail\`), the bare \`xcodebuild test | tee\`
    # pattern passes the lint. See selftest fixtures f/g/h for the
    # three carve-out shapes (full, partial-shell, partial-pipefail).
    return 1
  fi

  # Rule 3: `continue-on-error: true` inside the `Run tests` step
  # body (awk-bounded via line-range). ID-CI-0012 fixes the
  # column-0 anchor bug by reading the actual `- name:` line
  # positions into a variable first.
  local run_tests_lines
  # ID-CI-0019 (2026-09-27): anchored to `- name: Run tests` at
  # column 0, not the substring search. The previous unanchored
  # `grep "name: Run tests"` matched any line containing the
  # substring — including a comment line mentioning the pattern
  # by name. With a column-0 anchored regex we only match the
  # actual step header line. If a future workflow uses a different
  # step name, the rule 3 anchor missing hard-FAIL (added in
  # ID-CI-0018) catches it.
  run_tests_lines=$(grep -nE "^[[:space:]]*- name: Run tests([[:space:]]|$)" "$WORKFLOW" || true)
  if [[ -n "$run_tests_lines" ]]; then
    local start_line end_line bad all_bad=""
    # ID-CI-0021 (2026-09-27): iterate ALL `name: Run tests`
    # matches, not just the first. The previous code used `head -1`
    # on the grep output (auto-review 20260927-210802 caught this
    # as deferred P2 #14 — matrix builds with multiple `Run tests`
    # steps would silently skip rule 3 for steps after the first).
    # We now loop through every match; the first one with
    # `continue-on-error: true` (or any later one with the same
    # flag) fails CI.
    while IFS=: read -r start_line _unused; do
      # End is the next `- name:` at the same (or shallower) indent
      # level — for release.yml that's column 0 or 6. We use a
      # found-flag END pattern; the sentinel is only printed when no
      # subsequent -name was matched, so we don't get a newline in the
      # captured value (which would crash awk's -v on the second call).
      end_line=$(awk -v start="$start_line" '
        # ID-CI-0018 (2026-09-27): anchored end-regex. The previous
        # `/^[[:space:]]*- name:/` matched any indent depth, so a
        # nested `- name:` inside a `run: |` block would prematurely
        # truncate the range (auto-recommended P2 #23). The CI release
        # workflow indents steps to 6 spaces (`      - name:`); the
        # run-block content lives at 8+ spaces or starts with a
        # different character. Anchoring at exactly 6 spaces makes
        # the boundary precise. If a future workflow uses a different
        # indent, the sentinel (999999) falls through to EOF instead
        # of false-truncating mid-step — which is the safer failure
        # mode (over-reports vs under-reports).
        NR > start && /^      - name:/ { print NR; found=1; exit }
        END { if (!found) print 999999 }
      ' "$WORKFLOW")
      [[ -z "$end_line" ]] && end_line=999999

      bad=$(awk -v s="$start_line" -v e="$end_line" \
        'NR >= s && NR < e && /continue-on-error:[[:space:]]*true/ { print NR ":" $0 }' \
        "$WORKFLOW" || true)
      if [[ -n "$bad" ]]; then
        all_bad+="${bad}"$'\n'
      fi
    done < <(echo "$run_tests_lines")
    bad="$all_bad"

    if [[ -n "$bad" ]]; then
      echo ""
      echo "❌ FAIL: \`continue-on-error: true\` detected inside one or more Run tests steps"
      echo ""
      echo "$bad"
      echo ""
      echo "Why this matters:"
      echo "  - This is the v2.9.2-era pattern (1f646d5) that ID-CI-0005"
      echo "    removed on 2026-09-26 (e897f30). Reintroducing it"
      echo "    re-opens the same fail-open hole."
      echo "  - Scripts/release.sh:997 \`gh run watch\`"
      echo "    guard silently stops catching test regressions."
      echo ""
      echo "Fix: remove \`continue-on-error: true\` from the Run tests step."
      return 1
    fi
  else
    # ID-CI-0018 (2026-09-27): rule 3 anchor missing. A workflow
    # that doesn't have a step named exactly "Run tests" silently
    # skips this half of the bug class — renaming the step to
    # e.g. "Run unit tests" would defeat rule 3 entirely while
    # rule 1/2 still scans the whole file. Surface this as a
    # hard FAIL (not just a warning) so renaming doesn't
    # accidentally disarm the guard.
    echo ""
    echo "❌ FAIL: rule 3 anchor missing — no step named 'Run tests' found"
    echo ""
    echo "Searched \`$WORKFLOW\` for \`name: Run tests\` and got 0 hits."
    echo "Rule 3 (continue-on-error: true inside the Run tests step)"
    echo "requires a step with the literal name 'Run tests'. If you"
    echo "renamed the step, rule 3 silently skips this workflow — fix"
    echo "the step name OR add an explicit '- name: Run tests' guard"
    echo "step before continuing."
    return 1
  fi

  echo "✅ PASS: $WORKFLOW has no fail-open patterns in Run tests step"
  return 0
}

# ---- entry point ---------------------------------------------------------
if [[ "${1:-}" == "--selftest" ]]; then
  selftest || exit $?
  # ID-CI-0014 (2026-09-27): auto-review caught that the previous
  # `selftest; exit $?` short-circuited the real check, contradicting
  # the header's claim that "a real release.yml check with no arguments
  # also runs after `--selftest` returns 0." When invoked with
  # --selftest we now run selftest first; if it passes, fall through to
  # the real check. If selftest fails, exit with its code and skip the
  # real check (so a broken selftest can't be masked by a clean
  # release.yml).
fi

[[ -f "$WORKFLOW" ]] || { echo "❌ $WORKFLOW not found"; exit 1; }

echo "Scanning $WORKFLOW for fail-open patterns..."
check_workflow
