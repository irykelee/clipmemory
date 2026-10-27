import Foundation
import XCTest

/// Shared source-scanning helpers for the test tree's static guards.
///
/// Extracted 2026-10-27 (ID-REVIEW-1041) so that `Review1040RegressionTests`
/// and `Review1041RegressionTests` scan the tree the SAME way. Two guards that
/// disagree about what counts as a "site" would each be able to hide the
/// other's hole — the exact shape of defect ID-REVIEW-1038's M4 lesson
/// (a rule that never fired looked green because its own control group had
/// the same shape as the rule's blind spot).
enum TestSourceScanner {

    /// The directory that holds the test sources.
    static var testDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// The directory that holds the APP sources.
    ///
    /// Two levels up from the test directory (`…/Tests/ClipMemoryTests`) is
    /// the repository root; the app target lives in `ClipMemory/` beside it.
    static var appDirectory: URL {
        testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClipMemory")
    }

    /// Raised when the scanner cannot find a tree it was told to scan.
    ///
    /// ⚠️ It THROWS rather than returning an empty list on purpose: a guard
    /// that scans zero files passes vacuously, and a vacuous guard is
    /// indistinguishable from a working one (the ID-REVIEW-1038 M4 lesson).
    enum ScannerError: Error, CustomStringConvertible {
        case directoryMissing(String)

        var description: String {
            switch self {
            case .directoryMissing(let path):
                return "the scanner was pointed at a directory that does not exist: \(path)"
            }
        }
    }

    /// Every Swift file in the test tree, sorted by path.
    ///
    /// `excluded` holds FILE NAMES (not paths). The guards exclude the files
    /// that necessarily contain the patterns they look for — their own
    /// source, and the one helper that is allowed to make the call.
    static func testSourceFiles(excluding excluded: Set<String> = []) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: testDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if excluded.contains(url.lastPathComponent) { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Every Swift file in the APP tree, sorted by path.
    ///
    /// ID-REVIEW-1042 (2026-10-27): the app tree needed its own scan — the
    /// 1041 guard watches the TEST tree, and only the app tree can prove
    /// that no PRODUCTION path reaches the user's clipboard.
    ///
    /// Throws when the directory is missing, so a moved app tree makes the
    /// guard RED instead of vacuously green.
    static func appSourceFiles(excluding excluded: Set<String> = []) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScannerError.directoryMissing(appDirectory.path)
        }
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: appDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if excluded.contains(url.lastPathComponent) { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The path of `url` relative to the test directory.
    static func relativePath(of url: URL) -> String {
        relativePath(of: url, relativeTo: testDirectory)
    }

    /// The path of `url` relative to the APP directory.
    static func appRelativePath(of url: URL) -> String {
        relativePath(of: url, relativeTo: appDirectory)
    }

    /// The path of `url` relative to `base`.
    ///
    /// Computed by path COMPONENT, not by string prefix: `FileManager
    /// .enumerator` resolves symlinks while `appendingPathComponent` does
    /// not, so a prefix replacement silently degrades in a symlinked
    /// checkout (measured 2026-10-27, ID-REVIEW-1039).
    static func relativePath(of url: URL, relativeTo base: URL) -> String {
        let file = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let baseComponents = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard file.count > baseComponents.count,
              Array(file.prefix(baseComponents.count)) == baseComponents else {
            return url.lastPathComponent
        }
        return file.dropFirst(baseComponents.count).joined(separator: "/")
    }

    /// How many times the source names the SYSTEM-WIDE general pasteboard.
    ///
    /// The scan runs on a BLANKED copy (comments and string literals replaced
    /// by spaces) ⇒ a doc comment mentioning the API is not a use, and a
    /// sample inside a string literal is not a use either.
    ///
    /// ⚠️ ONE definition, shared by the 1041 guard (TEST tree) and the 1042
    /// guard (APP tree). Two guards that disagree about what counts as a
    /// "site" would each be able to hide the other's hole — the exact shape
    /// of defect ID-REVIEW-1038's M4 lesson.
    static func generalPasteboardUses(in source: String) -> Int {
        occurrenceCount(of: "NSPasteboard.general", in: blankingCommentsAndStrings(source))
    }

    /// How many times `needle` occurs in `source`.
    ///
    /// Counts OCCURRENCES, not lines: two sites on one line are two sites —
    /// counting distinct lines would let the second hide behind the first
    /// (the independent verifier found exactly that hole in ID-REVIEW-1040).
    static func occurrenceCount(of needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = source.startIndex
        while let found = source.range(of: needle, range: index..<source.endIndex) {
            count += 1
            index = found.upperBound
            if index >= source.endIndex { break }
        }
        return count
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Replace comments and string literals with spaces, preserving line
    /// structure.
    ///
    /// A hand-rolled scanner is needed because the obvious shortcut — "skip
    /// a match whose line prefix contains `//`" — is wrong in both
    /// directions: a `//` inside a string literal (`http://…`) hides a real
    /// call on the same line, and a `/* … */` block comment is not filtered
    /// at all.
    ///
    /// ⚠️ The two rules below are waived for this function **on purpose**:
    /// it is a single-pass, character-level scanner whose complexity comes
    /// from the lexical cases it must tell apart (`//`, `/* */`, `"`,
    /// multi-line `"` × 3, escapes). Splitting it into helpers would need an
    /// `inout` cursor threaded through every branch — the readability cost
    /// is larger than the metric it buys. Same pattern as
    /// `CryptoService.swift` (`file_length`) and `BackupPackage.swift`.
    static func blankingCommentsAndStrings(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        func isNewline(_ c: Character) -> Bool { c == "\n" }
        while i < chars.count {
            let c = chars[i]
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && !isNewline(chars[i]) {
                    out.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                while i < chars.count {
                    if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                        out.append("  ")
                        i += 2
                        break
                    }
                    out.append(isNewline(chars[i]) ? "\n" : " ")
                    i += 1
                }
                continue
            }
            if c == "\"" && i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                // A MULTI-LINE string literal (`"""…"""`).
                //
                // ⚠️ This case is NOT optional. Without it, the naive
                // single-quote scan below blanks `""` (the first two quotes
                // of the opening delimiter) and then keeps scanning the
                // literal's CONTENT as if it were code ⇒ a planted pattern
                // inside a `"""` block reads as a real call.
                // Measured 2026-10-27 (ID-REVIEW-1041): the guard's own
                // positive-control sample lived in a `"""` block and the
                // scanner reported it as a real use.
                out.append("   ")
                i += 3
                while i < chars.count {
                    if chars[i] == "\"" && i + 2 < chars.count
                        && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                        out.append("   ")
                        i += 3
                        break
                    }
                    if chars[i] == "\\" && i + 1 < chars.count {
                        out.append(" ")
                        out.append(isNewline(chars[i + 1]) ? "\n" : " ")
                        i += 2
                        continue
                    }
                    out.append(isNewline(chars[i]) ? "\n" : " ")
                    i += 1
                }
                continue
            }
            if c == "\"" {
                // A string literal. Swift also has raw strings;
                // the naive scan is good enough for a test-tree guard and
                // errs on the side of blanking.
                out.append(" ")
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        out.append(" ")
                        out.append(isNewline(chars[i + 1]) ? "\n" : " ")
                        i += 2
                        continue
                    }
                    if chars[i] == "\"" {
                        out.append(" ")
                        i += 1
                        break
                    }
                    out.append(isNewline(chars[i]) ? "\n" : " ")
                    i += 1
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}
