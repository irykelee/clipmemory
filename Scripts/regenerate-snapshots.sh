#!/usr/bin/env bash
# Regenerate snapshot goldens (P1-AUDIT-2026-09-22 P1-6).
# Deletes Tests/.../__Snapshots__/, runs xcodebuild test once (records
# new goldens), then prints `git add` line for the operator to commit.
#
# ID-CRASH-0038 skip-guard (2026-10-02, auto-review-20261002-202924 P1-1):
# skipped snapshot tests render nothing, so the goldens this script deletes
# are never re-recorded. The post-run check below hard-fails in that case
# instead of printing the commit invitation — committing a golden deletion
# would destroy baselines (e.g. the masking sentinel
# testRendersSensitiveItemMasked.png, docs/skips-ledger.md).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

SNAPSHOT_DIR="Tests/ClipMemoryTests/__Snapshots__"

echo "== Inventorying existing goldens =="
existing_goldens="$(find "$SNAPSHOT_DIR" -name '*.png' 2>/dev/null | sort || true)"

echo "== Removing existing goldens =="
find "$SNAPSHOT_DIR" -name '*.png' -delete 2>/dev/null || true

echo "== Recording new goldens =="
xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ClipboardItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/SettingsTabSnapshotTests \
  -only-testing:ClipMemoryTests/TrashItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/WelcomeViewSnapshotTests \
  test 2>&1 | tail -30 || true

echo "== Git status =="
git status --short "$SNAPSHOT_DIR/"

echo "== Verifying all pre-existing goldens were re-recorded =="
missing=0
while IFS= read -r golden; do
  if [ -z "$golden" ]; then continue; fi
  if [ ! -f "$golden" ]; then
    echo "MISSING golden (not re-recorded): $golden"
    missing=1
  fi
done <<< "$existing_goldens"

if [ "$missing" -ne 0 ]; then
  echo ""
  echo "ERROR: some goldens were NOT re-recorded. Their tests are either"
  echo "skipped (see docs/skips-ledger.md — skipped tests render nothing, so"
  echo "their goldens are never re-recorded) or the test run failed."
  echo "Do NOT commit golden deletions. Restore them with:"
  echo "  git checkout -- $SNAPSHOT_DIR/"
  exit 1
fi

echo ""
echo "All pre-existing goldens were re-recorded. Review the diff. If accepted, commit:"
echo "  git add $SNAPSHOT_DIR/"
echo "  git commit -m 'test(snapshots): regenerate goldens for <reason>'"
