import Foundation

/// ID-CRASH-0002 (2026-08-16 audit MEDIUM-1 fix): the macOS Crash Reporter
/// service writes user crash reports to
/// `~/Library/Logs/DiagnosticReports/<ProcessName>-<timestamp>.ips`
/// (Sonoma+, JSON format) or `.crash` (older, text format). Until this
/// service shipped, the only way for a user to dig into a ClipMemory
/// crash was to open Console.app and hunt — many users gave up and
/// filed a "the app disappeared" report that didn't help us debug
/// anything. The Help → View Recent Crashes menu now lists, sorts by
/// mtime, and offers Reveal-in-Finder / Open-in-Console buttons for
/// every report.
///
/// The service does NOT symbolicate — that's a separate post-mortem
/// step that requires the matching dSYM (now shipped as a Release
/// asset per ID-CRASH-0001) and `atos`. We display the binary image
/// name + offset pairs from the crash report so the user can paste
/// them into a symbolication command themselves, or hand the .ips
/// file to us directly.
struct CrashReport: Identifiable, Equatable {
    let id: String                // filename, also serves as SwiftUI list id
    let date: Date
    let processName: String
    let exceptionType: String     // e.g. "EXC_BAD_ACCESS" or "NSException"
    let signal: String?           // e.g. "SIGABRT" (only set for signal-style exceptions)
    let binaryImages: [BinaryImage]
    let firstFrames: [StackFrame]
    let fileURL: URL

    /// `BinaryImage` mirrors the `usedImages[]` entry of an .ips file.
    /// Image name (without extension) + UUID are what `atos -o` needs
    /// to look up the right dSYM; the offset is what `l` (load address)
    /// plus `atos` walks to produce a symbol name.
    struct BinaryImage: Equatable {
        let name: String           // e.g. "ClipMemory"
        let uuid: String           // e.g. "4C4C444C-5555-3144-A15A-..."
        let loadAddress: String    // 64-bit hex string
    }

    /// `StackFrame` is what the UI shows in the truncated stack column.
    /// `imageIndex` indexes into `binaryImages`; `imageOffset` is the
    /// offset into the binary image (the value `atos` needs).
    /// `symbol` is the *post-symbolication* symbol name (filled in by
    /// the OS before the report is written), so we display it when
    /// present and fall back to "imageIndex + offset" when the report
    /// predates the local dSYM install.
    struct StackFrame: Equatable {
        let imageIndex: Int
        let imageOffset: Int
        let symbol: String?
    }

    var firstFrameLine: String {
        guard let frame = firstFrames.first else { return "(no frames)" }
        let imageName = binaryImages[safe: frame.imageIndex]?.name ?? "?"
        if let symbol = frame.symbol, !symbol.isEmpty {
            return "\(imageName) → \(symbol)"
        }
        return "\(imageName) + \(frame.imageOffset)"
    }
}

extension Array {
    /// Safe subscript that returns nil for out-of-range indices. Used by
    /// `CrashReport.firstFrameLine` where the report's imageIndex might
    /// be malformed (corrupt report or a frame from a stripped binary).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// ID-CRASH-0002: enumerates and parses ClipMemory crash reports from
/// the user's DiagnosticReports directory.
///
/// Singleton because the macOS directory location is fixed
/// (`~/Library/Logs/DiagnosticReports/`) and there's no value in
/// multiple instances — the menu item needs a stable target to show.
/// The `directory` initializer parameter exists for tests to inject a
/// fixture directory without monkey-patching `HOME`.
@MainActor
final class CrashReportService {
    static let shared = CrashReportService()

    /// Maximum reports to enumerate. DiagnosticReports retains every
    /// report the system has written for the lifetime of the install;
    /// the file picker UI doesn't gain anything from listing 200
    /// items, and the file I/O cost on each `viewDidAppear` adds up.
    /// `nonisolated` because it's a constant — no actor isolation
    /// needed for a plain Int literal, and we want callers outside
    /// the actor (e.g. tests, callers passing an explicit override)
    /// to be able to reference it without a hop.
    nonisolated static let listLimit = 50

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        if let directory = directory {
            self.directory = directory
        } else {
            // ~/Library/Logs/DiagnosticReports/ is per-user; no need to
            // resolve the real path through FileManager.url(for: .libraryDirectory)
            // because the path is fixed across macOS versions.
            self.directory = URL(fileURLWithPath: NSString("~/Library/Logs/DiagnosticReports/").expandingTildeInPath)
        }
        self.fileManager = fileManager
    }

    /// Enumerates crash reports for this app, sorted by mtime descending.
    ///
    /// Returns an empty array (NOT throws) when the directory doesn't
    /// exist — first-launch users won't have it. Throws only for I/O
    /// errors we couldn't anticipate (permission revoked mid-scan, etc.)
    /// so the caller can surface a NSAlert rather than silently
    /// swallowing (per CLAUDE.md 2026-08-08 three-piece gate).
    func listRecentCrashReports(limit: Int = listLimit) throws -> [CrashReport] {
        // The directory is opt-in (created on first crash). Don't make
        // a brand-new install see "Failed to open Recent Crashes" — the
        // empty-state view covers this case.
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        let clipURLs = urls.filter {
            $0.lastPathComponent.hasPrefix("ClipMemory-") &&
            ($0.pathExtension == "ips" || $0.pathExtension == "crash")
        }
        let withDates = clipURLs.compactMap { url -> (URL, Date)? in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, mtime)
        }
        let sorted = withDates.sorted { $0.1 > $1.1 }
        return sorted.prefix(limit).compactMap { parseReport(at: $0.0, mtime: $0.1) }
    }

    // MARK: - Parsing

    /// Parses a single .ips or .crash file into a `CrashReport`. Returns
    /// nil when the file is unparseable (corrupt report, foreign format)
    /// rather than throwing — the caller shows "report unparseable" for
    /// that file rather than the whole list failing.
    ///
    /// The `.ips` format on Sonoma+ is a JSON header line followed by a
    /// JSON array (one element per line for diff-friendliness). The
    /// header has the human-readable fields (app_name, timestamp); the
    /// array has the structured crash data (exception, threads,
    /// usedImages). We parse both halves, then merge.
    ///
    /// The `.crash` (pre-Sonoma text format) is unsupported here — the
    /// deployment target is macOS 13 so we don't expect to see them,
    /// but we list the file in the directory scan anyway so the user
    /// can reveal it in Finder / Console.app.
    private func parseReport(at url: URL, mtime: Date) -> CrashReport? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        if url.pathExtension == "ips" {
            return parseIPS(raw: raw, url: url, mtime: mtime)
        }

        // .crash text format: best-effort filename + mtime fallback so
        // the user can still reveal it. Symbolication is out of scope.
        let processName = url.deletingPathExtension().lastPathComponent
            .components(separatedBy: "-").first ?? "ClipMemory"
        return CrashReport(
            id: url.lastPathComponent,
            date: mtime,
            processName: processName,
            exceptionType: "(legacy .crash format — reveal in Finder)",
            signal: nil,
            binaryImages: [],
            firstFrames: [],
            fileURL: url
        )
    }

    private func parseIPS(raw: String, url: URL, mtime: Date) -> CrashReport? {
        // The .ips file is a JSON header (first line) followed by a
        // JSON array (subsequent lines, one element per line for
        // diff-friendliness). Split on newlines to recover the two
        // halves; concatenate the rest to reconstruct the array.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let headerLine = lines.first else { return nil }
        let body = lines.dropFirst().joined(separator: "\n")

        let headerData = Data(headerLine.utf8)
        guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { return nil }

        let bodyData = Data(body.utf8)
        // The body shape varies by macOS release: pre-Ventura used a
        // JSON array of objects, Sonoma+ uses a single multi-line JSON
        // object (Apple's "JSON Lines-lite" diff-friendly format).
        // Accept either by trying array first, falling back to single
        // object. Missing or malformed body still lets us render the
        // header (date + process name) — the caller shows the file in
        // the table with placeholder exception type so the user can
        // still reveal it in Finder.
        let bodyObjects: [[String: Any]]
        if let parsed = try? JSONSerialization.jsonObject(with: bodyData) {
            if let array = parsed as? [[String: Any]] {
                bodyObjects = array
            } else if let single = parsed as? [String: Any] {
                bodyObjects = [single]
            } else {
                bodyObjects = []
            }
        } else {
            bodyObjects = []
        }

        // Header fields we care about. Fall back to mtime when the
        // header's timestamp is missing or malformed (a real .ips from
        // a third-party tool may omit it).
        let processName = (header["app_name"] as? String) ?? "ClipMemory"
        let date: Date = {
            guard let ts = header["timestamp"] as? String else { return mtime }
            return ipsTimestampFormatter.date(from: ts) ?? mtime
        }()

        // Walk the body objects for the exception record and the
        // triggered thread. .ips puts the crash data inline as one
        // big object, not in a labelled array, so we filter by
        // key presence.
        var exceptionType = "(no exception field)"
        var signal: String? = nil
        var binaryImages: [CrashReport.BinaryImage] = []
        var triggeredThreadFrames: [CrashReport.StackFrame] = []

        for obj in bodyObjects {
            if let exception = obj["exception"] as? [String: Any] {
                exceptionType = (exception["type"] as? String) ?? exceptionType
                signal = exception["signal"] as? String
            }
            if let usedImages = obj["usedImages"] as? [[String: Any]] {
                binaryImages = usedImages.compactMap { dict in
                    guard let name = dict["name"] as? String,
                          let uuid = dict["uuid"] as? String else { return nil }
                    // loadAddress arrives as either a hex string
                    // ("0x100000000") or a number (rare). Normalize.
                    let loadAddress: String
                    if let str = dict["base"] as? String {
                        loadAddress = str
                    } else if let num = dict["base"] as? UInt64 {
                        loadAddress = String(format: "0x%llx", num)
                    } else {
                        loadAddress = "?"
                    }
                    return CrashReport.BinaryImage(name: name, uuid: uuid, loadAddress: loadAddress)
                }
            }
            if let threads = obj["threads"] as? [[String: Any]] {
                for thread in threads {
                    let triggered = thread["triggered"] as? Bool ?? false
                    guard triggered else { continue }
                    if let frames = thread["frames"] as? [[String: Any]] {
                        triggeredThreadFrames = frames.compactMap { dict in
                            let imageIndex = (dict["imageIndex"] as? Int) ?? -1
                            let imageOffset = (dict["imageOffset"] as? Int) ?? 0
                            let symbol = dict["symbol"] as? String
                            return CrashReport.StackFrame(
                                imageIndex: imageIndex,
                                imageOffset: imageOffset,
                                symbol: symbol
                            )
                        }
                    }
                    break
                }
            }
        }

        return CrashReport(
            id: url.lastPathComponent,
            date: date,
            processName: processName,
            exceptionType: exceptionType,
            signal: signal,
            binaryImages: binaryImages,
            firstFrames: Array(triggeredThreadFrames.prefix(5)),
            fileURL: url
        )
    }

    /// Formatter for the .ips header timestamp format
    /// (`"2026-08-13 11:26:40.00 +0800"`). Apple's docs specify this
    /// exact format; fall back to mtime when unparseable so we never
    /// crash the UI from a bad header.
    private let ipsTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
}