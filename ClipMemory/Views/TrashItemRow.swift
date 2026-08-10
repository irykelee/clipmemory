import SwiftUI
import AppKit

/// Row view for items in the recycle bin. Shows content preview, deletion
/// timestamp, and offers Restore / Permanently Delete actions.
struct TrashItemRow: View, Equatable {
    let item: ClipboardItem
    // L-16 (2026-07-25 audit): inject the store instead of reaching for the
    // singleton. Defaults to `.shared` so existing UI call sites and previews
    // keep working; tests can pass a mock instance.
    let store: ClipboardStore
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void
    /// NEW-batch-restore (2026-08-10): batch selection state — drives
    /// the explicit checkbox column at the row's leading edge. Owned by
    /// the parent `ItemListView` (selectedTrashIDs: Set<UUID>) so this
    /// row stays a pure renderer.
    let isSelected: Bool
    /// NEW-batch-restore: tap the checkbox to toggle selection. Kept
    /// separate from `onRestore`/`onDeletePermanently` so the parent can
    /// route each tap to a distinct action.
    let onToggleSelection: () -> Void

    @State private var isHovered = false
    // F-3 (2026-07-23 audit): keyboard users Tab through the trash list
    // but the Restore / Delete buttons were hidden by `.opacity(isHovered
    // ? 1 : 0)` — invisible to anyone not using a mouse. Track row
    // focus and reveal the buttons when the row is focused OR hovered.
    @FocusState private var isFocused: Bool
    @State private var loadedImage: NSImage?
    @State private var loadedContent: String?
    // ID-VIEW-0009 (2026-08-01 audit): bump from the .cryptoKeyPrepared
    // observer below to re-fire the content .task after a key-race miss —
    // same mechanism as ClipboardItemRow (ID-VIEW-0002).
    @State private var decryptRetryToken = 0
    @State private var imageLoadFailed = false
    @State private var imageLoadStatus: ImageStorage.ImageLoadStatus?
    @State private var imageLongPressing = false
    @State private var pendingDelete = false
    // CLIP-3 (2026-07-24 review): same guard as ClipboardItemRow — fontScale
    // is only the invalidation trigger; all sizing goes through sz().
    @AppStorage("fontScale") private var fontScale: Double = 1.0

    static func == (lhs: TrashItemRow, rhs: TrashItemRow) -> Bool {
        lhs.item.id == rhs.item.id && lhs.isSelected == rhs.isSelected
    }

    private var rowBackground: Color {
        isHovered ? Color.accentColor.opacity(0.06) : Color.clear
    }

    // BUG-042 (2026-07-21): cache the formatter. Without this, every
    // scroll-frame during list scrolling allocates a new formatter per
    // visible row — visible perf hit on long trash lists.
    private static let deletedAtFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        return f
    }()

    private var formattedDeletedAt: String {
        guard let deletedAt = item.deletedAt else { return "" }
        return Self.deletedAtFormatter.localizedString(for: deletedAt, relativeTo: Date())
    }

    var body: some View {
        // 2026-07-25: reading fontScale subscribes this view to @AppStorage
        // invalidation — an unread wrapper creates no dependency, so
        // font-size changes never re-rendered. See ClipboardItemRow.
        let _ = fontScale
        HStack(alignment: .center, spacing: 8) {
            // NEW-batch-restore (2026-08-10): explicit selection column.
            // Always visible (not just when ≥1 selected) so users see how
            // to multi-select without trial-and-error. Toggle via the button's
            // own action — does NOT interfere with the inline Restore/Delete
            // buttons (Button hits don't propagate to row tap).
            Button(action: onToggleSelection) {
                SelectCheckbox(
                    shape: .circle,
                    state: isSelected ? .selected : .unselected
                )
            }
            .buttonStyle(.plain)
            .help(isSelected ? L10n.trashDeselectItem : L10n.trashSelectItem)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    if item.type == .image {
                        Group {
                            if let ns = loadedImage {
                                Image(nsImage: ns)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 80)
                                    .overlay(PressableImage { pressed in imageLongPressing = pressed }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity))
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial)
                                    if imageLoadFailed {
                                        let status = imageLoadStatus ?? .fileMissing
                                        VStack(spacing: 4) {
                                            Image(systemName: status == .decryptionFailed ? "lock.slash" : "exclamationmark.triangle")
                                                .font(.system(size: sz(22)))
                                                .foregroundColor(status == .decryptionFailed ? .secondary : .orange)
                                            Text(status == .decryptionFailed ? L10n.imageDecryptionFailed : L10n.imageMissing)
                                                .font(.system(size: sz(11)))
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        VStack(spacing: 4) {
                                            Image(systemName: "photo").font(.system(size: sz(24))).foregroundColor(.secondary)
                                            ProgressView().scaleEffect(0.5).frame(height: 8)
                                        }
                                    }
                                }
                                .frame(width: 120, height: 80)
                            }
                        }
                        .onChange(of: imageLongPressing) { pressing in
                            if pressing, let ns = loadedImage {
                                ImagePreviewPanel.show(image: ns)
                            } else {
                                ImagePreviewPanel.hide()
                            }
                        }
                        .onDisappear { ImagePreviewPanel.hide() }
                        .task(id: item.content) {
                            if store.imageMissingIds.contains(item.id) {
                                imageLoadFailed = true
                                imageLoadStatus = .fileMissing
                                return
                            }
                            if store.imageCorruptedIds.contains(item.id) {
                                imageLoadFailed = true
                                imageLoadStatus = .decryptionFailed
                                return
                            }
                            imageLoadFailed = false
                            imageLoadStatus = nil
                            let filename = item.content
                            // BUG-029 (2026-07-21): same split as
                            // ClipboardItemRow — loadImageObject stays on
                            // a detached thread; status-on-miss path now
                            // hops through imageStatusAsync so the legacy
                            // decrypt + migrationQueue.sync doesn't starve
                            // the cooperative thread pool.
                            let img: NSImage? = await Task.detached(priority: .userInitiated) {
                                ImageStorage.shared.loadImageObject(filename: filename)
                            }.value
                            let status: ImageStorage.ImageLoadStatus? = img == nil
                                ? await ImageStorage.shared.imageStatusAsync(for: filename)
                                : nil
                            let result = (img, status) as (NSImage?, ImageStorage.ImageLoadStatus?)
                            // I-8 fix (2026-07-20 audit): `Task.detached` does not
                            // inherit cancellation from the parent `.task(id:)`
                            // body. If the user scrolled away (item.content
                            // changed), the detached task keeps running in the
                            // background and our await eventually delivers a
                            // stale result that flashes the old image before
                            // the new row's task replaces it. Drop the result
                            // when the parent has been cancelled — the new
                            // row's task will populate state under its own id.
                            if Task.isCancelled { return }
                            if let img = result.0 {
                                loadedImage = img
                            } else {
                                imageLoadFailed = true
                                imageLoadStatus = result.1
                            }
                        }
                    } else if item.type == .richText {
                        Text(plainTextFallback)
                            .font(.system(size: sz(12))).foregroundColor(.secondary)
                            .lineLimit(3)
                    } else {
                        Text(loadedContent ?? "")
                            .font(.system(size: sz(12))).foregroundColor(Color(nsColor: .controlTextColor))
                            .lineLimit(3)
                    }
                }
                HStack {
                    if item.isSensitive {
                        Label(L10n.itemSensitive, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: sz(10)))
                            .foregroundColor(.orange)
                    }
                    if item.isPinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: sz(10)))
                            .foregroundColor(.orange)
                    }
                    Text(formattedDeletedAt)
                        .font(.system(size: sz(11)))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Button(action: onRestore) {
                    Label(L10n.trashRestore, systemImage: "arrow.uturn.left")
                        .font(.system(size: sz(12)))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                // F-2 (2026-07-23 audit): explicit a11y label so VoiceOver
                // announces the action. The `Label(...)` above already
                // provides visible text, but VoiceOver ignores `.help()`.
                .accessibilityLabel(L10n.trashRestore)
                .help(L10n.trashRestore)

                // F-1 + F-2 (2026-07-23 audit): wrap destructive permanent
                // delete in a confirmation dialog (one mis-click = data
                // loss otherwise) and give the icon-only button a VoiceOver
                // label — pure SF Symbols give VoiceOver no functional hint.
                Button {
                    pendingDelete = true
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: sz(12)))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .accessibilityLabel(L10n.actionDelete)
                .help(L10n.actionDelete)
            }
            .opacity(isHovered || isFocused ? 1 : 0)
        }
        // ID-VIEW-0001 (2026-07-31): this task loads text/link content.
        // It used to hang on the image branch's Group above (M14, 5f1ce38),
        // so it never ran for .text/.link items and the row rendered "".
        // Row-level attachment matches ClipboardItemRow.swift.
        // ID-VIEW-0009 (2026-08-01 audit): `decryptRetryToken` lets the
        // .cryptoKeyPrepared observer below re-fire this task after a
        // key-race double miss — mirrors ClipboardItemRow (ID-VIEW-0002).
        .task(id: "\(item.id.uuidString)-\(decryptRetryToken)") {
            guard item.type != .richText, item.type != .image else { return }
            if loadedContent != nil { return }
            let first = await Task.detached(priority: .utility) {
                store.getDecryptedContent(item) ?? ""
            }.value
            if Task.isCancelled { return }
            if !first.isEmpty {
                loadedContent = first
                return
            }
            // Empty result — likely a key race (prepareKey still in flight
            // on a fresh launch / login-item start with Keychain locked).
            // Retry once after a short delay; if the second attempt also
            // misses, keep loadedContent == nil and let the
            // .cryptoKeyPrepared observer below re-run this task once the
            // key lands. ID-VIEW-0009: write only a non-empty result —
            // storing "" made `loadedContent != nil` early-return on every
            // later pass, leaving the row blank for the whole session
            // (window + hosting controller persist @State).
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let second = await Task.detached(priority: .utility) {
                store.getDecryptedContent(item) ?? ""
            }.value
            if Task.isCancelled { return }
            if !second.isEmpty {
                loadedContent = second
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cryptoKeyPrepared)) { note in
            // ID-VIEW-0009 (2026-08-01 audit): the crypto key landed after
            // our decrypt attempts missed — bump the token in the .task id
            // so the task re-runs. Guards keep this a no-op for rows that
            // already have content or don't need decryption here.
            let success = (note.userInfo?["success"] as? Bool) ?? false
            guard success else { return }
            guard item.type != .richText, item.type != .image, loadedContent == nil else { return }
            decryptRetryToken += 1
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        .cornerRadius(6)
        .onHover { hovering in isHovered = hovering }
        // F-3 (2026-07-23 audit): make the row focusable so keyboard users
        // can Tab to it from the trash list. Pair with `.focused` so the
        // action buttons become visible (see opacity change above).
        .focusable()
        .focused($isFocused)
        // F-1 confirmation dialog. The `role: .destructive` button
        // surfaces the system red "Delete" label; cancel is `role: .cancel`
        // so ⌘. / Esc dismiss without action.
        .confirmationDialog(
            L10n.trashDeleteConfirmTitle,
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.trashDeleteConfirmConfirm, role: .destructive) {
                onDeletePermanently()
            }
            Button(L10n.buttonCancel, role: .cancel) {}
        } message: {
            Text(deleteConfirmationSnippet)
        }
    }

    /// Short preview shown in the F-1 confirmation dialog so the user can
    /// verify which item they're about to destroy. Images get a generic
    /// "[image]" label rather than a binary blob.
    private var deleteConfirmationSnippet: String {
        switch item.type {
        case .image:
            return L10n.itemImage
        case .richText:
            return store.getRTFPlaintext(item).prefix(80).description
        default:
            return store.getDecryptedContent(item).map {
                String($0.prefix(80))
            } ?? ""
        }
    }

    private var plainTextFallback: String {
        // ID-VIEW-0005 (2026-07-31 audit): use the injected store (L-16)
        // instead of bypassing DI via ClipboardStore.shared.
        store.getRTFPlaintext(item)
    }
}
