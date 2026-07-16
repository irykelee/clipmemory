import AppKit
import Foundation
import os.log
import Combine

class ClipboardMonitor: SensitiveDetectorProtocol {
    private var timer: DispatchSourceTimer?
    private let pasteboard = NSPasteboard.general
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "ClipboardMonitor")

    /// H9: Protects all mutable shared state from data races between main thread and timer queue.
    /// macOS 14+: OSAllocatedUnfairLock (modern, recommended). macOS 13: NSLock fallback.
    private let _stateLock: Any = {
        if #available(macOS 14, *) { return OSAllocatedUnfairLock<Void>() }
        return NSLock()
    }()

    private func withLock<T>(_ block: () throws -> T) rethrows -> T {
        if #available(macOS 14, *), let lock = _stateLock as? OSAllocatedUnfairLock<Void> {
            return try lock.withLock(block)
        }
        let lock = _stateLock as! NSLock
        lock.lock()
        defer { lock.unlock() }
        return try block()
    }

    private var _lastChangeCount: Int = 0
    private var lastChangeCount: Int {
        get { withLock { _lastChangeCount } }
        set { withLock { _lastChangeCount = newValue } }
    }

    /// Captured on main thread before timer fires; safe to read from timer queue.
    private var _captureRichText: Bool = true
    private var captureRichText: Bool {
        get { withLock { _captureRichText } }
        set { withLock { _captureRichText = newValue } }
    }

    /// Set to true when ClipboardStore writes to pasteboard, so we skip re-capturing.
    private var _skipNextCapture: Bool = false
    var skipNextCapture: Bool {
        get { withLock { _skipNextCapture } }
        set { withLock { _skipNextCapture = newValue } }
    }

    /// Bundle identifiers of apps to exclude from clipboard monitoring (e.g. password managers)
    private var _excludedBundleIds: Set<String> = []
    var excludedBundleIds: Set<String> {
        get { withLock { _excludedBundleIds } }
        set { withLock { _excludedBundleIds = newValue } }
    }

    /// Delegate for accessing store configuration (breaks circular dependency)
    weak var delegate: ClipboardMonitorDelegate?

    /// Cancellable for observing ClipboardStore settings changes
    private var settingsCancellable: AnyCancellable?

    /// Tracks the last known app that was frontmost before clipboard changed
    private var _lastKnownSourceBundleId: String?
    private var lastKnownSourceBundleId: String? {
        get { withLock { _lastKnownSourceBundleId } }
        set { withLock { _lastKnownSourceBundleId = newValue } }
    }

    /// Returns the bundle ID of the frontmost app, or nil if unavailable
    private func frontmostAppBundleId() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontApp.bundleIdentifier
    }

    let sensitivePatterns: [(pattern: String, isRegex: Bool)] = [
        // Credentials — non-regex keywords (may have minor false positives on rare normal text)
        ("pwd", false),
        ("passcode", false),
        ("ghp_", false),
        ("github_pat_", false),
        ("sk_live_", false),
        ("sk_test_", false),
        ("sk-", false),
        ("bearer", false),
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
        // Slack token
        ("xox[baprs]-[0-9a-zA-Z-]{10,}", true),
        // Discord bot token
        ("mfa\\.[\\w-]{84}", true),
        // OpenAI API key
        ("sk-[A-Za-z0-9]{48}", true),
        // Twilio API key
        ("SK[0-9a-fA-F]{32}", true),
        // SendGrid API key
        ("SG\\.[\\w-]{22}\\.[\\w-]{43}", true),
        // GitHub OAuth token
        ("gho_[0-9a-zA-Z]{36}", true),
        // npm access token
        ("npm_[A-Za-z0-9]{36}", true),
        // Heroku API key
        ("hbc_[0-9a-f]{48}", true),
        // Mailgun API key
        ("key-[0-9a-zA-Z]{32}", true),
        // Stripe keys
        ("sk_live_[0-9a-zA-Z]{24,}", true),
        ("rk_live_[0-9a-zA-Z]{24,}", true),
        // Personal IDs
        ("\\b[1-9]\\d{5}(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx]\\b", true),  // China ID card (18-digit)
        ("\\b[1-9]\\d{7}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}\\b", true),                         // China ID card (15-digit)
        // Bank cards (16-19 digit, basic check — may overlap with some IDs but safe to flag)
        ("\\b(?:4\\d{15}|5[1-5]\\d{14}|3[47]\\d{13}|6(?:011|5\\d{2})\\d{12}|3(?:0[0-5]|[68]\\d)\\d{11}|9\\d{15})\\b", true),
        // US SSN
        ("\\b\\d{3}-\\d{2}-\\d{4}\\b", true),
        // JWT
        ("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", true)
    ]

    // Pre-compiled regex patterns for sensitive value detection (R10: compile once)
    lazy var sensitiveValueRegexes: [NSRegularExpression] = {
        let patterns = [
            "(?i)(password|passwd|pwd)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
            "(?i)(api_key|apikey|api-key)\\s*[=:]\\s*['\"]?[^'\"\\s]+",
            "(?i)(token|bearer)\\s*[=:]\\s*['\"]?[a-zA-Z0-9_-]{20,}",
            "(?i)(sk|secret)\\s*[=:]\\s*['\"]?[^'\"\\s]{20,}",
            "(?i)(access_token|accesstoken)\\s*[=:]\\s*['\"]?[a-zA-Z0-9_-]{20,}",
            "(?i)(private.?key)\\s*[=:]\\s*['\"]?[A-Za-z0-9_-]{20,}"
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

    // Pre-compiled regex patterns paired with their source patterns — avoids index misalignment
    lazy var compiledSensitivePatterns: [(regex: NSRegularExpression, keyword: String)] = {
        sensitivePatterns.filter { $0.isRegex }.compactMap { entry in
            do {
                let regex = try NSRegularExpression(pattern: entry.pattern, options: .caseInsensitive)
                return (regex, entry.pattern)
            } catch {
                logger.error("Failed to compile sensitive pattern: \(entry.pattern) — \(error.localizedDescription)")
                return nil
            }
        }
    }()

    deinit { stopMonitoring() }

    func startMonitoring() {
        lastChangeCount = pasteboard.changeCount
        // Capture settings on main thread before timer fires
        captureRichText = ClipboardStore.shared.captureRichText
        // Observe future setting changes on main thread
        settingsCancellable = ClipboardStore.shared.$captureRichText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.captureRichText = newValue
            }
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
        settingsCancellable?.cancel()
        settingsCancellable = nil
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

        if let rtfData = pasteboard.data(forType: .rtf), !rtfData.isEmpty, self.captureRichText {
            processRichText(rtfData)
        } else if let content = pasteboard.string(forType: .string), !content.isEmpty {
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
        // Image size does not determine sensitivity — only content detection does.
        // Images are not auto-expired by size; storage is controlled by maxItems and manual clearing.
        let isSensitive = false
        let expiresAt: Date? = nil

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

    private func processRichText(_ rtfData: Data) {
        let plaintext = (try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
        let isSensitive = detectSensitive(plaintext)
        var expiresAt: Date?
        if isSensitive {
            let hours = delegate?.sensitiveClearHoursForMonitor() ?? 0
            if hours > 0 {
                expiresAt = Date().addingTimeInterval(TimeInterval(hours * 3600))
            }
        }
        let item = ClipboardItem(
            content: rtfData.base64EncodedString(),
            type: .richText,
            isSensitive: isSensitive,
            expiresAt: expiresAt
        )
        DispatchQueue.main.async {
            ClipboardStore.shared.addItem(item)
        }
    }

    func detectSensitive(_ content: String) -> Bool {
        // Reject pathological inputs that could cause quadratic regex backtracking.
        // Very long strings (> 50 KB) skip keyword/regex scanning and only check size.
        guard content.utf8.count <= 50_000 else { return false }

        let lowercased = content.lowercased()
        let range = NSRange(content.startIndex..., in: content)

        // Plain keyword check (non-regex)
        for (pattern, isRegex) in sensitivePatterns {
            if !isRegex && lowercased.contains(pattern) {
                return true
            }
        }

        // Pre-compiled regex check — paired with their source patterns to avoid index misalignment
        for (regex, _) in compiledSensitivePatterns where regex.firstMatch(in: content, options: [], range: range) != nil {
            return true
        }

        // R10: use pre-compiled sensitive value regexes
        for regex in sensitiveValueRegexes where regex.firstMatch(in: content, options: [], range: range) != nil {
            return true
        }

        return false
    }
}
