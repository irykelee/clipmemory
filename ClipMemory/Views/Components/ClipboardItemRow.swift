import SwiftUI
import AppKit

// MARK: - AppKit NSPressGestureRecognizer for stable image long-press
struct PressableImage: NSViewRepresentable {
    let onPressChanged: (Bool) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = LongPressView(onPressChanged: context.coordinator.onPressChanged)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LongPressView)?.onPressChanged = context.coordinator.onPressChanged
    }
    func makeCoordinator() -> Coordinator { Coordinator(onPressChanged: onPressChanged) }
    class Coordinator {
        var onPressChanged: (Bool) -> Void
        init(onPressChanged: @escaping (Bool) -> Void) { self.onPressChanged = onPressChanged }
    }
}

class LongPressView: NSView {
    var onPressChanged: (Bool) -> Void
    private var pressGesture: NSPressGestureRecognizer!

    init(onPressChanged: @escaping (Bool) -> Void) {
        self.onPressChanged = onPressChanged
        super.init(frame: .zero)
        pressGesture = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        pressGesture.minimumPressDuration = 0.4
        pressGesture.buttonMask = 0x1 // left mouse button
        addGestureRecognizer(pressGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handlePress(_ sender: NSPressGestureRecognizer) {
        let isPressed = sender.state == .began || sender.state == .changed
        DispatchQueue.main.async { self.onPressChanged(isPressed) }
    }

    deinit {
        if let gesture = pressGesture {
            removeGestureRecognizer(gesture)
        }
    }
}

struct ClipboardItemRow: View, Equatable {
    let item: ClipboardItem
    let isRevealed: Bool
    var isKeyboardSelected = false
    var isCopied = false
    var isSelected = false
    var searchText = ""
    var onCopyWithFeedback: (() -> Void)?
    let onPin: () -> Void
    let onDelete: () -> Void
    let onSelect: ((Bool) -> Void)?
    let onToggleReveal: () -> Void
    var onEditTags: () -> Void = { }
    @State private var isHovered = false
    @State private var loadedImage: NSImage?
    @State private var loadedContent: String?
    @State private var longPressing = false
    @State private var imageLongPressing = false
    @State private var showFullContent = false
    @State private var _cachedHighlighted: [String: AttributedString] = [:]
    @State private var loadedRichText: AttributedString?
    /// True after the .task attempted to load the image and got nil.
    /// The companion `imageLoadStatus` tells us whether the file is missing
    /// or decryption failed, so we only offer one-click delete for true orphans.
    @State private var imageLoadFailed = false
    @State private var imageLoadStatus: ImageStorage.ImageLoadStatus?

    static func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.isRevealed == rhs.isRevealed &&
        lhs.isCopied == rhs.isCopied &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isKeyboardSelected == rhs.isKeyboardSelected &&
        lhs.searchText == rhs.searchText &&
        lhs.item.isPinned == rhs.item.isPinned &&
        lhs.item.tagIds == rhs.item.tagIds &&
        lhs.item.createdAt == rhs.item.createdAt &&
        lhs.item.decryptionFailed == rhs.item.decryptionFailed
    }
    @State private var _cachedMaskedHighlighted: [String: AttributedString] = [:]
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    private var iconSize: CGFloat { fontScale * 13 }

    /// Explicit memberwise initializer so callers (ContentView) can name
    /// every prop including `onEditTags`. Kept identical to Swift's auto
    /// memberwise init; just declared here for clarity and to avoid
    /// @ViewBuilder inferring a no-arg init when used inline.
    init(item: ClipboardItem,
         isRevealed: Bool,
         isKeyboardSelected: Bool = false,
         isCopied: Bool = false,
         isSelected: Bool = false,
         searchText: String = "",
         onCopyWithFeedback: (() -> Void)? = nil,
         onPin: @escaping () -> Void,
         onDelete: @escaping () -> Void,
         onSelect: ((Bool) -> Void)? = nil,
         onToggleReveal: @escaping () -> Void,
         onEditTags: @escaping () -> Void = {}) {
        self.item = item
        self.isRevealed = isRevealed
        self.isKeyboardSelected = isKeyboardSelected
        self.isCopied = isCopied
        self.isSelected = isSelected
        self.searchText = searchText
        self.onCopyWithFeedback = onCopyWithFeedback
        self.onPin = onPin
        self.onDelete = onDelete
        self.onSelect = onSelect
        self.onToggleReveal = onToggleReveal
        self.onEditTags = onEditTags
    }

    private var rowBackground: Color {
        if isCopied { Color.green.opacity(0.12) } else if isSelected { Color.accentColor.opacity(0.10) } else if isHovered || isKeyboardSelected { Color.accentColor.opacity(0.06) } else if item.isSensitive { Color.orange.opacity(0.04) } else { Color.clear }
    }
    private var pinText: String { item.isPinned ? L10n.actionUnpin : L10n.actionPin }
    private var decryptedContent: String {
        loadedContent ?? ClipboardStore.shared.getDecryptedContent(item) ?? ""
    }
    private var formattedDate: String {
        cachedAbsoluteDateFormatter(for: LanguageManager.shared.selectedLanguage).string(from: item.createdAt)
    }

    private var cachedHighlighted: AttributedString {
        let cacheKey = "\(item.id.uuidString)-\(searchText)"
        if let cached = _cachedHighlighted[cacheKey] { return cached }
        let result = highlightedContent(decryptedContent, highlight: searchText)
        _cachedHighlighted[cacheKey] = result
        return result
    }
    private var cachedMaskedHighlighted: AttributedString {
        let cacheKey = "\(item.id.uuidString)-\(searchText)"
        if let cached = _cachedMaskedHighlighted[cacheKey] { return cached }
        let result = maskedHighlightedContent(decryptedContent, highlight: searchText)
        _cachedMaskedHighlighted[cacheKey] = result
        return result
    }

    private func highlightedContent(_ text: String, highlight: String) -> AttributedString {
        if highlight.isEmpty { return AttributedString(String(text.prefix(200))) }
        let lt = text.lowercased(), lh = highlight.lowercased()
        guard lt.range(of: lh) != nil else { return AttributedString(String(text.prefix(200))) }
        let fm = lt.range(of: lh)!
        let mso = lt.distance(from: lt.startIndex, to: fm.lowerBound)
        var prefix = ""
        let dsi: String.Index
        if mso > 30 { dsi = text.index(text.index(text.startIndex, offsetBy: mso), offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex; prefix = "..." } else { dsi = text.startIndex }
        let dei = text.index(dsi, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
        let ds = String(text[dsi..<dei])
        let prefixLen = prefix.count
        var a = AttributedString(prefix + ds)
        let lowerDS = ds.lowercased()
        // Compute highlight positions relative to ds, not lt
        let dsStartOffset = lt.distance(from: lt.startIndex, to: dsi)
        guard let fmInDS = lowerDS.range(of: lh) else { return a }
        var ss = fmInDS.lowerBound
        while let r = lowerDS.range(of: lh, range: ss..<lowerDS.endIndex) {
            let startOff = lowerDS.distance(from: lowerDS.startIndex, to: r.lowerBound)
            let endOff = startOff + lowerDS.distance(from: r.lowerBound, to: r.upperBound)
            if startOff < 200 {
                let si = a.index(a.startIndex, offsetByCharacters: prefixLen + startOff)
                let ei = a.index(a.startIndex, offsetByCharacters: min(prefixLen + endOff, prefixLen + 200))
                a[si..<ei].backgroundColor = .cyan.opacity(0.3)
                a[si..<ei].foregroundColor = .primary
            }
            ss = r.upperBound
        }
        return a
    }
    private func maskContent(_ c: String) -> String { c.count <= 4 ? String(repeating: "\u{2022}", count: c.count) : String(c.prefix(2)) + String(repeating: "\u{2022}", count: c.count - 4) + String(c.suffix(2)) }
    private func maskedHighlightedContent(_ content: String, highlight: String, ctx: Int = 15) -> AttributedString {
        if highlight.isEmpty { var a = AttributedString(maskContent(content)); a.foregroundColor = .orange; return a }
        let lc = content.lowercased(), lh = highlight.lowercased(); var vis: [Range<String.Index>] = []; var ss = lc.startIndex
        while let r = lc.range(of: lh, range: ss..<lc.endIndex) { let cs = lc.index(r.lowerBound, offsetBy: -ctx, limitedBy: lc.startIndex) ?? lc.startIndex; let ce = lc.index(r.upperBound, offsetBy: ctx, limitedBy: lc.endIndex) ?? lc.endIndex; vis.append(cs..<ce); ss = r.upperBound }
        guard !vis.isEmpty else { return AttributedString(maskContent(content)) }; vis.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []; for r in vis { if let last = merged.last, last.upperBound >= r.lowerBound { merged[merged.count-1] = last.lowerBound..<max(last.upperBound, r.upperBound) } else { merged.append(r) } }
        var res = AttributedString(); var ci = content.startIndex
        for r in merged { if ci < r.lowerBound { var b = AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: r.lowerBound))); b.foregroundColor = .orange; res += b }; var h = AttributedString(String(content[r])); h.backgroundColor = .blue.opacity(0.15); h.foregroundColor = .primary; res += h; ci = r.upperBound }
        if ci < content.endIndex { var t = AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: content.endIndex))); t.foregroundColor = .orange; res += t }
        return res
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: { onSelect?(!isSelected) }, label: { Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.system(size: iconSize)).foregroundColor(isSelected ? .accentColor : .secondary).frame(width: 22, height: 22) }).buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    if item.type == .image {
                        Group {
                            if let ns = loadedImage {
                                Image(nsImage: ns)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: imageLongPressing ? 300 : 80)
                                    .overlay(PressableImage { pressed in imageLongPressing = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                                    .transition(.opacity)
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
                                        // (delete button removed — the per-row trash icon at the end of
                                        //  each row already provides this action; the contextual x in the
                                        //  badge had unreliable hit testing due to its position outside the
                                        //  120×80 badge frame)
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
                        .animation(.easeIn(duration: 0.3), value: loadedImage)
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
                            if let img = result.0 {
                                loadedImage = img
                            } else {
                                imageLoadFailed = true
                                imageLoadStatus = result.1
                            }
                        }
                    } else if item.type == .richText {
                        if item.isSensitive && !isRevealed {
                            Text(longPressing ? cachedHighlighted : cachedMaskedHighlighted)
                                .font(.system(size: fontScale * 13)).lineLimit(3)
                                .overlay(PressableImage { pressed in longPressing = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                        } else {
                            Group {
                                if let rt = loadedRichText {
                                    Text(rt)
                                        .lineLimit(showFullContent ? nil : 3)
                                        .overlay(PressableImage { pressed in showFullContent = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                                        .transition(.opacity)
                                } else {
                                    Text(plainTextFallback)
                                        .font(.system(size: fontScale * 12)).foregroundColor(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .animation(.easeIn(duration: 0.3), value: loadedRichText)
                            .task(id: item.content) { await loadRichText() }
                        }
                    } else if item.isSensitive && !isRevealed {
                        Text(longPressing ? cachedHighlighted : cachedMaskedHighlighted)
                            .font(.system(size: fontScale * 13)).lineLimit(3)
                            .overlay(PressableImage { pressed in longPressing = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                    } else {
                        Text(showFullContent ? AttributedString(decryptedContent) : cachedHighlighted)
                            .font(.system(size: fontScale * 12)).foregroundColor(Color(nsColor: .controlTextColor))
                            .lineLimit(showFullContent ? nil : 3)
                            .overlay(PressableImage { pressed in showFullContent = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                HStack(spacing: 8) { Text(formattedDate).font(.system(size: fontScale * 11)).foregroundColor(.primary.opacity(0.55)); if item.isSensitive { Label(L10n.itemSensitive, systemImage: "exclamationmark.shield").font(.system(size: fontScale * 11)).foregroundColor(.orange) }; if !item.tagIds.isEmpty { TagChipStack(tagIds: item.tagIds, store: ClipboardStore.shared) } }
            }
            .contentShape(Rectangle())
            .gesture(ExclusiveGesture(TapGesture(count: 2).onEnded { onPin() }, TapGesture().onEnded { onCopyWithFeedback?() }))
            HStack(spacing: 6) {
                Button(action: onEditTags) {
                    Image(systemName: "tag")
                        .font(.system(size: iconSize))
                        .foregroundColor(item.tagIds.isEmpty ? .secondary : .accentColor)
                        .frame(width: 24, height: 24)
                        .overlay(alignment: .topTrailing) {
                            if !item.tagIds.isEmpty {
                                Text("\(item.tagIds.count)")
                                    .font(.system(size: fontScale * 8))
                                    .padding(2)
                                    .background(Color.accentColor, in: Circle())
                                    .foregroundColor(.white)
                                    .offset(x: 4, y: -4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(L10n.tooltipEditTags)
                .accessibilityLabel(L10n.tooltipEditTags)
                Button(action: onPin) { Image(systemName: item.isPinned ? "star.fill" : "star").font(.system(size: iconSize)).foregroundColor(item.isPinned ? .orange : .secondary).frame(width: 24, height: 24) }.buttonStyle(.plain).help(item.isPinned ? L10n.tooltipUnpin : L10n.tooltipPin)
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: iconSize)).foregroundColor(.secondary).frame(width: 24, height: 24) }.buttonStyle(.plain).help(L10n.tooltipDelete)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(rowBackground).animation(.easeOut(duration: 0.3), value: isCopied).contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(action: { onCopyWithFeedback?() }, label: {
                Label(L10n.actionCopy, systemImage: "doc.on.doc")
            })
            if item.type == .image {
                Button(action: copyOcrText, label: {
                    Label(L10n.itemOcrCopy, systemImage: "text.viewfinder")
                })
                .disabled(item.ocrText == nil)
            }
            if item.isSensitive {
                Button(action: onToggleReveal, label: {
                    Label(isRevealed ? L10n.actionHideContent : L10n.actionShowContent,
                          systemImage: isRevealed ? "eye.slash" : "eye")
                })
            }
            Button(action: onPin, label: {
                Label(pinText, systemImage: item.isPinned ? "star.slash" : "star")
            })
            Divider()
            Button(action: onEditTags, label: {
                Label(L10n.tooltipEditTags, systemImage: "tag")
            })
            Divider()
            Button(role: .destructive, action: onDelete, label: {
                Label(L10n.actionDelete, systemImage: "trash")
            })
        }
        .task(id: item.id) {
            guard item.type != .richText, item.type != .image else { return }
            if loadedContent != nil { return }
            let result = await Task.detached(priority: .utility) {
                ClipboardStore.shared.getDecryptedContent(item) ?? ""
            }.value
            loadedContent = result
        }
    }

    private var plainTextFallback: String {
        guard item.type == .richText else { return "" }
        guard let base64 = ClipboardStore.shared.getDecryptedContent(item),
              let rtfData = Data(base64Encoded: base64),
              let nsAttr = try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return L10n.itemRichText
        }
        return nsAttr.string
    }

    private func loadRichText() async {
        guard item.type == .richText else { return }
        guard let base64 = ClipboardStore.shared.getDecryptedContent(item),
              let rtfData = Data(base64Encoded: base64),
              let nsAttr = try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return
        }
        let rt = AttributedString(nsAttr)
        let plain = nsAttr.string
        await MainActor.run {
            loadedRichText = rt
            loadedContent = plain
        }
    }

    /// Copies the OCR-recognized text of this image item to the pasteboard.
    /// The app's own copy-loop interception means this won't create a new
    /// history entry.
    private func copyOcrText() {
        guard let text = ClipboardStore.shared.getDecryptedOcrText(item), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
