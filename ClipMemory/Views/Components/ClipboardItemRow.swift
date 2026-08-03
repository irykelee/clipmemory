import SwiftUI
import AppKit

// BUG-009 (2026-07-22): NSCache-backed memoization (not @State) so
// writes during view-body evaluation do not trigger "Modifying state
// during view update." countLimit prevents unbounded growth.
private let highlightedCache: NSCache<NSString, NSAttributedString> = {
    let c = NSCache<NSString, NSAttributedString>()
    c.countLimit = 500
    return c
}()
private let maskedHighlightedCache: NSCache<NSString, NSAttributedString> = {
    let c = NSCache<NSString, NSAttributedString>()
    c.countLimit = 500
    return c
}()
// Spec §3.1: OCR highlight cache, count-limited like the existing two caches.
// FILE-SCOPE (not inside struct) — shared across all ClipboardItemRow
// instances, mirroring `highlightedCache` / `maskedHighlightedCache` above.
// Key includes ocrText.hashValue so a fresh OCR result (different ciphertext)
// invalidates the cache (review 1.3).
private let highlightedOcrCache: NSCache<NSString, NSAttributedString> = {
    let c = NSCache<NSString, NSAttributedString>()
    c.countLimit = 500
    return c
}()

// MARK: - AppKit NSPressGestureRecognizer for stable image long-press
struct PressableImage: NSViewRepresentable {
    let onPressChanged: (Bool) -> Void
    // ID-A11Y-0002 (2026-07-30 audit): expose accessibilityLabel so VoiceOver
    // reads a meaningful name (e.g. "图片缩略图，长按显示预览") instead of
    // being silent. Default to L10n.itemImage so callers can omit.
    var accessibilityLabel: String = L10n.itemImage

    func makeNSView(context: Context) -> NSView {
        let v = LongPressView(onPressChanged: context.coordinator.onPressChanged)
        v.setAccessibilityLabel(accessibilityLabel)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LongPressView)?.onPressChanged = context.coordinator.onPressChanged
        nsView.setAccessibilityLabel(accessibilityLabel)
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
    // L-17 (2026-07-25 audit): inject the store instead of reaching for the
    // singleton. Defaults to `.shared` so existing UI call sites and previews
    // keep working; tests can pass a mock / observed instance.
    let store: ClipboardStore
    let isRevealed: Bool
    var isKeyboardSelected = false
    var isCopied = false
    var isSelected = false
    var searchText = ""
    /// Debounced copy of `searchText` (250ms). Used for the OCR snippet so we
    /// don't flash snippet text on rows that won't survive the next filter
    /// pass. See `cachedHighlightedOcr` for usage.
    var searchTextDebounced = ""
    var onCopyWithFeedback: (() -> Void)?
    let onPin: () -> Void
    let onDelete: () -> Void
    let onSelect: ((Bool) -> Void)?
    let onToggleReveal: () -> Void
    var onEditTags: () -> Void = { }
    @State private var isHovered = false
    // E-13 (2026-07-23 audit): the row reads LanguageManager.shared
    // for `cachedAbsoluteDateFormatter(for:)` (line ~140) but didn't
    // observe it. Switching language via Settings → Language wouldn't
    // re-render the row's date label until the row scrolled off + on
    // (item.id task re-firing). Subscribe so language changes trigger
    // an immediate refresh of the rendered date string.
    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var loadedImage: NSImage?
    @State private var loadedContent: String?
    @State private var loadedOCRText: String?
    @State private var loadedRichText: AttributedString?
    @State private var longPressing = false
    @State private var imageLongPressing = false
    @State private var showFullContent = false
    @State private var imageLoadFailed = false
    @State private var imageLoadStatus: ImageStorage.ImageLoadStatus?
    // ID-VIEW-0002 (2026-07-31 audit): bumped by the .cryptoKeyPrepared
    // observer below so the content `.task` re-runs after the crypto key
    // lands — the previous "retry once after 200ms then give up" path left
    // the row permanently blank when prepareKey took longer.
    @State private var decryptRetryToken = 0

    static func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.isRevealed == rhs.isRevealed &&
        lhs.isCopied == rhs.isCopied &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isKeyboardSelected == rhs.isKeyboardSelected &&
        lhs.searchText == rhs.searchText &&
        lhs.searchTextDebounced == rhs.searchTextDebounced &&
        lhs.item.isPinned == rhs.item.isPinned &&
        lhs.item.tagIds == rhs.item.tagIds &&
        lhs.item.createdAt == rhs.item.createdAt &&
        lhs.item.decryptionFailed == rhs.item.decryptionFailed &&
        // H-19 (2026-07-24 audit): isSensitive + ocrText were missing — when
        // OCR attaches text in the background or sensitive classification
        // flips, SwiftUI saw the row as unchanged and skipped re-render. The
        // orange "sensitive" badge appeared late and the context menu's
        // "Copy OCR" stayed disabled until the row scrolled off + on.
        lhs.item.isSensitive == rhs.item.isSensitive &&
        lhs.item.ocrText == rhs.item.ocrText
    }
    // CLIP-3 (2026-07-24 review): @AppStorage stays only as the invalidation
    // trigger (re-render on setting change). All sizing must go through
    // sz()'s NaN/Inf/clamp guards — never multiply by the raw stored value.
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    private var iconSize: CGFloat { sz(13) }

    /// Explicit memberwise initializer so callers (ContentView) can name
    /// every prop including `onEditTags`. Kept identical to Swift's auto
    /// memberwise init; just declared here for clarity and to avoid
    /// @ViewBuilder inferring a no-arg init when used inline.
    init(item: ClipboardItem,
         store: ClipboardStore = .shared,
         isRevealed: Bool,
         isKeyboardSelected: Bool = false,
         isCopied: Bool = false,
         isSelected: Bool = false,
         searchText: String = "",
         searchTextDebounced: String = "",
         onCopyWithFeedback: (() -> Void)? = nil,
         onPin: @escaping () -> Void,
         onDelete: @escaping () -> Void,
         onSelect: ((Bool) -> Void)? = nil,
         onToggleReveal: @escaping () -> Void,
         onEditTags: @escaping () -> Void = {}) {
        self.item = item
        self.store = store
        self.isRevealed = isRevealed
        self.isKeyboardSelected = isKeyboardSelected
        self.isCopied = isCopied
        self.isSelected = isSelected
        self.searchText = searchText
        self.searchTextDebounced = searchTextDebounced
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
        loadedContent ?? ""
    }
    private var formattedDate: String {
        // ID-SYNC-0005 (2026-08-01 audit): locked formatting — the shared
        // formatter instance is no longer exposed directly.
        cachedAbsoluteDateString(from: item.createdAt, languageCode: LanguageManager.shared.selectedLanguage)
    }

    private var cachedHighlighted: AttributedString {
        let key = "\(item.id.uuidString)-\(searchText)-\(decryptedContent.hashValue)" as NSString
        if let cached = highlightedCache.object(forKey: key) {
            return AttributedString(cached)
        }
        let result = Self.highlightedContent(decryptedContent, highlight: searchText)
        highlightedCache.setObject(NSAttributedString(result), forKey: key)
        return result
    }
    private var cachedMaskedHighlighted: AttributedString {
        let key = "\(item.id.uuidString)-\(searchText)-\(decryptedContent.hashValue)" as NSString
        if let cached = maskedHighlightedCache.object(forKey: key) {
            return AttributedString(cached)
        }
        let result = Self.maskedHighlightedContent(decryptedContent, highlight: searchText)
        maskedHighlightedCache.setObject(NSAttributedString(result), forKey: key)
        return result
    }

    /// Computes the OCR snippet AttributedString, with NSCache memoization.
    /// Returns empty AttributedString when conditions don't warrant rendering:
    /// - `searchTextDebounced` empty / whitespace-only (spec §2 trigger;
    ///   DEBOUNCED so we don't flash snippets during the 250ms filter window)
    /// - item is not an image
    /// - `ocrPreviewEnabled` is off
    /// - OCR text missing AND `ocrAttempted` true (no text ever produced)
    ///
    /// Cache key includes `ocrText.hashValue` so a fresh OCR result (different
    /// ciphertext) invalidates the cache (review 1.3).
    private var cachedHighlightedOcr: AttributedString {
        let trimmed = searchTextDebounced.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              item.type == .image,
              store.ocrPreviewEnabled else {
            return AttributedString("")
        }
        let ocrHash = item.ocrText?.hashValue ?? 0
        let key = "\(item.id.uuidString)-\(ocrHash)-\(trimmed)" as NSString
        if let cached = highlightedOcrCache.object(forKey: key) {
            return AttributedString(cached)
        }
        let result: AttributedString
        if let ocrText = loadedOCRText {
            result = Self.highlightedOcrContent(ocrText: ocrText, highlight: trimmed)
        } else if item.ocrText != nil {
            // Ciphertext present but decrypt failed — show warning placeholder.
            // AttributedString does NOT have `.with {}`; mutate via subscript.
            // ID-VIEW-0003 (2026-07-31 audit): do NOT cache this warning —
            // the cache key has no loadedOCRText dimension, so a cached
            // warning would keep hitting after the late OCR decrypt lands
            // and stay poisoned for the whole session. Return uncached so
            // the next body evaluation recomputes.
            var warnAttr = AttributedString(Self.warningOcrText)
            warnAttr.foregroundColor = .orange
            return warnAttr
        } else if !item.ocrAttempted {
            var phAttr = AttributedString(Self.placeholderOcrText)
            phAttr.foregroundColor = .secondary
            result = phAttr
        } else {
            result = AttributedString("")
        }
        highlightedOcrCache.setObject(NSAttributedString(result), forKey: key)
        return result
    }

    private static var placeholderOcrText: String { L10n.itemOcrProcessing }
    private static var warningOcrText: String { L10n.itemOcrUnreadable }

    // ID-CRASH-0002 (2026-07-31 audit): static + internal so the Unicode
    // case-fold regression test can call it without a view tree.
    static func highlightedContent(_ text: String, highlight: String) -> AttributedString {
        if highlight.isEmpty { return AttributedString(String(text.prefix(200))) }
        let lh = highlight.lowercased()
        // ID-CRASH-0002 (2026-07-31 audit): same class as BUG-008 (below) —
        // the first match was located in `text.lowercased()` and the
        // resulting offset (`mso`) applied to `text` via a NON-limited
        // `offsetBy:`. Unicode case-fold that changes length (e.g. "İ"→"i̇",
        // "ß"→"ss") inflates the lowercased copy, so `mso` could run past
        // `text.endIndex` and trap. Locate the match on the ORIGINAL string
        // with `.caseInsensitive` so every index below belongs to `text`.
        guard let fm = text.range(of: highlight, options: .caseInsensitive) else { return AttributedString(String(text.prefix(200))) }
        let mso = text.distance(from: text.startIndex, to: fm.lowerBound)
        var prefix = ""
        let dsi: String.Index
        if mso > 30 { dsi = text.index(text.index(text.startIndex, offsetBy: mso), offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex; prefix = "..." } else { dsi = text.startIndex }
        let dei = text.index(dsi, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
        let ds = String(text[dsi..<dei])
        let prefixLen = prefix.count
        var a = AttributedString(prefix + ds)
        let lowerDS = ds.lowercased()
        // BUG-008 (2026-07-21): dsStartOffset was dead code AND a cross-string
        // bug — `dsi` is an index into `text` (L157), but `lt.distance(from:
        // lt.startIndex, to: dsi)` used it with `lt` (`text.lowercased()`, a
        // different String instance). For Unicode text where lowercased()
        // changes internal representation (e.g. "İ" → "i̇", "ß" → "ss"),
        // this traps with fatalError. Highlight computation already uses
        // `lowerDS` (the substring `ds` lowercased), so this offset was
        // also semantically dead — never read. Delete only.
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
    /// Pure function for OCR text snippet + multi-match highlight (spec §4).
    ///
    /// Differs from `highlightedContent` in three ways to fix latent bugs:
    /// 1. Uses `range(of:options:.caseInsensitive)` on the ORIGINAL string — never
    ///    creates a `lowercased()` copy. BUG-008 (`highlightedContent` L199-206)
    ///    cross-indexed lowercased() and original, trapping on Unicode case-
    ///    folding that changes grapheme count (e.g. `İ` → `i̇`).
    /// 2. Sanitizes NUL + non-newline control chars via `sanitizeOCR()` to
    ///    prevent `AttributedString` init from crashing on OCR output containing
    ///    unprintable bytes (review 4.2).
    /// 3. Returns empty `AttributedString` when no match — caller decides whether
    ///    to show a snippet at all. Misleading "first 120 chars" fallback was
    ///    removed (review 4.3).
    static func highlightedOcrContent(ocrText: String, highlight: String) -> AttributedString {
        let cleaned = sanitizeOCR(ocrText)
        if highlight.isEmpty {
            return AttributedString(String(cleaned.prefix(120)))
        }
        // .diacriticInsensitive so Turkish İ/ı, German ß, and other case-fold
        // pairs where lowercased() grows/drops combining marks still match
        // (e.g. "İSTANBUL" vs "istanbul"). Operating on the original string —
        // not a lowercased() copy — means we never cross-index strings of
        // different grapheme counts, so BUG-008 cannot trap.
        guard let firstMatch = cleaned.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString("")
        }
        let matchStart = cleaned.distance(from: cleaned.startIndex, to: firstMatch.lowerBound)
        let lo = max(0, matchStart - 40)
        let hi = min(cleaned.count, matchStart + highlight.count + 80)
        var excerpt = String(cleaned[
            cleaned.index(cleaned.startIndex, offsetBy: lo)
            ..< cleaned.index(cleaned.startIndex, offsetBy: hi)
        ])
        if lo > 0 { excerpt = "…" + excerpt }
        if hi < cleaned.count { excerpt += "…" }

        var attr = AttributedString(excerpt)
        var ss = excerpt.startIndex
        while let r = excerpt.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive], range: ss..<excerpt.endIndex) {
            let startOff = excerpt.distance(from: excerpt.startIndex, to: r.lowerBound)
            let endOff = excerpt.distance(from: excerpt.startIndex, to: r.upperBound)
            let si = attr.index(attr.startIndex, offsetByCharacters: startOff)
            let ei = attr.index(attr.startIndex, offsetByCharacters: min(endOff, excerpt.count))
            if si < ei {
                attr[si..<ei].backgroundColor = .cyan.opacity(0.3)
                attr[si..<ei].foregroundColor = .primary
            }
            ss = r.upperBound
        }
        return attr
    }

    /// QuickBar variant: 60-char total window (±20 around match) for the 340px
    /// popover (spec §3.1 review 3.1). Reuses `sanitizeOCR` and the same
    /// caseInsensitive-on-original rule.
    static func highlightedOcrContentNarrow(ocrText: String, highlight: String) -> AttributedString {
        let cleaned = sanitizeOCR(ocrText)
        if highlight.isEmpty { return AttributedString(String(cleaned.prefix(40))) }
        // NEW-F (2026-07-27 review): QuickBar's narrow variant used only
        // `.caseInsensitive`, while the main-list `highlightedOcrContent`
        // adds `.diacriticInsensitive`. The mismatch meant "café" / "CAFE"
        // could match in the main list but not in QuickBar. Align options.
        guard let firstMatch = cleaned.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString("")
        }
        let matchStart = cleaned.distance(from: cleaned.startIndex, to: firstMatch.lowerBound)
        let lo = max(0, matchStart - 20)
        let hi = min(cleaned.count, matchStart + highlight.count + 40)
        var excerpt = String(cleaned[
            cleaned.index(cleaned.startIndex, offsetBy: lo)
            ..< cleaned.index(cleaned.startIndex, offsetBy: hi)
        ])
        if lo > 0 { excerpt = "…" + excerpt }
        if hi < cleaned.count { excerpt += "…" }

        var attr = AttributedString(excerpt)
        var ss = excerpt.startIndex
        while let r = excerpt.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive], range: ss..<excerpt.endIndex) {
            let startOff = excerpt.distance(from: excerpt.startIndex, to: r.lowerBound)
            let endOff = excerpt.distance(from: excerpt.startIndex, to: r.upperBound)
            let si = attr.index(attr.startIndex, offsetByCharacters: startOff)
            let ei = attr.index(attr.startIndex, offsetByCharacters: min(endOff, excerpt.count))
            if si < ei {
                attr[si..<ei].backgroundColor = .cyan.opacity(0.3)
                attr[si..<ei].foregroundColor = .primary
            }
            ss = r.upperBound
        }
        return attr
    }

    /// Strip NUL bytes and non-newline control characters. OCR may emit these;
    /// `AttributedString` init traps on NUL. The `filter` line keeps any
    /// character that is a letter/number/punctuation/symbol/whitespace — the
    /// complement (control chars, format chars, etc.) is dropped. Whitespace
    /// already includes newlines, so the "except newlines" carve-out falls out
    /// automatically. No separate `replacingOccurrences("\0", "")` is needed
    /// (review 3) — `filter` already covers it.
    private static func sanitizeOCR(_ s: String) -> String {
        s.filter { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0.isWhitespace }
    }

    // ID-CRASH-0002 (2026-07-31 audit): static + internal (with
    // `maskedHighlightedContent`) so the Unicode case-fold regression test
    // can exercise the crash path without a view tree.
    static func maskContent(_ c: String) -> String { c.count <= 4 ? String(repeating: "\u{2022}", count: c.count) : String(c.prefix(2)) + String(repeating: "\u{2022}", count: c.count - 4) + String(c.suffix(2)) }
    static func maskedHighlightedContent(_ content: String, highlight: String, ctx: Int = 15) -> AttributedString {
        if highlight.isEmpty { var a = AttributedString(maskContent(content)); a.foregroundColor = .orange; return a }
        // ID-CRASH-0002 (2026-07-31 audit): same class as BUG-008 — match
        // ranges were computed on `content.lowercased()` (a DIFFERENT String)
        // and then subscripted into `content` below (`content[r]`). Unicode
        // case-fold that changes grapheme count ("İ"→"i̇", "ß"→"ss") shifts
        // every index after the fold point, so the lc-range could run past
        // content.endIndex and trap on the main thread. Run the search on
        // the ORIGINAL string with `.caseInsensitive` so every Range<String
        // .Index> below is an index into `content` itself (same fix pattern
        // as `highlightedOcrContent` / BUG-008).
        var vis: [Range<String.Index>] = []; var ss = content.startIndex
        while let r = content.range(of: highlight, options: .caseInsensitive, range: ss..<content.endIndex) {
            let cs = content.index(r.lowerBound, offsetBy: -ctx, limitedBy: content.startIndex) ?? content.startIndex
            let ce = content.index(r.upperBound, offsetBy: ctx, limitedBy: content.endIndex) ?? content.endIndex
            vis.append(cs..<ce); ss = r.upperBound
        }
        guard !vis.isEmpty else { return AttributedString(maskContent(content)) }; vis.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []; for r in vis { if let last = merged.last, last.upperBound >= r.lowerBound { merged[merged.count-1] = last.lowerBound..<max(last.upperBound, r.upperBound) } else { merged.append(r) } }
        var res = AttributedString(); var ci = content.startIndex
        for r in merged { if ci < r.lowerBound { var b = AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: r.lowerBound))); b.foregroundColor = .orange; res += b }; var h = AttributedString(String(content[r])); h.backgroundColor = .blue.opacity(0.15); h.foregroundColor = .primary; res += h; ci = r.upperBound }
        if ci < content.endIndex { var t = AttributedString(String(repeating: "\u{2022}", count: content.distance(from: ci, to: content.endIndex))); t.foregroundColor = .orange; res += t }
        return res
    }

    var body: some View {
        // 2026-07-25: reading fontScale here is what subscribes this view to
        // @AppStorage invalidation. Declared-but-unread property wrappers
        // create no SwiftUI dependency, so font-size changes never re-
        // rendered the row even though every size goes through sz().
        let _ = fontScale
        HStack(alignment: .center, spacing: 8) {
            Button {
                    onSelect?(!isSelected)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: iconSize))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                // F-19 (2026-07-23 audit): VoiceOver sees only "button" for an
                // icon-only select toggle. Add an explicit label that flips
                // with state and announce the .isSelected trait so screen
                // readers convey the row's current selection.
                .accessibilityLabel(isSelected ? L10n.actionDeselect : L10n.actionSelect)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    if item.type == .image {
                        VStack(alignment: .leading, spacing: 2) {
                            Group {
                            if let ns = loadedImage {
                                Image(nsImage: ns)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 80)
                                    .overlay(PressableImage { pressed in imageLongPressing = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                                    .transition(.opacity)
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
                                        // (delete button removed — the per-row trash icon at the end of
                                        //  each row already provides this action; the contextual x in the
                                        //  badge had unreliable hit testing due to its position outside the
                                        //  120×80 badge frame)
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
                        .animation(.easeIn(duration: 0.3), value: loadedImage)
                        .onChange(of: imageLongPressing) { pressing in
                            if pressing, let ns = loadedImage {
                                ImagePreviewPanel.show(image: ns)
                            } else {
                                ImagePreviewPanel.hide()
                            }
                        }
                        .onDisappear { ImagePreviewPanel.hide() }
                        .task(id: item.content) {
                            // P0-3 T2: if the startup integrity scan already knows
                            // this image is missing/corrupt, show status immediately
                            // without waiting for async disk I/O.
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
                            // BUG-029 (2026-07-21): split into two awaits —
                            // loadImageObject stays on a detached thread
                            // (CPU-bound NSImage decode), but the
                            // status-on-miss path now hops through
                            // imageStatusAsync so the legacy decrypt +
                            // migrationQueue.sync doesn't starve the
                            // cooperative thread pool when hundreds of
                            // cold images are loaded at once.
                            let img: NSImage? = await Task.detached(priority: .userInitiated) {
                                ImageStorage.shared.loadImageObject(filename: filename)
                            }.value
                            let status: ImageStorage.ImageLoadStatus? = img == nil
                                ? await ImageStorage.shared.imageStatusAsync(for: filename)
                                : nil
                            let result = (img, status) as (NSImage?, ImageStorage.ImageLoadStatus?)
                            // I-8 fix (2026-07-20 audit): see TrashItemRow.swift
                            // for the same pattern. `Task.detached` does not
                            // inherit cancellation from the parent `.task(id:)`
                            // body, so when the user switches rows the late
                            // image arrives back into a stale `loadedImage`
                            // state and briefly shows the wrong picture. The
                            // guard here uses the same idiom: re-check
                            // `Task.isCancelled` after the await and drop the
                            // result if the parent task has been cancelled.
                            if Task.isCancelled { return }
                            if let img = result.0 {
                                loadedImage = img
                            } else {
                                imageLoadFailed = true
                                imageLoadStatus = result.1
                            }
                        }
                        // OCR snippet under thumbnail (spec §3). Renders only
                        // when the cached AttributedString is non-empty — the
                        // helper returns empty for unrendered cases
                        // (no search text / no OCR / OCR produced nothing).
                        let cached = cachedHighlightedOcr
                        if !cached.characters.isEmpty {
                            Text(cached)
                                .font(.system(size: sz(11)))
                                .lineLimit(2)
                        }
                        }  // closes VStack wrapping the image branch
                    } else if item.type == .richText {
                        if item.isSensitive && !isRevealed {
                            Text(longPressing ? cachedHighlighted : cachedMaskedHighlighted)
                                .font(.system(size: sz(13))).lineLimit(3)
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
                                        .font(.system(size: sz(12))).foregroundColor(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .animation(.easeIn(duration: 0.3), value: loadedRichText)
                            .task(id: item.content) { await loadRichText() }
                        }
                    } else if item.isSensitive && !isRevealed {
                        Text(longPressing ? cachedHighlighted : cachedMaskedHighlighted)
                            .font(.system(size: sz(13))).lineLimit(3)
                            .overlay(PressableImage { pressed in longPressing = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                    } else {
                        Text(showFullContent ? AttributedString(decryptedContent) : cachedHighlighted)
                            .font(.system(size: sz(12))).foregroundColor(Color(nsColor: .controlTextColor))
                            .lineLimit(showFullContent ? nil : 3)
                            .overlay(PressableImage { pressed in showFullContent = pressed }.frame(maxWidth: .infinity, maxHeight: .infinity))
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                HStack(spacing: 8) { Text(formattedDate).font(.system(size: sz(11))).foregroundColor(.primary.opacity(0.55)); if item.isSensitive { Label(L10n.itemSensitive, systemImage: "exclamationmark.shield").font(.system(size: sz(11))).foregroundColor(.orange) }; if !item.tagIds.isEmpty { TagChipStack(tagIds: item.tagIds, store: store) } }
            }
            .contentShape(Rectangle())
            .gesture(ExclusiveGesture(TapGesture(count: 2).onEnded { onPin() }, TapGesture().onEnded { onCopyWithFeedback?() }))
            // B-1 (2026-07-27): the trailing icon-button column was
            // previously inlined in `body`, contributing ~45 lines to an
            // already-large body. Extracted to `RowActions` so the body
            // focuses on layout + content rendering. `RowActions` is a
            // private struct (not a method) because ViewBuilder constraints
            // (icon overlays, topTrailing tag-count badge) are easier to
            // express as a `body` than as a deeply-nested return chain.
            RowActions(
                item: item,
                iconSize: iconSize,
                onEditTags: onEditTags,
                onPin: onPin,
                onDelete: onDelete
            )
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
                // Live lookup: the row's captured item struct can be stale when
                // OCR finished after the list rendered (bug: menu looked dead).
                .disabled(liveOcrText == nil)
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
        // ID-VIEW-0003 (2026-07-31 audit): task id gains the
        // `item.ocrText != nil` dimension so a late OCR attach re-runs the
        // OCR decrypt — previously the row re-rendered (Equatable) but the
        // task never re-fired, `loadedOCRText` stayed nil, and
        // `cachedHighlightedOcr` showed the false "无法读取" warning.
        // ID-VIEW-0002 (2026-07-31 audit): `decryptRetryToken` lets the
        // .cryptoKeyPrepared observer below re-fire this task after a
        // key-race double miss.
        .task(id: "\(item.id.uuidString)-\(item.ocrText != nil)-\(decryptRetryToken)") {
            if item.type == .image {
                guard item.ocrText != nil, loadedOCRText == nil else { return }
                let ocrResult = await Task.detached(priority: .utility) {
                    store.getDecryptedOcrText(item)
                }.value
                if Task.isCancelled { return }
                loadedOCRText = ocrResult
                return
            }
            guard item.type != .richText else { return }
            if loadedContent != nil { return }
            // ID-FIX-key-race (2026-07-30 audit): v2.7.3's `prepareKey()` runs
            // on a detached background task. On a fresh launch, the main
            // window's `.task` here can fire BEFORE `prepareKey` finishes —
            // `getDecryptedContent` returns nil on `.keyUnavailable`, and
            // `loadedContent = ""` makes the row blank. The user has to
            // interact (click → paste) for the key to finally be ready.
            // Retry once after a short delay so the key has time to land
            // in `cachedLoadedKey`. The delay is below the 60 fps frame
            // budget so it doesn't visibly stagger the UI; if the second
            // attempt also returns empty, keep loadedContent == nil and let
            // the .cryptoKeyPrepared observer below re-run this task once
            // the key lands (ID-VIEW-0002, 2026-07-31 audit).
            let first = await Task.detached(priority: .utility) {
                store.getDecryptedContent(item) ?? ""
            }.value
            if Task.isCancelled { return }
            if !first.isEmpty {
                loadedContent = first
                return
            }
            // Empty result — likely a key race. Give prepareKey a moment
            // and retry once.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let second = await Task.detached(priority: .utility) {
                store.getDecryptedContent(item) ?? ""
            }.value
            if Task.isCancelled { return }
            // I-8 fix (2026-07-20 audit): same cancellation-isolation as the
            // image `.task`. Drop the decrypted text when the row has been
            // recycled so we don't paste stale text into the new item's state.
            // ID-VIEW-0002 (2026-07-31 audit): write only a non-empty result.
            // Storing "" made `loadedContent != nil` early-return on every
            // later pass, so the row stayed blank for the whole session with
            // no recovery path (window + hosting controller persist @State).
            if !second.isEmpty {
                loadedContent = second
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cryptoKeyPrepared)) { note in
            // ID-VIEW-0002 (2026-07-31 audit): the crypto key landed after
            // our decrypt attempts missed — bump the token in the .task id
            // so the task re-runs. Guards keep this a no-op for rows that
            // already have content or don't need decryption here.
            let success = (note.userInfo?["success"] as? Bool) ?? false
            guard success else { return }
            let needsRetry: Bool
            if item.type == .image {
                needsRetry = item.ocrText != nil && loadedOCRText == nil
            } else {
                needsRetry = item.type != .richText && loadedContent == nil
            }
            guard needsRetry else { return }
            decryptRetryToken += 1
        }
    }

    /// CLIP-1 main (2026-07-24 audit): route RTF preview through the cached
    /// plaintext path. The prior inline decrypt + NSAttributedString parse
    /// bypassed `rtfPlaintextCache` (M-24 contract), causing every hover-
    /// triggered body re-render to repeat 20-100 ms of sync work. Now hits
    /// the cache populated by `loadRichText` (line 489) and degrades to the
    /// localized placeholder for genuinely unparseable items.
    private var plainTextFallback: String {
        guard item.type == .richText else { return "" }
        return store.getRTFPlaintext(item)
    }

    /// The item as it currently exists in the store (the captured row struct
    /// ID-PERF-0012 (2026-07-30 audit): `store.items.first(where:)` is O(n)
    /// per call; `liveItem` was invoked on every contextMenu render,
    /// every OCR-triggered update, etc. — N tag lookups × 10K items = 10K
    /// UUID comparisons. Compute the live index once per body
    /// (via `liveIndexByID` built lazily) so the row gets O(1) lookup.
    /// The dict is rebuilt on each body call (cheap for 10K items — one
    /// pass, ~1 ms) but only built once per body, not per property
    /// access.
    private var liveIndexByID: [UUID: ClipboardItem] {
        Dictionary(uniqueKeysWithValues: store.items.lazy.map { ($0.id, $0) })
    }
    private var liveItem: ClipboardItem {
        liveIndexByID[item.id] ?? item
    }

    private var liveOcrText: String? { liveItem.ocrText }

    private func loadRichText() async {
        guard item.type == .richText else { return }
        guard let base64 = store.getDecryptedContent(item) else { return }
        // H-7/H-8 (2026-07-24 audit): NSAttributedString RTF parse was inline
        // before any await, so 20–100ms blocked the main thread on every
        // richText row. Image path uses Task.detached(priority: .userInitiated)
        // (L294); mirror that here. `parseRichText` is a pure static helper
        // (nonisolated by virtue of being a struct static), so wrapping it in
        // Task.detached moves the parse off-main. After await resumes we're
        // back on @MainActor for the @State writes.
        guard let parsed = await Task.detached(priority: .userInitiated) { () -> (attributed: AttributedString, plain: String)? in
            Self.parseRichText(base64: base64)
        }.value else { return }
        // M-3 (2026-07-21 audit): bridge to store cache so copyToClipboard
        // hits cache (< 1ms) instead of re-parsing NSAttributedString
        // (20-100ms sync). Cache key matches getRTFPlaintext for symmetric
        // hit/miss.
        store.cacheRTFPlaintext(item, parsed.plain)
        loadedRichText = parsed.attributed
        loadedContent = parsed.plain
    }

    /// H-7/H-8 (2026-07-24 audit): pure RTF parser extracted from `loadRichText`
    /// so the parse can run off the main thread via Task.detached. Returns
    /// nil for any failure (bad base64, bad RTF body, empty input) — the
    /// caller treats nil as "skip and show placeholder".
    static func parseRichText(base64: String) -> (attributed: AttributedString, plain: String)? {
        guard !base64.isEmpty,
              let rtfData = Data(base64Encoded: base64),
              let nsAttr = try? NSAttributedString(
                data: rtfData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else { return nil }
        return (AttributedString(nsAttr), nsAttr.string)
    }

    /// Copies the OCR-recognized text of this image item to the pasteboard.
    /// Goes through `writeOcrTextToPasteboard`, which tells our own
    /// ClipboardMonitor first — so this won't create a new history entry.
    private func copyOcrText() {
        guard let text = store.getDecryptedOcrText(liveItem), !text.isEmpty else { return }
        Self.writeOcrTextToPasteboard(text, store: store, isSensitive: liveItem.isSensitive)
    }

    /// CLIP-2 (2026-07-24 audit): the OCR copy path wrote the pasteboard
    /// directly without `recordOwnWrite()`, so the monitor's next poll saw
    /// the changeCount bump and re-captured our own OCR text as a brand-new
    /// history entry. Mirrors the M-4 ordering contract in
    /// `ClipboardStore.copyToClipboard`: recordOwnWrite() MUST run BEFORE
    /// clearContents() — clearContents increments changeCount immediately,
    /// and a monitor tick landing in the window between clear and
    /// recordOwnWrite would re-capture the write.
    /// Static + store-injected so tests can exercise it against a
    /// MemoryStorageBackend store without touching ClipboardStore.shared.
    static func writeOcrTextToPasteboard(_ text: String, store: ClipboardStore, isSensitive: Bool = false) {
        store.onRecordOwnWrite?()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // ID-SECURITY-0003 (2026-07-31 audit): OCR plaintext of a sensitive
        // item is still a secret — stamp the standard concealed marker so
        // well-behaved pasteboard readers (credential-aware apps, and our
        // own ClipboardMonitor.swift:374-384 read path) suppress capture.
        // Empty-data marker mirrors the convention used by 1Password etc.
        // NEW-8 (2026-08-03 audit): the old anchor `:289-296` pointed at
        // the own-write fingerprint helper, which is unrelated to
        // concealed-type detection.
        if isSensitive {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}

// MARK: - B-1 (2026-07-27): trailing icon-button column extracted

/// Trailing action column of `ClipboardItemRow`: tag (with optional
/// count badge), pin, delete. Carved out of `body` to keep the row's
/// layout tree readable. Stateless — receives the item snapshot, icon
/// size, and the same callbacks the parent uses, so behavior is
/// unchanged. Pinned to the F-20 a11y audit (2026-07-23) so the three
/// icon-only buttons keep their `accessibilityLabel` and `.help()`
/// strings in lockstep with the visible label.
private struct RowActions: View {
    let item: ClipboardItem
    let iconSize: CGFloat
    let onEditTags: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onEditTags) {
                Image(systemName: "tag")
                    .font(.system(size: iconSize))
                    .foregroundColor(item.tagIds.isEmpty ? .secondary : .accentColor)
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .topTrailing) {
                        if !item.tagIds.isEmpty {
                            Text("\(item.tagIds.count)")
                                .font(.system(size: sz(8)))
                                .padding(2)
                                .background(Color.accentColor, in: Circle())
                                // ID-A11Y-0007 (2026-07-30 audit): same
                                // `.regularMaterial` halo as A11Y-0006 so the
                                // tag-count badge stays legible on light
                                // accent colors (system yellow). Plain
                                // `.white` is hard to read there.
                                .foregroundStyle(Color.white)
                                .background(.regularMaterial, in: Circle())
                                .offset(x: 4, y: -4)
                                // ID-L10N-0015 (2026-07-30 audit): route through
                                // L10n (was hardcoded zh-Hans). Use plural()
                                // for proper count grammar.
                                .accessibilityLabel(L10n.tagBadgeAccessibility(item.tagIds.count))
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(L10n.tooltipEditTags)
            .accessibilityLabel(L10n.tooltipEditTags)
            // F-20 (2026-07-23 audit): pin + delete were Image-only Buttons with only
            // a `.help()` tooltip — `.help()` does NOT surface to VoiceOver / a11y
            // users. Reusing the same L10n strings keeps the visible label and the
            // VoiceOver announcement in sync (and avoids creating new keys that would
            // need 7-lang review).
            Button(action: onPin) {
                Image(systemName: item.isPinned ? "star.fill" : "star")
                    .font(.system(size: iconSize))
                    .foregroundColor(item.isPinned ? .orange : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? L10n.tooltipUnpin : L10n.tooltipPin)
            .accessibilityLabel(item.isPinned ? L10n.tooltipUnpin : L10n.tooltipPin)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: iconSize))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L10n.tooltipDelete)
            .accessibilityLabel(L10n.tooltipDelete)
        }
    }
}
