#!/usr/bin/env bash
# Regenerate snapshot goldens (P1-AUDIT-2026-09-22 P1-6).
# Deletes Tests/.../__Snapshots__/, runs xcodebuild test once (records
# new goldens), then prints `git add` line for the operator to commit.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "== Removing existing goldens =="
find Tests/ClipMemoryTests/__Snapshots__ -name '*.png' -delete 2>/dev/null || true

echo "== Recording new goldens =="
xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory \
  -only-testing:ClipMemoryTests/ClipboardItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/SettingsTabSnapshotTests \
  -only-testing:ClipMemoryTests/TrashItemRowSnapshotTests \
  -only-testing:ClipMemoryTests/WelcomeViewSnapshotTests \
  test 2>&1 | tail -30 || true

echo "== Git status =="
git status --short Tests/ClipMemoryTests/__Snapshots__/

echo ""
echo "Review the diff. If accepted, commit:"
echo "  git add Tests/ClipMemoryTests/__Snapshots__/"
echo "  git commit -m 'test(snapshots): regenerate goldens for <reason>'"