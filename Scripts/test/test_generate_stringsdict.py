#!/usr/bin/env python3
"""REL-5 regression tests for Scripts/generate_stringsdict.py.

Guards against the class of bug where order-dependent chained
str.replace() calls produced broken mixed-language plural strings in
es.lproj/pt.lproj (e.g. "%d elemento will be permanently deleted",
"Pinned elementos serán not be deleted").

Checks:
  1. Generated XML parses as a valid plist for every locale.
  2. es/pt values contain no leftover English fragments.
  3. es/pt values still carry the %d placeholder.
  4. On-disk stringsdict files are in sync with the generator output
     (catches "fixed the generator but forgot to regenerate").

Run: python3 Scripts/test/test_generate_stringsdict.py
Exit 0 = PASS, non-zero = FAIL
"""

import plistlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from generate_stringsdict import KEYS, LOCALE_CATEGORIES, generate_for_locale  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# English fragments that must never survive into an es/pt translation.
# Kept lowercase-insensitive; covers the REL-5 broken output shapes.
ENGLISH_FRAGMENTS = [
    "will be",
    "will not",
    "are you sure",
    "pinned items",
    "cannot be undone",
    "moved to the trash",
    "selected",
]

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)
        print(f"FAIL: {msg}")


def plural_values(plist_dict):
    for key, entry in plist_dict.items():
        count = entry["count"]
        for cat, value in count.items():
            if cat == "NSStringFormatSpecTypeKey":
                continue
            yield key, cat, value


for locale in LOCALE_CATEGORIES:
    xml = generate_for_locale(locale, KEYS)

    # 1. Valid plist XML.
    try:
        plist = plistlib.loads(xml.encode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        check(False, f"{locale}: generated stringsdict is not a valid plist: {exc}")
        continue

    check(set(plist.keys()) == {k for k, _, _ in KEYS},
          f"{locale}: generated keys {sorted(plist.keys())} != KEYS")

    # 2./3. es/pt: no English leftovers, %d preserved.
    if locale in ("es", "pt"):
        for key, cat, value in plural_values(plist):
            lower = value.lower()
            for frag in ENGLISH_FRAGMENTS:
                check(frag not in lower,
                      f"{locale}/{key}/{cat}: English fragment {frag!r} in {value!r}")
            check("%d" in value,
                  f"{locale}/{key}/{cat}: missing %d placeholder in {value!r}")

    # 4. On-disk file matches generator output.
    on_disk = REPO_ROOT / "ClipMemory" / f"{locale}.lproj" / "Localizable.stringsdict"
    check(on_disk.exists(), f"{locale}: {on_disk} missing")
    if on_disk.exists():
        check(on_disk.read_text(encoding="utf-8") == xml,
              f"{locale}: on-disk stringsdict out of sync — re-run "
              "python3 Scripts/generate_stringsdict.py")

if failures:
    print(f"\n{len(failures)} check(s) FAILED")
    sys.exit(1)
print("PASS: stringsdict generation valid, es/pt free of English fragments, on-disk files in sync")
sys.exit(0)
