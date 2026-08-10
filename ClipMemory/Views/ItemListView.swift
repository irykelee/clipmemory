import SwiftUI
import AppKit

/// NEW-7 Phase 4: extracted from ContentView. Owns the main item list
/// rendering (List with grouped sections + selection state + batch
/// toolbar), the trash sub-view, and the alert/sheet plumbing for
/// delete + clear operations.
///
/// All state is passed in via @Binding — ContentView remains the source
/// of truth for filter / search / day-rollover caches (Phase 5+ work to
/// collapse into an `@StateObject` ViewModel is out of scope here, see
/// `docs/superpowers/specs/2026-07-21-contentview-split-plan.md`).
struct ItemListView: View {
    // H-12 (2026-07-24 audit): was `let store`. ListView reads many computed
    // properties backed by @Published values (`store.items`, `store.trashedItems`,
    // `store.todayCount`, etc.) — without `@ObservedObject`, ItemListView had
    // no subscription of its own and relied entirely on ContentView re-rendering
    // and re-pushing bindings. Today this happens to work (ContentView observes
    // ClipboardStore), but it was a fragile implicit dependency: any refactor
    // that memoized ContentView's body (ViewModel extraction, post NEW-7 Phase 5)
    // would silently break ItemListView's refresh path. Add the subscription
    // here so the view re-renders directly when store changes, independent of
    // the parent's pipeline.
    @ObservedObject var store: ClipboardStore
    /// Read-only context the list branch keys off (all/text/trash/etc.).
    let selectedTab: SidebarTab
    /// Result of ContentView's `filterItems` — pre-filtered, already grouped.
    let displayedItems: [ClipboardItem]
    let groupedItemsWithIndex: [(group: TimeGroup, items: [(item: ClipboardItem, globalIndex: Int)])]
    let batchAllPinned: Bool

    @Binding var searchText: String
    /// Debounced copy of `searchText` (250ms after last keystroke). Threaded
    /// into ClipboardItemRow so the OCR snippet doesn't flash on rows that
    /// won't survive the next filter pass (raw `searchText` updates on every
    /// keystroke; `filterItems` only re-runs once the debounce fires).
    @Binding var searchTextDebounced: String
    @Binding var collapsedGroups: Set<TimeGroup>
    @Binding var selectedItems: Set<UUID>
    @Binding var keyboardSelectedIndex: Int?
    @Binding var lastCopiedId: UUID?
    @Binding var scrollAnchor: UUID?
    @Binding var revealedItems: Set<UUID>
    @Binding var pendingClearMode: ClearMode?
    @Binding var pendingTypeClear: ClipboardItemType?
    @Binding var showingConditionalClear: Bool
    @Binding var showingDeleteAlert: Bool
    @Binding var itemToDelete: ClipboardItem?
    @Binding var showingEmptyTrashAlert: Bool
    @Binding var tagPickerItem: ClipboardItem?

    static func shouldToggleGroupHeader(searchText: String) -> Bool {
        searchText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedTab == .trash {
                trashView
            } else if displayedItems.isEmpty { emptyState } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(groupedItemsWithIndex, id: \.group) { section in
                            Section {
                                if !searchText.isEmpty || !collapsedGroups.contains(section.group) {
                                    ForEach(section.items, id: \.item.id) { itemWithIndex in
                                        self.buildItemRow(itemWithIndex: itemWithIndex)
                                            .listRowInsets(EdgeInsets())
                                            .listRowSeparator(.hidden)
                                            .id(itemWithIndex.item.id)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(section.group.label).font(.system(size: sz(12), weight: .semibold)).foregroundColor(.secondary)
                                    Spacer()
                                    Button(action: { pendingClearMode = clearModeForGroup(section.group) }, label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: sz(11)))
                                            .foregroundColor(.secondary)
                                    })
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.buttonClear)
                                    Image(systemName: chevronName(section.group))
                                        .font(.system(size: sz(10)))
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                                // BUG-007 (2026-07-21 audit, still present in
                                // ItemListView after Phase 4 extraction):
                                // the group header tap toggles `collapsedGroups`
                                // even when search text is non-empty. Search
                                // force-expands groups for display, so the tap
                                // is a no-op visually, and clearing search
                                // then reveals the user-collapsed state
                                // unexpectedly. Skip the toggle during search.
                                .onTapGesture {
                                    if Self.shouldToggleGroupHeader(searchText: searchText) { toggleGroup(section.group) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .layoutPriority(1)
                    .task(id: scrollAnchor) {
                        if let anchor = scrollAnchor {
                            proxy.scrollTo(anchor, anchor: .center)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if !selectedItems.isEmpty {
                        HStack {
                            Text(L10n.batchSelected(selectedItems.count))
                                .font(.system(size: sz(12)))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                store.togglePinItems(displayedItems.filter { selectedItems.contains($0.id) })
                                selectedItems.removeAll()
                            }, label: {
                                Label(
                                    batchAllPinned ? L10n.actionUnpin : L10n.actionPin,
                                    systemImage: batchAllPinned ? "star.slash" : "star"
                                )
                                .font(.system(size: sz(12)))
                            })
                            .buttonStyle(.plain)
                            Button(action: {
                                store.deleteItems(displayedItems.filter { selectedItems.contains($0.id) })
                                selectedItems.removeAll()
                            }, label: {
                                Label(L10n.actionDelete, systemImage: "trash")
                                    .font(.system(size: sz(12)))
                            })
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            Button(action: { selectedItems.removeAll() }, label: {
                                Text(L10n.buttonCancel).font(.system(size: sz(12)))
                            })
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: selectedItems.isEmpty)
            }
        }
        // M-11 (2026-07-24 audit): 4 stacked `.alert` modifiers without a
        // runtime exclusivity check. Replaced with a single `.alert(...)`
        // driven by an enum. The four source @Binding flags from
        // ContentView remain unchanged — we derive the active alert from
        // them in a computed property, then reset all four sources when
        // the alert dismisses (via `activeAlertBool.wrappedValue = false`
        // in the binding setter). Priority order: per-item delete >
        // type clear > group clear > empty trash.
        //
        // We use the `isPresented:` Bool overload with both `actions:` and
        // `message:` trailing closures because the `item:` overload on
        // macOS 13 (our deployment target) only supports `actions:` — no
        // `message:`. The `_:item:_:message:` overload with both was added
        // in macOS 14.
        .alert(activeAlert?.title ?? Text(""), isPresented: activeAlertBool) {
            switch activeAlert {
            case .deleteSingle:
                Button(L10n.buttonCancel, role: .cancel) {}
                Button(L10n.buttonDelete, role: .destructive) {
                    if let item = itemToDelete { store.deleteItem(item) }
                }
            case .clearType:
                Button(L10n.buttonCancel, role: .cancel) { pendingTypeClear = nil }
                Button(L10n.buttonClear, role: .destructive) {
                    if let type = pendingTypeClear {
                        store.clearItems(type: type, range: .all)
                    }
                    pendingTypeClear = nil
                }
            case .clearMode:
                Button(L10n.buttonCancel, role: .cancel) { pendingClearMode = nil }
                Button(L10n.buttonClear, role: .destructive) { confirmClear() }
            case .emptyTrash:
                Button(L10n.buttonCancel, role: .cancel) { showingEmptyTrashAlert = false }
                Button(L10n.buttonClear, role: .destructive) {
                    store.emptyTrash()
                    showingEmptyTrashAlert = false
                }
            case .none:
                Button(L10n.buttonCancel, role: .cancel) {}
            }
        } message: {
            if let kind = activeAlert {
                switch kind {
                case .deleteSingle:
                    Text(L10n.alertDeleteMessage)
                case .clearType:
                    if let type = pendingTypeClear {
                        Text(L10n.clearTypeConfirm(typeLabel(type), store.items.filter { $0.type == type && !$0.isPinned }.count))
                    }
                case .clearMode:
                    Text(clearAlertText)
                case .emptyTrash:
                    Text(L10n.trashEmptyConfirmMessage(store.trashedItems.count))
                }
            }
        }
    }

    /// M-11 binding helper: Bool binding that toggles `activeAlert` on/off.
    /// When the user dismisses the alert (sets the binding to `false`),
    /// we reset all four source @Bindings so a stale state can't re-show.
    /// Reset only `itemToDelete` when the active kind was `.deleteSingle`,
    /// otherwise we leak the deleted-item reference into the next session
    /// of the view. (M-11 post-audit fix: previous reset-all path silently
    /// kept `itemToDelete` pinned.)
    private var activeAlertBool: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { newValue in
                guard !newValue else { return }
                // Only reset `itemToDelete` when that was the active alert;
                // resetting it unconditionally would clobber a pending
                // delete the user just opened from a different source.
                switch activeAlert {
                case .deleteSingle:
                    itemToDelete = nil
                    showingDeleteAlert = false
                case .clearType:
                    pendingTypeClear = nil
                case .clearMode:
                    pendingClearMode = nil
                case .emptyTrash:
                    showingEmptyTrashAlert = false
                case .none:
                    break
                }
            }
        )
    }

    // MARK: - Active-alert model (M-11)
    //
    // Encodes which of the four dialogs the view should currently show.
    // Only one case is ever non-nil because the four source @Bindings are
    // mutually exclusive in practice (different buttons), and the priority
    // order in `activeAlert` guarantees we never try to render two alerts
    // at once even if some upstream code path did flip two flags.

    private enum ActiveAlert: String, Identifiable {
        case deleteSingle
        case clearType
        case clearMode
        case emptyTrash
        var id: String { rawValue }

        /// M-11 (2026-07-24 audit): title for the unified `.alert(...)` modifier.
        /// The `_ :isPresented:_ :message:` overload on macOS 13 takes a
        /// `Text` title — we derive it from the alert kind so each dialog
        /// keeps its original copy.
        var title: Text {
            switch self {
            case .deleteSingle: return Text(L10n.alertDeleteTitle)
            case .clearType:    return Text(L10n.alertClearTitle)
            case .clearMode:    return Text(L10n.alertClearTitle)
            case .emptyTrash:   return Text(L10n.trashEmptyConfirmTitle)
            }
        }
    }

    private var activeAlert: ActiveAlert? {
        if showingDeleteAlert { return .deleteSingle }
        if pendingTypeClear != nil { return .clearType }
        if pendingClearMode != nil { return .clearMode }
        if showingEmptyTrashAlert { return .emptyTrash }
        return nil
    }

    // MARK: - Trash sub-view

    /// NEW-batch-restore: selection state for the trash list's multi-select
    /// mode. Local to ItemListView (not exposed to ContentView) — trash
    /// selection has no meaning outside the trash view, so parent coupling
    /// would be over-engineering. Drives per-row checkboxes via TrashItemRow's
    /// `isSelected` prop, NOT a native `List(selection:)` binding — the
    /// latter hid checkmarks when nothing was selected and showed a frosted
    /// `.regularMaterial` overlay that read as a "deep blue bar" in dark mode.
    /// Explicit row checkboxes are clearer and the toolbar can stay minimal.
    @State private var selectedTrashIDs: Set<UUID> = []
    /// NEW-batch-restore (revised, user round 6 feedback): anchor for
    /// Windows-style Shift+click range selection. Click an item → this
    /// records the click; Shift+click a different item → select the
    /// range from anchor to current. Matches the OS file-manager pattern
    /// so power users don't have to retrain their muscle memory.
    @State private var lastClickedTrashID: UUID?

    private var trashView: some View {
        VStack(spacing: 0) {
            if store.trashedItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: sz(36)))
                        .foregroundColor(.secondary)
                    Text(L10n.trashEmpty)
                        .font(.system(size: sz(14)))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                // NEW-batch-restore (revised twice):
                // (user round 5: drop .regularMaterial blue bar)
                // (user round 6: 全选 button on LEFT with icon — was lost
                //  on the right with only Spacer+text), always-visible
                //  master checkbox with tri-state (square / dash / check
                //  based on selection state), action buttons right.
                HStack(spacing: 8) {
                    // Master "全选" on the LEFT — always visible, with icon
                    // so it's obvious how to multi-select.
                    Button(action: {
                        if trashAllSelected {
                            selectedTrashIDs.removeAll()
                        } else {
                            selectedTrashIDs = Set(store.trashedItems.map(\.id))
                        }
                    }, label: {
                        HStack(spacing: 4) {
                            Image(systemName: trashAllSelected
                                  ? "checkmark.square.fill"
                                  : (selectedTrashIDs.isEmpty ? "square" : "minus.square"))
                                .font(.system(size: sz(12)))
                                .foregroundColor(selectedTrashIDs.isEmpty ? .secondary : .accentColor)
                            Text(L10n.trashSelectAll)
                                .font(.system(size: sz(12)))
                        }
                    })
                    .buttonStyle(.plain)

                    if !selectedTrashIDs.isEmpty {
                        Spacer()
                        Text(L10n.trashBatchRestore(selectedTrashIDs.count))
                            .font(.system(size: sz(12)))
                            .foregroundColor(.secondary)
                        Button(action: {
                            let toRestore = store.trashedItems.filter { selectedTrashIDs.contains($0.id) }
                            store.restoreFromTrash(toRestore)
                            selectedTrashIDs.removeAll()
                            lastClickedTrashID = nil
                        }, label: {
                            Label(L10n.trashRestore, systemImage: "arrow.uturn.left")
                                .font(.system(size: sz(12)))
                        })
                        .buttonStyle(.plain)
                        Button(action: {
                            selectedTrashIDs.removeAll()
                            lastClickedTrashID = nil
                        }, label: {
                            Text(L10n.buttonCancel)
                                .font(.system(size: sz(12)))
                        })
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    } else {
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay(Divider(), alignment: .bottom)

                List {
                    ForEach(store.trashedItems) { item in
                        TrashItemRow(
                            item: item,
                            store: store,
                            onRestore: { store.restoreFromTrash(item) },
                            onDeletePermanently: { store.deletePermanently(item) },
                            isSelected: selectedTrashIDs.contains(item.id),
                            onToggleSelection: { handleTrashToggle(for: item.id) }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    /// NEW-batch-restore (revised, user round 6): tri-state "全选" derived
    /// value. `true` only when every trash item is selected; empty/partial
    /// selections drive the indeterminate `minus.square` icon in the toolbar.
    /// Empty trash (no items at all) also returns `true` — but the toolbar
    /// itself isn't rendered in that state, so this is a no-op.
    private var trashAllSelected: Bool {
        !store.trashedItems.isEmpty && selectedTrashIDs.count == store.trashedItems.count
    }

    /// NEW-batch-restore (revised, user round 6): Windows-style multi-select
    /// handler. Reads NSEvent.modifierFlags so the same callback supports
    /// single-click toggle, shift-click range select, and the
    /// master-checkbox's select-all action. Mirrors Finder's row-click
    /// pattern so the user doesn't have to learn a new interaction model.
    private func handleTrashToggle(for itemID: UUID) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let anchor = lastClickedTrashID,
           let anchorIdx = store.trashedItems.firstIndex(where: { $0.id == anchor }),
           let currentIdx = store.trashedItems.firstIndex(where: { $0.id == itemID }) {
            // Range select: include every item from anchor to current
            // inclusive, in array order (newest first since `trashedItems`
            // is sorted with the most recently trashed on top).
            let lo = min(anchorIdx, currentIdx)
            let hi = max(anchorIdx, currentIdx)
            for i in lo...hi {
                selectedTrashIDs.insert(store.trashedItems[i].id)
            }
        } else {
            // Plain click: toggle this item. Update the anchor so the next
            // shift+click can range from this position.
            if selectedTrashIDs.contains(itemID) {
                selectedTrashIDs.remove(itemID)
            } else {
                selectedTrashIDs.insert(itemID)
            }
            lastClickedTrashID = itemID
        }
    }

    // MARK: - Empty state

    /// M-10 (2026-07-24 audit): the empty-state analytics event used to live
    /// inside the computed property, so every body re-render logged it
    /// (even when nothing relevant changed). Now fire it from a `.task(id:)`
    /// keyed on the visible-shape signature — `displayedItems.isEmpty` plus
    /// the underlying store items count — so it only runs when the empty
    /// state actually appears or the empty class flips.
    @State private var lastEmptyEventKey: String = ""
    private func logEmptyStateIfNeeded() {
        let name = store.items.isEmpty ? "no_items_overall" : "filter_no_match"
        let key = "\(name)|\(store.items.count)"
        if key != lastEmptyEventKey {
            lastEmptyEventKey = key
            UIObservability.logEmptyStateRender(name: name, itemCount: store.items.count)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: selectedTab == .pinned ? "star" : "tray")
                .font(.system(size: sz(40)))
                .foregroundColor(.secondary)
            Text(selectedTab == .pinned ? L10n.emptyNoPinned : L10n.emptyNoHistory)
                .font(.system(size: sz(14)))
                .foregroundColor(.secondary)
            if selectedTab == .pinned {
                Text(L10n.emptyPinnedHint)
                    .font(.system(size: sz(12)))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text(L10n.emptyHistoryHint)
                    .font(.system(size: sz(12)))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // M-10 (2026-07-24 audit): fire the analytics event from a task
        // keyed on the visible-shape signature so it only runs when the
        // empty class actually changes — not on every body re-render.
        .task(id: "\(store.items.isEmpty ? 1 : 0)|\(store.items.count)") {
            logEmptyStateIfNeeded()
        }
    }

    // MARK: - Row builder + helpers

    private func copyItem(_ item: ClipboardItem) { store.copyToClipboard(item) }

    private func toggleReveal(_ id: UUID) {
        if revealedItems.contains(id) { revealedItems.remove(id) } else { revealedItems.insert(id) }
    }

    private func toggleGroup(_ g: TimeGroup) {
        if collapsedGroups.contains(g) { collapsedGroups.remove(g) } else { collapsedGroups.insert(g) }
    }

    /// SF Symbol name for the group-header chevron. Shows `down` when the
    /// group is expanded, or `right` when collapsed — but force-expands
    /// during a search so users can see the matching items.
    private func chevronName(_ g: TimeGroup) -> String {
        (!collapsedGroups.contains(g) || !searchText.isEmpty) ? "chevron.down" : "chevron.right"
    }

    /// Builds a single ClipboardItemRow. Extracted from the ForEach body to
    /// keep Swift's type-checker happy — the row init has 12 named parameters
    /// and SwiftUI's @ViewBuilder blows the solver budget when inlined inside
    /// a deeply nested Section/ForEach.
    @ViewBuilder
    private func buildItemRow(itemWithIndex: (item: ClipboardItem, globalIndex: Int)) -> some View {
        let item: ClipboardItem = itemWithIndex.item
        let itemId: UUID = item.id
        let revealed: Bool = revealedItems.contains(itemId)
        let kbSelected: Bool = keyboardSelectedIndex == itemWithIndex.globalIndex
        let copied: Bool = lastCopiedId == itemId
        let selected: Bool = selectedItems.contains(itemId)
        let copyAction: () -> Void = {
            self.lastCopiedId = itemId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self.lastCopiedId == itemId { self.lastCopiedId = nil }
            }
            self.copyItem(item)
        }
        let pinAction: () -> Void = { self.store.togglePin(item) }
        let deleteAction: () -> Void = {
            self.itemToDelete = item
            self.showingDeleteAlert = true
        }
        let selectAction: (Bool) -> Void = { isOn in
            if isOn { self.selectedItems.insert(itemId) } else { self.selectedItems.remove(itemId) }
        }
        let revealAction: () -> Void = { self.toggleReveal(itemId) }
        let editTagsAction: () -> Void = { self.tagPickerItem = item }
        ClipboardItemRow(item: item,
            store: store,
            isRevealed: revealed,
            isKeyboardSelected: kbSelected,
            isCopied: copied,
            isSelected: selected,
            searchText: searchText,
            searchTextDebounced: searchTextDebounced,
            onCopyWithFeedback: copyAction,
            onPin: pinAction,
            onDelete: deleteAction,
            onSelect: selectAction,
            onToggleReveal: revealAction,
            onEditTags: editTagsAction)
    }

    // MARK: - Clear-mode plumbing

    private var clearAlertText: String {
        guard let mode = pendingClearMode else { return "" }
        let count: Int
        switch mode {
        case .today: count = store.todayCount
        case .yesterday: count = store.yesterdayCount
        case .older: count = store.olderCount
        case .all: count = store.items.filter { !$0.isPinned }.count
        }
        return count > 0 ? L10n.alertClearMessage(count) : L10n.alertClearNone
    }

    /// Maps a time group to the ClearMode used by the toolbar menu so the new
    /// per-group header trash button reuses the exact same confirmation flow.
    private func clearModeForGroup(_ group: TimeGroup) -> ClearMode {
        switch group {
        case .today: return .today
        case .yesterday: return .yesterday
        case .older: return .older
        }
    }

    private func confirmClear() {
        guard let mode = pendingClearMode else { return }
        switch mode {
        case .today: store.clearToday()
        case .yesterday: store.clearYesterday()
        case .older: store.clearOlder()
        case .all: store.clearAllItems()
        }
        pendingClearMode = nil
    }
}

/// Hoisted from `ContentView` so `ItemListView` can reference the same
/// enum (group-header trash button + toolbar menu use the same flow).
/// Was previously `private enum` nested in ContentView — moving to module
/// scope is a no-op observable change.
enum ClearMode {
    case today, yesterday, older, all
}
