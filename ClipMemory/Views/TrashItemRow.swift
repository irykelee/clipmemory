import SwiftUI
import AppKit

/// Row view for items in the recycle bin. Shows content preview, deletion
/// timestamp, and offers Restore / Permanently Delete actions.
struct TrashItemRow: View, Equatable {
    let item: ClipboardItem
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void

    @State private var isHovered = false
    @State private var loadedImage: NSImage?
    @State private var imageLoadFailed = false
    @State private var imageLoadStatus: ImageStorage.ImageLoadStatus?
    @State private var imageLongPressing = false
    @AppStorage("fontScale") private var fontScale: Double = 1.0

    static func == (lhs: TrashItemRow, rhs: TrashItemRow) -> Bool {
        lhs.item.id == rhs.item.id
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

    private var decryptedContent: String {
        ClipboardStore.shared.getDecryptedContent(item) ?? ""
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
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
                                                .font(.system(size: fontScale * 22))
                                                .foregroundColor(status == .decryptionFailed ? .secondary : .orange)
                                            Text(status == .decryptionFailed ? L10n.imageDecryptionFailed : L10n.imageMissing)
                                                .font(.system(size: fontScale * 11))
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        VStack(spacing: 4) {
                                            Image(systemName: "photo").font(.system(size: fontScale * 24)).foregroundColor(.secondary)
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
                            imageLoadFailed = false
                            imageLoadStatus = nil
                            let filename = item.content
                            let result: (NSImage?, ImageStorage.ImageLoadStatus?) = await Task.detached(priority: .userInitiated) {
                                if let img = ImageStorage.shared.loadImageObject(filename: filename) {
                                    return (img, nil)
                                }
                                return (nil, ImageStorage.shared.imageStatus(for: filename))
                            }.value
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
                            .font(.system(size: fontScale * 12)).foregroundColor(.secondary)
                            .lineLimit(3)
                    } else {
                        Text(decryptedContent)
                            .font(.system(size: fontScale * 12)).foregroundColor(Color(nsColor: .controlTextColor))
                            .lineLimit(3)
                    }
                }
                HStack {
                    if item.isSensitive {
                        Label(L10n.itemSensitive, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: fontScale * 10))
                            .foregroundColor(.orange)
                    }
                    if item.isPinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: fontScale * 10))
                            .foregroundColor(.orange)
                    }
                    Text(formattedDeletedAt)
                        .font(.system(size: fontScale * 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Button(action: onRestore) {
                    Label(L10n.trashRestore, systemImage: "arrow.uturn.left")
                        .font(.system(size: fontScale * 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Button(action: onDeletePermanently) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: fontScale * 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        .cornerRadius(6)
        .onHover { hovering in isHovered = hovering }
    }

    private var plainTextFallback: String {
        ClipboardStore.shared.getRTFPlaintext(item)
    }
}
