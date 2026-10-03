#!/bin/bash
# TDD test for Scripts/regenerate-snapshots.sh (the destructive-flow
# tripwire). auto-review-20261003-101344 P2: the script's branch logic had
# zero automated coverage — the four-branch exercise in the rework commit
# messages was manual and unrepeatable, exactly the fail-open-`|| true`
# regression class this review cycle exists to purge. The sibling scripts
# carry harnesses here under Scripts/test/; this follows that convention.
#
# Exercises every reachable exit path against a throwaway git repo (seam:
# CLIPMEMORY_SNAPSHOT_SCRIPT_ROOT) with a stub xcodebuild (PATH seam — the
# restricted PATH keeps the real toolchain out of reach):
#   1. bogus GIT_DIR          -> fail-closed preflight, goldens intact
#   2. dirty snapshot tree    -> preflight refuses, goldens intact
#   3. empty inventory        -> "inventory is EMPTY" branch (reachable
#                                only since the grep-no-match routing
#                                fix, 101344 P2), refuses BEFORE deletion
#   4. stub no-op xcodebuild  -> restored=N "restored from git" exit 1;
#                                tracked-only inventory: an untracked
#                                stray *.actual.png is swept, never
#                                restored; tree back to clean
#   5. stub re-records, no
#      env                    -> "This state is not expected" exit 1
#                                (the true env gate)
#   6. stub re-records +
#      CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1
#                             -> the ONLY exit-0 path
#
# Run: bash Scripts/test/test_regenerate_snapshots.sh
# Exit 0 = all branches PASS, 1 = any assertion failed.

set -euo pipefail

# Two levels up: this harness lives at Scripts/test/, the script under
# test at Scripts/. (One `/..` lands at Scripts/ — the bug that made the
# first run exit 127 on every branch.)
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/Scripts/regenerate-snapshots.sh"
SNAP="Tests/ClipMemoryTests/__Snapshots__"

WORK="$(mktemp -d)"
STUB_NOOP_DIR="$(mktemp -d)"
STUB_WRITER_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK" "$STUB_NOOP_DIR" "$STUB_WRITER_DIR"' EXIT

FAIL=0
RUN_STATUS=0
CASE_NO=0

# --- Stub xcodebuild binaries ---
# no-op: suites "run", nothing is written (simulates: no record path).
printf '#!/bin/sh\nexit 1\n' > "$STUB_NOOP_DIR/xcodebuild"
chmod +x "$STUB_NOOP_DIR/xcodebuild"

# writer: re-records every golden listed in $STUB_GOLDEN_LIST into
# $STUB_SNAPSHOT_DIR (simulates: env-gated record path landed).
cat > "$STUB_WRITER_DIR/xcodebuild" <<'EOF'
#!/bin/sh
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf 'stub-rerecorded-%s\n' "$name" > "$STUB_SNAPSHOT_DIR/$name"
done < "$STUB_GOLDEN_LIST"
exit 0
EOF
chmod +x "$STUB_WRITER_DIR/xcodebuild"

# --- Helpers ---

assert_contains() { # label, outfile, pattern
  if grep -q "$3" "$2"; then :; else
    echo "FAIL [case $CASE_NO $1]: output missing: $3" >&2
    FAIL=1
  fi
}

assert_not_contains() { # label, outfile, pattern
  if grep -q "$3" "$2"; then
    echo "FAIL [case $CASE_NO $1]: output must NOT contain: $3" >&2
    FAIL=1
  fi
}

assert_eq() { # label, actual, expected
  if [ "$2" = "$3" ]; then :; else
    echo "FAIL [case $CASE_NO $1]: got '$2', want '$3'" >&2
    FAIL=1
  fi
}

golden_count() { # -> stdout
  ls "$ROOT/$SNAP" 2>/dev/null | grep -c '\.png$' || true
}

dirty_count() { # -> stdout (git status --porcelain lines)
  git -C "$ROOT" status --porcelain | wc -l | tr -d ' '
}

new_repo() { # name -> sets ROOT, commits 8 fake goldens
  CASE_NO=$((CASE_NO + 1))
  ROOT="$WORK/$1"
  mkdir -p "$ROOT/$SNAP"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" config user.email test@example.com
  git -C "$ROOT" config user.name test
  # Throwaway repos must not inherit the global hooks config (the repo's
  # pre-commit chain would fire on these fixture commits).
  git -C "$ROOT" config core.hooksPath "$ROOT/.no-hooks"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    printf 'golden-%s\n' "$i" > "$ROOT/$SNAP/Golden$i.png"
  done
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -qm goldens
}

run_case() { # outfile, stubbin, [env assignment]... -> sets RUN_STATUS
  local out="$1" stubbin="$2"
  shift 2
  RUN_STATUS=0
  # /bin/bash absolute: `env PATH=<restricted> bash ...` would look up
  # bash via the NEW PATH and fail with 127 on macOS (no /usr/bin/bash).
  env "$@" CLIPMEMORY_SNAPSHOT_SCRIPT_ROOT="$ROOT" \
    PATH="$stubbin:/usr/bin:/bin" \
    /bin/bash "$SCRIPT" > "$out" 2>&1 || RUN_STATUS=$?
}

OUT="$WORK/out.txt"

# --- Case 1: bogus GIT_DIR -> fail-closed preflight, nothing deleted ---
new_repo case1
run_case "$OUT" "$STUB_NOOP_DIR" GIT_DIR=/nonexistent
assert_eq "exit code" "$RUN_STATUS" "1"
assert_contains "message" "$OUT" "git cannot resolve this repository"
assert_eq "goldens intact" "$(golden_count)" "8"
assert_eq "tree clean" "$(dirty_count)" "0"

# --- Case 2: dirty snapshot tree -> preflight refuses ---
new_repo case2
printf 'local edit\n' >> "$ROOT/$SNAP/Golden1.png"
run_case "$OUT" "$STUB_NOOP_DIR"
assert_eq "exit code" "$RUN_STATUS" "1"
assert_contains "message" "$OUT" "uncommitted tracked changes"
assert_eq "goldens intact" "$(golden_count)" "8"
assert_eq "edit not clobbered" "$(dirty_count)" "1"

# --- Case 3: empty inventory -> refuses BEFORE deletion ---
# Reachable only since 101344 P2: under pipefail a no-match grep used to
# exit 1 and get misreported as "golden inventory failed", making the
# empty-inventory guard dead code.
new_repo case3
git -C "$ROOT" rm -qr "$SNAP"
git -C "$ROOT" commit -qm "retire all goldens"
run_case "$OUT" "$STUB_NOOP_DIR"
assert_eq "exit code" "$RUN_STATUS" "1"
assert_contains "message" "$OUT" "inventory is EMPTY"
assert_not_contains "not misrouted" "$OUT" "golden inventory failed"

# --- Case 4: no record path -> restored from git, exit 1; stray swept ---
new_repo case4
printf 'stray\n' > "$ROOT/$SNAP/StrayTest.actual.png"
run_case "$OUT" "$STUB_NOOP_DIR"
assert_eq "exit code" "$RUN_STATUS" "1"
assert_contains "message" "$OUT" "restored from git"
assert_eq "goldens restored" "$(golden_count)" "8"
assert_eq "tree clean" "$(dirty_count)" "0"
if [ -e "$ROOT/$SNAP/StrayTest.actual.png" ]; then
  echo "FAIL [case 4 stray]: untracked stray survived (should be swept)" >&2
  FAIL=1
fi

# --- Case 5: everything re-recorded WITHOUT env -> true env gate ---
new_repo case5
git -C "$ROOT" ls-files "$SNAP" | while IFS= read -r p; do basename "$p"; done \
  > "$WORK/case5-names.txt"
run_case "$OUT" "$STUB_WRITER_DIR" \
  STUB_GOLDEN_LIST="$WORK/case5-names.txt" \
  STUB_SNAPSHOT_DIR="$ROOT/$SNAP"
assert_eq "exit code" "$RUN_STATUS" "1"
assert_contains "message" "$OUT" "This state is not expected"
assert_eq "re-recorded present" "$(golden_count)" "8"
assert_eq "diff awaiting review" "$(dirty_count)" "8"

# --- Case 6: env gate set -> the ONLY exit-0 path ---
new_repo case6
git -C "$ROOT" ls-files "$SNAP" | while IFS= read -r p; do basename "$p"; done \
  > "$WORK/case6-names.txt"
run_case "$OUT" "$STUB_WRITER_DIR" \
  STUB_GOLDEN_LIST="$WORK/case6-names.txt" \
  STUB_SNAPSHOT_DIR="$ROOT/$SNAP" \
  CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1
assert_eq "exit code" "$RUN_STATUS" "0"
assert_contains "message" "$OUT" "All pre-existing goldens were re-recorded"
assert_eq "re-recorded present" "$(golden_count)" "8"
assert_eq "diff awaiting review" "$(dirty_count)" "8"

# --- Verdict ---
if [ "$FAIL" -ne 0 ]; then
  echo "test_regenerate_snapshots: FAIL" >&2
  exit 1
fi
echo "test_regenerate_snapshots: PASS (6 branches, all exit paths covered)"
