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

    /// Presents the macOS share sheet anchored at the key window. Falls
    /// back silently if no window is on-screen (callers — context menu /
    /// toolbar — should not be reachable in that state anyway).
    @MainActor
    static func presentShareSheet(for items: [ClipboardItem]) {
        let urls = makeShareableFileURLs(for: items)
        guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
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

    private static func scheduleCleanup(url: URL, afterSeconds seconds: UInt64) {
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            try? FileManager.default.removeItem(at: url)
        }
    }
}