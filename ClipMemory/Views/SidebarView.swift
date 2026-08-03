import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ClipboardStore
    @Binding var selectedTab: SidebarTab
    // ID-VIEW-0015 (2026-08-03, user-driven): search moved into the
    // sidebar header (macOS system-app convention). The bindings are owned
    // by ContentView — filtering, debounce, focus and keyboard selection
    // all stay in one place there. onSubmit behavior also lives in
    // ContentView (it needs cachedDisplayedItems / copyItemWithFlash).
    @Binding var searchText: String
    @FocusState.Binding var isSearchFocused: Bool
    let onSearchSubmit: () -> Void
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
            // ID-VIEW-0022 (2026-08-03, user-driven): brand logo returned
            // to the sidebar header. The user's "left-align" instruction
            // really meant the sidebar column on the left side of the
            // window — the macOS system-app convention (Finder / Notes /
            // Reminders all show the brand at the top of the sidebar).
            // expandWidth: true (default) lets the logo span the column
            // width.
            LogoView()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 14)
            // Search field styling follows the macOS sidebar-search
            // convention (Finder / System Settings): a distinct filled
            // capsule with a hairline border and real breathing room
            // above/below, instead of the old translucent toolbar look
            // that blended into the background. (ID-VIEW-0017 styling.)
            // top padding intentionally 0 — the LogoView above provides
            // 14pt of bottom breathing room.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: sz(11)))
                TextField(L10n.searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: sz(12)))
                    .focused($isSearchFocused)
                    // Fill the sidebar width (the old toolbar field was a
                    // fixed 180pt; here the sidebar column is the constraint).
                    .frame(maxWidth: .infinity)
                    // ID-VIEW-0011 behavior preserved: Return copies the
                    // keyboard-selected (or first) visible item. The actual
                    // copy logic lives in ContentView via onSearchSubmit.
                    .onSubmit { onSearchSubmit() }
                // 2026-07-27 (user-requested): one-tap clear. Hidden when
                // empty so the sidebar stays visually quiet.
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        isSearchFocused = true
                    }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: sz(11)))
                    })
                    .buttonStyle(.plain)
                    // ID-L10N-0002: localized VoiceOver label.
                    .accessibilityLabel(L10n.searchClear)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                // macOS sidebar-search look: solid fill + hairline border,
                // clearly distinct from the sidebar background.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            // (top padding intentionally 0 — the LogoView above provides
            // 14pt of bottom breathing room.)
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
            // ID-VIEW-0017: macOS sidebar apps don't show a persistent
            // scrollbar track. Hide the indicator; scrolling still works,
            // and the raised minHeight (ContentView) makes overflow rare.
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: selectedTab) { _ in onTabChanged() }
    }
}
