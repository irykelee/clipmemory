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
            // ID-VIEW-0023 (2026-08-03, user-driven): the brand logo lives
            // in the TOOLBAR, leading side via .navigation placement.
            // The user has corrected this five times (0017/0018/0019/0020/
            // 0021/0022) — the right place is the toolbar's leading edge,
            // not the sidebar header, not a .principal center, not a
            // .automatic leading spot. The sidebar is navigation-only.
            //
            // ID-VIEW-0028 (2026-08-03, user-driven): search field restyled
            // to match the macOS 26 (Tahoe) system default sidebar search
            // box (referenced capcap-rec-260803-232039.mp4). Key changes:
            //   - the magnifying glass icon is now a CHIP (circular
            //     filled background) instead of a bare glyph — this is
            //     the macOS 26 standard
            //   - the container is a rounded rect with a 1pt colored
            //     border that fills with the accent color when focused
            //   - padding is tighter (8pt horiz, 6pt vert) so the box
            //     is the same height as other sidebar rows
            //   - the clear ✕ button is hidden when empty (kept from
            //     ID-VIEW-0017) and only shown when there's text
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 16, height: 16)
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: sz(9), weight: .semibold))
                }
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
                        CloseButton {}
                    })
                    .buttonStyle(.plain)
                    // ID-L10N-0002: localized VoiceOver label.
                    .accessibilityLabel(L10n.searchClear)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                // macOS 26 sidebar-search look: rounded rect with a
                // colored border that fills with the accent tint when
                // focused. Focus state is bound to the same isSearchFocused
                // @FocusState that the TextField uses.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSearchFocused ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSearchFocused ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: isSearchFocused ? 1.5 : 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)
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
