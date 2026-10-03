#!/usr/bin/env bash
# Snapshot-golden tripwire (P1-AUDIT-2026-09-22 P1-6; reworked 2026-10-03).
#
# HONEST STATUS (auto-review-20261003-073406 P1): SnapshotTestHelpers has NO
# record path — a missing golden only XCTFails (SnapshotTestHelpers.swift
# :125-134) and the only `__Snapshots__` write anywhere in Tests/ is the
# mismatch artifact `<test>.actual.png` (:150). So this script CANNOT
# re-record goldens: after `find -delete` the suites fail on missing goldens
# and nothing is written. Retained as a destructive-flow tripwire: it
# refuses to run while __Snapshots__ has uncommitted tracked changes, and
# the post-run guard restores every missing golden from git and exits 1
# loudly. The regenerate flow becomes reachable only after an env-gated
# record path is implemented (gated in docs/skips-ledger.md restore
# checklist; the guard must then be upgraded from existence-check to
# content-check). Legitimate baseline retirement is `git rm` of the golden
# together with retiring/reworking its test — never this script.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

SNAPSHOT_DIR="Tests/ClipMemoryTests/__Snapshots__"

echo "== Preflight: refusing to run on a dirty snapshot tree =="
if [ -n "$(git status --porcelain --untracked-files=no "$SNAPSHOT_DIR/")" ]; then
  echo "ERROR: $SNAPSHOT_DIR has uncommitted tracked changes. Commit or"
  echo "stash them first — the guard's restore step (git checkout --) is"
  echo "allowed to overwrite tracked files and would clobber them."
  exit 1
fi

echo "== Inventorying existing goldens =="
existing_goldens="$(find "$SNAPSHOT_DIR" -name '*.png' 2>/dev/null | sort || true)"

echo "== Removing existing goldens =="
find "$SNAPSHOT_DIR" -name '*.png' -delete 2>/dev/null || true

echo "== Running snapshot suites (NO record path exists — goldens will NOT be re-recorded) =="
xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ClipboardItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/SettingsTabSnapshotTests \
  -only-testing:ClipMemoryTests/TrashItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/WelcomeViewSnapshotTests \
  test 2>&1 | tail -30 || true

echo "== Guard: verifying and restoring goldens =="
missing=0
while IFS= read -r golden; do
  if [ -z "$golden" ]; then continue; fi
  if [ ! -f "$golden" ]; then
    echo "MISSING golden (expected — no record path exists yet): $golden"
    git checkout -- "$golden"
    missing=1
  fi
done <<< "$existing_goldens"

if [ "$missing" -ne 0 ]; then
  echo ""
  echo "Missing goldens restored from git (tree back to pre-run state)."
  echo "ERROR: no goldens were re-recorded — SnapshotTestHelpers has no record"
  echo "path (missing golden = XCTFail; see docs/skips-ledger.md restore"
  echo "checklist). This script only tripwires the destructive flow."
  exit 1
fi

echo ""
echo "All pre-existing goldens were re-recorded. Review the diff. If accepted, commit:"
echo "  git add $SNAPSHOT_DIR/"
echo "  git commit -m 'test(snapshots): regenerate goldens for <reason>'"
