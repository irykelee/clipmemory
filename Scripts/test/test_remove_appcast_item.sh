#!/bin/bash
# TDD test for Scripts/update_appcast.sh::remove_appcast_item
#
# remove_appcast_item is the inverse of insert_appcast_item, needed by
# rollback-release.sh: when a release is rolled back, release.yml has
# already pushed the <item> for that version to main, so the feed keeps
# advertising a version whose tarball no longer exists. Sparkle clients
# then offer an update that 404s on download.
#
# Validates that remove_appcast_item:
#   1. Removes the whole <item> block for the target version
#   2. Removes ONLY that item, leaving siblings byte-intact
#   3. Leaves no orphan fragments (enclosure / title / pubDate)
#   4. Preserves the channel skeleton
#   5. Is idempotent (removing an absent version is a no-op, exit 0)
#   6. Refuses a malformed appcast (no </channel>) instead of silently
#      rewriting it unchanged — mirrors REL-4's guard on insert
#
# Run: bash Scripts/test/test_remove_appcast_item.sh
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

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

FAKE_CONTENT="$TEST_DIR/payload.txt"
printf 'deterministic payload for predictable length\n' > "$FAKE_CONTENT"
FAKE_TARBALL="$TEST_DIR/ClipMemory.tar.gz"
tar -czf "$FAKE_TARBALL" -C "$TEST_DIR" "payload.txt"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../update_appcast.sh
source "${SCRIPT_DIR}/update_appcast.sh"

# --- Assertion 1: function exists ---
if ! declare -f remove_appcast_item > /dev/null; then
    echo "FAIL: remove_appcast_item function not defined in Scripts/update_appcast.sh" >&2
    echo "  expected: source-able script defines remove_appcast_item()" >&2
    exit 1
fi

# --- Build a two-item feed (9.9.10 newest, prepended) ---
insert_appcast_item "$FAKE_APPCAST" "9.9.9"  "$FAKE_TARBALL" "SIG_KEEP=" > /dev/null
insert_appcast_item "$FAKE_APPCAST" "9.9.10" "$FAKE_TARBALL" "SIG_DROP=" > /dev/null

# Capture the sibling block verbatim so we can prove it survives untouched.
KEEP_BLOCK_BEFORE=$(awk '/<item>/{f=1} f{print} /<\/item>/{if(f&&seen)exit; if(f)seen=1}' "$FAKE_APPCAST" \
    | grep -A100 'sparkle:version>9.9.9<' || true)

# --- Run the function under test: drop the rolled-back version ---
remove_appcast_item "$FAKE_APPCAST" "9.9.10" > /dev/null

# --- Assertion 2: exactly one item remains ---
item_count=$(grep -c "<item>" "$FAKE_APPCAST")
if [ "$item_count" -ne 1 ]; then
    echo "FAIL: expected 1 <item> after removal, got $item_count" >&2
    cat "$FAKE_APPCAST" >&2
    exit 1
fi

# --- Assertion 3: the removed version is fully gone ---
for fragment in \
    "<sparkle:version>9.9.10</sparkle:version>" \
    "<sparkle:shortVersionString>9.9.10</sparkle:shortVersionString>" \
    "<title>Version 9.9.10</title>" \
    "SIG_DROP=" \
    "releases/download/v9.9.10/"
do
    if grep -qF "$fragment" "$FAKE_APPCAST"; then
        echo "FAIL: orphan fragment left behind after removal: $fragment" >&2
        cat "$FAKE_APPCAST" >&2
        exit 1
    fi
done

# --- Assertion 4: the sibling item survived intact ---
for fragment in \
    "<sparkle:version>9.9.9</sparkle:version>" \
    "SIG_KEEP=" \
    "releases/download/v9.9.9/"
do
    if ! grep -qF "$fragment" "$FAKE_APPCAST"; then
        echo "FAIL: removal damaged the sibling item, missing: $fragment" >&2
        cat "$FAKE_APPCAST" >&2
        exit 1
    fi
done

# Structural balance: every <item> has a matching </item>.
open_count=$(grep -c "<item>" "$FAKE_APPCAST")
close_count=$(grep -c "</item>" "$FAKE_APPCAST")
if [ "$open_count" -ne "$close_count" ]; then
    echo "FAIL: unbalanced item tags after removal (<item>=$open_count </item>=$close_count)" >&2
    cat "$FAKE_APPCAST" >&2
    exit 1
fi

# --- Assertion 5: channel skeleton preserved ---
for fragment in "<channel>" "</channel>" "<title>ClipMemory Updates</title>" "</rss>"; do
    if ! grep -qF "$fragment" "$FAKE_APPCAST"; then
        echo "FAIL: removal damaged the channel skeleton, missing: $fragment" >&2
        exit 1
    fi
done

# --- Assertion 6: idempotent — removing an absent version is a no-op ---
BEFORE_NOOP=$(cat "$FAKE_APPCAST")
if ! remove_appcast_item "$FAKE_APPCAST" "9.9.10" > /dev/null; then
    echo "FAIL: removing an absent version should exit 0 (idempotent)" >&2
    exit 1
fi
AFTER_NOOP=$(cat "$FAKE_APPCAST")
if [ "$BEFORE_NOOP" != "$AFTER_NOOP" ]; then
    echo "FAIL: no-op removal modified the file" >&2
    diff <(printf '%s' "$BEFORE_NOOP") <(printf '%s' "$AFTER_NOOP") >&2 || true
    exit 1
fi

# --- Assertion 7: substring versions must not collide ---
# Removing "9.9.1" must NOT match "9.9.10" — a naive grep/sed on the bare
# version string would take the wrong block out of the feed.
COLLIDE_APPCAST="$TEST_DIR/collide.xml"
cat > "$COLLIDE_APPCAST" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClipMemory Updates</title>
  </channel>
</rss>
EOF
insert_appcast_item "$COLLIDE_APPCAST" "9.9.10" "$FAKE_TARBALL" "SIG_LONG=" > /dev/null
remove_appcast_item "$COLLIDE_APPCAST" "9.9.1" > /dev/null
if ! grep -qF "<sparkle:version>9.9.10</sparkle:version>" "$COLLIDE_APPCAST"; then
    echo "FAIL: removing 9.9.1 wrongly matched and removed 9.9.10 (substring collision)" >&2
    exit 1
fi

# --- Assertion 8: malformed appcast is refused, not silently rewritten ---
BROKEN_APPCAST="$TEST_DIR/broken.xml"
printf '<?xml version="1.0"?>\n<rss><channel><item></item>\n' > "$BROKEN_APPCAST"
BROKEN_BEFORE=$(cat "$BROKEN_APPCAST")
if remove_appcast_item "$BROKEN_APPCAST" "9.9.9" 2>/dev/null; then
    echo "FAIL: expected non-zero exit on appcast with no </channel>" >&2
    exit 1
fi
if [ "$BROKEN_BEFORE" != "$(cat "$BROKEN_APPCAST")" ]; then
    echo "FAIL: refused removal must leave the malformed file untouched" >&2
    exit 1
fi

echo "PASS: remove_appcast_item drops exactly the target item, preserves siblings and skeleton, is idempotent, resists substring collision, and refuses a malformed appcast"
