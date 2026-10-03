#!/usr/bin/env bash
# Snapshot-golden tripwire (P1-AUDIT-2026-09-22 P1-6; reworked 2026-10-03).
#
# HONEST STATUS (auto-review-20261003-073406 P1): SnapshotTestHelpers has NO
# record path — a missing golden only XCTFails (SnapshotTestHelpers.swift
# :97-106) and the only `__Snapshots__` write anywhere in Tests/ is the
# mismatch artifact `<test>.actual.png` (:126; was :122 before the 085151
# rework comment fix shifted it). So this script CANNOT
# re-record goldens: after `find -delete` the suites fail on missing goldens
# and nothing is written. Retained as a destructive-flow tripwire:
# - refuses to run without a working git, a verified clean snapshot tree,
#   and a NON-EMPTY tracked-golden inventory — all git steps fail CLOSED
#   BEFORE any deletion (auto-review-20261003-085151 P1: with the previous
#   fail-open checks, a bogus GIT_DIR passed preflight, emptied the
#   inventory, wiped all goldens and then blamed the record path);
# - inventories TRACKED goldens only (git ls-files): untracked
#   `<test>.actual.png` mismatch artifacts must never enter the restore
#   list (auto-review-20261003-083314 P1);
# - per-file restore is guarded (a checkout failure cannot abort the loop
#   under set -e and strand the remaining goldens deleted);
# - the one irreversible step — the delete — is verified by POST-STATE
#   (auto-review-20261003-101344 P2: BSD find's -delete always exits 0,
#   verified empirically even on unlink permission-denied, so the delete
#   cannot be made fail-closed by exit status; any surviving *.png aborts
#   the run before the suites execute);
# - after the run it reports accurately: restored > 0 → "restored from git,
#   nothing re-recorded" exit 1; restored == 0 (every golden reappeared
#   WITHOUT a git restore — impossible without a record path) → requires
#   CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1.
# Branch coverage: Scripts/test/test_regenerate_snapshots.sh exercises
# every exit path against a throwaway git repo via the
# CLIPMEMORY_SNAPSHOT_SCRIPT_ROOT seam (101344 P2).
# The regenerate flow becomes reachable only after an env-gated record path
# is implemented: set CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1 AND upgrade
# the guard from existence-check to content-check (docs/skips-ledger.md,
# tool-guard entry). With the env set, the failure-path bulk sweep REFUSES
# to run (it would clobber freshly recorded goldens). Legitimate baseline
# retirement is `git rm` of the golden together with retiring/reworking its
# test — never this script.
set -euo pipefail

# Test seam (101344 P2): the self-test
# (Scripts/test/test_regenerate_snapshots.sh) points this at a throwaway
# git repo so the destructive flow is exercised without touching this
# checkout. Unset in production use.
PROJECT_ROOT="${CLIPMEMORY_SNAPSHOT_SCRIPT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$PROJECT_ROOT"

SNAPSHOT_DIR="Tests/ClipMemoryTests/__Snapshots__"

echo "== Preflight: git sanity =="
if ! git rev-parse --show-toplevel > /dev/null 2>&1; then
  echo "ERROR: git cannot resolve this repository (bogus GIT_DIR /"
  echo "dubious ownership?). Refusing a destructive flow without working"
  echo "git — the restore steps depend on it."
  exit 1
fi
if ! status_out="$(git status --porcelain --untracked-files=no "$SNAPSHOT_DIR/")"; then
  echo "ERROR: git status failed. Refusing to run before a verified"
  echo "clean-tree check."
  exit 1
fi
if [ -n "$status_out" ]; then
  echo "ERROR: $SNAPSHOT_DIR has uncommitted tracked changes. Commit or"
  echo "stash them first — the guard's restore step (git checkout --) is"
  echo "allowed to overwrite tracked files and would clobber them."
  exit 1
fi

echo "== Inventorying TRACKED goldens (git ls-files; untracked actual.png artifacts excluded) =="
# Fail closed (085151 P1): a git failure or an EMPTY inventory must abort
# BEFORE the deletion step — an empty inventory would make the restore loop
# a no-op and the deletion unrecoverable. The inner `grep … || true`
# tolerates grep's no-match exit 1 under pipefail so the EMPTY case falls
# through to the guard below (101344 P2: previously a no-match grep was
# misreported as "golden inventory failed" and the empty-inventory guard
# was unreachable); a genuine git ls-files failure still trips this `if !`.
if ! existing_goldens="$(git ls-files -- "$SNAPSHOT_DIR" | { grep '\.png$' || true; } | sort)"; then
  echo "ERROR: golden inventory failed (git ls-files / grep). Refusing to"
  echo "delete goldens without a verified inventory."
  exit 1
fi
if [ -z "$existing_goldens" ]; then
  echo "ERROR: inventory is EMPTY — no tracked goldens found under"
  echo "$SNAPSHOT_DIR. Refusing a destructive run with an unverified"
  echo "inventory."
  exit 1
fi

echo "== Removing existing PNGs (tracked goldens + stale actual.png artifacts) =="
# 101344 P2: the previous `2>/dev/null || true` made this — the script's
# ONE irreversible step — fail-open and silent. BSD find's -delete always
# exits 0 (empirically verified: a permission-denied unlink still exits 0),
# so the delete cannot be made fail-closed by exit status; verify the
# intended post-state instead: NO *.png may survive it. (On GNU find a
# delete failure exits non-zero and set -e aborts here — also fail-closed.)
find "$SNAPSHOT_DIR" -name '*.png' -delete
if [ -n "$(find "$SNAPSHOT_DIR" -name '*.png' -print -quit 2>/dev/null)" ]; then
  echo "ERROR: *.png files survived the delete step (find reported success"
  echo "but files remain — permissions?). Refusing to run the suites"
  echo "against an unclear tree. Investigate, then restore with"
  echo "'git checkout -- $SNAPSHOT_DIR/'."
  exit 1
fi

echo "== Running snapshot suites (NO record path exists — goldens will NOT be re-recorded) =="
xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ClipboardItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/SettingsTabSnapshotTests \
  -only-testing:ClipMemoryTests/TrashItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/WelcomeViewSnapshotTests \
  test 2>&1 | tail -30 || true

echo "== Guard: verifying and restoring tracked goldens =="
restored=0
restore_failed=0
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
      restore_failed=1
    else
      restored=$((restored + 1))
    fi
  fi
done <<< "$existing_goldens"

if [ "$restore_failed" -ne 0 ]; then
  if [ "${CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED:-0}" = "1" ]; then
    # The sweep's safety rests on "nothing could have been re-recorded" —
    # an invariant that expires the moment the record path lands (085151
    # P2). With the env set, a bulk `git checkout --` would clobber any
    # freshly recorded golden, so refuse and hand over to the operator.
    echo ""
    echo "ERROR: restore failed while CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1."
    echo "Refusing to bulk-sweep: git checkout -- would clobber freshly"
    echo "recorded goldens. Inspect $SNAPSHOT_DIR manually."
    exit 1
  fi
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

if [ "$restored" -gt 0 ]; then
  # The normal path of this tripwire (auto-review-20261003-085157 P2: the
  # previous wording claimed this state was "unreachable by design" while
  # it is in fact what happens on every run).
  echo ""
  echo "All $restored missing tracked goldens restored from git (tree back to"
  echo "pre-run state). No goldens were re-recorded — SnapshotTestHelpers has"
  echo "no record path (missing golden = XCTFail; see docs/skips-ledger.md"
  echo "restore checklist). This script only tripwires the destructive flow."
  exit 1
fi

# restored == 0 and no failures: every tracked golden reappeared WITHOUT a
# git restore. The inventory was non-empty and all PNGs were deleted before
# the run, so something must have written them — impossible without a
# record path. Require the operator to have consciously landed the record
# path + content-check guard upgrade (073406 P2-3 forcing function).
if [ "${CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED:-0}" != "1" ]; then
  echo ""
  echo "ERROR: every tracked golden is present after the run and none was"
  echo "restored from git — but SnapshotTestHelpers has NO record path, so"
  echo "nothing in Tests/ can have written them. This state is not expected."
  echo "If you have just implemented the env-gated record path AND upgraded"
  echo "this guard to a content check (docs/skips-ledger.md tool-guard"
  echo "entry), re-run with CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1."
  exit 1
fi

echo ""
echo "All pre-existing goldens were re-recorded. Review the diff. If accepted, commit:"
echo "  git add $SNAPSHOT_DIR/"
echo "  git commit -m 'test(snapshots): regenerate goldens for <reason>'"
