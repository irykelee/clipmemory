import SwiftUI

/// Renders up to `maxChipsVisible` chips for an item's attached tag ids,
/// defensively dropping any orphan UUIDs (tag id without a matching
/// `ClipboardStore.tags` entry — possible if a tag was deleted out-of-band).
///
/// Uses the project's existing `FlowLayout` so chips wrap naturally inside
/// the row. Caps at 4 to keep list row height stable; full list is always
/// available via the tag picker sheet.
struct TagChipStack: View {
    let tagIds: Set<UUID>
    let store: ClipboardStore

    /// Pinned to 4 so the list row stays a single visual line in most cases.
    /// Changing this number changes visible density — covered by a unit test.
    static let maxChipsVisible = 4

    /// Pure helper exposed for testing. Drops orphans and sorts by tag name
    /// so the visible chips are deterministic across launches and rows.
    static func visibleTags(from tagIds: Set<UUID>, store: ClipboardStore) -> [Tag] {
        tagIds
            .compactMap { store.tags[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(maxChipsVisible)
            .map { $0 }
    }

    var body: some View {
        let chips = TagChipStack.visibleTags(from: tagIds, store: store)
        if chips.isEmpty {
            EmptyView()
        } else {
            FlowLayout(spacing: 4) {
                ForEach(chips, id: \.id) { tag in
                    TagChip(tag: tag)
                }
            }
        }
    }
}
