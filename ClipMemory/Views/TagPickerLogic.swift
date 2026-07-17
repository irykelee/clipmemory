import Foundation

/// How a single TagSuggestion name maps to the user's existing tag dictionary.
/// Used by TagPickerSheet to decide whether to render a suggestion as
/// "auto-check existing tag" or "create new tag" in the suggestions block.
enum SuggestionClassification: Equatable {
    /// A tag with this name already exists in the store. The sheet will
    /// auto-check it on appear instead of offering to create a duplicate.
    case existing(Tag)
    /// No tag has this name yet. The sheet shows a chip that, when tapped,
    /// creates a new tag with this name and attaches it to the item.
    case create(String)
}

/// Pure decision helpers used by TagPickerSheet. Extracted from the view so
/// we can unit-test the rules without rendering SwiftUI.
enum TagPickerLogic {

    /// Pick a default color for a brand-new tag, preferring the first preset
    /// color that no existing tag currently uses. If every preset is in use,
    /// fall back to cycling via modulo so we never deadlock on color choice.
    /// - Parameter existingTags: All tags currently in the store.
    /// - Returns: A hex string from `Tag.presetColors`.
    static func defaultColorHex(existingTags: [Tag]) -> String {
        let used = Set(existingTags.map(\.colorHex))
        if let unused = Tag.presetColors.first(where: { !used.contains($0) }) {
            return unused
        }
        return Tag.presetColors[existingTags.count % Tag.presetColors.count]
    }

    /// Classify a single suggestion name against the user's existing tag set.
    /// - Returns: `.existing(tag)` when an exact-name match exists,
    ///            `.create(name)` when no match exists,
    ///            `nil` for empty/whitespace names.
    static func classifySuggestion(name: String, existingTags: [Tag]) -> SuggestionClassification? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let hit = existingTags.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            return .existing(hit)
        }
        return .create(trimmed)
    }

    /// Build a `Tag` from a `SuggestionClassification`. Used by the sheet to
    /// turn "tap suggestion chip" or "tap existing chip" into the right tag
    /// instance. `.create` → fresh tag with `isAutoSuggested: true`.
    /// `.existing` → returns the existing tag's identity (id/createdAt/etc).
    static func makeTag(from classification: SuggestionClassification, colorHex: String) -> Tag {
        switch classification {
        case .existing(let tag):
            return tag
        case .create(let name):
            return Tag(name: name, colorHex: colorHex, isAutoSuggested: true)
        }
    }

    /// Build a tag from the manual "+ 新建标签" form. Always user-typed, so
    /// `isAutoSuggested: false` regardless of how the color was chosen.
    static func makeTagManual(name: String, colorHex: String) -> Tag {
        Tag(name: name, colorHex: colorHex, isAutoSuggested: false)
    }

    /// Decide the new attached-id set when the user taps a tag chip in the
    /// sheet. Pure helper so we can unit-test the toggle without rendering.
    static func toggleAttachment(currentlyAttached: Set<UUID>, tapping tagId: UUID) -> Set<UUID> {
        var next = currentlyAttached
        if next.contains(tagId) {
            next.remove(tagId)
        } else {
            next.insert(tagId)
        }
        return next
    }

    /// Compute vocabulary autocomplete candidates for a user-typed prefix.
    /// Pure helper delegating to `ClipboardStore.tags(matchingPrefix:limit:)`
    /// so we can unit-test the prefix/limit/empty behavior without rendering
    /// SwiftUI. Returns at most `limit` tags ordered by createdAt desc.
    static func autocompleteCandidates(prefix: String, limit: Int = 5, store: ClipboardStore) -> [Tag] {
        store.tags(matchingPrefix: prefix, limit: limit)
    }

    /// Attach an existing tag with `name` to `itemId`, or create a new
    /// auto-suggested tag and attach it. Guards against duplicates if the tag
    /// was created after the sheet's suggestion list was computed.
    static func attachOrCreateTag(name: String, colorHex: String, to itemId: UUID, store: ClipboardStore) {
        if let existing = store.tags.values.first(where: { $0.name.lowercased() == name.lowercased() }) {
            store.addTag(to: itemId, tagId: existing.id)
        } else {
            let tag = makeTag(from: .create(name), colorHex: colorHex)
            store.addTag(tag)
            store.addTag(to: itemId, tagId: tag.id)
        }
    }
}
