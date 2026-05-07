import AppKit
import Foundation

class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general

    /// Set to true when ClipboardStore writes to pasteboard, so we skip re-capturing.
    var skipNextCapture = false

    private let sensitivePatterns: [(pattern: String, isRegex: Bool)] = [
        // Credentials
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
        // Private keys
        ("-----BEGIN.*PRIVATE KEY-----", true),
        ("-----BEGIN.*RSA PRIVATE KEY-----", true),
        ("-----BEGIN.*OPENSSH PRIVATE KEY-----", true),
        ("-----BEGIN EC PRIVATE KEY-----", true),
        // API keys & tokens
        ("[a-zA-Z0-9]{20,}\\.[a-zA-Z0-9]{10,}\\.[a-zA-Z0-9_-]{50,}", true),
        ("AIza[0-9A-Za-z_-]{35}", true),
        ("AKIA[0-9A-Z]{16}", true),
        ("sq0csp-[0-9A-Za-z_-]{43}", true),
        ("sq0atp-[0-9A-Za-z_-]{22}", true),
        ("amzn\\.mws\\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", true),
        // Personal IDs
        ("\\b[1-9]\\d{5}(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx]\\b", true),  // China ID card (18-digit)
        ("\\b[1-9]\\d{7}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{2}\\b", true),                         // China ID card (15-digit)
        // Bank cards (16-19 digit, basic check — may overlap with some IDs but safe to flag)
        ("\\b(?:4\\d{15}|5[1-5]\\d{14}|3[47]\\d{13}|6(?:011|5\\d{2})\\d{12}|3(?:0[0-5]|[68]\\d)\\d{11}|9\\d{15})\\b", true),
        // US SSN
        ("\\b\\d{3}-\\d{2}-\\d{4}\\b", true),
        // JWT
        ("eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", true),
    ]

    // Pre-compiled regex patterns for sensitive value detection (R10: compile once)
    private lazy var sensitiveValueRegexes: [NSRegularExpression] = {
        let patterns = [
            "(?i)(password|passwd|pwd)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
            "(?i)(api_key|apikey|api-key)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
            "(?i)(token|bearer)\\s*[=:]\\s*['\"]?[a-zA-Z0-9_-]{20,}",
            "(?i)(sk|secret)\\s*[=:]\\s*['\"]?[^'\"\\s]{20,}",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // Pre-compiled regex patterns for sensitive pattern matching
    private lazy var sensitivePatternRegexes: [NSRegularExpression] = {
        let regexPatterns = sensitivePatterns.filter { $0.isRegex }.map { $0.pattern }
        return regexPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

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
                // Only mark large images (>= 10KB) as sensitive — small images are likely icons/emoji
                let isSensitive = imageData.count >= 10 * 1024
                let hours = ClipboardStore.shared.sensitiveClearHours
                let expiresAt: Date? = isSensitive && hours > 0 ? Date().addingTimeInterval(TimeInterval(hours * 3600)) : nil
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
        let range = NSRange(content.startIndex..., in: content)
        var regexIndex = 0

        for (pattern, isRegex) in sensitivePatterns {
            if isRegex {
                // R10: use pre-compiled regex at matching index
                if regexIndex < sensitivePatternRegexes.count {
                    if sensitivePatternRegexes[regexIndex].firstMatch(in: content, options: [], range: range) != nil {
                        return true
                    }
                }
                regexIndex += 1
            } else {
                if lowercased.contains(pattern) {
                    return true
                }
            }
        }

        // R10: use pre-compiled sensitive value regexes
        for regex in sensitiveValueRegexes {
            if regex.firstMatch(in: content, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }
}
