#!/usr/bin/env python3
"""test_sync_readme.py — regression tests for sync_readme.py dedupe + helpers.

Run: python3 Scripts/test_sync_readme.py

Exits 0 on pass, 1 on any failure. Stdlib only — no pytest/unittest dependency.

The 2026-07-23 ship review found sync_readme.py left duplicate `### vX.Y.Z`
blocks in 6 lang READMEs after every release (v2.5.10 + v2.5.11 both
confirmed). These tests pin the dedupe contract so the regression cannot
silently reappear.
"""

import os
import sys

# Allow running from project root, Scripts/, or Scripts/test/
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))
from sync_readme import (  # noqa: E402
    remove_existing_section,
    section_version,
    insert_section,
    bump_title,
    first_section_offset,
)


FAILS = 0


def check(label, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ✓ {label}")
    else:
        print(f"  ✗ {label}{(': ' + detail) if detail else ''}")
        FAILS += 1


def section(version, body_lines=None):
    body_lines = body_lines or ["- fix one", "- fix two"]
    return f"### v{version} (2026-07-23) — test\n\n" + "\n".join(body_lines)


def test_remove_existing_section_strips_single_match():
    print("\n[remove_existing_section] strips single match")
    text = (
        "### v2.5.10 (2026-07-22) — prior\n\n- a\n- b\n\n"
        "### v2.5.11 (2026-07-23) — target\n\n- c\n\n"
        "### v2.5.9 (2026-07-21) — older\n\n- d\n"
    )
    new, count = remove_existing_section(text, "2.5.11")
    check("returns count=1", count == 1, f"got {count}")
    check("v2.5.11 block removed", "v2.5.11" not in new)
    check("v2.5.10 preserved", "v2.5.10" in new)
    check("v2.5.9 preserved", "v2.5.9" in new)


def test_remove_existing_section_strips_multiple_matches():
    print("\n[remove_existing_section] strips multiple matches (the dedupe bug)")
    text = (
        "### v2.5.11 (2026-07-23) — first\n\n- a\n\n"
        "### v2.5.11\n\n- duplicate\n\n"
        "### v2.5.10\n\n- prior\n"
    )
    new, count = remove_existing_section(text, "2.5.11")
    check("returns count=2", count == 2, f"got {count}")
    check("no v2.5.11 block remains", "### v2.5.11" not in new)
    check("v2.5.10 preserved", "v2.5.10" in new)


def test_remove_existing_section_returns_zero_for_missing_version():
    print("\n[remove_existing_section] zero-match case")
    text = "### v2.5.10\n\n- a\n"
    new, count = remove_existing_section(text, "9.9.9")
    check("returns count=0", count == 0)
    check("text unchanged", new == text)


def test_section_version_extracts_vxyz():
    print("\n[section_version] extracts version")
    check("plain heading", section_version("### v2.5.11") == "2.5.11")
    check("with date + em-dash suffix",
          section_version("### v2.5.11 (2026-07-23) — ContentView split") == "2.5.11")
    check("with leading whitespace", section_version("   ### v2.5.10 — x") == "2.5.10")
    try:
        section_version("## not a changelog section")
        check("rejects non-vX.Y.Z heading", False, "should have raised")
    except ValueError:
        check("rejects non-vX.Y.Z heading", True)


def test_insert_section_rejects_existing_version():
    print("\n[insert_section] precondition assertion")
    text_with_dup = (
        "## 📋 Changelog\n\n"
        "### v2.5.10 (2026-07-22) — prior\n\n- a\n\n"
        "### v2.5.11 (2026-07-23) — already there\n\n- b\n"
    )
    new_section = section("2.5.11")
    try:
        insert_section(text_with_dup, new_section)
        check("raises ValueError when version already present", False, "did not raise")
    except ValueError as exc:
        check("raises ValueError when version already present",
              "remove_existing_section" in str(exc))


def test_insert_section_inserts_when_version_absent():
    print("\n[insert_section] happy path")
    text = "## 📋 Changelog\n\n### v2.5.10 (2026-07-22) — prior\n\n- a\n"
    new_section = section("2.5.11", ["- fix A"])
    out = insert_section(text, new_section)
    check("new version present", "### v2.5.11" in out)
    check("prior version preserved", "### v2.5.10" in out)
    check("inserted before prior",
          out.index("### v2.5.11") < out.index("### v2.5.10"))


def test_bump_title_replaces_version():
    print("\n[bump_title] replaces version")
    text = "# 剪忆 ClipMemory v2.5.10\n\nbody\n"
    out = bump_title(text, "2.5.11")
    check("title version updated", "# 剪忆 ClipMemory v2.5.11" in out)
    check("body unchanged", "body" in out)


def test_end_to_end_dedupe_no_duplicate_after_repeat():
    print("\n[end-to-end] dedupe across re-run (the ship regression)")
    initial = (
        "# ClipMemory v2.5.11\n\n"
        "## 📋 Changelog\n\n"
        "### v2.5.10 (2026-07-22) — prior\n\n- prior\n"
    )
    new_section = section("2.5.11", ["- new fix A", "- new fix B"])

    after_first = insert_section(initial, new_section)
    check("first sync inserts v2.5.11", "### v2.5.11" in after_first)
    check("first sync: exactly 1 v2.5.11 block",
          after_first.count("### v2.5.11") == 1)

    after_second_remove, removed_count = remove_existing_section(after_first, "2.5.11")
    check("caller's remove_existing_section strips the existing block",
          removed_count == 1 and "### v2.5.11" not in after_second_remove)
    after_second_insert = insert_section(after_second_remove, new_section)
    check("second sync: still exactly 1 v2.5.11 block (no duplicate)",
          after_second_insert.count("### v2.5.11") == 1)

    try:
        insert_section(after_first, new_section)
        check("insert_section raised on duplicate", False, "bug regressed — no exception")
    except ValueError:
        check("insert_section raised on duplicate (silent duplicate bug re-blocked)", True)


def test_first_section_offset_finds_changelog_start():
    print("\n[first_section_offset] finds changelog start")
    text = "intro\n\n## 📋 Changelog\n\n### v2.5.11\n\n- a\n"
    offset = first_section_offset(text)
    check("points at ### v2.5.11 line", text[offset:].startswith("### v2.5.11"))


def main():
    test_remove_existing_section_strips_single_match()
    test_remove_existing_section_strips_multiple_matches()
    test_remove_existing_section_returns_zero_for_missing_version()
    test_section_version_extracts_vxyz()
    test_insert_section_rejects_existing_version()
    test_insert_section_inserts_when_version_absent()
    test_bump_title_replaces_version()
    test_end_to_end_dedupe_no_duplicate_after_repeat()
    test_first_section_offset_finds_changelog_start()

    print()
    if FAILS:
        print(f"❌ {FAILS} test(s) FAILED")
        sys.exit(1)
    print("✅ all tests passed")


if __name__ == "__main__":
    main()