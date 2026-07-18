#!/bin/bash
# TDD test for Scripts/update_appcast.sh::insert_appcast_item
#
# Validates that insert_appcast_item:
#   1. Appends an <item> before </channel> preserving the channel skeleton
#   2. Records the version in both sparkle:shortVersionString and sparkle:version
#   3. Records the tarball byte length and EdDSA signature on the enclosure
#   4. Points the enclosure at the GitHub Releases download URL
#   5. Accumulates multiple items across runs
#
# Run: bash Scripts/test/test_update_appcast.sh
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

# --- Setup: temp workspace ---
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# --- Fake appcast (same skeleton as the real one) ---
FAKE_APPCAST="$TEST_DIR/appcast.xml"
cat > "$FAKE_APPCAST" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>ClipMemory Updates</title>
    <link>https://raw.githubusercontent.com/irykelee/clipmemory/main/appcast.xml</link>
    <description>Most recent changes with links to updates for ClipMemory.</description>
    <language>en</language>
  </channel>
</rss>
EOF

# --- Fake tarball with deterministic content ---
FAKE_CONTENT="$TEST_DIR/payload.txt"
printf 'deterministic payload for predictable length\n' > "$FAKE_CONTENT"
FAKE_TARBALL="$TEST_DIR/ClipMemory.tar.gz"
tar -czf "$FAKE_TARBALL" -C "$TEST_DIR" "payload.txt"
EXPECTED_LENGTH=$(stat -f %z "$FAKE_TARBALL")

# --- Source update_appcast.sh (must NOT execute main body when sourced) ---
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../update_appcast.sh
source "${SCRIPT_DIR}/update_appcast.sh"

# --- Assertion 1: function exists ---
if ! declare -f insert_appcast_item > /dev/null; then
    echo "FAIL: insert_appcast_item function not defined in Scripts/update_appcast.sh" >&2
    echo "  expected: source-able script defines insert_appcast_item()" >&2
    exit 1
fi

# --- Run the function under test (twice, to verify accumulation) ---
insert_appcast_item "$FAKE_APPCAST" "9.9.9" "$FAKE_TARBALL" "SIG_AAA=" > /dev/null
insert_appcast_item "$FAKE_APPCAST" "9.9.10" "$FAKE_TARBALL" "SIG_BBB=" > /dev/null

# --- Assertion 2: two items present ---
item_count=$(grep -c "<item>" "$FAKE_APPCAST")
if [ "$item_count" -ne 2 ]; then
    echo "FAIL: expected 2 <item> elements, got $item_count" >&2
    exit 1
fi

# --- Assertion 3: versions recorded ---
for needle in \
    "<sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>" \
    "<sparkle:version>9.9.9</sparkle:version>" \
    "<sparkle:shortVersionString>9.9.10</sparkle:shortVersionString>" \
    "<sparkle:version>9.9.10</sparkle:version>"; do
    if ! grep -qF "$needle" "$FAKE_APPCAST"; then
        echo "FAIL: version element missing" >&2
        echo "  needle: $needle" >&2
        exit 1
    fi
done

# --- Assertion 4: enclosure carries length + signature + download URL ---
for needle in \
    "length=\"${EXPECTED_LENGTH}\"" \
    "sparkle:edSignature=\"SIG_AAA=\"" \
    "sparkle:edSignature=\"SIG_BBB=\"" \
    "url=\"https://github.com/irykelee/clipmemory/releases/download/v9.9.10/ClipMemory.tar.gz\""; do
    if ! grep -qF "$needle" "$FAKE_APPCAST"; then
        echo "FAIL: enclosure attribute missing" >&2
        echo "  needle: $needle" >&2
        exit 1
    fi
done

# --- Assertion 5: channel skeleton preserved ---
for needle in \
    "<title>ClipMemory Updates</title>" \
    "</channel>" \
    "</rss>"; do
    if ! grep -qF "$needle" "$FAKE_APPCAST"; then
        echo "FAIL: appcast skeleton broken" >&2
        echo "  needle: $needle" >&2
        exit 1
    fi
done

echo "PASS: insert_appcast_item inserts version + length + signature + URL and accumulates items"
exit 0
