import AppKit
import Foundation

/// ID-VIEW-0030/0031/0032 (2026-08-13, user-driven): bridges clipboard
/// image items to macOS share-sheet / drag providers.
///
/// Filename = `<item.id>.png` — ID-based, deterministic. NSSharingServicePicker
/// "Save to Files" + Finder drag both surface the system's native
/// "Replace / Keep Both / Cancel" prompt on collision; we NEVER silently
/// overwrite a user file (L18 data-deletion discipline: the user's existing
/// file must always be visible to them at decision time).
enum ShareService {
    enum ShareError: Error {
        case imageLoadFailed
        case writeFailed(Error)
    }

    /// Decrypts the image bytes for `item` and writes them to a temp file
    /// named after the source filename (`item.content`). Preserving the
    /// source name keeps the share UX predictable — the file the user sees
    /// in Finder / Messages / AirDrop has the same name it had in
    /// ClipMemory's storage (the per-image UUID-based filename from
    /// ImageStorage.saveImage). The returned URL is safe to hand to
    /// NSSharingServicePicker or NSItemProvider; cleanup is scheduled for
    /// 60s after creation (Finder / share sheet both finish well within
    /// that window — if a share stalls the file still gets cleaned up).
    static func makeShareableFileURL(for item: ClipboardItem) throws -> URL {
        guard let data = ImageStorage.shared.loadImage(filename: item.content) else {
            throw ShareError.imageLoadFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(item.content)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ShareError.writeFailed(error)
        }
        scheduleCleanup(url: url, afterSeconds: 60)
        return url
    }

    /// Batch version — returns one URL per item. Items whose bytes fail to
    /// load are silently skipped (caller sees the shorter array and can
    /// decide whether to show a NSAlert).
    static func makeShareableFileURLs(for items: [ClipboardItem]) -> [URL] {
        items.compactMap { item in
            try? makeShareableFileURL(for: item)
        }
    }

    /// Presents the macOS share sheet anchored to `anchorView`. When the
    /// anchor is provided, the picker positions itself relative to that
    /// view's bounds — AppKit handles coord-space conversion internally,
    /// avoiding the SwiftUI top-down / AppKit bottom-up mismatch that
    /// made earlier rect-based anchoring land at the wrong screen
    /// position. When `anchorView` is nil, falls back to the key
    /// window's contentView top-center. Silently no-ops if no key window
    /// or no shareable items.
    @MainActor
    static func presentShareSheet(for items: [ClipboardItem], anchorView: NSView? = nil) {
        let urls = makeShareableFileURLs(for: items)
        guard !urls.isEmpty, let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let anchorView = anchorView {
            // ID-VIEW-0035 (2026-08-13, user-driven): the toolbar Share
            // button is a real NSButton (via NSViewRepresentable), so we
            // can hand its NSView + bounds directly to AppKit — no
            // SwiftUI↔AppKit coord-system translation required.
            // preferredEdge .maxY places the picker below the button
            // (matches Safari / Mail / Photos toolbar share buttons).
            picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        } else {
            // Fallback for callers without a captured view (e.g., future
            // programmatic invocations from non-toolbar triggers).
            let fallback = NSRect(
                x: contentView.bounds.midX,
                y: contentView.bounds.maxY,
                width: 0,
                height: 0
            )
            picker.show(relativeTo: fallback, of: contentView, preferredEdge: .minY)
        }
    }

    /// ID-VIEW-0031 (2026-08-13, user-driven): build NSItemProviders for drag.
    /// Each image becomes a temp file URL wrapped in an NSItemProvider.
    /// Items whose bytes fail to load are silently skipped (consistent with
    /// `makeShareableFileURLs`). Not @MainActor — pure data transform.
    static func makeDragProviders(for items: [ClipboardItem]) -> [NSItemProvider] {
        items.compactMap { item in
            guard let url = try? makeShareableFileURL(for: item) else { return nil }
            return NSItemProvider(contentsOf: url)
        }
    }

    /// ID-VIEW-0036 (2026-08-13, user-driven): direct save-to-folder path.
    /// Opens NSOpenPanel in directory-pick mode, copies each item's temp
    /// file to the chosen folder using `item.content` as the destination
    /// filename. Filename collisions are surfaced via NSAlert per L18 —
    /// user must explicitly choose Replace / Keep Both / Cancel; we never
    /// silently overwrite (see `feedback/data-loss-prevention-discipline`).
    /// Files that fail to load are skipped before this is reached.
    @MainActor
    static func saveToFolder(for items: [ClipboardItem]) {
        let urls = makeShareableFileURLs(for: items)
        guard !urls.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.actionExport
        panel.message = L10n.exportPanelMessage(urls.count)

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        for sourceURL in urls {
            let dest = folderURL.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                let choice = presentConflictAlert(filename: sourceURL.lastPathComponent)
                switch choice {
                case .replace:
                    do {
                        try FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: sourceURL, to: dest)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                case .keepBoth:
                    let newDest = uniqueDestination(in: folderURL, baseName: sourceURL.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: sourceURL, to: newDest)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                case .cancel, .none:
                    return
                }
            } else {
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: dest)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    private enum ConflictChoice {
        case replace, keepBoth, cancel
    }

    @MainActor
    private static func presentConflictAlert(filename: String) -> ConflictChoice? {
        let alert = NSAlert()
        alert.messageText = L10n.exportFileExistsTitle(filename)
        alert.informativeText = L10n.exportFileExistsBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.exportConflictReplace)
        alert.addButton(withTitle: L10n.exportConflictKeepBoth)
        alert.addButton(withTitle: L10n.buttonCancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        default: return .cancel
        }
    }

    /// Append " (1)", " (2)", … until a non-existent path is found.
    /// Mirrors Finder's "Keep Both" naming convention.
    private static func uniqueDestination(in folder: URL, baseName: String) -> URL {
        let fm = FileManager.default
        let ext = (baseName as NSString).pathExtension
        let stem = (baseName as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty
                ? folder.appendingPathComponent("\(stem) (\(index))")
                : folder.appendingPathComponent("\(stem) (\(index)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func scheduleCleanup(url: URL, afterSeconds seconds: UInt64) {
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            try? FileManager.default.removeItem(at: url)
        }
    }
}