import Foundation

/// Decision outcomes from NewTagLogic.submit. The sidebar's "+ 新建标签"
/// sheet consumes this to decide whether to show "Create" or "Use Existing"
/// and what tag id to feed back to ContentView for selection.
enum NewTagSubmitResult: Equatable {
    /// A new tag was created. The associated id is the freshly-assigned one.
    case created(UUID)
    /// A tag with this name already existed. The associated id is the
    /// existing tag's id — no new tag was created.
    case reused(UUID)
}

/// Pure helpers backing NewTagSheet (the sidebar's "+ 新建标签" entry).
/// The sheet renders SwiftUI; this enum owns the decisions so we can
/// unit-test the rules without rendering.
enum NewTagLogic {

    /// Submit a tag-creation attempt from the sidebar.
    /// - Returns: `.reused(id)` if a tag with this trimmed name already
    ///            exists, `.created(id)` if a new tag was added,
    ///            `nil` if the name was empty/whitespace-only.
    /// - Side effect: when `.created`, the new tag is written to `store`.
    static func submit(name: String,
                       colorHex: String,
                       store: ClipboardStore) -> NewTagSubmitResult? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let existing = store.tags.values.first(where: { $0.name == trimmed }) {
            return .reused(existing.id)
        }

        // Manual sidebar path → isAutoSuggested=false. Uses the chosen color;
        // we do not run defaultColorHex here because the user explicitly picked.
        let tag = Tag(name: trimmed, colorHex: colorHex, isAutoSuggested: false)
        store.addTag(tag)
        return .created(tag.id)
    }
}
