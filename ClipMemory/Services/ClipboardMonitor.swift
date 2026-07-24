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
    /// C3: the unfair-lock storage and its cast share one #available branch, and the
    /// NSLock fallback needs no cast at all — there is no `as!` trap path left, so a
    /// future storage change degrades to NSLock instead of crashing the polling queue.
    private let _unfairLock: Any? = {
        if #available(macOS 14, *) { return OSAllocatedUnfairLock<Void>() }
        return nil
    }()
    private let _nsLock = NSLock()

    private func withLock<T>(_ block: () throws -> T) rethrows -> T {
        if #available(macOS 14, *), let lock = _unfairLock as? OSAllocatedUnfairLock<Void> {
            return try lock.withLock(block)
        }
        _nsLock.lock()
        defer { _nsLock.unlock() }
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

    /// Atomic compound update for `excludedBundleIds` (per gate 1b Medium #5 fix).
    /// The compound operation `var ids = monitor.excludedBundleIds; ids.insert(...);
    /// monitor.excludedBundleIds = ids` is racy — the getter and setter each
    /// take the lock individually but the read-modify-write window is unprotected.
    /// This method takes the lock once for the whole mutation, eliminating the
    /// TOCTOU race that loses inserted/removed entries under concurrent load.
    ///
    /// Usage:
    /// ```
    /// monitor.updateExcludedBundleIds { ids in
    ///     ids.insert("com.testbed.target")
    ///     ids.remove("com.example.legitimateapp")
    /// }
    /// ```
    func updateExcludedBundleIds(_ block: (inout Set<String>) -> Void) {
        withLock {
            var copy = _excludedBundleIds
            block(&copy)
            _excludedBundleIds = copy
        }
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
        // Capture settings on main thread before timer fires.
        // H-13 (2026-07-20 audit): route through `delegate` so this class
        // doesn't reach into the `ClipboardStore.shared` singleton. The
        // publisher forward stays live for the lifetime of the monitor.
        captureRichText = delegate?.captureRichTextSettingForMonitor() ?? true
        settingsCancellable = delegate?.captureRichTextPublisher
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

        // H-1 (2026-07-21 audit fix): Pre-heat lazy regex compilation on the
        // main thread BEFORE the timer resumes. Swift's `lazy var` is not
        // thread-safe; without this, the first clipboard event from the
        // timer queue (`com.clipmemory.clipboardmonitor`) racing with a
        // background `processRichText` call on
        // `DispatchQueue.global(qos: .userInitiated)` could trigger
        // undefined behavior (crash / double-init) on first capture that
        // happens to be rich-text.
        _ = sensitiveValueRegexes
        _ = compiledSensitivePatterns
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
        // L-1 (2026-07-21 audit): the original check-then-act was two separate
        // lock acquisitions; a recordOwnWrite() landing between the read and the
        // false-write could re-set the flag back to true after we cleared it,
        // defeating the skip and re-capturing our own write. Wrap the read+clear
        // in a single withLock so the toggle is atomic with respect to the
        // observer. lastChangeCount is set outside the lock on the next line as
        // before — that field is independently protected by its own lock-aware
        // accessor and not in L-1's scope.
        let shouldSkip = withLock { () -> Bool in
            if _skipNextCapture {
                _skipNextCapture = false
                return true
            }
            return false
        }
        if shouldSkip {
            lastChangeCount = pasteboard.changeCount
            return
        }

        // Skip if the source app is in the exclusion list (e.g. password managers)
        if let sourceApp = lastKnownSourceBundleId,
           excludedBundleIds.contains(sourceApp.lowercased()) {
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
            DispatchQueue.main.async { [weak delegate] in
                // H-13: hand the item to the store via delegate. Going
                // through `delegate?` rather than `ClipboardStore.shared`
                // means a future delegate implementation (preview-only,
                // multi-store replay, etc.) works without touching this file.
                delegate?.monitorDidCaptureItem(item)
            }
        } else if let imageData = Self.firstImageData(read: { pasteboard.data(forType: $0) }) {
            processImageData(imageData)
        }
    }

    /// H-1 (2026-07-24 audit): the pasteboard image UTIs to probe, in
    /// priority order. PNG/TIFF win via their built-in `.png` / `.tiff`
    /// constants; JPEG / HEIC / GIF / JPEG-2000 / BMP don't have
    /// NSPasteboard.PasteboardType constants (only PNG and TIFF do —
    /// confirmed via Apple docs 2026-07-24) so they're built from raw
    /// UTI strings. The capture path iterates this list and takes the
    /// first non-empty hit. JPEG screenshots from Preview/Safari and
    /// HEIC phone photos copied via AirDrop were silently dropped
    /// before — they're capturable now.
    static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("public.jpeg-2000"),
        NSPasteboard.PasteboardType("com.microsoft.bmp")
    ]

    /// H-1 (2026-07-24 audit): extract image data from a pasteboard across
    /// all common image UTI types. First non-empty hit wins. `read` is
    /// injected so tests can stub the pasteboard without touching the host.
    static func firstImageData(read: (NSPasteboard.PasteboardType) -> Data?) -> Data? {
        for type in imagePasteboardTypes {
            if let data = read(type), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// CLIP-1: deterministic dedup fingerprint for captured image bytes.
    /// Keyed HMAC-SHA256 over the base64 of the raw data — same style as the
    /// text-item contentHash (`CryptoService.hmacHex`), so the hash can't
    /// serve as an offline dictionary oracle. The base64 hop keeps the
    /// CryptoServiceProtocol surface unchanged (string in, hex out). Static
    /// so tests can call it directly with an injected ServiceContainer.crypto.
    /// Returns nil on crypto failure; callers then store without a dedup
    /// fingerprint, same contract as text items.
    static func imageContentHash(for imageData: Data) -> String? {
        ServiceContainer.crypto.hmacHex(for: imageData.base64EncodedString())
    }

    private func detectType(_ content: String) -> ClipboardItemType {
        // L-1 (2026-07-24 audit): mailto:/ftp:/file:/www. were silently
        // downgraded to .text, losing the link styling (and any downstream
        // link-aware affordances). www. is bare (no scheme) and commonly
        // copied from browsers / chat; treat it as a link so the user can
        // click through after the OS auto-completes the scheme.
        if content.hasPrefix("http://") || content.hasPrefix("https://")
            || content.hasPrefix("mailto:") || content.hasPrefix("ftp://")
            || content.hasPrefix("file://") || content.hasPrefix("www.") {
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
        // CLIP-1: fingerprint the image bytes BEFORE saving so the item
        // carries a contentHash into ClipboardStore.addItem. Without it the
        // store's dedup branch can never match images — the item's `content`
        // is a fresh UUID filename that differs on every capture — and each
        // re-copy of the same image produced a new file + a new list entry.
        let contentHash = Self.imageContentHash(for: imageData)

        ImageStorage.shared.saveImage(imageData, id: id) { [weak self] filename in
            guard let filename = filename else { return }
            let item = ClipboardItem(
                id: id,
                content: filename,
                type: .image,
                isSensitive: isSensitive,
                expiresAt: expiresAt,
                contentHash: contentHash
            )
            // H-13: route through delegate; was `ClipboardStore.shared.addItem(item)`.
            self?.delegate?.monitorDidCaptureItem(item)
            // On-device OCR for search + text extraction (non-blocking).
            if self?.delegate?.ocrEnabledForMonitor() == true {
                VisionOCRService.shared.recognizeText(in: imageData) { text in
                    guard let text = text, !text.isEmpty else { return }
                    self?.delegate?.monitorDidRecognizeText(text, forImageItemId: id)
                }
            }
        }
    }

    private func processRichText(_ rtfData: Data) {
        // H-11 (2026-07-20 audit): NSAttributedString RTF parse is synchronous
        // and can take 100s of ms on large pastes — being called from the
        // 0.5s clipboard poll queue that's already running captureRichText
        // evaluation. Hand it off to a userInitiated queue so the poll keeps
        // ticking; addItem back to the main thread once plaintext is in hand.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let plaintext = (try? NSAttributedString(
                data: rtfData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ))?.string ?? ""
            let isSensitive = self.detectSensitive(plaintext)
            var expiresAt: Date?
            if isSensitive {
                let hours = self.delegate?.sensitiveClearHoursForMonitor() ?? 0
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
            DispatchQueue.main.async { [weak delegate] in
                // H-13: same singleton-out pattern as `processImageData` —
                // route the acceptance through the delegate.
                delegate?.monitorDidCaptureItem(item)
            }
        }
    }

    func detectSensitive(_ content: String) -> Bool {
        // Reject pathological inputs that could cause quadratic regex backtracking.
        // Very long strings (> 50 KB) skip keyword/regex scanning and only check size.
        guard content.utf8.count <= 50_000 else { return false }

        let range = NSRange(content.startIndex..., in: content)

        // Plain keyword check (non-regex) — M-1 (2026-07-24 audit): the prior
        // implementation built `content.lowercased()` (a second O(n) scan +
        // full-string allocation) only to call `.contains(pattern)` on it.
        // Case-insensitive substring search on the original string produces
        // identical matches without the intermediate allocation.
        for (pattern, isRegex) in sensitivePatterns {
            if !isRegex && content.range(of: pattern, options: .caseInsensitive) != nil {
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
