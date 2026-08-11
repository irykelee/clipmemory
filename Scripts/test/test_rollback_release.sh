#!/bin/bash
# Tests for Scripts/rollback-release.sh
#
# Covers the 5 critical paths via fake `gh` + intercepted `git` destructive
# commands + a real fake repo layout so the script's SCRIPT_DIR/PROJECT_DIR
# derivation lands inside the sandbox:
#   1. release exists        → proceeds past Gate 2
#   2. release NOT exists    → die at Gate 2, NO destructive ops
#   3. tag delete            → Step 4 issues local + remote tag delete
#   4. project.yml restore   → Step 5 sed writes PREV_VERSION, not VERSION
#   5. non-TTY Confirm gate  → exit 3, NO destructive ops
#
# SAFETY INVARIANT: every real destructive command (`gh release delete`,
# `git tag -d`, `git push origin :refs/tags/...`) is intercepted by a stub
# on $FAKE_BIN. A test bug MUST NOT reach a real GitHub release or remote
# tag — only the stubs (which write to local logs) are invoked.
#
# Run: bash Scripts/test/test_rollback_release.sh
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Fake repo: must mirror real layout so rollback-release.sh's
# SCRIPT_DIR/PROJECT_DIR derivation (SCRIPT_DIR = Scripts/, PROJECT_DIR = .)
# naturally lands inside FAKE_REPO and exercises the real source. ---
FAKE_REPO="$TEST_DIR/fake-repo"
mkdir -p "$FAKE_REPO/Scripts"
cd "$FAKE_REPO"
git init -q
git config user.email test@example.com
git config user.name Test
git config commit.gpgsign false
cat > project.yml <<'EOF'
MARKETING_VERSION: "2.7.9"
CURRENT_PROJECT_VERSION: "2.7.9"
DEVELOPMENT_TEAM: "G59B692W3M"
EOF
# Fake appcast carrying the item for the release we roll back (2.7.9) plus a
# sibling (2.7.8) that must survive Step 6 untouched.
cat > appcast.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClipMemory Updates</title>
    <item>
      <title>Version 2.7.9</title>
      <sparkle:shortVersionString>2.7.9</sparkle:shortVersionString>
      <sparkle:version>2.7.9</sparkle:version>
      <enclosure url="https://github.com/irykelee/clipmemory/releases/download/v2.7.9/ClipMemory.tar.gz"
                 sparkle:edSignature="SIG_ROLLED_BACK=" />
    </item>
    <item>
      <title>Version 2.7.8</title>
      <sparkle:shortVersionString>2.7.8</sparkle:shortVersionString>
      <sparkle:version>2.7.8</sparkle:version>
      <enclosure url="https://github.com/irykelee/clipmemory/releases/download/v2.7.8/ClipMemory.tar.gz"
                 sparkle:edSignature="SIG_KEEP=" />
    </item>
  </channel>
</rss>
EOF
git add project.yml appcast.xml && git commit -qm "fake init"
git tag v2.7.8
git tag v2.7.9  # the release we want to roll back
git symbolic-ref HEAD refs/heads/main 2>/dev/null || git checkout -b main

# --- Fake bin: stub gh, intercept git's destructive commands only. ---
# Real git handles safe ops (status/branch/etc.) on FAKE_REPO. Destructive
# ops (tag -d, push origin) are stubbed and logged so a test bug can't
# touch real state.
FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
GH_STATE="$TEST_DIR/gh-state"
mkdir -p "$GH_STATE"
# File contents = the value `gh api ... --jq .name` would resolve to.
# Real gh runs jq internally; our fake bypasses that and returns the
# pre-computed .name value directly. Matches the script's contract:
# TITLE=$(gh api ... --jq .name) must be non-empty and not "null".
echo "v2.7.8 — fake release for test / 测试用" > "$GH_STATE/release-v2.7.9.json"

cat > "$FAKE_BIN/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$GH_STATE/calls.log"
case "\$1 \$2" in
  "api repos/"*)
    # Step 7 asks for the PREV release's tarball digest; Gate 2 asks for the
    # rolled-back release's title. Distinguish by the --jq expression.
    if [[ "\$*" == *"assets"* ]]; then
      echo "sha256:feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"
    elif [[ -f "$GH_STATE/release-v2.7.9.json" ]]; then
      cat "$GH_STATE/release-v2.7.9.json"
    else
      echo "null"
    fi
    ;;
  "release delete")
    rm -f "$GH_STATE/release-v2.7.9.json"
    echo "  ✅ [fake-gh] deleted release \$2" >> "$GH_STATE/calls.log"
    ;;
  *)
    echo "[fake-gh] unhandled: gh \$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

# Stub curl so the jsDelivr purge in Step 6 never leaves the sandbox.
cat > "$FAKE_BIN/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$GH_STATE/curl.log"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/git" <<EOF
#!/bin/bash
# SAFETY: intercept every command that would touch a real remote. The fake
# repo has no 'origin', so an escape would fail rather than mutate real
# state — but these are stubbed explicitly so the logs prove what the
# script issued.
case "\$1 \$2" in
  "tag -d")
    echo "[fake-git] tag -d \$3" >> "$FAKE_REPO/.git/fake-tag-deletes.log"
    exit 0
    ;;
  "push origin")
    echo "[fake-git] push \$*" >> "$FAKE_REPO/.git/fake-push.log"
    exit 0
    ;;
  "pull --ff-only")
    echo "[fake-git] pull \$*" >> "$FAKE_REPO/.git/fake-pull.log"
    exit 0
    ;;
  "clone --quiet")
    # Step 7 clones the tap repo. Materialise a minimal working copy at the
    # requested destination (last arg) so the script's sed/commit/push path
    # is exercised for real.
    DEST="\${@: -1}"
    mkdir -p "\$DEST/Casks"
    /usr/bin/git init -q "\$DEST"
    /usr/bin/git -C "\$DEST" config user.email test@example.com
    /usr/bin/git -C "\$DEST" config user.name Test
    /usr/bin/git -C "\$DEST" config commit.gpgsign false
    printf 'cask "clipmemory" do\n  version "2.7.9"\n  sha256 "deadbeef"\nend\n' > "\$DEST/Casks/clipmemory.rb"
    /usr/bin/git -C "\$DEST" add Casks/clipmemory.rb
    /usr/bin/git -C "\$DEST" commit -qm "seed"
    echo "[fake-git] clone -> \$DEST" >> "$FAKE_REPO/.git/fake-clone.log"
    exit 0
    ;;
esac
# Intercept pushes issued via -C <dir> (Step 7's tap push) before passthrough.
if [[ "\$1" == "-C" && "\$3" == "push" ]]; then
    echo "[fake-git] tap push \$*" >> "$FAKE_REPO/.git/fake-tap-push.log"
    exit 0
fi
# Pass everything else through to real git (status, branch, etc.)
exec /usr/bin/git "\$@"
EOF
chmod +x "$FAKE_BIN/git"

# Copy rollback-release.sh into FAKE_REPO/Scripts/ so its SCRIPT_DIR
# resolves to FAKE_REPO/Scripts and PROJECT_DIR (= SCRIPT_DIR/..) resolves
# to FAKE_REPO — exercising the real script source. Track it so `git status
# --porcelain` returns clean (Gate 1, rollback-release.sh:50); real repo
# also tracks it under Scripts/.
cp "$SCRIPT_DIR/rollback-release.sh" "$FAKE_REPO/Scripts/rollback-release.sh"
chmod +x "$FAKE_REPO/Scripts/rollback-release.sh"
# Step 6 sources update_appcast.sh for remove_appcast_item; Step 7 renders
# cask-template.rb. Both must exist at the same SCRIPT_DIR the script derives.
cp "$SCRIPT_DIR/update_appcast.sh" "$FAKE_REPO/Scripts/update_appcast.sh"
cp "$SCRIPT_DIR/cask-template.rb" "$FAKE_REPO/Scripts/cask-template.rb"
git add Scripts/rollback-release.sh Scripts/update_appcast.sh Scripts/cask-template.rb
git commit -qm "track rollback"

# Baseline commit for reset_state: Step 6 commits appcast.xml, so rewinding
# needs a hard reset rather than a working-tree rewrite.
BASE_REF=$(/usr/bin/git -C "$FAKE_REPO" rev-parse HEAD)

PASS=0; FAIL=0
ok()  { echo "  ✅ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $*"; FAIL=$((FAIL + 1)); }
expect_rc() {
  local want="$1" desc="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" -eq "$want" ]]; then ok "$desc"; else bad "$desc (rc=$got, want $want)"; fi
}

# Helper: rewind fake-repo state to "release v2.7.9 exists + project.yml = 2.7.9"
reset_state() {
    /usr/bin/git -C "$FAKE_REPO" reset --hard -q "$BASE_REF"
    cat > "$FAKE_REPO/project.yml" <<'EOF'
MARKETING_VERSION: "2.7.9"
CURRENT_PROJECT_VERSION: "2.7.9"
DEVELOPMENT_TEAM: "G59B692W3M"
EOF
    echo "v2.7.8 — fake release for test / 测试用" > "$GH_STATE/release-v2.7.9.json"
    : > "$GH_STATE/calls.log"
    : > "$GH_STATE/curl.log"
    rm -f "$FAKE_REPO/.git/fake-tag-deletes.log" "$FAKE_REPO/.git/fake-push.log" \
          "$FAKE_REPO/.git/fake-pull.log" "$FAKE_REPO/.git/fake-clone.log" \
          "$FAKE_REPO/.git/fake-tap-push.log"
}

# Helper: run the fake rollback with PATH override
run_fake_rollback() {
    env PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$TEST_DIR" \
        "$FAKE_REPO/Scripts/rollback-release.sh" "$@"
}

echo "=== Path 1: release exists → proceeds past Gate 2 ==="
reset_state
expect_rc 0 "exits 0 when release exists + --yes" run_fake_rollback v2.7.9 v2.7.8 --yes
grep -q 'gh api repos/' "$GH_STATE/calls.log" && ok "Gate 2: gh api called (proves release was checked)" || bad "Gate 2 not reached"

echo "=== Path 2: release NOT exists → die, NO destructive ops ==="
reset_state
rm -f "$GH_STATE/release-v2.7.9.json"
expect_rc 1 "die (rc=1) when release missing" run_fake_rollback v2.7.9 v2.7.8 --yes
grep -q 'release delete' "$GH_STATE/calls.log" && bad "Step 3 (gh release delete) ran despite Gate 2 failure" || ok "Step 3 NOT reached after Gate 2 die"
[[ ! -s "$FAKE_REPO/.git/fake-tag-deletes.log" ]] && ok "Step 4 local tag delete NOT reached" || bad "Step 4a ran after Gate 2 die"
[[ ! -s "$FAKE_REPO/.git/fake-push.log" ]] && ok "Step 4 remote tag push NOT reached" || bad "Step 4b ran after Gate 2 die"

echo "=== Path 3: tag delete — Step 4a local + Step 4b remote ==="
# Path 2 removed release-v2.7.9.json (Gate 2 died before Step 4). Re-create
# it so the script reaches Step 4 and we can verify the destructive ops
# are issued (to the fakes only).
echo "v2.7.8 — fake release for test / 测试用" > "$GH_STATE/release-v2.7.9.json"
rm -f "$FAKE_REPO/.git/fake-tag-deletes.log" "$FAKE_REPO/.git/fake-push.log"
run_fake_rollback v2.7.9 v2.7.8 --yes >/dev/null 2>&1
grep -q 'tag -d v2.7.9' "$FAKE_REPO/.git/fake-tag-deletes.log" && ok "Step 4a: git tag -d v2.7.9 invoked" || bad "Step 4a missing"
grep -q 'push origin :refs/tags/v2.7.9' "$FAKE_REPO/.git/fake-push.log" && ok "Step 4b: git push origin :refs/tags/v2.7.9 invoked" || bad "Step 4b missing"

echo "=== Path 4: project.yml restored to PREV_VERSION (not VERSION) ==="
reset_state
run_fake_rollback v2.7.9 v2.7.8 --yes >/dev/null 2>&1
grep -q 'MARKETING_VERSION: "2.7.8"' "$FAKE_REPO/project.yml" \
    && ok "Step 5: MARKETING_VERSION = 2.7.8 (PREV)" \
    || bad "MARKETING_VERSION not restored (got: $(grep MARKETING_VERSION "$FAKE_REPO/project.yml"))"
grep -q 'CURRENT_PROJECT_VERSION: "2.7.8"' "$FAKE_REPO/project.yml" \
    && ok "Step 5: CURRENT_PROJECT_VERSION = 2.7.8 (PREV)" \
    || bad "CURRENT_PROJECT_VERSION not restored"
# VERSION (2.7.9) must NOT survive in version fields after restore.
# DEVELOPMENT_TEAM contains "G59B692W3M" — no version strings, so a bare
# grep for "2.7.9" is safe.
grep -q '"2.7.9"' "$FAKE_REPO/project.yml" \
    && bad "project.yml still contains VERSION 2.7.9 after restore" \
    || ok "VERSION (2.7.9) no longer in project.yml"

echo "=== Path 5: non-TTY Confirm gate → die (rc=3), NO destructive ops ==="
reset_state
# Run WITHOUT --yes; redirect stdin from /dev/null so the `read ... < /dev/tty`
# line sees no TTY → CONFIRM="" → exit 3 at the Confirm gate (script L64-65).
expect_rc 3 "die (rc=3) at Confirm gate without --yes and no TTY" \
    run_fake_rollback v2.7.9 v2.7.8 < /dev/null
grep -q 'release delete' "$GH_STATE/calls.log" \
    && bad "Step 3 ran despite Confirm gate failure" \
    || ok "Step 3 NOT reached after Confirm gate die"
[[ ! -s "$FAKE_REPO/.git/fake-tag-deletes.log" ]] && ok "Step 4 local NOT reached" || bad "Step 4a ran"
[[ ! -s "$FAKE_REPO/.git/fake-push.log" ]] && ok "Step 4 remote NOT reached" || bad "Step 4b ran"
# Confirm project.yml was NOT touched by the failed run
grep -q '"2.7.9"' "$FAKE_REPO/project.yml" \
    && ok "project.yml still 2.7.9 (Step 5 not reached after Confirm die)" \
    || bad "project.yml was modified despite aborted run"

echo "=== Path 6: Step 6 removes the rolled-back appcast item, keeps siblings ==="
reset_state
run_fake_rollback v2.7.9 v2.7.8 --yes >/dev/null 2>&1
grep -qF '<sparkle:version>2.7.9</sparkle:version>' "$FAKE_REPO/appcast.xml" \
    && bad "appcast still advertises rolled-back v2.7.9 (Sparkle would 404 on download)" \
    || ok "Step 6: v2.7.9 item removed from appcast.xml"
grep -qF '<sparkle:version>2.7.8</sparkle:version>' "$FAKE_REPO/appcast.xml" \
    && ok "Step 6: sibling v2.7.8 item survived" \
    || bad "Step 6 removed the wrong item — sibling v2.7.8 is gone"
grep -qF 'SIG_ROLLED_BACK=' "$FAKE_REPO/appcast.xml" \
    && bad "orphan enclosure fragment left in appcast" \
    || ok "Step 6: no orphan fragment from the removed item"
grep -q 'push origin main' "$FAKE_REPO/.git/fake-push.log" \
    && ok "Step 6: appcast change pushed to main" \
    || bad "Step 6 did not push the appcast fix"
grep -q 'purge.jsdelivr.net' "$GH_STATE/curl.log" \
    && ok "Step 6: jsDelivr mirror purged (stale feed would persist 7d otherwise)" \
    || bad "Step 6 did not purge jsDelivr"

echo "=== Path 7: Step 7 restores tap Cask to PREV ==="
reset_state
run_fake_rollback v2.7.9 v2.7.8 --yes >/dev/null 2>&1
[[ -s "$FAKE_REPO/.git/fake-clone.log" ]] \
    && ok "Step 7: tap repo cloned" \
    || bad "Step 7 never cloned the tap repo"
grep -q 'tap push' "$FAKE_REPO/.git/fake-tap-push.log" 2>/dev/null \
    && ok "Step 7: tap Cask rollback pushed (brew upgrade would 404 otherwise)" \
    || bad "Step 7 did not push the tap Cask rollback"

echo "=== Path 8: appcast remediation failure is loud, not silent ==="
# Corrupt the appcast so remove_appcast_item refuses (no </channel>). The
# script must still report and exit non-zero rather than claim success —
# rollback is exactly when a silently-skipped step does the most damage.
reset_state
printf '<?xml version="1.0"?>\n<rss><channel><item></item>\n' > "$FAKE_REPO/appcast.xml"
/usr/bin/git -C "$FAKE_REPO" add appcast.xml
/usr/bin/git -C "$FAKE_REPO" commit -qm "corrupt appcast"
OUT=$(run_fake_rollback v2.7.9 v2.7.8 --yes 2>&1) && RC=0 || RC=$?
[[ "$RC" -ne 0 ]] \
    && ok "Path 8: exits non-zero when a remediation step fails (rc=$RC)" \
    || bad "Path 8: exited 0 despite a failed remediation step"
grep -q '补救步骤失败' <<< "$OUT" \
    && ok "Path 8: failure surfaced in output" \
    || bad "Path 8: failure not reported to the operator"
grep -q 'tag -d v2.7.9' "$FAKE_REPO/.git/fake-tag-deletes.log" \
    && ok "Path 8: earlier destructive steps still completed (no partial abort)" \
    || bad "Path 8: appcast failure aborted the earlier rollback steps"

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "✅ All $PASS checks passed."
    exit 0
else
    echo "❌ $FAIL of $((PASS + FAIL)) checks failed."
    exit 1
fi
