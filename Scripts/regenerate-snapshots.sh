#!/usr/bin/env bash
# Snapshot-golden tripwire (P1-AUDIT-2026-09-22 P1-6; reworked 2026-10-03).
#
# HONEST STATUS (auto-review-20261003-073406 P1): SnapshotTestHelpers has NO
# record path — a missing golden only XCTFails (SnapshotTestHelpers.swift
# :97-106) and the only `__Snapshots__` write anywhere in Tests/ is the
# mismatch artifact `<test>.actual.png` (:122). So this script CANNOT
# re-record goldens: after `find -delete` the suites fail on missing goldens
# and nothing is written. Retained as a destructive-flow tripwire:
# - refuses to run while __Snapshots__ has uncommitted tracked changes;
# - inventories TRACKED goldens only (git ls-files): untracked
#   `<test>.actual.png` mismatch artifacts must never enter the restore
#   list (auto-review-20261003-083314 P1 — with the old find-based
#   inventory an untracked artifact made `git checkout --` fail under
#   `set -e` and abort the loop mid-way, stranding tracked goldens
#   deleted);
# - the post-run guard restores every missing golden from git (per-file
#   checkout failures are guarded, not fatal to the loop; a bulk sweep
#   runs only on the failure path, where no re-record could have
#   happened) and exits 1 loudly.
# The regenerate flow becomes reachable only after an env-gated record
# path is implemented: set CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1 AND
# upgrade the guard from existence-check to content-check
# (docs/skips-ledger.md, tool-guard entry). Legitimate baseline
# retirement is `git rm` of the golden together with retiring/reworking
# its test — never this script.
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

echo "== Inventorying TRACKED goldens (git ls-files; untracked actual.png artifacts excluded) =="
existing_goldens="$(git ls-files "$SNAPSHOT_DIR" | grep '\.png$' | sort || true)"

echo "== Removing existing PNGs (tracked goldens + stale actual.png artifacts) =="
find "$SNAPSHOT_DIR" -name '*.png' -delete 2>/dev/null || true

echo "== Running snapshot suites (NO record path exists — goldens will NOT be re-recorded) =="
xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ClipboardItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/SettingsTabSnapshotTests \
  -only-testing:ClipMemoryTests/TrashItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/WelcomeViewSnapshotTests \
  test 2>&1 | tail -30 || true

echo "== Guard: verifying and restoring tracked goldens =="
missing=0
while IFS= read -r golden; do
  [ -z "$golden" ] && continue
  if [ ! -f "$golden" ]; then
    echo "MISSING golden (expected — no record path exists yet): $golden"
    # Guarded restore (083314 P1): a checkout failure must not abort the
    # loop under set -e and strand the remaining goldens deleted. The
    # existence check below is the real failure detector.
    git checkout -- "$golden" 2>/dev/null || true
    if [ ! -f "$golden" ]; then
      echo "ERROR: single-file restore failed for: $golden"
      missing=1
    fi
  fi
done <<< "$existing_goldens"

if [ "$missing" -ne 0 ]; then
  # No record path exists, so nothing in this run legitimately re-recorded
  # a golden — a bulk sweep cannot clobber fresh recordings here.
  echo "== Bulk sweep: restoring anything the per-file pass missed =="
  git checkout -- "$SNAPSHOT_DIR/" 2>/dev/null || true
  still_missing=0
  while IFS= read -r golden; do
    [ -z "$golden" ] && continue
    if [ ! -f "$golden" ]; then
      echo "STILL MISSING after bulk restore: $golden"
      still_missing=1
    fi
  done <<< "$existing_goldens"
  if [ "$still_missing" -ne 0 ]; then
    echo ""
    echo "ERROR: $SNAPSHOT_DIR restore incomplete — inspect manually before"
    echo "doing anything else (tracked goldens are in the git index, so"
    echo "'git checkout -- $SNAPSHOT_DIR/' recovers them)."
  else
    echo ""
    echo "All tracked goldens restored from git (tree back to pre-run state)."
  fi
  echo "ERROR: no goldens were re-recorded — SnapshotTestHelpers has no record"
  echo "path (missing golden = XCTFail; see docs/skips-ledger.md restore"
  echo "checklist). This script only tripwires the destructive flow."
  exit 1
fi

# Every tracked golden came back present. With no record path this branch
# should be unreachable (nothing writes goldens) — require the operator to
# have consciously landed the record path + content-check guard upgrade
# (073406 P2-3 forcing function; 083314 P2).
if [ "${CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED:-0}" != "1" ]; then
  echo ""
  echo "ERROR: all tracked goldens are present after the run, but"
  echo "SnapshotTestHelpers has NO record path, so nothing in Tests/ can"
  echo "have written them. This branch is unreachable by design."
  echo "If you have just implemented the env-gated record path AND upgraded"
  echo "this guard to a content check (docs/skips-ledger.md tool-guard"
  echo "entry), re-run with CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1."
  exit 1
fi

echo ""
echo "All pre-existing goldens were re-recorded. Review the diff. If accepted, commit:"
echo "  git add $SNAPSHOT_DIR/"
echo "  git commit -m 'test(snapshots): regenerate goldens for <reason>'"
