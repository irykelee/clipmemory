import AppKit
import Foundation

class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general

    /// Set to true when ClipboardStore writes to pasteboard, so we skip re-capturing.
    var skipNextCapture = false

    private let sensitivePatterns: [(pattern: String, isRegex: Bool)] = [
        ("password", false),
        ("pwd", false),
        ("passwd", false),
        ("passcode", false),
        ("secret", false),
        ("api_key", false),
        ("apikey", false),
        ("api-key", false),
        ("token", false),
        ("auth", false),
        ("bearer", false),
        ("sk-", false),
        ("ghp_", false),
        ("ssh-rsa", false),
        ("-----BEGIN.*PRIVATE KEY-----", true),
        ("-----BEGIN.*RSA PRIVATE KEY-----", true),
        ("-----BEGIN.*OPENSSH PRIVATE KEY-----", true),
        ("-----BEGIN EC PRIVATE KEY-----", true),
        ("[a-zA-Z0-9]{20,}\\.[a-zA-Z0-9]{10,}\\.[a-zA-Z0-9_-]{50,}", true),
        ("AIza[0-9A-Za-z_-]{35}", true),
        ("AKIA[0-9A-Z]{16}", true),
        ("sq0csp-[0-9A-Za-z_-]{43}", true),
        ("sq0atp-[0-9A-Za-z_-]{22}", true),
        ("amzn\\.mws\\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", true),
        // Removed [0-9a-f]{32} - too broad, matches UUIDs, MD5 hashes, any hex string
    ]

    private let sensitiveValuePatterns = [
        "(?i)(password|passwd|pwd)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
        "(?i)(api_key|apikey|api-key)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
        "(?i)(token|bearer)\\s*[=:]\\s*['\"]?[a-zA-Z0-9_-]{20,}",
        "(?i)(sk|secret)\\s*[=:]\\s*['\"]?[^'\"\\s]{20,}",
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

    /// Called by ClipboardStore after it writes to pasteboard, so we skip re-capturing.
    func recordOwnWrite() {
        skipNextCapture = true
        lastChangeCount = pasteboard.changeCount
    }

    private func checkClipboard() {
        // Skip if ClipboardStore just wrote to pasteboard (break copy loop)
        if skipNextCapture {
            skipNextCapture = false
            lastChangeCount = pasteboard.changeCount
            return
        }
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
        } else if let imageData = pasteboard.data(forType: .png), !imageData.isEmpty {
            let id = UUID()
            if let filename = ImageStorage.shared.saveImage(imageData, id: id) {
                // Treat screenshots as potentially sensitive by default (may contain passwords/IDs)
                let isSensitive = true
                let hours = ClipboardStore.shared.sensitiveClearHours
                let expiresAt: Date? = hours > 0 ? Date().addingTimeInterval(TimeInterval(hours * 3600)) : nil
                let item = ClipboardItem(
                    id: id,
                    content: filename,
                    type: .image,
                    isSensitive: isSensitive,
                    expiresAt: expiresAt
                )
                DispatchQueue.main.async {
                    ClipboardStore.shared.addItem(item)
                }
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

        for (pattern, isRegex) in sensitivePatterns {
            if isRegex {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(content.startIndex..., in: content)
                    if regex.firstMatch(in: content, options: [], range: range) != nil {
                        return true
                    }
                }
            } else {
                if lowercased.contains(pattern) {
                    return true
                }
            }
        }

        for pattern in sensitiveValuePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(content.startIndex..., in: content)
                if regex.firstMatch(in: content, options: [], range: range) != nil {
                    return true
                }
            }
        }

        return false
    }
}
