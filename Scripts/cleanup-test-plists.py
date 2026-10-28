#!/usr/bin/env python3
"""ID-REVIEW-1040: clean up the `UserDefaults` plist files the test suite
left behind on this machine.

The deletion rule is derived from the SOURCE, not from a guess: every suite
name the test tree creates is extracted from the code, and a leftover file
is deleted only when its name starts with one of those literals. A file that
does not match is reported and KEPT.

The production domain (`com.clipmemory.app`) is never touched.

usage:
    python3 Scripts/cleanup-test-plists.py                      # dry run (default)
    python3 Scripts/cleanup-test-plists.py --also-suspects       # dry run, suspects included
    python3 Scripts/cleanup-test-plists.py --apply               # actually delete
    python3 Scripts/cleanup-test-plists.py --also-suspects --apply
"""
import glob
import io
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(REPO, "Tests", "ClipMemoryTests")
PREFS = os.path.expanduser("~/Library/Preferences")

PRODUCTION = "com.clipmemory.app"

# Names the source creates, and the extra names the shared infrastructure
# owns. Everything here is a TEST artifact.
EXTRA_PREFIXES = [
    "test-",                       # makeTestDefaults()
    "LanguageManager-test-isolation",
    "ClipboardStore-XCTest-isolation",
    "HotKeyManager-XCTest-isolation",
    "BackupService-XCTest-isolation",
    "TestIsolation-XCTest-isolation",
    "SafeModeService-XCTest-isolation",
    "AppStorageDefaults-XCTest-isolation",
    # ID-REVIEW-1048 (2026-10-28): StartupHealth's own isolation suite.
    "StartupHealth-XCTest-isolation",
]


def suite_prefixes() -> list:
    """Every suite-name prefix the test source creates."""
    prefixes = set(EXTRA_PREFIXES)
    literal = re.compile(r'"((?:[^"\\]|\\.)*)"')
    for dirpath, _dirnames, filenames in os.walk(TESTS):
        for fn in filenames:
            if not fn.endswith(".swift"):
                continue
            src = io.open(os.path.join(dirpath, fn), encoding="utf-8").read()
            for m in literal.finditer(src):
                text = m.group(1)
                if "suiteName" not in src[max(0, m.start() - 80):m.start()]:
                    continue
                # keep the part before the first interpolation
                head = text.split("\\(")[0]
                if not head:
                    continue
                # a prefix must be long enough to be specific
                if len(head) < 3:
                    continue
                prefixes.add(head)
    return sorted(prefixes)


def main() -> int:
    apply = "--apply" in sys.argv
    also_suspects = "--also-suspects" in sys.argv
    prefixes = suite_prefixes()
    files = sorted(glob.glob(os.path.join(PREFS, "*.plist")))

    doomed = []
    kept = []
    suspects = []
    uuid_re = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    for path in files:
        name = os.path.basename(path)[:-len(".plist")]
        if name == PRODUCTION:
            kept.append((name, "production domain — never touched"))
            continue
        hit = next((p for p in prefixes if name.startswith(p)), None)
        if hit:
            doomed.append((name, path, hit))
            continue
        # Not matched by any known prefix ⇒ KEPT. But a name that carries a
        # UUID and no reverse-DNS dot is almost certainly a test suite whose
        # literal no longer exists in the source — report it separately
        # instead of silently mixing it in with the real applications.
        if uuid_re.search(name) and "." not in name:
            if also_suspects:
                doomed.append((name, path, "<suspect: UUID + no dot>"))
            else:
                suspects.append(name)
        else:
            kept.append((name, "no matching test-suite prefix"))

    blocks = 0
    apparent = 0
    for _name, path, _hit in doomed:
        try:
            st = os.lstat(path)
        except OSError:
            continue
        blocks += st.st_blocks * 512
        apparent += st.st_size

    print(f"test-suite prefixes recognised : {len(prefixes)}")
    print(f"plist files in ~/Library/Preferences: {len(files)}")
    # MiB (1024**2) so the numbers line up with `du -sh` on the same folder.
    print(f"would DELETE : {len(doomed)}  ({blocks / 1024 ** 2:.1f} MiB of blocks, "
          f"{apparent / 1024 ** 2:.1f} MiB of bytes)")
    print(f"would KEEP   : {len(kept)}")
    print(f"SUSPECTS (kept, but look like test suites whose literal is gone): {len(suspects)}")
    for name in suspects[:15]:
        print(f"  ? {name}")
    if len(suspects) > 15:
        print(f"  … and {len(suspects) - 15} more")

    by_prefix = {}
    for name, _path, hit in doomed:
        by_prefix.setdefault(hit, []).append(name)
    print("\n-- deleted, by prefix --")
    for p in sorted(by_prefix, key=lambda k: -len(by_prefix[k]))[:30]:
        print(f"{len(by_prefix[p]):>8}  {p}")

    print("\n-- KEPT (first 40) --")
    for name, why in kept[:40]:
        print(f"  {name}   [{why}]")
    if len(kept) > 40:
        print(f"  … and {len(kept) - 40} more")

    if not apply:
        print("\nDRY RUN — nothing was deleted. Re-run with --apply to delete.")
        if suspects and not also_suspects:
            print("Add --also-suspects to include the suspects (they look like test "
                  "suites whose name literal no longer exists in the source).")
        return 0

    deleted = 0
    failed = []
    for name, path, _hit in doomed:
        try:
            os.remove(path)
            deleted += 1
        except OSError as exc:
            failed.append(f"{name}: {exc}")
    print(f"\nDELETED {deleted} files.")
    if failed:
        print(f"FAILED {len(failed)}:")
        for f in failed[:20]:
            print("  " + f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
