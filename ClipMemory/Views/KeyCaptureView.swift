import SwiftUI
import AppKit
// HOTKEY-0001 (2026-08-10): Carbon kVK_* constants for keyCode comparisons
// — replaces bare numeric literals (126/125/36/53/3) that the audit
// flagged as unreadable + typo-prone.
import Carbon.HIToolbox

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
            //
            // L-19 (2026-07-25 audit): require the view's window to actually
            // be the key window. The previous `window == nil` short-circuit
            // let a detached/transitioning view process events meant for the
            // real key window.
            guard self.window == NSApp.keyWindow else {
                return event
            }
            // During IME composition, pass all keys through to IME
            if let fr = NSApp.keyWindow?.firstResponder as? NSTextView, fr.hasMarkedText() {
                return event
            }
            // Cmd+F — menu key equivalent is consumed before local monitor sees it,
            // so we rely on `.onCommand` in ContentView instead.
            if event.modifierFlags.contains(.command) && event.keyCode == UInt16(kVK_ANSI_F) {
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
            switch Int(event.keyCode) {
            case kVK_UpArrow:    if shouldCaptureArrows    { self.onUp?();      return nil }; return event
            case kVK_DownArrow:  if shouldCaptureArrows    { self.onDown?();    return nil }; return event
            case kVK_Return:     if shouldCaptureEnterEsc  { self.onReturn?();  return nil }; return event
            case kVK_Escape:     if shouldCaptureEnterEsc  { self.onEscape?();  return nil }; return event
            default:             return event
            }
        }
    }

    deinit {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
    }
}
