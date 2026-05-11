import AppKit
import Foundation
import os.log

class ClipboardMonitor {
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "ClipboardMonitor")

    /// Set to true when ClipboardStore writes to pasteboard, so we skip re-capturing.
    var skipNextCapture = false

    /// Bundle identifiers of apps to exclude from clipboard monitoring (e.g. password managers)
    var excludedBundleIds: Set<String> = []

    /// Delegate for accessing store configuration (breaks circular dependency)
    weak var delegate: ClipboardMonitorDelegate?

    /// Tracks the last known app that was frontmost before clipboard changed
    private var lastKnownSourceBundleId: String?

    /// Returns the bundle ID of the frontmost app, or nil if unavailable
    private func frontmostAppBundleId() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontApp.bundleIdentifier
    }

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
        ("eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", true)
    ]

    // Pre-compiled regex patterns for sensitive value detection (R10: compile once)
    private lazy var sensitiveValueRegexes: [NSRegularExpression] = {
        let patterns = [
            "(?i)(password|passwd|pwd)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
            "(?i)(api_key|apikey|api-key)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
            "(?i)(token|bearer)\\s*[=:]\\s*['\"]?[a-zA-Z0-9_-]{20,}",
            "(?i)(sk|secret)\\s*[=:]\\s*['\"]?[^'\"\\s]{20,}"
        ]
        var compiled: [NSRegularExpression] = []
        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                compiled.append(regex)
            } catch {
                logger.error("Failed to compile sensitive value regex: \(pattern) — \(error.localizedDescription)")
            }
        }
        return compiled
    }()

    // Pre-compiled regex patterns for sensitive pattern matching
    private lazy var sensitivePatternRegexes: [NSRegularExpression] = {
        let regexPatterns = sensitivePatterns.filter { $0.isRegex }.map { $0.pattern }
        var compiled: [NSRegularExpression] = []
        for pattern in regexPatterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                compiled.append(regex)
            } catch {
                logger.error("Failed to compile sensitive pattern regex: \(pattern) — \(error.localizedDescription)")
            }
        }
        return compiled
    }()

    deinit { stopMonitoring() }

    func startMonitoring() {
        lastChangeCount = pasteboard.changeCount
        // Track frontmost app changes via notification
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Initialize with current frontmost app
        lastKnownSourceBundleId = frontmostAppBundleId()

        let queue = DispatchQueue(label: "com.clipmemory.clipboardmonitor", qos: .utility)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: 0.5)
        timer?.setEventHandler { [weak self] in
            self?.checkClipboard()
        }
        timer?.resume()
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func appDidActivate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let bundleId = app.bundleIdentifier {
            lastKnownSourceBundleId = bundleId
        }
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

        // Skip if the source app is in the exclusion list (e.g. password managers)
        if let sourceApp = lastKnownSourceBundleId, excludedBundleIds.contains(sourceApp) {
            lastChangeCount = pasteboard.changeCount
            return
        }
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if let content = pasteboard.string(forType: .string), !content.isEmpty {
            let itemType = detectType(content)
            let isSensitive = detectSensitive(content)
            var expiresAt: Date?
            if isSensitive {
                let hours = delegate?.sensitiveClearHoursForMonitor() ?? 0
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
            processImageData(imageData)
        } else if let imageData = pasteboard.data(forType: .tiff), !imageData.isEmpty {
            processImageData(imageData)
        }
    }

    private func detectType(_ content: String) -> ClipboardItemType {
        if content.hasPrefix("http://") || content.hasPrefix("https://") {
            return .link
        }
        return .text
    }

    private func processImageData(_ imageData: Data) {
        let id = UUID()
        let isSensitive = imageData.count >= 50 * 1024
        let hours = delegate?.sensitiveClearHoursForMonitor() ?? 0
        let expiresAt: Date? = isSensitive && hours > 0 ? Date().addingTimeInterval(TimeInterval(hours * 3600)) : nil

        ImageStorage.shared.saveImage(imageData, id: id) { [weak self] filename in
            guard let filename = filename else { return }
            let item = ClipboardItem(
                id: id,
                content: filename,
                type: .image,
                isSensitive: isSensitive,
                expiresAt: expiresAt
            )
            ClipboardStore.shared.addItem(item)
        }
    }

    private func detectSensitive(_ content: String) -> Bool {
        let lowercased = content.lowercased()
        let range = NSRange(content.startIndex..., in: content)
        var regexIdx = 0

        for (pattern, isRegex) in sensitivePatterns {
            if isRegex {
                guard regexIdx < sensitivePatternRegexes.count else { return false }
                if sensitivePatternRegexes[regexIdx].firstMatch(in: content, options: [], range: range) != nil {
                    return true
                }
                regexIdx += 1
            } else if lowercased.contains(pattern) {
                return true
            }
        }

        // R10: use pre-compiled sensitive value regexes
        for regex in sensitiveValueRegexes where regex.firstMatch(in: content, options: [], range: range) != nil {
            return true
        }

        return false
    }
}
