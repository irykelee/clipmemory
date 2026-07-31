import SwiftUI
import AppKit

/// Sheet for managing tags attached to a single ClipboardItem.
/// Shows: top-bar with content preview, suggestions block (auto-create or
/// auto-check), all-tags multi-select block, and an inline "new tag" form
/// with a real-time duplicate-name detector.
///
/// All mutations write through `ClipboardStore` directly — there is no draft
/// state. Dismissing the sheet is a no-op (the work is already persisted).
struct TagPickerSheet: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    // 2026-07-25: font-scale invalidation trigger. MUST be read in body —
    // an unread @AppStorage creates no SwiftUI dependency, so font-size
    // changes never re-rendered views that size via sz().
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @State private var suggestionsToCreate: [String] = []
    @State private var suggestedNames: [String] = []
    // 2026-07-27 (user-decision): default ON. The user explicitly chose
    // opt-out after two flip-flops in the same day; this default is now
    // the stable answer and should not be changed without re-asking.
    // Even though NLTagger's Chinese NER is unreliable, the user values
    // surfacing the signal more than hiding it — and the toggle gives an
    // immediate escape hatch for users who don't want it.
    @State private var showNameSuggestions = true
    @State private var isCreating = false
    @State private var newName = ""
    @State private var newColor: String = Tag.presetColors.first ?? "#4ECDC4"
    @State private var pendingDelete: Tag?
    // 2026-07-27 (user-requested): track whether the user actually
    // mutated anything in the sheet so the Done button can be disabled
    // on a no-op close. Set by toggleAttachment / delete-confirmation
    // paths; cleared never (the user either did something or didn't).
    @State private var hasChanges = false

    private var allTagsSorted: [Tag] {
        store.tags.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// The item snapshot passed into the sheet can become stale after store
    /// mutations. Always read the live store item so toggles reflect current
    /// attachments.
    private func currentItem() -> ClipboardItem {
        store.items.first(where: { $0.id == item.id }) ?? item
    }

    var body: some View {
        let _ = fontScale  // 2026-07-25: subscribe to font-scale changes (see declaration)
        // ID-PERF-0013 (2026-07-30 audit): `currentItem()` was called once
        // per tag row (and per create-block), each O(n) `store.items.first`.
        // For 10K items × 100 tags = 1M UUID comparisons per body build.
        // Compute the live item once here and let the per-row call sites
        // use a captured constant. Same `let` was already used for
        // `fontScale` above; this just adds a second cheap binding.
        let current = currentItem()
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewBlock
                    if !suggestionsToCreate.isEmpty { suggestionsBlock }
                    if showNameSuggestions && !suggestedNames.isEmpty { suggestedNamesBlock }
                    allTagsBlock(current: current)
                    createBlock
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 500)
        // ID-LIFE-0009 (2026-07-30 audit): use .task instead of .onAppear so
        // the suggestions Task is auto-cancelled when the sheet dismisses.
        // The detached NLTagger call doesn't inherit cancellation but
        // Task.isCancelled below guards the @State mutation.
        .task { await loadSuggestions() }
        .alert(L10n.tagPickerDeleteConfirmTitle,
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button(L10n.buttonCancel, role: .cancel) { pendingDelete = nil }
            Button(L10n.tagPickerDeleteConfirmConfirm, role: .destructive) {
                if let tag = pendingDelete {
                    store.deleteTag(id: tag.id)
                }
                pendingDelete = nil
                hasChanges = true
            }
        } message: {
            if let tag = pendingDelete {
                let count = store.items.filter { $0.tagIds.contains(tag.id) }.count
                Text(L10n.tagPickerDeleteConfirmMessage(tag.name, count))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(L10n.tagPickerTitle).font(.system(size: sz(14), weight: .semibold))
            Spacer()
            Toggle(L10n.tagPickerNameSuggestionsToggle, isOn: $showNameSuggestions)
                .toggleStyle(.checkbox)
                .font(.system(size: sz(11)))
                .disabled(suggestedNames.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 2026-07-27 (user-requested): the Done button used to live in the
    /// header as a small accent-colored link — too easy to miss when the
    /// sheet grew tall. Moved to a full-width pill button anchored at
    /// the bottom of the window, matching macOS sheet conventions
    /// (e.g. system Print / Save sheets).
    ///
    /// 2026-07-27 (user-requested): split into Cancel + Done. Done is
    /// disabled (grey) until the user actually mutates something — a
    /// user who opens the sheet to *browse* shouldn't get a prominent
    /// "Done" button that suggests an action was taken. ⌘↩ still
    /// dismisses via the defaultAction shortcut on Done; Esc dismisses
    /// via cancel-style close on Cancel.
    private var footer: some View {
        HStack(spacing: 8) {
            Button(L10n.buttonCancel) { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Button(L10n.buttonDone) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
                .help(hasChanges ? L10n.buttonDone : L10n.tagPickerDoneNoChangesHint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Preview

    private var previewBlock: some View {
        let preview: String
        if item.isSensitive {
            preview = L10n.itemSensitive
        } else {
            preview = store.getDecryptedContent(item) ?? item.content
        }
        // 2026-07-27 (user-requested): the preview used to be truncated
        // to 60 chars + lineLimit(1) — i.e. long content was completely
        // hidden. Now shows full content with a 5-line viewport cap
        // (~90pt at 13pt text) and SwiftUI's built-in persistent
        // scroll indicator (`.scrollIndicators(.visible)` on macOS 13+).
        //
        // Earlier attempts (3 commits) wrapped NSScrollView via
        // NSViewRepresentable. They failed: (a) bare NSHostingView
        // returns noIntrinsicMetric so NSScrollView can't compute thumb
        // position; (b) subclass overrides that fix (a) triggered a
        // crash on sidebar-tag re-tap (recursive fittingSize during
        // sheet relayout). SwiftUI's native ScrollView with
        // `.scrollIndicators(.visible)` is the documented macOS 13+
        // path and avoids the AppKit bridge entirely.
        //
        // Viewport: 5 lines of 13pt text at ~1.4 line-height ≈ 91pt +
        // inner padding ≈ 100pt. Caps are on the viewport (`.frame
        // (maxHeight: 100)`), NOT on the Text — let Text wrap
        // naturally to the available width.
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .leading)
                .padding(.top, 2)
            ScrollView(.vertical) {
                Text(preview)
                    .font(.system(size: sz(13)))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 100)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Suggestions

    private var suggestionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tagPickerSectionSuggestions)
                .font(.system(size: sz(11), weight: .semibold))
                .foregroundColor(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(suggestionsToCreate, id: \.self) { name in
                    Button {
                        TagPickerLogic.attachOrCreateTag(name: name, colorHex: newColor, to: item.id, store: store)
                        suggestionsToCreate.removeAll { $0 == name }
                        // ID-VIEW-0004 (2026-07-31 audit): adopting a
                        // suggestion IS a mutation — mark it so Done enables
                        // (previously stayed disabled and looked like a no-op).
                        hasChanges = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus").font(.system(size: sz(9)))
                            Text(name).font(.system(size: sz(11)))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(4)
                    }
                    // ID-L10N-0015 (2026-07-30 audit): route through L10n
                    // (was hardcoded zh-Hans). Inline string previously left
                    // non-Chinese locales hearing the icon-only "plus"
                    // announcement.
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tagPickerAddSuggestion(name))
                }
            }
        }
    }

    // MARK: - Suggested names (person/org/place)

    private var suggestedNamesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tagPickerSectionSuggestedNames)
                .font(.system(size: sz(11), weight: .semibold))
                .foregroundColor(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(suggestedNames, id: \.self) { name in
                    Button {
                        TagPickerLogic.attachOrCreateTag(name: name, colorHex: newColor, to: item.id, store: store)
                        suggestedNames.removeAll { $0 == name }
                        // ID-VIEW-0004 (2026-07-31 audit): same as the
                        // suggestions block — adopting a suggested name is a
                        // mutation, so Done must enable.
                        hasChanges = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "person").font(.system(size: sz(9)))
                            Text(name).font(.system(size: sz(11)))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - All tags

    private func allTagsBlock(current: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tagPickerSectionAllTags)
                .font(.system(size: sz(11), weight: .semibold))
                .foregroundColor(.secondary)
            // ID-PERF-0013 (2026-07-30 audit): each tag row reuses the
            // `current` captured in `body` (already O(1) via the per-body
            // dict) instead of calling `currentItem()` again.
            ForEach(allTagsSorted, id: \.id) { tag in
                tagRow(tag, current: current)
            }
            if allTagsSorted.isEmpty {
                Text("—").foregroundColor(.secondary).font(.system(size: sz(11)))
            }
        }
    }

    private func tagRow(_ tag: Tag, current: ClipboardItem) -> some View {
        let isAttached = current.tagIds.contains(tag.id)
        return HStack(spacing: 8) {
            // Tap anywhere on row = toggle attachment
            Button(action: { toggleAttachment(tag: tag) }, label: {
                HStack(spacing: 8) {
                    Image(systemName: isAttached ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isAttached ? .accentColor : .secondary)
                        .font(.system(size: sz(14)))
                    TagChip(tag: tag)
                    Spacer()
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)

            // Long-press for delete confirmation
            TagRowLongPress(onDelete: { pendingDelete = tag })
        }
        // F-16 (2026-07-23 audit): the only path to delete a tag was a
        // long-press gesture (NSViewRepresentable). Mouse-only — keyboard
        // and VoiceOver users had no way to trigger delete. Add a SwiftUI
        // context menu (right-click / ⌃-click via a11y) and bind the
        // Delete (⌫) / Forward Delete keys via `.onDeleteCommand` so the
        // row also responds when it's keyboard-focused.
        .contextMenu {
            Button(role: .destructive) {
                pendingDelete = tag
            } label: {
                Label(L10n.tagPickerDeleteConfirmTitle, systemImage: "trash")
            }
        }
        .onDeleteCommand {
            pendingDelete = tag
        }
        .padding(.vertical, 2)
    }

    private func toggleAttachment(tag: Tag) {
        if currentItem().tagIds.contains(tag.id) {
            store.removeTag(from: item.id, tagId: tag.id)
        } else {
            store.addTag(to: item.id, tagId: tag.id)
        }
        hasChanges = true
    }

    // MARK: - Create new

    private var createBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCreating {
                createForm
            } else {
                Button(action: { isCreating = true; newColor = TagPickerLogic.defaultColorHex(existingTags: Array(store.tags.values)) }, label: {
                    Label(L10n.tagPickerCreate, systemImage: "plus.circle")
                        .font(.system(size: sz(12)))
                })
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameConflict: Tag? {
        store.tags.values.first { $0.name.lowercased() == trimmedName.lowercased() }
    }
    /// Vocabulary autocomplete chips: existing tags whose name starts with the
    /// typed prefix, excluding the exact match (handled by `nameConflict`).
    private var autocompleteCandidates: [Tag]? {
        guard !trimmedName.isEmpty, nameConflict == nil else { return nil }
        let cands = TagPickerLogic.autocompleteCandidates(prefix: trimmedName, limit: 5, store: store)
        return cands.isEmpty ? nil : cands
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.tagPickerCreate, text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: sz(12)))
                // Secondary CLIP-2 (2026-07-24 audit): without .onSubmit,
                // pressing Return inside the field fell through to the
                // header's Done button (`.keyboardShortcut(.defaultAction)`)
                // and dismissed the sheet, discarding the in-progress tag
                // draft. Route Return through the same submit path as the
                // Create / Use-existing button. An empty (whitespace-only)
                // name keeps the draft open instead of closing the sheet.
                .onSubmit { submitNewTag() }

            if let candidates = autocompleteCandidates, !candidates.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(candidates, id: \.id) { tag in
                        Button {
                            newName = tag.name
                            newColor = tag.colorHex
                        } label: {
                            Text(tag.name)
                                .font(.system(size: sz(11)))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(hex: tag.colorHex).opacity(0.15))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color(hex: tag.colorHex).opacity(0.5), lineWidth: 0.5)
                                )
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let conflict = nameConflict {
                Text(L10n.tagPickerNameConflict(conflict.name))
                    .font(.system(size: sz(10)))
                    .foregroundColor(.orange)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Tag.presetColors, id: \.self) { hex in
                        Button(action: { newColor = hex }, label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().stroke(Color.primary.opacity(hex == newColor ? 0.8 : 0.15),
                                                    lineWidth: hex == newColor ? 2 : 0.5)
                                )
                        })
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker(L10n.newTagCustomColor, selection: Binding(
                    get: { Color(hex: newColor) },
                    set: { newColor = $0.toHex() }
                ))
                .font(.system(size: sz(12)))
            }

            HStack {
                Button(L10n.buttonCancel) {
                    isCreating = false
                    newName = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                Spacer()
                Button(nameConflict != nil ? L10n.tagPickerUseExisting : L10n.tagPickerCreateButton) {
                    submitNewTag()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private func submitNewTag() {
        guard Self.submitNewTag(name: newName, colorHex: newColor, itemId: item.id, store: store) else {
            return
        }
        newName = ""
        isCreating = false
        // ID-VIEW-0004 (2026-07-31 audit): creating / attaching a tag via the
        // inline form is a mutation — mark it so Done enables (previously
        // only toggleAttachment / delete-confirm set this).
        hasChanges = true
    }

    /// Secondary CLIP-2: single submit implementation shared by the Create /
    /// Use-existing button and the TextField's `.onSubmit` (Return key).
    /// Extracted as a static so the regression test can drive it without a
    /// SwiftUI view tree.
    /// - Returns: `true` when a tag was attached (created or reused);
    ///   `false` when the trimmed name is empty — the caller keeps the
    ///   draft open so Return doesn't silently discard typed state.
    static func submitNewTag(name: String, colorHex: String, itemId: UUID, store: ClipboardStore) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let conflict = store.tags.values.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            // Reuse existing tag — just attach.
            store.addTag(to: itemId, tagId: conflict.id)
        } else {
            let tag = TagPickerLogic.makeTagManual(name: trimmed, colorHex: colorHex)
            store.addTag(tag)
            store.addTag(to: itemId, tagId: tag.id)
        }
        return true
    }

    // MARK: - onAppear

    private func loadSuggestions() async {
        let rawContent = store.getDecryptedContent(item) ?? item.content
        let facets = await Task.detached(priority: .userInitiated) {
            TagSuggestion.detect(for: item.type, content: rawContent)
        }.value
        // ID-LIFE-0009: guard against writing recycled @State after the sheet
        // dismissed (Task.detached.value doesn't propagate cancellation).
        guard !Task.isCancelled else { return }
        let existing = Array(store.tags.values)
        let names = TagSuggestion.tagNames(for: facets.kind)
        suggestionsToCreate = names.filter { name in
            !existing.contains(where: { $0.name == name })
        }
        suggestedNames = facets.names
    }
}

// MARK: - Long-press delete affordance

/// NSViewRepresentable wrapping NSPressGestureRecognizer at row level.
/// macOS's SwiftUI `.onLongPressGesture` works for buttons but is unreliable
/// inside List rows, so we drop down to AppKit for the delete confirmation.
struct TagRowLongPress: NSViewRepresentable {
    let onDelete: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = false
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis",
                                             accessibilityDescription: nil) ?? NSImage(),
                              target: context.coordinator,
                              action: #selector(Coordinator.trigger(_:)))
        button.bezelStyle = .smallSquare
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        let press = NSPressGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.5
        view.addGestureRecognizer(press)
        context.coordinator.onDelete = onDelete
        context.coordinator.button = button
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDelete = onDelete
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onDelete: (() -> Void)?
        weak var button: NSButton?
        @objc func pressed(_ sender: NSPressGestureRecognizer) {
            if sender.state == .began { onDelete?() }
        }
        @objc func trigger(_ sender: NSButton) { onDelete?() }
    }
}
