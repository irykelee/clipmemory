import SwiftUI
import AppKit

/// Invisible NSViewRepresentable that captures global keyboard events.
/// Used by QuickBar and main window for keyboard navigation.
struct KeyCaptureView: NSViewRepresentable {
    var searchText: String = ""
    var onUp: () -> Void
    var onDown: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void
    var onCommandF: (() -> Void)?

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.searchText = searchText
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
        view.onEscape = onEscape
        view.onCommandF = onCommandF
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.searchText = searchText
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
        nsView.onCommandF = onCommandF
    }
}

final class KeyCaptureNSView: NSView {
    var searchText: String = ""
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCommandF: (() -> Void)?

    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMonitor()
    }

    private func setupMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // CLIP-1 secondary (2026-07-24 audit): window affinity guard.
            // NSEvent.addLocalMonitorForEvents delivers a keyDown to EVERY
            // registered local monitor in the app - it does not respect which
            // NSWindow is key. When the main window and QuickBar popover are
            // both alive, both KeyCaptureNSView instances get every keyDown,
            // and one monitor returning nil does NOT prevent the other from
            // running. Result: pressing Return on a QuickBar selection ALSO
            // fires the main window's onReturn handler, and the wrong item
            // can land on the pasteboard. Returning event unchanged when
            // our window is not key confines the monitor to its own window.
            guard self.window == nil || self.window == NSApp.keyWindow else {
                return event
            }
            // During IME composition, pass all keys through to IME
            if let fr = NSApp.keyWindow?.firstResponder as? NSTextView, fr.hasMarkedText() {
                return event
            }
            // Cmd+F — menu key equivalent is consumed before local monitor sees it,
            // so we rely on `.onCommand` in ContentView instead.
            if event.modifierFlags.contains(.command) && event.keyCode == 3 {
                self.onCommandF?()
                return nil
            }
            let isTextInput = (NSApp.keyWindow?.firstResponder as? NSText)?.isEditable == true
            // When search text is empty, arrow keys should navigate list not move cursor
            let shouldCaptureArrows = !isTextInput || self.searchText.isEmpty
            // When typing in any editable text field (search bar, tag name input,
            // hotkey capture), Return / Esc belong to the field — let them
            // propagate so .onSubmit fires and Esc clears the field. The list-level
            // handlers (onReturn copy / onEscape close) only apply when no text
            // field has focus. Without this guard, pressing Esc while editing a
            // tag name would silently close the main window.
            let shouldCaptureEnterEsc = !isTextInput
            switch event.keyCode {
            case 126: if shouldCaptureArrows { self.onUp?(); return nil }; return event      // UpArrow
            case 125: if shouldCaptureArrows { self.onDown?(); return nil }; return event    // DownArrow
            case 36:  if shouldCaptureEnterEsc { self.onReturn?(); return nil }; return event // Return
            case 53:  if shouldCaptureEnterEsc { self.onEscape?(); return nil }; return event // Escape
            default:  return event
            }
        }
    }

    deinit {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
    }
}
