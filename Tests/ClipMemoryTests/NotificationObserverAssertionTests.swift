import XCTest
@testable import ClipMemory

/// `NotificationObserverAssertionTests` (2026-08-08 user review):
///
/// Walks every custom `Notification.Name` declared in `ClipMemory/`
/// and asserts that each has at least one PRODUCTION observer — i.e.
/// an `addObserver(forName: ...)` or `.publisher(for: ...)` call
/// outside the `Tests/` tree. Implemented as a static-text scan
/// because Swift reflection can't enumerate static
/// `Notification.Name` properties without ObjC runtime interop.
///
/// Why this exists: the 2026-08-08 audit found that 3 of N custom
/// notifications were posted by production code but had ZERO observers
/// — the posts went nowhere. The post itself is the observable half
/// of "loud failure" — silently swallowing it defeats the purpose.
/// This test makes the invariant a CI gate.
///
/// CRITICAL (per user 2026-08-08 correction): custom notifications
/// are AUTO-DERIVED from a source regex scan, NOT hand-written.
/// Hand-writing them creates a "silent green" — any new notification
/// declared without an observer would silently pass if it wasn't in
/// the array. Auto-derivation closes that gap.
final class NotificationObserverAssertionTests: XCTestCase {

    // MARK: - Source-derived custom notifications

    /// Pattern A — `static let X = Notification.Name("Y")` style
    /// (most common): captures the property name (shortName) AND
    /// the rawValue. The shortName is the identifier used after `.`
    /// in Swift (e.g., `.encryptionFailed`); the rawValue is what's
    /// stored in the underlying `Notification.Name` (e.g.,
    /// `"ClipboardStore.encryptionFailed"`). They can differ when
    /// the module prefix and the short suffix don't share a common
    /// tail — e.g., `.trashLoadFailed` with rawValue
    /// `"TrashStore.loadFailed"`. Also matches the explicit-arg
    /// form `static let X = Notification.Name(rawValue: "Y")`.
    private static let staticNotificationPattern =
        #"static\s+let\s+(\w+)\s*=\s*Notification\.Name\((?:rawValue:\s*)?"([\w.]+)"\)"#

    /// Pattern B — inline literal `Notification.Name("Y")` style
    /// (no `static let` declaration). Captures only the rawValue;
    /// the shortName is derived from the rawValue's last segment.
    /// Excludes matches already captured by Pattern A (so we don't
    /// double-count when a file uses both styles). Also matches
    /// the explicit-arg form `Notification.Name(rawValue: "Y")`.
    private static let inlineNotificationPattern =
        #"Notification\.Name\((?:rawValue:\s*)?"([\w.]+)"\)"#

    /// Custom notifications derived from a source scan.
    /// (`shortName`, `rawValue`, `declaredAt`) — `declaredAt` is
    /// `<relativePath>:<lineNumber>` for the failure message.
    private struct DeclaredNotification {
        let shortName: String
        let rawValue: String
        let declaredAt: String
    }

    /// Lazy so the source scan runs once per test target (the file
    /// walker is fast even under Debug+coverage instrumentation — ~0.2s
    /// for ~70 files; the cache is a nicety, not a correctness need).
    private static let cachedDeclared: [DeclaredNotification] = {
        declaredNotifications()
    }()

    func testEveryCustomNotificationHasAtLeastOneProductionObserver() {
        let declared = Self.cachedDeclared
        let observers = productionObserversByNotificationName()
        let whitelisted = Set(knownZeroObserverWhitelist.map { $0.shortName })

        var failures: [String] = []
        for entry in declared where !whitelisted.contains(entry.shortName) {
            if (observers[entry.shortName] ?? []).isEmpty {
                failures.append("- \(entry.rawValue) (shortName `\(entry.shortName)`, declared at \(entry.declaredAt)): ZERO production observers.")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count) non-whitelisted custom Notification.Name(s) have zero production observers:\n"
                    + failures.joined(separator: "\n"))
        }
    }

    func testWhitelistEntriesStillHaveZeroObservers() {
        let observers = productionObserversByNotificationName()
        // Build a shortName → rawValue map from the declared scan
        let rawValueByShort: [String: String] = Dictionary(
            uniqueKeysWithValues: Self.cachedDeclared.map { ($0.shortName, $0.rawValue) }
        )
        var leaks: [String] = []
        for entry in knownZeroObserverWhitelist {
            let count = (observers[entry.shortName] ?? []).count
            if count > 0 {
                let raw = rawValueByShort[entry.shortName] ?? entry.shortName
                leaks.append("- \(raw) (shortName `\(entry.shortName)`): \(count) observer(s) found. "
                              + "REMOVE FROM `knownZeroObserverWhitelist` now that the observer exists.")
            }
        }
        if !leaks.isEmpty {
            XCTFail("Whitelist entries that now have observers — REMOVE FROM `knownZeroObserverWhitelist`:\n"
                    + leaks.joined(separator: "\n"))
        }
    }

    /// Whitelist of notifications currently without observers.
    /// `ledgerID` is the ledger entry these fall under (or "(none)"
    /// if there's no formal ID — they're tracked as "dead channels"
    /// in H-1 scope). `reason` is the short justification.
    ///
    /// Per user 2026-08-08 review: M-9 (Gitee token) and M-2 (import
    /// trim bypassing trash) are dead channels but those IDs don't
    /// cover these specific notifications. The notifications
    /// themselves are posted with no consumer — that gap is the
    /// H-1 "dead channel" batch.
    private struct WhitelistEntry {
        let shortName: String
        let ledgerID: String
        let reason: String
    }
    private let knownZeroObserverWhitelist: [WhitelistEntry] = [
        WhitelistEntry(
            shortName: "tagBackendCorrupted",
            ledgerID: "(none — v2 audit H-1 dead channels list at v2 report :28/:34)",
            reason: "Posted in `ClipboardStore.loadTags` only; consumer (Settings diagnostics banner) is reserved channel per audit CLIP-7, no observer yet."),
        // H-1 (2026-08-08): clipboardSaveFailed now has a real consumer
        // — AppDelegate.clipboardSaveFailedObserver wires NSAlert via the
        // existing 60s EncryptionFailedAlertThrottler. Removed from the
        // whitelist so the observer-gate reverse-assertion enforces it.
        WhitelistEntry(
            shortName: "ocrLanguageFallback",
            ledgerID: "ID-SYNC-0004 (post itself FIXED; consumer leg deferred to H-1)",
            reason: "Posted in OCRService when language list unsupported; consumer (Settings banner 'OCR using English') is reserved channel per v2 audit H-1 (dead channels list at v2 report :28/:34), no observer yet."),
    ]

    // MARK: - Source scan

    /// Repo root for the scan. Uses `#filePath` so the test works in
    /// any working directory (CI checks out under e.g.
    /// `/Users/runner/work/...`, not `/Users/iryke/Projects/ClipMemory`).
    /// The test file lives at `<repo>/Tests/ClipMemoryTests/...` —
    /// walk up 3 levels.
    private var repoRoot: String {
        let here = #filePath
        let testFile = (here as NSString).lastPathComponent
        precondition(testFile == "NotificationObserverAssertionTests.swift",
                     "test file relocation detected — recompute repoRoot path components")
        let dir = (here as NSString).deletingLastPathComponent  // ClipMemoryTests/
        let parent = (dir as NSString).deletingLastPathComponent // Tests/
        return (parent as NSString).deletingLastPathComponent   // <repo>
    }

    /// Returns `[(relativePath, absolutePath)]` for every .swift file
    /// under `repoRoot/ClipMemory` (excluding `Tests/`).
    private static func allSwiftSourceFiles(in root: String) -> [(String, String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [(String, String)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            if url.path.contains("/Tests/") { continue }
            results.append((url.lastPathComponent, url.path))
        }
        return results
    }

    /// Discover all custom notifications by scanning ClipMemory/
    /// for both `static let X = Notification.Name("Y")` and inline
    /// `Notification.Name("Y")` literals. De-duplicates: inline
    /// literals whose rawValue is already covered by a `static let`
    /// are dropped.
    private static func declaredNotifications() -> [DeclaredNotification] {
        let root = "\(repoRootFromStaticContext())/ClipMemory"
        let files = allSwiftSourceFiles(in: root)
        var byShortName: [String: DeclaredNotification] = [:]
        var rawValues: Set<String> = []

        // Pass 1: static let — captures both shortName AND rawValue
        guard let staticRe = try? NSRegularExpression(
            pattern: staticNotificationPattern
        ) else { return [] }
        for (_, absPath) in files {
            guard let contents = try? String(contentsOfFile: absPath, encoding: .utf8) else { continue }
            let lines = contents.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                let lineNum = idx + 1
                let range = NSRange(location: 0, length: (line as NSString).length)
                let matches = staticRe.matches(in: line, options: [], range: range)
                for m in matches where m.numberOfRanges >= 3 {
                    let shortName = (line as NSString).substring(with: m.range(at: 1))
                    let rawValue = (line as NSString).substring(with: m.range(at: 2))
                    let rel = (absPath as NSString).lastPathComponent
                    byShortName[shortName] = DeclaredNotification(
                        shortName: shortName,
                        rawValue: rawValue,
                        declaredAt: "\(rel):\(lineNum)"
                    )
                    rawValues.insert(rawValue)
                }
            }
        }

        // Pass 2: inline literals — only add if rawValue not already covered
        guard let inlineRe = try? NSRegularExpression(
            pattern: inlineNotificationPattern
        ) else { return Array(byShortName.values) }
        for (_, absPath) in files {
            guard let contents = try? String(contentsOfFile: absPath, encoding: .utf8) else { continue }
            let lines = contents.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                let lineNum = idx + 1
                // Skip lines already captured by static pass
                if line.contains("static let ") && line.contains("= Notification.Name(") { continue }
                let range = NSRange(location: 0, length: (line as NSString).length)
                let matches = inlineRe.matches(in: line, options: [], range: range)
                for m in matches where m.numberOfRanges >= 2 {
                    let rawValue = (line as NSString).substring(with: m.range(at: 1))
                    // De-duplicate: if a `static let X = Notification.Name("Y")`
                    // already added this rawValue in Pass 1, skip the inline
                    // duplicate. (System notifications like NSCalendarDayChanged-
                    // Notification appear inline only — they get added once
                    // here, then dedup is a no-op on subsequent lines.)
                    if rawValues.contains(rawValue) { continue }
                    rawValues.insert(rawValue)
                    // For inline literals, derive shortName from rawValue's
                    // last segment after the final `.`.
                    let shortName = String(rawValue.split(separator: ".").last ?? "")
                    guard !shortName.isEmpty else { continue }
                    let rel = (absPath as NSString).lastPathComponent
                    byShortName[shortName] = DeclaredNotification(
                        shortName: shortName,
                        rawValue: rawValue,
                        declaredAt: "\(rel):\(lineNum)"
                    )
                }
            }
        }

        return Array(byShortName.values).sorted { $0.shortName < $1.shortName }
    }

    /// `#filePath` is not usable from a static context (instance
    /// property), so the static scanner resolves the repo root from
    /// this test file's path at static-init time. Same 3-level walk.
    private static func repoRootFromStaticContext() -> String {
        let here = #filePath
        let dir = (here as NSString).deletingLastPathComponent
        let parent = (dir as NSString).deletingLastPathComponent
        return (parent as NSString).deletingLastPathComponent
    }

    // MARK: - Observer scan

    /// Returns `[shortName: [sourceLocation]]` so failures point at
    /// the actual observer site. The observer scan walks `ClipMemory/`
    /// and matches two patterns:
    ///  - `addObserver(forName: ...)` (NotificationCenter block API)
    ///  - `.publisher(for: .xyz)` (Combine `.onReceive`)
    ///
    /// Known blind spots (documented per user 2026-08-08 review):
    ///  - Comment lines containing `publisher(for: .xyz)` (e.g.
    ///    `Views/QuickBarView.swift:332`) are matched as observers
    ///    — harmless false positives (the reverse assertion catches
    ///    if a real observer is added but the comment still
    ///    references an older name)
    ///  - Selector-style `addObserver(self, selector:, name:)` not
    ///    captured (only 1 site in the project: ClipboardMonitor.swift:207)
    private func productionObserversByNotificationName()
        -> [String: [String]]
    {
        var result: [String: [String]] = [:]
        let root = "\(repoRoot)/ClipMemory"
        let files = Self.allSwiftSourceFiles(in: root)
        for (_, absPath) in files {
            guard let contents = try? String(contentsOfFile: absPath, encoding: .utf8) else { continue }
            let lines = contents.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                let lineNum = idx + 1
                let rel = (absPath as NSString).lastPathComponent
                if line.contains("addObserver(") && !line.contains("removeObserver(") {
                    let window = (idx..<min(lines.count, idx + 4))
                        .map { lines[$0] }
                        .joined(separator: "\n")
                    // Pattern A: `forName: .shortName` (post-V-2.8.0 style)
                    if let name = extractNotificationName(after: "forName:", in: window) {
                        result[name, default: []].append("\(rel):\(lineNum)")
                    }
                    // Pattern B: `forName: Notification.Name("rawValue")` (inline
                    // literal — used in AppDelegate.swift:297, ClipboardStore.swift:378).
                    // The rawValue may equal a shortName from the static
                    // declarations (e.g. "LanguageDidChange" matches the
                    // implicit shortName) OR be a fully-qualified module path
                    // (e.g. "ImageStorageMigrationCompleted"). We index by
                    // both so the lookup finds a match regardless of which
                    // form the consumer used.
                    let inlineMatches = matchesPattern(in: window, pattern: #"forName:\s*Notification\.Name\("([\w.]+)"\)"#)
                    for rawValue in inlineMatches {
                        result[rawValue, default: []].append("\(rel):\(lineNum)")
                        // Also index by last segment so a consumer that
                        // uses `.foo` (where the static declaration has
                        // rawValue "Module.foo") can match.
                        if let lastSegment = rawValue.split(separator: ".").last {
                            result[String(lastSegment), default: []].append("\(rel):\(lineNum)")
                        }
                    }
                }
                if line.contains("publisher(") {
                    // publisher( is the call start; for: .X or
                    // for: Notification.Name(...rawValue...) may be on
                    // the same line or the next 1-2 lines. Use a window
                    // so multi-line forms are captured.
                    let window = (idx..<min(lines.count, idx + 3))
                        .map { lines[$0] }
                        .joined(separator: "\n")
                    let names = matchesPattern(in: window, pattern: #"for:\s*(?:Notification\.Name\((?:rawValue:\s*)?"([\w.]+)"|\.([\w.]+))"#)
                    for short in names {
                        if !short.isEmpty {
                            result[short, default: []].append("\(rel):\(lineNum)")
                        }
                    }
                }
            }
        }
        return result
    }

    /// Given a snippet AFTER a known marker (e.g., `forName:`),
    /// extract the dotted identifier like `.encryptionFailed`.
    /// Stops at the next non-identifier char (`,`, `)`, space, etc.).
    private func extractNotificationName(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let afterMarker = text[range.upperBound...]
        var idx = afterMarker.startIndex
        while idx < afterMarker.endIndex, afterMarker[idx].isWhitespace {
            idx = afterMarker.index(after: idx)
        }
        guard idx < afterMarker.endIndex, afterMarker[idx] == "." else { return nil }
        idx = afterMarker.index(after: idx)
        let nameStart = idx
        while idx < afterMarker.endIndex,
              afterMarker[idx].isLetter || afterMarker[idx].isNumber || afterMarker[idx] == "_" {
            idx = afterMarker.index(after: idx)
        }
        if idx == nameStart { return nil }
        return String(afterMarker[nameStart..<idx])
    }

    /// Returns captured group values for each regex match in `text`.
    /// Tries groups 1..<n in order and returns the first non-empty
    /// value. This handles alternation patterns where the value
    /// appears in different groups depending on which branch matched
    /// (e.g., publisher regex matches either `Notification.Name("X")`
    /// — value in group 1 — or `.X` — value in group 2).
    private func matchesPattern(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return re.matches(in: text, options: [], range: range).compactMap { result -> String? in
            for i in 1..<result.numberOfRanges {
                let r = result.range(at: i)
                if r.location != NSNotFound {
                    let s = nsText.substring(with: r)
                    if !s.isEmpty { return s }
                }
            }
            return nil
        }
    }
}
