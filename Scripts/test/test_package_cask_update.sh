#!/bin/bash
# TDD test for Scripts/package.sh::update_cask_sha
#
# Validates that update_cask_sha:
#   1. Computes the actual SHA256 of a tarball
#   2. Writes it back into Casks/clipmemory.rb replacing the old sha256 stanza
#   3. Also updates the version stanza to the new version
#   4. Preserves all other Cask content unchanged
#
# Run: bash Scripts/test/test_package_cask_update.sh
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

# --- Setup: temp workspace ---
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# --- Fake Cask (mimics real layout: leading whitespace, version + sha256 lines) ---
FAKE_CASK="$TEST_DIR/clipmemory.rb"
cat > "$FAKE_CASK" <<'EOF'
	cask "clipmemory" do
 	version "0.0.0"
	  sha256 "OLD_PLACEHOLDER_SHA_NEVER_MATCHES_REAL_OUTPUT_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

	  url "https://github.com/irykelee/clipmemory/releases/download/v#{version}/ClipMemory.tar.gz"
	  name "ClipMemory"
	  desc "Clipboard history manager for macOS with encryption and Quick Bar"
	  homepage "https://github.com/irykelee/clipmemory"

	  depends_on macos: ">= :ventura"

	  app "ClipMemory.app"

	  zap trash: [
	    "~/Library/Application Support/ClipMemory",
	    "~/Library/Preferences/com.clipmemory.app.plist",
	  ]
	end
EOF

# --- Fake tarball with deterministic content ---
FAKE_CONTENT="$TEST_DIR/payload.txt"
printf 'deterministic payload for predictable sha\n' > "$FAKE_CONTENT"
FAKE_TARBALL="$TEST_DIR/ClipMemory.tar.gz"
tar -czf "$FAKE_TARBALL" -C "$TEST_DIR" "payload.txt"
EXPECTED_SHA=$(shasum -a 256 "$FAKE_TARBALL" | awk '{print $1}')

# --- Source package.sh (must NOT execute main body when sourced) ---
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../package.sh
source "${SCRIPT_DIR}/package.sh"

# --- Assertion 1: function exists ---
if ! declare -f update_cask_sha > /dev/null; then
    echo "FAIL: update_cask_sha function not defined in Scripts/package.sh" >&2
    echo "  expected: source-able script defines update_cask_sha()" >&2
    exit 1
fi

# --- Run the function under test ---
update_cask_sha "$FAKE_CASK" "$FAKE_TARBALL" "9.9.9" > /dev/null

# --- Assertion 2: version line updated ---
got_version=$(grep -E '^[[:space:]]*version ' "$FAKE_CASK" | head -1 | sed -E 's/.*version "([^"]+)".*/\1/')
if [ "$got_version" != "9.9.9" ]; then
    echo "FAIL: version not updated" >&2
    echo "  expected: 9.9.9" >&2
    echo "  got:      $got_version" >&2
    exit 1
fi

# --- Assertion 3: sha256 line updated to expected SHA ---
got_sha=$(grep -E '^[[:space:]]*sha256 ' "$FAKE_CASK" | head -1 | sed -E 's/.*sha256 "([^"]+)".*/\1/')
if [ "$got_sha" != "$EXPECTED_SHA" ]; then
    echo "FAIL: sha256 not updated correctly" >&2
    echo "  expected: $EXPECTED_SHA" >&2
    echo "  got:      $got_sha" >&2
    exit 1
fi

# --- Assertion 4: other content preserved (URL, name, desc, homepage, etc.) ---
for needle in \
    'url "https://github.com/irykelee/clipmemory/releases/download/v#{version}/ClipMemory.tar.gz"' \
    'name "ClipMemory"' \
    'desc "Clipboard history manager for macOS with encryption and Quick Bar"' \
    'homepage "https://github.com/irykelee/clipmemory"' \
    'depends_on macos: ">= :ventura"' \
    'app "ClipMemory.app"' \
    '"~/Library/Application Support/ClipMemory"' \
    '"~/Library/Preferences/com.clipmemory.app.plist"'; do
    if ! grep -qF "$needle" "$FAKE_CASK"; then
        echo "FAIL: preserved content missing" >&2
        echo "  needle: $needle" >&2
        exit 1
    fi
done

# --- Assertion 5: old placeholder gone ---
if grep -q "OLD_PLACEHOLDER_SHA" "$FAKE_CASK"; then
    echo "FAIL: old placeholder SHA still present after update" >&2
    exit 1
fi

echo "PASS: update_cask_sha correctly updates version + sha256 + preserves other content"
exit 0