#!/usr/bin/env python3
"""Offline unit tests for Scripts/sync_readme.py (no network, no API key)."""

import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

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


class TestLlmConfig(unittest.TestCase):
    def tearDown(self):
        for var in ("README_SYNC_BASE_URL", "README_SYNC_MODEL", "README_SYNC_API_KEY"):
            os.environ.pop(var, None)

    def test_defaults_to_deepseek(self):
        for var in ("README_SYNC_BASE_URL", "README_SYNC_MODEL", "README_SYNC_API_KEY"):
            os.environ.pop(var, None)
        base, model, _ = sync_readme.llm_config()
        self.assertIn("deepseek", base)
        self.assertEqual(model, "deepseek-chat")

    def test_env_overrides(self):
        os.environ["README_SYNC_BASE_URL"] = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        os.environ["README_SYNC_MODEL"] = "qwen-plus"
        os.environ["README_SYNC_API_KEY"] = "test-key"
        base, model, key = sync_readme.llm_config()
        self.assertIn("dashscope", base)
        self.assertEqual(model, "qwen-plus")
        self.assertEqual(key, "test-key")


class TestTranslateErrorContext(unittest.TestCase):
    """REL-12 (2026-07-24 review): HTTP/JSON failures must name the target
    language instead of surfacing as a bare exception."""

    def test_network_error_names_language(self):
        with mock.patch("urllib.request.urlopen", side_effect=OSError("boom")):
            with self.assertRaises(RuntimeError) as ctx:
                sync_readme.translate("src", "ja", "style", "https://x", "m", "k")
        self.assertIn("ja", str(ctx.exception))
        self.assertIn("boom", str(ctx.exception))

    def test_malformed_payload_names_language(self):
        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return b'{"unexpected": true}'

        with mock.patch("urllib.request.urlopen", return_value=FakeResponse()):
            with self.assertRaises(RuntimeError) as ctx:
                sync_readme.translate("src", "ko", "style", "https://x", "m", "k")
        self.assertIn("ko", str(ctx.exception))


class TestAtomicWrite(unittest.TestCase):
    """REL-12 (2026-07-24 review): a failure during the in-memory build
    phase must leave every README on disk untouched."""

    GOOD = "# ClipMemory v2.5.0\n\n## Changelog\n\n### v2.5.0 (2026-07-20) — old\n\n- a\n"
    BAD = "# ClipMemory no version\n\n## Changelog\n\n### v2.5.0 (2026-07-20) — old\n\n- a\n"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self._saved = (sync_readme.ROOT, sync_readme.FILES,
                       sync_readme.translate, sys.argv[:])
        sync_readme.ROOT = self.tmp
        sync_readme.translate = lambda *a: "### v2.5.1 (2026-07-25) — EN\n\n- x"
        changelog = os.path.join(self.tmp, "changelog.md")
        with open(changelog, "w", encoding="utf-8") as handle:
            handle.write("### v2.5.1 (2026-07-25) — new\n\n- x\n")
        sys.argv = ["sync_readme.py", "--version", "2.5.1", "--changelog", changelog]
        os.environ["README_SYNC_API_KEY"] = "test-key"

    def tearDown(self):
        sync_readme.ROOT, sync_readme.FILES, sync_readme.translate, sys.argv = self._saved
        os.environ.pop("README_SYNC_API_KEY", None)
        shutil.rmtree(self.tmp)

    def _write(self, name, content):
        with open(os.path.join(self.tmp, name), "w", encoding="utf-8") as handle:
            handle.write(content)

    def _read(self, name):
        with open(os.path.join(self.tmp, name), encoding="utf-8") as handle:
            return handle.read()

    def test_build_failure_writes_nothing(self):
        self._write("good.md", self.GOOD)
        self._write("bad.md", self.BAD)  # bump_title raises: no version title
        sync_readme.FILES = {"zh-Hans": ["good.md"], "en": ["bad.md"]}
        with self.assertRaises(ValueError):
            sync_readme.main()
        self.assertEqual(self._read("good.md"), self.GOOD)
        self.assertEqual(self._read("bad.md"), self.BAD)

    def test_success_writes_all_files(self):
        self._write("a.md", self.GOOD)
        self._write("b.md", self.GOOD)
        sync_readme.FILES = {"zh-Hans": ["a.md"], "en": ["b.md"]}
        sync_readme.main()
        for name in ("a.md", "b.md"):
            self.assertIn("# ClipMemory v2.5.1", self._read(name))
            self.assertIn("### v2.5.1", self._read(name))


if __name__ == "__main__":
    unittest.main()
