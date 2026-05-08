import AppKit
import SwiftUI

/// Manages the main popup window lifecycle and persistence
class WindowManager: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let windowFrameKey = "WindowFrame"

    override init() {
        super.init()
    }

    private var savedWindowFrame: NSRect {
        get {
            let defaultFrame = NSRect(x: 0, y: 0, width: 400, height: 500)
            guard let data = UserDefaults.standard.data(forKey: windowFrameKey),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                  let x = dict["x"], let y = dict["y"],
                  let w = dict["w"], let h = dict["h"] else {
                return defaultFrame
            }
            let savedFrame = NSRect(x: x, y: y, width: w, height: h)
            let anyScreenIntersects = NSScreen.screens.contains { $0.visibleFrame.intersects(savedFrame) }
            if !anyScreenIntersects {
                let visible = NSScreen.main?.visibleFrame ?? defaultFrame
                return NSRect(x: visible.midX - 200, y: visible.midY - 250, width: 400, height: 500)
            }
            return savedFrame
        }
        set {
            let dict: [String: CGFloat] = [
                "x": newValue.origin.x,
                "y": newValue.origin.y,
                "w": newValue.size.width,
                "h": newValue.size.height
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict) {
                UserDefaults.standard.set(data, forKey: windowFrameKey)
            }
        }
    }

    func showWindow(pinnedOnly: Bool = false, settingsOnly: Bool = false) {
        if window == nil {
            let contentView = ContentView(pinnedOnly: pinnedOnly, settingsOnly: settingsOnly)
            window = NSWindow(
                contentRect: savedWindowFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = L10n.appName
            window?.delegate = self
            window?.isReleasedWhenClosed = false
            window?.makeKeyAndOrderFront(nil)
            window?.contentView = NSHostingView(rootView: contentView)
        } else {
            window?.contentView = NSHostingView(rootView: ContentView(pinnedOnly: pinnedOnly, settingsOnly: settingsOnly))
            window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        if let w = window {
            savedWindowFrame = w.frame
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = window {
            savedWindowFrame = w.frame
        }
    }
}
