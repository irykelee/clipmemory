import SwiftUI

/// Sheet for creating a brand-new tag from the sidebar's "+ 新建标签"
/// button. Independent of TagPickerSheet (which is per-item); here the
/// goal is just "create a tag" — no item to attach to.
///
/// Behaviour on submit:
/// - Fresh name → creates a `Tag` (isAutoSuggested=false), returns its id
///   via `onCreated`, dismisses.
/// - Existing name (exact match after trimming) → returns the existing
///   tag's id via `onCreated`, dismisses. No new tag is created.
/// - Empty/whitespace name → submit button disabled, no-op.
struct NewTagSheet: View {
    @ObservedObject var store: ClipboardStore
    /// Called with the tag id (created or reused). ContentView uses this to
    /// add the new tag to `selectedTagIds` so the user immediately sees
    /// the result of their action in the sidebar.
    let onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: String = Tag.presetColors.first ?? "#4ECDC4"

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var nameConflict: Tag? {
        guard !trimmedName.isEmpty else { return nil }
        return store.tags.values.first { $0.name.lowercased() == trimmedName.lowercased() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField(L10n.tagPickerCreate, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: sz(12)))
                    .onSubmit(submit)

                if let conflict = nameConflict {
                    Text(L10n.tagPickerNameConflict(conflict.name))
                        .font(.system(size: sz(10)))
                        .foregroundColor(.orange)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(Tag.presetColors, id: \.self) { hex in
                            Button(action: { color = hex }, label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle().stroke(
                                            Color.primary.opacity(hex == color ? 0.8 : 0.15),
                                            lineWidth: hex == color ? 2 : 0.5
                                        )
                                    )
                            })
                            .buttonStyle(.plain)
                        }
                    }
                    ColorPicker(L10n.newTagCustomColor, selection: Binding(
                        get: { Color(hex: color) },
                        set: { color = $0.toHex() }
                    ))
                    .font(.system(size: sz(12)))
                }

                HStack {
                    Button(L10n.buttonCancel, role: .cancel, action: { dismiss() })
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(nameConflict != nil ? L10n.tagPickerUseExisting : L10n.newTagCreate,
                           action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 320, height: 240)
        .onAppear {
            color = TagPickerLogic.defaultColorHex(existingTags: Array(store.tags.values))
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.newTagTitle).font(.system(size: sz(14), weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit() {
        guard let result = NewTagLogic.submit(name: name, colorHex: color, store: store) else {
            return
        }
        let id: UUID
        switch result {
        case .created(let created): id = created
        case .reused(let existing): id = existing
        }
        onCreated(id)
        dismiss()
    }
}
