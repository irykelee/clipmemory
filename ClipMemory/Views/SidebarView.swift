import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ClipboardStore
    @Binding var selectedTab: SidebarTab
    let selectedTagIds: Set<UUID>
    let tabCounts: [SidebarTab: Int]
    let tagCounts: [UUID: Int]
    let sortedTags: [Tag]
    let onToggleTag: (UUID) -> Void
    let onNewTag: () -> Void
    let onDeleteTag: (Tag) -> Void
    let onClearType: (ClipboardItemType) -> Void
    let onTabChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LogoView()
                .padding(.horizontal, 8)
                .padding(.top, 8)
            List(selection: $selectedTab) {
                ForEach([SidebarTab.all, .text, .image, .link, .richText], id: \.self) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .badge(tabCounts[tab] ?? 0)
                        .tag(tab)
                        .contextMenu {
                            if let type = tab.typeFilter {
                                Button(role: .destructive, action: { onClearType(type) }, label: {
                                    Label(L10n.clearTypeAction(typeLabel(type)), systemImage: "trash")
                                })
                            }
                        }
                }
                Section {
                    Label(SidebarTab.pinned.label, systemImage: SidebarTab.pinned.icon)
                        .tag(SidebarTab.pinned)
                    Label(SidebarTab.trash.label, systemImage: SidebarTab.trash.icon)
                        .badge(store.trashedItems.count)
                        .tag(SidebarTab.trash)
                    Label(SidebarTab.settings.label, systemImage: SidebarTab.settings.icon)
                        .tag(SidebarTab.settings)
                }
                Section(L10n.sidebarSectionTags) {
                    if store.tags.isEmpty {
                        Text(L10n.sidebarTagsEmpty)
                            .font(.system(size: sz(11)))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sortedTags, id: \.id) { tag in
                            SidebarTagRow(
                                tag: tag,
                                count: tagCounts[tag.id] ?? 0,
                                isSelected: selectedTagIds.contains(tag.id),
                                onTap: { onToggleTag(tag.id) },
                                onDelete: { onDeleteTag(tag) }
                            )
                        }
                    }
                    Button(action: onNewTag, label: {
                        Label(L10n.sidebarNewTag, systemImage: "plus.circle")
                            .font(.system(size: sz(12)))
                    })
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            .listStyle(.sidebar)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: selectedTab) { _ in onTabChanged() }
    }
}
