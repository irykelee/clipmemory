import AppKit
import Foundation

class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general

    private let sensitivePatterns = [
        "password", "pwd", "passwd", "secret",
        "api_key", "apikey", "token", "auth",
        "Bearer ", "sk-", "ghp_", "ssh-rsa"
    ]

    func startMonitoring() {
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if let content = pasteboard.string(forType: .string), !content.isEmpty {
            let itemType = detectType(content)
            let isSensitive = detectSensitive(content)
            var expiresAt: Date? = nil
            if isSensitive {
                let hours = ClipboardStore.shared.sensitiveClearHours
                if hours > 0 {
                    expiresAt = Date().addingTimeInterval(TimeInterval(hours * 3600))
                }
            }
            let item = ClipboardItem(
                content: content,
                type: itemType,
                isSensitive: isSensitive,
                expiresAt: expiresAt
            )
            DispatchQueue.main.async {
                ClipboardStore.shared.addItem(item)
            }
        }
    }

    private func detectType(_ content: String) -> ClipboardItemType {
        if content.hasPrefix("http://") || content.hasPrefix("https://") {
            return .link
        }
        return .text
    }

    private func detectSensitive(_ content: String) -> Bool {
        let lowercased = content.lowercased()
        for pattern in sensitivePatterns {
            if lowercased.contains(pattern) {
                return true
            }
        }
        return false
    }
}
