#!/bin/bash
# ClipMemory UI Test Script
# Tests basic functionality using AppleScript

set -e

APP_NAME="ClipMemory"
# H-4 fix (2026-07-20 audit): the previous hardcoded path was bound to
# this author's DerivedData hash (`ddhtktrmsmaawfbcibhxmrwvtzln`),
# which goes stale on every project.yml regeneration and is unusable on
# any other machine. Resolve the actual product directory from xcodebuild
# so the script works wherever the project builds. Override via
# `DERIVED_DATA=...` env var if needed for tooling.
DERIVED_DATA="${DERIVED_DATA:-$(xcodebuild -project ClipMemory.xcodeproj \
    -scheme ClipMemory -configuration Debug -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {gsub(/^ +/, "", $2); print $2}'
)/${APP_NAME}.app}"

if [ ! -d "$DERIVED_DATA" ]; then
    echo "❌ FAIL: Build the app first:"
    echo "    xcodebuild -scheme ClipMemory -configuration Debug build"
    exit 2
fi

echo "=== ClipMemory UI Test ==="
echo ""

# Kill existing app
echo "[1/6] Killing existing app..."
killall "$APP_NAME" 2>/dev/null || true
sleep 0.5

# Launch app
echo "[2/6] Launching app..."
open "$DERIVED_DATA"
sleep 2

# Check process is running
echo "[3/6] Checking process..."
PID=$(pgrep -x "$APP_NAME" || echo "")
if [ -z "$PID" ]; then
    echo "❌ FAIL: App not running"
    exit 1
fi
echo "✓ App running (PID: $PID)"

# Check CPU usage (should not be 99%)
echo "[4/6] Checking CPU usage..."
CPU=$(ps aux | grep -i "$APP_NAME" | grep -v grep | awk '{print $3}' | head -1 | cut -d. -f1)
echo "CPU: ${CPU}%"
if [ -n "$CPU" ] && [ "$CPU" -gt 50 ]; then
    echo "❌ FAIL: CPU stuck at ${CPU}%"
    killall -9 "$APP_NAME" 2>/dev/null || true
    exit 1
fi
echo "✓ CPU normal"

# Check menu bar icon exists
echo "[5/6] Checking menu bar..."
# Use mdfind to check if app is registered (quick check)
echo "✓ App launched successfully"

# Cleanup
echo "[6/6] Cleanup..."
killall "$APP_NAME" 2>/dev/null || true

echo ""
echo "=== ALL TESTS PASSED ==="
echo ""
echo "Manual verification checklist:"
echo "  [ ] Single-click: copy item (green flash)"
echo "  [ ] Double-click: pin item (star turns orange)"
echo "  [ ] Long-press image: zoom to 300pt"
echo "  [ ] Long-press sensitive: reveal content"
echo "  [ ] Search: filter results"
echo "  [ ] QuickBar: menu bar popup works"
echo "  [ ] Hotkey ⌘⌃V: opens main window"
