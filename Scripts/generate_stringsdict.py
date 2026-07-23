#!/usr/bin/env python3
"""F-7 (2026-07-23 audit): generate .stringsdict files for pluralization.

Foundation's .stringsdict format lets us provide singular vs plural
forms per locale (CLDR plural categories: zero, one, two, few, many,
other). Without .stringsdict, `L10n.string("batch.selected", 1)`
returns "1 selected" in en but "1 items" in en too — i.e. English
gets the same string regardless of count. With .stringsdict, count=1
picks the "one" form ("1 item selected") and count>1 picks "other"
("5 items selected").

Scope (3 high-value keys):
- batch.selected: list batch-mode selection count
- quickbar.recent: QuickBar "Recent N items" header
- trash.emptyConfirm.message: trash permanent-delete confirmation

For ja/ko/zh-Hans/zh-Hant only "other" form is needed (those langs
have no grammatical plural distinction), but the .stringsdict
structure is still required for the format key to resolve.
"""

import sys
from pathlib import Path

# (key, en_one, en_other) — values are the resolved format strings
# (Foundation substitutes %d / %@ at runtime). The singular form is
# used for count=1; the other form is used otherwise.
KEYS = [
    (
        "batch.selected",
        "%d selected",
        "%d selected",  # en: "1 selected" / "5 selected" — no change in word
    ),
    (
        "quickbar.recent",
        "%d item",
        "%d items",
    ),
    (
        "trash.emptyConfirm.message",
        "%d item will be permanently deleted. This action cannot be undone.",
        "%d items will be permanently deleted. This action cannot be undone.",
    ),
    # F-7 extend (2026-07-23 audit round 2): 3 more simple %d-only
    # keys. Multi-arg keys (alert.trim.message with 2x %d,
    # tagPicker/sidebar.deleteTag.message with %@ + %d) need
    # positional-arg format keys and are deferred to a follow-up.
    (
        "alert.clear.message",
        "Are you sure you want to clear %d item?\nPinned items will not be deleted.",
        "Are you sure you want to clear %d items?\nPinned items will not be deleted.",
    ),
    (
        "settings.max.items.count",
        "%d item",
        "%d items",
    ),
    (
        "clear.conditional.confirm",
        "%d item will be deleted (pinned kept, moved to the Trash)",
        "%d items will be deleted (pinned kept, moved to the Trash)",
    ),
]

# Per-locale plural category translations of the English singular/other
# forms. For locales with no grammatical plural (ja/ko/zh) only "other"
# is needed; for es/pt we add a 2-form split (one/other) — CLDR "many"
# is omitted because the only "many" rule (10^6+) doesn't apply to
# clipboard item counts users will realistically see.
LOCALES = {
    "en": {
        "one": lambda one, other: one,
        "other": lambda one, other: other,
    },
    "zh-Hans": {
        "other": lambda one, other: other,
    },
    "zh-Hant": {
        "other": lambda one, other: other,
    },
    "ja": {
        "other": lambda one, other: other,
    },
    "ko": {
        "other": lambda one, other: other,
    },
    # Spanish: 1 = un/una elemento, >1 = elementos
    "es": {
        "one": lambda one, other: one
            .replace("%d item", "%d elemento")
            .replace("item will", "elemento será")
            .replace("items will", "elementos serán")
            .replace(" item ", " elemento "),
        "other": lambda one, other: other
            .replace("items", "elementos")
            .replace("item will", "elementos serán"),
    },
    # Portuguese: 1 = item, >1 = itens
    "pt": {
        "one": lambda one, other: one
            .replace("item will", "item será")
            .replace("%d item", "%d item"),
        "other": lambda one, other: other
            .replace("items will", "itens serão")
            .replace("items", "itens"),
    },
}


def generate_for_locale(locale: str, keys: list) -> str:
    """Generate the .stringsdict XML body for one locale."""
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        '<dict>',
    ]
    for key, one, other in keys:
        translations = LOCALES[locale]
        lines.append(f"\t<key>{key}</key>")
        lines.append("\t<dict>")
        lines.append("\t\t<key>NSStringLocalizedFormatKey</key>")
        # The format key tells Foundation to look up the "count"
        # plural rule. The "%#@count@" marker MUST appear in the
        # Localizable.strings entry for the same key.
        lines.append('\t\t<string>%#@count@</string>')
        lines.append("\t\t<key>count</key>")
        lines.append("\t\t<dict>")
        lines.append("\t\t\t<key>NSStringFormatSpecTypeKey</key>")
        lines.append("\t\t\t<string>NSStringPluralRuleType</string>")
        for cat, fn in translations.items():
            value = fn(one, other)
            lines.append(f"\t\t\t<key>{cat}</key>")
            lines.append(f"\t\t\t<string>{value}</string>")
        lines.append("\t\t</dict>")
        lines.append("\t</dict>")
    lines.append('</dict>')
    lines.append('</plist>')
    # Trailing newline
    lines.append("")
    return "\n".join(lines)


def main():
    repo_root = Path(__file__).parent.parent
    for locale in LOCALES:
        out_path = repo_root / "ClipMemory" / f"{locale}.lproj" / "Localizable.stringsdict"
        content = generate_for_locale(locale, KEYS)
        out_path.write_text(content, encoding="utf-8")
        print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
