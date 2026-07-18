#!/usr/bin/env python3
"""sync_readme.py — Propagate a release changelog entry to all 8 READMEs.

Usage:
    python3 Scripts/sync_readme.py --version 2.5.0 --changelog v250-zh.md [--dry-run]

What it does:
  1. Bumps the `# ... vX.Y.Z` title in all 8 READMEs.
  2. Inserts the zh-Hans section (your input file, including its `### v...`
     heading) into README.md and docs/lang/README_ZH-HANS.md.
  3. Translates the section into the other 6 languages with DeepSeek
     (env `DEEPSEEK_API_KEY`), using a fixed glossary plus the target file's
     previous changelog section as the style reference, and inserts it at the
     top of each file's changelog.
  4. With --dry-run, prints the generated sections without writing files.

Only stdlib is used. Never hardcode API keys in this file.
"""

import argparse
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = {
    "zh-Hans": ["README.md", "docs/lang/README_ZH-HANS.md"],
    "en": ["docs/lang/README_EN.md"],
    "zh-Hant": ["docs/lang/README_ZH-HANT.md"],
    "ja": ["docs/lang/README_JA.md"],
    "ko": ["docs/lang/README_KO.md"],
    "es": ["docs/lang/README_ES.md"],
    "pt": ["docs/lang/README_PT.md"],
}

LANG_NAMES = {
    "en": "English",
    "zh-Hant": "繁體中文（台灣用語）",
    "ja": "日本語",
    "ko": "한국어",
    "es": "Español",
    "pt": "Português",
}

# Fixed terminology so translations stay consistent release over release.
GLOSSARY = {
    "剪忆": {"en": "ClipMemory", "zh-Hant": "剪憶", "ja": "ClipMemory", "ko": "ClipMemory", "es": "ClipMemory", "pt": "ClipMemory"},
    "回收站": {"en": "Recycle Bin", "zh-Hant": "資源回收筒", "ja": "ごみ箱", "ko": "휴지통", "es": "Papelera", "pt": "Lixeira"},
    "自动更新": {"en": "auto-update", "zh-Hant": "自動更新", "ja": "自動アップデート", "ko": "자동 업데이트", "es": "actualización automática", "pt": "atualização automática"},
    "更新源": {"en": "update feed", "zh-Hant": "更新源", "ja": "更新フィード", "ko": "업데이트 피드", "es": "feed de actualización", "pt": "feed de atualização"},
    "备份": {"en": "backup", "zh-Hant": "備份", "ja": "バックアップ", "ko": "백업", "es": "copia de seguridad", "pt": "cópia de segurança"},
    "标签": {"en": "tag", "zh-Hant": "標籤", "ja": "タグ", "ko": "태그", "es": "etiqueta", "pt": "etiqueta"},
}

TITLE_RE = re.compile(r"^(# .+? v)\d+\.\d+\.\d+", re.MULTILINE)
SECTION_RE = re.compile(r"^### v\d+\.\d+\.\d+", re.MULTILINE)


def bump_title(text, version):
    new, count = TITLE_RE.subn(r"\g<1>" + version, text, count=1)
    if count == 0:
        raise ValueError("title version pattern not found")
    return new


def first_section_offset(text):
    """Byte offset where the first `### vX.Y.Z` changelog section starts."""
    match = SECTION_RE.search(text)
    if not match:
        raise ValueError("no changelog section (### vX.Y.Z) found")
    return match.start()


def previous_section(text):
    """The text of the newest changelog section (for style reference)."""
    start = first_section_offset(text)
    nxt = SECTION_RE.search(text, start + 1)
    return text[start:nxt.start() if nxt else len(text)].strip()


def insert_section(text, section):
    offset = first_section_offset(text)
    return text[:offset] + section.strip() + "\n\n" + text[offset:]


def glossary_block(lang):
    return "\n".join(f"- {zh} → {targets[lang]}" for zh, targets in GLOSSARY.items())


def llm_config():
    """Resolve the OpenAI-compatible endpoint/model/key from the environment.

    Defaults to DeepSeek; override for any compatible provider, e.g. Alibaba
    DashScope: README_SYNC_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions
    README_SYNC_MODEL=qwen-plus README_SYNC_API_KEY=$BAILIAN_KEY
    """
    base_url = os.environ.get("README_SYNC_BASE_URL", "https://api.deepseek.com/chat/completions")
    model = os.environ.get("README_SYNC_MODEL", "deepseek-chat")
    key = os.environ.get("README_SYNC_API_KEY") or os.environ.get("DEEPSEEK_API_KEY", "")
    return base_url, model, key


def translate(source, lang, style_ref, base_url, model, deepseek_key):
    prompt = f"""你是专业软件本地化译者。把下面的 Markdown 更新日志从简体中文翻译成{LANG_NAMES[lang]}。

要求：
1. 保持 Markdown 结构（###、-、**、代码标记、emoji）不变。
2. 版本号、日期、URL、文件名、命令、key 名保持原样。
3. 术语严格按词汇表，不要自造译法。
4. 语言风格参照该语言上一版更新日志（见【风格参照】）。

【词汇表】
{glossary_block(lang)}

【风格参照】
{style_ref}

【待翻译】
{source}

只输出翻译后的 Markdown，不要输出任何解释。"""

    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.2,
    }).encode("utf-8")
    request = urllib.request.Request(
        base_url,
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {deepseek_key}"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"].strip()


def main():
    parser = argparse.ArgumentParser(description="Sync release changelog to all 8 READMEs.")
    parser.add_argument("--version", required=True, help="new version, e.g. 2.5.0")
    parser.add_argument("--changelog", required=True, help="zh-Hans changelog markdown file (incl. ### heading)")
    parser.add_argument("--dry-run", action="store_true", help="print generated sections, do not write files")
    args = parser.parse_args()

    with open(args.changelog, encoding="utf-8") as handle:
        source = handle.read().strip()
    if not SECTION_RE.match(source):
        sys.exit("changelog file must start with a '### vX.Y.Z' heading")

    base_url, model, deepseek_key = llm_config()
    if not deepseek_key and not args.dry_run:
        sys.exit("README_SYNC_API_KEY (or DEEPSEEK_API_KEY) not set — see llm_config() for provider env vars")

    outputs = {"zh-Hans": source}
    for lang in FILES:
        if lang == "zh-Hans":
            continue
        path = os.path.join(ROOT, FILES[lang][0])
        with open(path, encoding="utf-8") as handle:
            style_ref = previous_section(handle.read())
        if args.dry_run and not deepseek_key:
            outputs[lang] = f"[dry-run 无 API key，跳过翻译] 词汇表 {len(GLOSSARY)} 条，风格参照 {len(style_ref)} 字符"
        else:
            print(f"翻译 {lang} ...", file=sys.stderr)
            outputs[lang] = translate(source, lang, style_ref, base_url, model, deepseek_key)

    if args.dry_run:
        for lang, section in outputs.items():
            print(f"\n===== {lang} =====\n{section}")
        return

    for lang, paths in FILES.items():
        for relative in paths:
            path = os.path.join(ROOT, relative)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            text = bump_title(text, args.version)
            text = insert_section(text, outputs[lang])
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            print(f"updated {relative}", file=sys.stderr)

    print("\nDone. 请用 `git diff --stat` 核对后再提交。", file=sys.stderr)


if __name__ == "__main__":
    main()
