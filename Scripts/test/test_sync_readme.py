#!/usr/bin/env python3
"""Offline unit tests for Scripts/sync_readme.py (no network, no API key)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import sync_readme  # noqa: E402


class TestBumpTitle(unittest.TestCase):
    def test_bumps_version_in_title(self):
        text = "# 剪忆 ClipMemory v2.4.2\n\nbody\n"
        self.assertTrue(sync_readme.bump_title(text, "2.5.0").startswith("# 剪忆 ClipMemory v2.5.0"))

    def test_only_first_title_bumped(self):
        text = "# ClipMemory v2.4.2\n\n## v2.4.2 changelog\n"
        result = sync_readme.bump_title(text, "2.5.0")
        self.assertEqual(result.count("v2.5.0"), 1)

    def test_missing_title_raises(self):
        with self.assertRaises(ValueError):
            sync_readme.bump_title("# No version here\n", "2.5.0")


class TestInsertSection(unittest.TestCase):
    SAMPLE = "# T v2.4.2\n\n## 更新日志\n\n### v2.4.2 (2026-07-18) — X\n\n- a\n\n### v2.4.1 (2026-07-18) — Y\n\n- b\n"

    def test_inserts_before_newest_section(self):
        result = sync_readme.insert_section(self.SAMPLE, "### v2.5.0 (2026-07-18) — Z\n\n- c")
        self.assertLess(result.index("### v2.5.0"), result.index("### v2.4.2"))
        self.assertLess(result.index("### v2.4.2"), result.index("### v2.4.1"))

    def test_previous_section_returns_newest_only(self):
        prev = sync_readme.previous_section(self.SAMPLE)
        self.assertIn("### v2.4.2", prev)
        self.assertNotIn("### v2.4.1", prev)

    def test_no_section_raises(self):
        with self.assertRaises(ValueError):
            sync_readme.insert_section("# nothing\n", "### v2.5.0 — Z")


class TestGlossary(unittest.TestCase):
    def test_all_languages_covered_for_every_term(self):
        langs = {"en", "zh-Hant", "ja", "ko", "es", "pt"}
        for zh, targets in sync_readme.GLOSSARY.items():
            self.assertEqual(set(targets.keys()), langs, f"glossary term {zh} incomplete")

    def test_glossary_block_mentions_term(self):
        block = sync_readme.glossary_block("en")
        self.assertIn("回收站 → Recycle Bin", block)


if __name__ == "__main__":
    unittest.main()
