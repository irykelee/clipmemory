#!/usr/bin/env bash
# Scripts/production-probe-smoke.sh
# ID-REVIEW-1045 (2026-10-28): production-side BLACK-BOX sentinel for the
# "is this a test process?" probe (`TestIsolation.isRunningTests`).
#
# ## Why this script exists
#
# ID-REVIEW-1042 / 1043 / 1044 each added an isolation gate, and every one
# of those gates is conditioned on ONE shared probe. The probe itself was
# an untestable `static let`, so two halves stayed unreachable:
#
#   * "a NON-test process ⇒ the probe is false" — the half that decides
#     whether the PRODUCTION app registers its global hotkey, shows its
#     menu-bar item, and keeps its data in the real domain. In a test
#     host the probe is ALWAYS true, so that half was structurally
#     unreachable from XCTest.
#   * "the probe is false IN THE REAL PRODUCTION PROCESS" — not even a
#     pure function can answer this, because a test process cannot
#     observe a production process.
#
# ⇒ If the probe were ever made constant-true, EVERY production feature
# gated on it would silently die (no ⌘⇧V, no menu-bar item, data parked
# in an isolated store) while the whole test suite stayed GREEN — the
# test host has the same shape as "constant true".
#
# This script closes that gap from the outside: it starts the REAL
# Release binary and checks that the production process REALLY registers
# the global hotkey.
#
# ## Judgement basis — and a CORRECTION
#
# ⚠️ ID-REVIEW-1044 concluded that "Carbon key combinations are
# SYSTEM-GLOBAL exclusive" (a probe in another process could ask who
# owns ⌘⇧V). MEASURED 2026-10-28: that conclusion does NOT hold across
# processes.
#
#   * same process: a second RegisterEventHotKey for the same
#     combination returns -9878 (eventHotKeyExistsErr)  ← 1044's datum
#   * ACROSS processes: two processes can hold the same combination at
#     the same time — a probe with a DIFFERENT signature registers
#     fine (noErr), and so does a probe with the PRODUCTION signature
#     (0x434C5050 / id 1).
#
# ⇒ an external process CANNOT ask Carbon "who owns ⌘⇧V".
#
# ⇒ The sentinel therefore judges by the app's OWN log line:
# `HotKeyManager` logs "Hotkey registered: …" ONLY when
# `RegisterEventHotKey` returned `noErr`. Seeing that line in the
# production app's log is a direct, positive proof that the production
# process really took the system-global shortcut.
#
# The negative control is the matching line the SAME code emits on the
# skip path: "Hotkey registration skipped in test host". That line means
# the probe said TRUE in a real production process ⇒ exactly the
# failure this sentinel exists to catch.
#
# ## What this script touches on the user's machine
#
# * It launches the real ClipMemory Release binary ⇒ that instance
#   registers the real global hotkey and shows the real menu-bar item
#   for the duration of the run, and writes ordinary app-lifecycle keys
#   into the production domain (`lastLaunchTime`, …) — normal app
#   behaviour, not test pollution.
# * It kills that instance at the end.
# * It removes the crash sentinel the killed instance left behind
#   (ID-REVIEW-1046: the sentinel means "the previous run did NOT exit
#   gracefully" ⇒ the SIGTERM **this script** sends is not a user
#   crash ⇒ leaving it would charge the user a fake crash on their next
#   launch). The sentinel is removed ONLY when this script started the
#   app — on the skip path an instance of the user's own is running and
#   its sentinel must stay untouched.
# * It SKIPS itself (exit 77) when a real ClipMemory instance is already
#   running — in that case the log line could not be attributed.
#
# ## CI
#
# Not wired into CI on purpose: a GitHub Actions macOS runner has no
# logged-in GUI session, so `NSStatusBar` / Carbon registration cannot
# be trusted there. Run this locally before a release.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cm-probe-smoke.XXXXXX")"
APP_BIN=""
APP_PID=""
LOG_PID=""
SKIP_BUILD=0
SENTINEL_PATH="$HOME/Library/Application Support/ClipMemory/.running-sentinel"
APP_LAUNCHED_BY_US=0

say()  { printf '%s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; }
# ⚠️ ID-REVIEW-1045 P2-1 (independent verifier): "skipped" must NOT be
# indistinguishable from "passed" by exit code — a wrapper that only checks
# `$?` would read "we did not verify anything" as "verified". Exit 77 is
# the conventional "skipped / not verified" code.
SKIP_EXIT=77
skip() {
    printf '⏭️  SKIPPED (not verified) — %s\n' "$*"
    printf '   exit code %s = skipped, NOT verified (a wrapper checking only $? must not read this as success)\n' "$SKIP_EXIT"
    exit "$SKIP_EXIT"
}

cleanup() {
    if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" 2>/dev/null; then
        kill "$LOG_PID" 2>/dev/null || true
    fi
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    # ⚠️ ID-REVIEW-1046 (2026-10-28): the crash sentinel means "the
    # previous run did NOT exit gracefully" (the app writes it at
    # launch and deletes it on a graceful exit; see
    # SafeModeService's header comment). This script kills the app with
    # SIGTERM ⇒ `applicationWillTerminate` never runs ⇒ the sentinel
    # survives ⇒ the user's NEXT launch would charge them one crash
    # that this script caused.
    #
    # ⇒ remove it — but ONLY when this script started the app. On the
    # skip path the user's own instance is running and its sentinel is
    # not ours to touch.
    if [[ "$APP_LAUNCHED_BY_US" == "1" && -f "$SENTINEL_PATH" ]]; then
        rm -f "$SENTINEL_PATH" 2>/dev/null || true
        printf '🧾 removed the crash sentinel our SIGTERM left behind (it was not a user crash)\n'
    fi
    # A failed run keeps its artefacts — a silent failure with no
    # evidence is the one outcome this script must not produce.
    if [[ "${KEEP_WORK_DIR:-0}" == "1" ]]; then
        printf '🧾 artefacts kept: %s\n' "$WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help)
            say "usage: $0 [--skip-build]"
            say "  Builds the Release app, starts it, and asserts that the"
            say "  PRODUCTION process really registers the global hotkey."
            exit 0
            ;;
        *) fail "unknown argument: $arg"; exit 2 ;;
    esac
done

# ── STEP 0: preconditions ────────────────────────────────────────────────
if pgrep -f "ClipMemory.app/Contents/MacOS/ClipMemory" >/dev/null 2>&1; then
    skip "a real ClipMemory instance is already running — the log line could not be attributed"
fi

# ── STEP 1: build the Release binary ─────────────────────────────────────
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    say "▸ building Release…"
    # ⚠️ Do NOT override CODE_SIGN_IDENTITY here.
    #
    # The project signs with "Apple Development" (project.yml), i.e. the
    # SAME signing identity that owns the production keychain item. An
    # ad-hoc build (CODE_SIGN_IDENTITY="-") is a DIFFERENT identity ⇒
    # macOS raises a keychain ACL prompt when the app touches the
    # production root key ⇒ the app BLOCKS on that prompt (measured
    # 2026-10-28: ~27 s of startup delay and a `SecurityAgent` process
    # left on the user's screen) ⇒ the script would report a false
    # failure AND leave a modal dialog behind.
    #
    # ⇒ the script must use the project's real signing identity.
    if ! (cd "$REPO_ROOT" && xcodebuild -scheme ClipMemory -configuration Release build \
            >"$WORK_DIR/build.log" 2>&1); then
        fail "Release build failed — see $WORK_DIR/build.log"
        say "This script needs the project's normal signing identity"
        say "(\"Apple Development\", DEVELOPMENT_TEAM in project.yml) — an ad-hoc"
        say "build would trip the keychain ACL prompt and block the app."
        tail -20 "$WORK_DIR/build.log" >&2
        exit 1
    fi
fi

APP_BIN="$(cd "$REPO_ROOT" && xcodebuild -scheme ClipMemory -configuration Release \
    -showBuildSettings 2>/dev/null | python3 -c '
import re, sys
settings = {}
for line in sys.stdin:
    m = re.match(r"\s+([A-Z0-9_]+) = (.*)$", line)
    if m:
        settings[m.group(1)] = m.group(2).strip()
target = settings.get("TARGET_BUILD_DIR", "")
wrapper = settings.get("WRAPPER_NAME", "")
if target and wrapper:
    print(target + "/" + wrapper + "/Contents/MacOS/" + settings.get("EXECUTABLE_NAME", "ClipMemory"))
')"
if [[ -z "$APP_BIN" || ! -x "$APP_BIN" ]]; then
    fail "Release binary not found (looked for: $APP_BIN) — build first or drop --skip-build"
    exit 1
fi
say "▸ Release binary: $APP_BIN"

# An ad-hoc binary trips the keychain ACL prompt on the production root
# key and blocks (measured 2026-10-28) ⇒ the measurement would be
# meaningless and the user's screen would be left with a modal dialog.
if codesign -dv "$APP_BIN" 2>&1 | grep -q "Signature=adhoc"; then
    fail "the Release binary is ad-hoc signed — it would trip the keychain ACL"
    fail "prompt and block on the user's screen. Rebuild with the project's"
    fail "signing identity (see project.yml CODE_SIGN_IDENTITY)."
    exit 1
fi

# ── STEP 2: subscribe to the app's own log ──────────────────────────────
# `--level info` is required: os_log's info level is NOT persisted, so a
# later `log show` may miss it, but a live `log stream` sees it.
/usr/bin/log stream --level info --style compact \
    --predicate 'subsystem == "com.clipmemory.app" AND category == "HotKeyManager"' \
    >"$WORK_DIR/hotkey.log" 2>/dev/null &
LOG_PID=$!
sleep 2
if ! kill -0 "$LOG_PID" 2>/dev/null; then
    fail "could not start 'log stream' — is this a logged-in GUI session?"
    exit 1
fi
say "▸ subscribed to the app's HotKeyManager log"

# ── STEP 3: start the real production app ────────────────────────────────
say "▸ starting the production app…"
"$APP_BIN" >"$WORK_DIR/app.log" 2>&1 &
APP_PID=$!
# From here on the app is OURS ⇒ the crash sentinel it writes is ours to
# clean up in cleanup() (see the ID-REVIEW-1046 note there).
APP_LAUNCHED_BY_US=1

# ── STEP 4: let the production app finish starting ───────────────────────
say "▸ waiting for the production app to finish starting…"
sleep 12
if ! kill -0 "$APP_PID" 2>/dev/null; then
    KEEP_WORK_DIR=1
    fail "the production app exited unexpectedly"
    tail -20 "$WORK_DIR/app.log" >&2
    exit 1
fi

# ── STEP 5: judge by the app's own registration log line ─────────────────
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
LOG_PID=""

# ⚠️ ID-REVIEW-1045 P1-1 (independent verifier, measured): checking for the
# success string ALONE lets a mutation that moves the success log line
# (while the probe stays constant-true) make this script PASS even though
# the production app skipped the registration — the success string is
# emitted by the code under test, so it is not bound to the Carbon outcome.
#
# ⇒ The judgement therefore requires ALL THREE:
#   ① the success line is present, AND
#   ② the skip line is ABSENT (the app did not take the skip path), AND
#   ③ the line came from the process THIS script started (PID match) — so a
#      stale line from another instance cannot satisfy it.
if grep -q "Hotkey registered:" "$WORK_DIR/hotkey.log" \
    && ! grep -q "Hotkey registration skipped" "$WORK_DIR/hotkey.log" \
    && grep -q "ClipMemory\[$APP_PID:" "$WORK_DIR/hotkey.log"; then
    say "▸ the production process logged a SUCCESSFUL hotkey registration"
    say "   (and did NOT log the skip line, and the line came from PID $APP_PID)"
    say "   ⇒ the 'is this a test process?' probe is FALSE in production  ✅"
elif grep -q "Hotkey registration skipped" "$WORK_DIR/hotkey.log"; then
    KEEP_WORK_DIR=1
    fail "the production process SKIPPED the global hotkey registration"
    say ""
    say "This is the ID-REVIEW-1045 failure mode: the 'is this a test"
    say "process?' probe reported TRUE in a real production process, so"
    say "every gate conditioned on it (hotkey, menu-bar item, storage"
    say "domain, …) silently disabled itself. The XCTest suite cannot"
    say "see this: in a test host the probe is true by construction."
    say ""
    say "Check: TestIsolation.isRunningTests / TestIsolation.isTestProcess"
    say "and the gates in HotKeyManager.register() /"
    say "AppDelegate.setupStatusItem()."
    exit 1
else
    KEEP_WORK_DIR=1
    fail "the production app logged NEITHER a successful registration NOR the skip line"
    fail "⇒ the hotkey path was not reached at all (see the log below)"
    cat "$WORK_DIR/hotkey.log" >&2
    exit 1
fi

# ── STEP 6: stop the app, leave nothing behind ───────────────────────────
cleanup
APP_PID=""
say "▸ production app stopped"

say ""
say "✅ production-probe-smoke PASSED"
say "   The production process really registers the global hotkey,"
say "   i.e. the 'is this a test process?' probe is FALSE in production."
say ""
say "   (The specific key combination is NOT asserted: os_log redacts the"
say "   interpolated value as <private>, and the user's hotkey is"
say "   configurable — so the captured line cannot prove which"
say "   combination was taken. See ID-REVIEW-1045 P2-2.)"
exit 0
