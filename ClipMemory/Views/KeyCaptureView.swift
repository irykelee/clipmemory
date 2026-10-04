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
            self?.handleKeyEvent(event) ?? event
        }
    }

    /// Handles a single keyDown event. Returns `nil` to swallow the event,
    /// the original `event` to propagate, or a synthetic `NSEvent?` value.
    /// Extracted from setupMonitor's inline closure (P1-AUDIT-2026-09-22
    /// cyclomatic-complexity refactor).
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard shouldHandleKey(event) else { return event }
        if let swallowResult = tryHandleCommandF(event) { return swallowResult }
        return routeToNavigationHandler(event)
    }

    /// Affinity guards: must be the key window, must not be inside IME composition.
    /// Extracted for cyclomatic complexity reduction.
    private func shouldHandleKey(_ event: NSEvent) -> Bool {
        // CLIP-1 secondary (2026-07-24 audit): window affinity guard.
        guard window == NSApp.keyWindow else { return false }
        // L-19 (2026-07-25 audit): also require the actual key window.
        // During IME composition, pass all keys through to IME.
        if let fr = NSApp.keyWindow?.firstResponder as? NSTextView, fr.hasMarkedText() { return false }
        return true
    }

    /// Cmd+F — menu key equivalent is consumed before local monitor sees it,
    /// so we rely on `.onCommand` in ContentView instead. Returns `nil` to
    /// swallow, `event` to propagate, or nil-from-this-helper if not Cmd+F.
    private func tryHandleCommandF(_ event: NSEvent) -> NSEvent?? {
        guard event.modifierFlags.contains(.command) && event.keyCode == UInt16(kVK_ANSI_F) else {
            return nil
        }
        onCommandF?()
        return .some(nil) // swallow
    }

    /// Routes arrow / return / escape keys to their navigation handlers.
    /// Returns the event to propagate (or nil to swallow).
    private func routeToNavigationHandler(_ event: NSEvent) -> NSEvent? {
        let isTextInput = (NSApp.keyWindow?.firstResponder as? NSText)?.isEditable == true
        // When search text is empty, arrow keys should navigate list not move cursor.
        let shouldCaptureArrows = !isTextInput || searchText.isEmpty
        // When typing in any editable text field (search bar, tag name input,
        // hotkey capture), Return / Esc belong to the field — let them
        // propagate so .onSubmit fires and Esc clears the field. The list-level
        // handlers (onReturn copy / onEscape close) only apply when no text
        // field has focus. Without this guard, pressing Esc while editing a
        // tag name would silently close the main window.
        let shouldCaptureEnterEsc = !isTextInput
        switch Int(event.keyCode) {
        case kVK_UpArrow:    if shouldCaptureArrows { onUp?();      return nil }; return event
        case kVK_DownArrow:  if shouldCaptureArrows { onDown?();    return nil }; return event
        case kVK_Return:     if shouldCaptureEnterEsc { onReturn?();  return nil }; return event
        case kVK_Escape:     if shouldCaptureEnterEsc { onEscape?();  return nil }; return event
        default:             return event
        }
    }

    deinit {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
    }
}
