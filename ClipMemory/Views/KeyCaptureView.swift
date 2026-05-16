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

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.searchText = searchText
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.searchText = searchText
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
    }
}

final class KeyCaptureNSView: NSView {
    var searchText: String = ""
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

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
            // During IME composition, pass all keys through to IME
            if let fr = NSApp.keyWindow?.firstResponder as? NSTextView, fr.hasMarkedText() {
                return event
            }
            let isTextInput = (NSApp.keyWindow?.firstResponder as? NSText)?.isEditable == true
            // When search text is empty, arrow keys should navigate list not move cursor
            let shouldCaptureArrows = !isTextInput || self.searchText.isEmpty
            switch event.keyCode {
            case 126: if shouldCaptureArrows { self.onUp?(); return nil }; return event      // UpArrow
            case 125: if shouldCaptureArrows { self.onDown?(); return nil }; return event    // DownArrow
            case 36:  self.onReturn?(); return nil   // Return
            case 53:  self.onEscape?(); return nil  // Escape
            default:  return event
            }
        }
    }

    deinit {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
    }
}
