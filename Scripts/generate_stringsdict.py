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

# Per-locale plural categories. Locales with no grammatical plural
# (ja/ko/zh) only need "other"; en/es/pt get a 2-form split (one/other)
# — CLDR "many" is omitted because the only "many" rule (10^6+) doesn't
# apply to clipboard item counts users will realistically see.
LOCALE_CATEGORIES = {
    "en": ["one", "other"],
    "zh-Hans": ["other"],
    "zh-Hant": ["other"],
    "ja": ["other"],
    "ko": ["other"],
    "es": ["one", "other"],
    "pt": ["one", "other"],
}

# Explicit per-key translations for es/pt.
#
# REL-5 (2026-07-24): these used to be produced by chained
# str.replace() calls on the English source (e.g. "%d item" ->
# "%d elemento" ran BEFORE "item will" -> "elemento será", so the
# longer pattern never matched). The order-dependent chain shipped
# broken mixed-language strings in es.lproj ("...elemento will be
# permanently deleted", "Pinned elementos serán not be deleted").
# An explicit table has no ordering pitfalls and is reviewable by a
# native speaker without reading replace logic.
TRANSLATIONS = {
    "es": {
        "batch.selected": {
            "one": "%d seleccionado",
            "other": "%d seleccionados",
        },
        "quickbar.recent": {
            "one": "%d elemento",
            "other": "%d elementos",
        },
        "trash.emptyConfirm.message": {
            "one": "%d elemento será eliminado permanentemente. Esta acción no se puede deshacer.",
            "other": "%d elementos serán eliminados permanentemente. Esta acción no se puede deshacer.",
        },
        "alert.clear.message": {
            "one": "¿Seguro que quieres borrar %d elemento?\nLos elementos fijados no se borrarán.",
            "other": "¿Seguro que quieres borrar %d elementos?\nLos elementos fijados no se borrarán.",
        },
        "settings.max.items.count": {
            "one": "%d elemento",
            "other": "%d elementos",
        },
        "clear.conditional.confirm": {
            "one": "%d elemento será eliminado (los fijados se conservan, movido a la papelera)",
            "other": "%d elementos serán eliminados (los fijados se conservan, movidos a la papelera)",
        },
    },
    "pt": {
        "batch.selected": {
            "one": "%d selecionado",
            "other": "%d selecionados",
        },
        "quickbar.recent": {
            "one": "%d item",
            "other": "%d itens",
        },
        "trash.emptyConfirm.message": {
            "one": "%d item será apagado permanentemente. Esta ação não pode ser desfeita.",
            "other": "%d itens serão apagados permanentemente. Esta ação não pode ser desfeita.",
        },
        "alert.clear.message": {
            "one": "Tem certeza de que deseja limpar %d item?\nItens fixados não serão apagados.",
            "other": "Tem certeza de que deseja limpar %d itens?\nItens fixados não serão apagados.",
        },
        "settings.max.items.count": {
            "one": "%d item",
            "other": "%d itens",
        },
        "clear.conditional.confirm": {
            "one": "%d item será apagado (fixados mantidos, movido para a lixeira)",
            "other": "%d itens serão apagados (fixados mantidos, movidos para a lixeira)",
        },
    },
}


def resolve(locale: str, category: str, key: str, one: str, other: str) -> str:
    """Resolve the format string for one locale/category/key."""
    if locale in TRANSLATIONS:
        return TRANSLATIONS[locale][key][category]
    # en keeps the authored one/other forms; ja/ko/zh use the single
    # "other" form for every count.
    return one if category == "one" else other


def generate_for_locale(locale: str, keys: list) -> str:
    """Generate the .stringsdict XML body for one locale."""
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        '<dict>',
    ]
    for key, one, other in keys:
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
        for cat in LOCALE_CATEGORIES[locale]:
            value = resolve(locale, cat, key, one, other)
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
    for locale in LOCALE_CATEGORIES:
        out_path = repo_root / "ClipMemory" / f"{locale}.lproj" / "Localizable.stringsdict"
        content = generate_for_locale(locale, KEYS)
        out_path.write_text(content, encoding="utf-8")
        print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
