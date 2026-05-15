import SwiftUI
import AppKit

/// Invisible NSViewRepresentable that captures global keyboard events.
/// Used by QuickBar and main window for keyboard navigation.
struct KeyCaptureView: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
    }
}

final class KeyCaptureNSView: NSView {
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
            switch event.keyCode {
            // USB HID Usage IDs — matching values used in Carbon's HIToolbox constants
            case 126: self.onUp?(); return nil      // UpArrow
            case 125: self.onDown?(); return nil    // DownArrow
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
