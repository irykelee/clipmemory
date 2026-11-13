import XCTest
@testable import ClipMemory

/// `ObserverTokenLifecycleTests` (ID-REVIEW-1027, 2026-11-13
/// auto-review P1-1)
///
/// Asserts the **observer-token lifecycle invariant** across the whole
/// production tree: every declared `NSObjectProtocol?` observer token
/// must be released by a `removeObserver` call inside a `deinit` block
/// of the same file.
///
/// Why this exists: the 2026-11-13 independent review flagged the two
/// storage-mirror observers as possibly leaking. Human adjudication
/// confirmed the *mechanism* was right — `storageMirrorFailedObserver`
/// and `storageMirrorRecoveredObserver` were registered but missing
/// from `AppDelegate.deinit` — even though the review's suggested fix
/// location (`applicationWillResignActive`) was wrong and would have
/// traded a leak for a functional regression. The repo has been bitten
/// by this exact omission before: the round-15 Finding A (2026-08-08) was
/// `trashLoadFailedObserver` registered but never removed, and the
/// "leak guard" comment has been carried on ID-CRASH-0007 / 0008 /
/// 0012 / 0022 / 0035 ever since.
///
/// The invariant is stated **generically** (every token in every file,
/// not the two that happened to be broken today) so the next observer
/// registered without a `deinit` removal is caught by CI instead of by
/// a reviewer.
///
/// Implementation note: the cleanup in this codebase always binds the
/// token to a local alias first — `if let o = <token> { …
/// removeObserver(o) }` — so the check matches the *binding*, not a
/// literal `removeObserver(<token>)`.
final class ObserverTokenLifecycleTests: XCTestCase {

    /// `private var xObserver: NSObjectProtocol?`, `private(set) var …`,
    /// `var …` — every access-modifier spelling the tree uses.
    private static let declarationPattern =
        #"(?m)^\s*(?:public|private|internal|fileprivate|open)?\s*(?:\(set\)\s*)?var\s+(\w+)\s*:\s*NSObjectProtocol\?"#

    /// `let nc = NSWorkspace.shared.notificationCenter` — the tree aliases
    /// the workspace centre locally in one place, so a centre comparison
    /// has to resolve aliases before it can compare anything.
    private static let centreAliasPattern = #"(?m)^\s*let\s+(\w+)\s*=\s*([\w.]+)\s*$"#

    /// `token = <centre>.addObserver( … )` — where the token was born.
    private static let registrationCentrePattern = #"(\w+)\s*=\s*([\w.]+)\.addObserver\s*\("#

    /// `if let alias = token { … <centre>.removeObserver( … ) }` — where the
    /// token was released. The centre is captured separately from the
    /// existing `removalPattern` because the two must MATCH, not merely
    /// both exist.
    private static let removalCentrePattern =
        #"if\s+let\s+\w+\s*=\s*(\w+)\s*\{[^{}]*?([\w.]+)\.removeObserver\s*\("#

    /// The only two notification centres this tree observes. A centre that
    /// does not normalise to one of these is reported rather than ignored:
    /// an unrecognised spelling must not silently pass as "released".
    private static let knownCentres: Set<String> = [
        "NotificationCenter.default",
        "NSWorkspace.shared.notificationCenter"
    ]

    /// `if let <alias> = <token> { … removeObserver( … ) }` — the shape
    /// every observer cleanup in the tree uses.
    private static let removalPattern = #"if\s+let\s+\w+\s*=\s*(\w+)\s*\{[^{}]*removeObserver\("#

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // …/Tests/ClipMemoryTests/<file>
            .deletingLastPathComponent()  // ClipMemoryTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    func testEveryDeclaredObserverTokenIsReleasedInDeinit() throws {
        let files = try Self.productionSwiftFiles()
        XCTAssertFalse(files.isEmpty, "no production sources found — the scan would be vacuous")

        var offenders: [String] = []
        var scannedTokens = 0

        for path in files {
            let source = try String(contentsOf: path, encoding: .utf8)
            let declared = Self.declaredObserverTokens(in: source)
            guard !declared.isEmpty else { continue }
            scannedTokens += declared.count

            let deinitBodies = Self.deinitBodies(in: source)
            XCTAssertFalse(
                deinitBodies.isEmpty,
                "\(Self.relative(path)) declares \(declared.count) observer token(s) but has no deinit to release them in"
            )

            let released = Set(deinitBodies.flatMap { Self.releasedObserverTokens(in: $0) })
            let leaked = declared.filter { !released.contains($0) }
            if !leaked.isEmpty {
                offenders.append("\(Self.relative(path)): \(leaked.sorted().joined(separator: ", "))")
            }
        }

        XCTAssertGreaterThan(scannedTokens, 0, "scanned 0 observer tokens — the scan would be vacuous")
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Observer tokens with no removeObserver in deinit — every token must \
            be released in the owning type's deinit (same leak guard as \
            trashLoadFailedObserver): \(offenders.sorted().joined(separator: " | "))
            """
        )
    }

    /// A separate, narrower assertion: the storage-mirror observers are
    /// the ones this round added, so pin them explicitly. If someone
    /// later drops them from the cleanup list, the generic test above
    /// fails too — but this one names the culprit in the failure text.
    func testTheStorageMirrorObserversAreReleasedInDeinit() throws {
        let path = Self.repoRoot.appendingPathComponent("ClipMemory/AppDelegate.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let deinitBodies = Self.deinitBodies(in: source)
        XCTAssertFalse(deinitBodies.isEmpty, "AppDelegate.swift has no deinit block")

        let released = Set(deinitBodies.flatMap { Self.releasedObserverTokens(in: $0) })
        for token in ["storageMirrorFailedObserver", "storageMirrorRecoveredObserver"] {
            XCTAssertTrue(
                released.contains(token),
                "\(token) is not released in AppDelegate.deinit — the observer token would outlive the delegate"
            )
        }
    }

    /// A second, independent invariant: the observer must be released from
    /// the **same** notification centre it was registered on.
    ///
    /// ID-REVIEW-1027 follow-up (2026-11-13, independent verifier F-1):
    /// the first version of this guard only checked that a `removeObserver`
    /// call existed somewhere in the deinit. Mutating the release to use
    /// the WRONG centre (`NSWorkspace.shared.notificationCenter` instead of
    /// `NotificationCenter.default`) kept the guard GREEN — but the token
    /// would then stay in `NotificationCenter.default`'s dispatch table
    /// forever. That is not a hypothetical: this repo shipped exactly that
    /// bug once (ID-APP-0002, `sessionDidResignActiveObserver` registered on
    /// `NotificationCenter.default` but released on the workspace centre).
    ///
    /// So "released" is now checked as a PAIR: same token, same centre.
    /// A centre that does not normalise to one of `knownCentres` is
    /// reported, not skipped — a spelling the guard cannot reason about
    /// must not read as "released".
    func testObserverTokenIsReleasedFromTheCentreItWasRegisteredOn() throws {
        let files = try Self.productionSwiftFiles()
        XCTAssertFalse(files.isEmpty, "no production sources found — the scan would be vacuous")

        var offenders: [String] = []
        var checked = 0

        for path in files {
            let source = try String(contentsOf: path, encoding: .utf8)
            let declared = Set(Self.declaredObserverTokens(in: source))
            guard !declared.isEmpty else { continue }

            let aliases = Self.centreAliases(in: source)
            let registered = Self.registrationCentres(in: source, aliases: aliases)
            let released = Self.removalCentres(in: source, aliases: aliases)

            for token in declared.sorted() {
                guard let centre = registered[token] else {
                    offenders.append("\(Self.relative(path)): \(token) — no registration centre found")
                    continue
                }
                guard let removal = released[token] else {
                    offenders.append("\(Self.relative(path)): \(token) — no removal centre found")
                    continue
                }
                guard Self.knownCentres.contains(centre) else {
                    offenders.append(
                        "\(Self.relative(path)): \(token) — registration centre '\(centre)' is not a known centre"
                    )
                    continue
                }
                guard Self.knownCentres.contains(removal) else {
                    offenders.append(
                        "\(Self.relative(path)): \(token) — release centre '\(removal)' is not a known centre"
                    )
                    continue
                }
                checked += 1
                if centre != removal {
                    offenders.append(
                        "\(Self.relative(path)): \(token) — registered on \(centre) but released on \(removal)"
                    )
                }
            }
        }

        XCTAssertGreaterThan(checked, 0, "checked 0 observer tokens — the scan would be vacuous")
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Observer tokens released from the wrong notification centre — a token must be \
            released from the SAME centre it was registered on: \
            \(offenders.sorted().joined(separator: " | "))
            """
        )
    }

    // MARK: - Scanning helpers

    private static func productionSwiftFiles() throws -> [URL] {
        let root = repoRoot.appendingPathComponent("ClipMemory")
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // `.lproj` bundles can carry .strings, not .swift — but skip
            // defensively so a stray localized source can't skew the scan.
            if url.pathExtension == "swift" && !url.path.contains(".lproj") {
                result.append(url)
            }
        }
        return result
    }

    private static func relative(_ url: URL) -> String {
        let root = repoRoot.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.lastPathComponent
    }

    private static func declaredObserverTokens(in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: declarationPattern) else { return [] }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[tokenRange])
        }
    }

    private static func releasedObserverTokens(in deinitBody: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: removalPattern) else { return [] }
        let range = NSRange(location: 0, length: (deinitBody as NSString).length)
        return regex.matches(in: deinitBody, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: deinitBody) else { return nil }
            return String(deinitBody[tokenRange])
        }
    }

    /// Extracts the body of every `deinit { … }` block.
    ///
    /// Brace counting is done per line, ignoring anything after a `//`
    /// comment so a brace inside a comment can't unbalance the scan. The
    /// tree's deinit bodies contain no string literals with braces, so
    /// no string-aware tokenizer is needed here.
    private static func deinitBodies(in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var bodies: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("deinit"), trimmed.hasSuffix("{") else {
                index += 1
                continue
            }
            var depth = 0
            var collected: [String] = []
            var cursor = index
            while cursor < lines.count {
                let code = lines[cursor].components(separatedBy: "//").first ?? lines[cursor]
                depth += code.filter { $0 == "{" }.count
                depth -= code.filter { $0 == "}" }.count
                collected.append(lines[cursor])
                if depth == 0, cursor > index { break }
                cursor += 1
            }
            bodies.append(collected.joined(separator: "\n"))
            index = cursor + 1
        }
        return bodies
    }

    // MARK: - Centre helpers

    /// Resolve `let nc = NSWorkspace.shared.notificationCenter` style
    /// aliases so two spellings of the same centre compare equal.
    ///
    /// Aliases are resolved for the WHOLE file, not in source order: the
    /// tree uses `nc` before the `let` that defines it (the observer is
    /// registered at the top of a function, the alias is declared further
    /// down in the same function), so an order-sensitive resolver would
    /// miss it.
    private static func centreAliases(in source: String) -> [String: String] {
        var aliases: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: centreAliasPattern) else { return [:] }
        let range = NSRange(location: 0, length: (source as NSString).length)
        for match in regex.matches(in: source, range: range) {
            guard match.numberOfRanges > 2,
                  let aliasRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else { continue }
            aliases[String(source[aliasRange])] = String(source[valueRange])
        }
        return aliases
    }

    /// Follow an alias chain to the expression it stands for. The `seen`
    /// set makes a self-referential alias terminate instead of looping.
    private static func normaliseCentre(_ expression: String, aliases: [String: String]) -> String {
        var current = expression.trimmingCharacters(in: .whitespaces)
        var seen: Set<String> = []
        while let target = aliases[current], !seen.contains(current) {
            seen.insert(current)
            current = target.trimmingCharacters(in: .whitespaces)
        }
        return current
    }

    /// token → the centre it was registered on.
    private static func registrationCentres(
        in source: String,
        aliases: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: registrationCentrePattern) else { return [:] }
        let range = NSRange(location: 0, length: (source as NSString).length)
        for match in regex.matches(in: source, range: range) {
            guard match.numberOfRanges > 2,
                  let tokenRange = Range(match.range(at: 1), in: source),
                  let centreRange = Range(match.range(at: 2), in: source) else { continue }
            let token = String(source[tokenRange])
            let centre = normaliseCentre(String(source[centreRange]), aliases: aliases)
            // A token registered twice on different centres cannot be
            // released from "the" centre — keep the first and let the
            // comparison below catch the disagreement.
            if let existing = result[token], existing != centre {
                result[token] = "\(existing) + \(centre)"
                continue
            }
            result[token] = centre
        }
        return result
    }

    /// token → the centre it was released on, taken from the deinit
    /// blocks only (the release has to live there, per the first
    /// invariant).
    private static func removalCentres(
        in source: String,
        aliases: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: removalCentrePattern) else { return [:] }
        for body in deinitBodies(in: source) {
            let range = NSRange(location: 0, length: (body as NSString).length)
            for match in regex.matches(in: body, range: range) {
                guard match.numberOfRanges > 2,
                      let tokenRange = Range(match.range(at: 1), in: body),
                      let centreRange = Range(match.range(at: 2), in: body) else { continue }
                let token = String(body[tokenRange])
                let centre = normaliseCentre(String(body[centreRange]), aliases: aliases)
                if let existing = result[token], existing != centre {
                    result[token] = "\(existing) + \(centre)"
                    continue
                }
                result[token] = centre
            }
        }
        return result
    }
}
