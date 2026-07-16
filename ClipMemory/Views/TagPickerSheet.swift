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
    @State private var suggestionsToCreate: [String] = []
    @State private var isCreating = false
    @State private var newName = ""
    @State private var newColor: String = Tag.presetColors.first ?? "#4ECDC4"
    @State private var pendingDelete: Tag?

    private var allTagsSorted: [Tag] {
        store.tags.values.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewBlock
                    if !suggestionsToCreate.isEmpty { suggestionsBlock }
                    allTagsBlock
                    createBlock
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 500)
        .onAppear(perform: loadSuggestions)
        .alert(L10n.tagPickerDeleteConfirmTitle,
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button(L10n.buttonCancel, role: .cancel) { pendingDelete = nil }
            Button(L10n.tagPickerDeleteConfirmConfirm, role: .destructive) {
                if let tag = pendingDelete {
                    store.deleteTag(id: tag.id)
                }
                pendingDelete = nil
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
            Button(L10n.buttonDone) { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: sz(12)))
                .foregroundColor(.accentColor)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Preview

    private var previewBlock: some View {
        let preview = store.getDecryptedContent(item) ?? item.content
        return HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundColor(.secondary)
            Text(String(preview.prefix(60)))
                .font(.system(size: sz(11)))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
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
                        let tag = TagPickerLogic.makeTag(from: .create(name), colorHex: newColor)
                        store.addTag(tag)
                        store.addTag(to: item.id, tagId: tag.id)
                        suggestionsToCreate.removeAll { $0 == name }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus").font(.system(size: 9))
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

    private var allTagsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tagPickerSectionAllTags)
                .font(.system(size: sz(11), weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(allTagsSorted, id: \.id) { tag in
                tagRow(tag)
            }
            if allTagsSorted.isEmpty {
                Text("—").foregroundColor(.secondary).font(.system(size: sz(11)))
            }
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        let isAttached = item.tagIds.contains(tag.id)
        return HStack(spacing: 8) {
            // Tap anywhere on row = toggle attachment
            Button(action: { toggleAttachment(tag: tag) }, label: {
                HStack(spacing: 8) {
                    Image(systemName: isAttached ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isAttached ? .accentColor : .secondary)
                        .font(.system(size: 14))
                    TagChip(tag: tag)
                    Spacer()
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)

            // Long-press for delete confirmation
            TagRowLongPress(onDelete: { pendingDelete = tag })
        }
        .padding(.vertical, 2)
    }

    private func toggleAttachment(tag: Tag) {
        if item.tagIds.contains(tag.id) {
            store.removeTag(from: item.id, tagId: tag.id)
        } else {
            store.addTag(to: item.id, tagId: tag.id)
        }
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
        store.tags.values.first { $0.name == trimmedName }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.tagPickerCreate, text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: sz(12)))

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
        if let conflict = nameConflict {
            // Reuse existing tag — just attach.
            store.addTag(to: item.id, tagId: conflict.id)
        } else {
            let tag = TagPickerLogic.makeTagManual(name: trimmedName, colorHex: newColor)
            store.addTag(tag)
            store.addTag(to: item.id, tagId: tag.id)
        }
        newName = ""
        isCreating = false
    }

    // MARK: - onAppear

    private func loadSuggestions() {
        let content = store.getDecryptedContent(item) ?? item.content
        let names = TagSuggestion.suggest(for: item.type, content: content)
        let existing = Array(store.tags.values)
        // Auto-attach suggestions that already exist (by name) but aren't attached yet.
        for name in names {
            if let hit = existing.first(where: { $0.name == name }),
               !item.tagIds.contains(hit.id) {
                store.addTag(to: item.id, tagId: hit.id)
            }
        }
        // Surface only names that DON'T already exist as tags.
        suggestionsToCreate = names.filter { name in
            !existing.contains(where: { $0.name == name })
        }
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