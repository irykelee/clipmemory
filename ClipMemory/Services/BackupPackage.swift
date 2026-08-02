import Foundation
import CryptoKit
import CommonCrypto
import os.log

/// Export/import of a `.clipmemory` package (zip archive).
///
/// Layout:
///   manifest.json  {formatVersion, createdAt, appVersion, keySalt, itemCount, tagCount, imageCount}
///   key.enc        machine key encrypted with a passphrase-derived key (HKDF-SHA256 + AES-GCM)
///   items.json / tags.json / trash.json   raw encrypted store blobs
///   Images/        encrypted image files
///
/// The passphrase is mandatory: without it the package key would be a bare copy
/// of the machine's encryption key. GCM's auth tag doubles as passphrase check.
enum BackupPackageError: Error, Equatable {
    case wrongPassword
    case invalidPackage
    case unsupportedFormatVersion(Int)
    case missingKeyMaterial
    case archiveFailed
    /// M-10 (2026-07-20 audit): the OS CSPRNG reported a non-success status
    /// during salt/nonce generation; we cannot produce a deterministic HKDF
    /// output from a zero-filled buffer, so surface the failure rather
    /// than silently shipping a weak salt.
    case secureRandomUnavailable
    /// M-1 spec §3.2 (2026-07-21): `CCKeyDerivationPBKDF` returned a non-success
    /// status — surface rather than silently ship a weak/zero derived key.
    case pbkdf2Failure
    /// M-1 spec §3.2 (2026-07-21): package's `keyDerivationVersion` is outside
    /// the supported set {1, 2}. Distinct from `unsupportedFormatVersion` (which
    /// is about the overall package data format) so log / test can pinpoint
    /// the actual blocker.
    case unsupportedKeyDerivationVersion(Int)
    /// BUG-024 (2026-07-22): file-level corruption that breaks the
    /// whole-package transaction. Distinct from `invalidPackage`
    /// (manifest/keyfile structure) and `wrongPassword` (key check):
    /// these files parse cleanly but contain corrupt data the
    /// decoder or file system rejected.
    case corruptedData(String, BackupFileSource)
}

/// BUG-024 (2026-07-22): identifies which JSON/file in a `.clipmemory`
/// package failed to read or decode, so logs can pinpoint the offending
/// file and tests can assert against a stable enum case. `.image` carries
/// the filename via the `corruptedData` reason string, not here.
enum BackupFileSource: String, Equatable, Sendable {
    case items
    case trash
    case tags
    case image
    /// M-7 (2026-07-24 audit): distinguish "manifest file missing or
    /// unreadable" / "manifest JSON corrupt" from the generic .invalidPackage
    /// the import path used to throw, so logs and tests can pinpoint the
    /// failing file rather than collapsing every early-stage failure into
    /// the same error case.
    case manifest
}

struct BackupManifest: Codable {
    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var keySalt: String
    var itemCount: Int
    var tagCount: Int
    var imageCount: Int
    /// ID-BACKUP-0001 (2026-07-31): trash.json entry count. Optional so
    /// packages written before this field existed (which also had the
    /// itemCount-excludes-trash bug) stay importable — nil means "not
    /// declared, skip the trash count check".
    var trashCount: Int? = nil
    /// M-1 fix (2026-07-21): backup packages used HKDF-SHA256 to derive a
    /// key from a passphrase, but HKDF is unsuitable for passphrase-to-key
    /// derivation — it has no work factor. An attacker with the package can
    /// crack weak passphrases in milliseconds using a dictionary attack
    /// (baked into Hashcat as mode 1600). PBKDF2-HMAC-SHA256 with 600 000
    /// iterations (OWASP 2023) raises that cost by ~10⁵. Old packages (no
    /// `keyDerivationVersion` field) default to version 1 (HKDF) on read.
    var keyDerivationVersion: Int = 2

    enum CodingKeys: String, CodingKey {
        case formatVersion, createdAt, appVersion, keySalt
        case itemCount, tagCount, imageCount, trashCount, keyDerivationVersion
    }
}

/// M-1 spec §3.1 (2026-07-21): custom decoder lives in extension so Swift
/// still synthesizes the memberwise init that `exportPackage` relies on
/// (reviewer H-1 fix). Default missing `keyDerivationVersion` field to 1
/// so the HKDF read path activates transparently for legacy `.clipmemory`
/// files written by pre-M-1 ClipMemory (v2.5.8 and earlier).
extension BackupManifest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        keySalt = try container.decode(String.self, forKey: .keySalt)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        tagCount = try container.decode(Int.self, forKey: .tagCount)
        imageCount = try container.decode(Int.self, forKey: .imageCount)
        // ID-BACKUP-0001: absent in pre-2026-07-31 packages → skip the
        // trash count check for them.
        trashCount = try container.decodeIfPresent(Int.self, forKey: .trashCount)
        // Default HKDF (version 1) for old packages without this field.
        keyDerivationVersion = try container.decodeIfPresent(Int.self, forKey: .keyDerivationVersion) ?? 1
    }
}

struct BackupImportResult {
    var itemsImported = 0
    var itemsSkipped = 0
    var tagsImported = 0
    var imagesImported = 0
    /// BUG-024 (2026-07-22): count of items dropped because their
    /// content failed GCM auth (per-entry corruption, not package-level).
    /// Distinct from `itemsSkipped` (dedupe by id/contentHash).
    var itemsSkippedCorrupt = 0
}

final class BackupPackage {
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "BackupPackage")
    private static let currentFormatVersion = 1

    // MARK: - Passphrase key derivation

    /// M-1 fix: version 1 used HKDF-SHA256 (no work factor, vulnerable to
    /// dictionary attack). Version 2 uses PBKDF2-HMAC-SHA256 with 600 000
    /// iterations (OWASP 2023) — ~10⁵× slower than HKDF for weak passphrases.
    private static let pbkdf2Iterations = 600_000

    /// BKP-3 (2026-07-24 audit): cap on items.json / trash.json / tags.json
    /// blob size inside a package. These are JSON arrays of encrypted store
    /// entries — orders of magnitude below 100 MB in practice. A larger file
    /// means a hostile or corrupt package that would OOM the process via
    /// `Data(contentsOf:)` before the decoder ever runs. Same fail-closed
    /// style as the M-2 image cap (50 MB) below.
    private static let maxStoreBlobBytes = 100 * 1024 * 1024

    /// BKP-5 (2026-08-02 audit): cap on manifest.json / key.enc inside a
    /// package — the last two import-path reads without a size guard
    /// (BKP-3 covers the store blobs, M-2 the images). The manifest is
    /// <1 KB and key.enc is exactly 60 bytes in practice, so 1 MB is
    /// generous headroom. A larger file means a hostile or corrupt
    /// package that would OOM the process via `Data(contentsOf:)` —
    /// same fail-closed discipline as BKP-3.
    private static let maxManifestBytes = 1 * 1024 * 1024

    static func deriveKey(passphrase: String, salt: Data, version: Int = 2) throws -> SymmetricKey {
        switch version {
        case 1:
            // Legacy HKDF path for old packages.
            let inputKeyMaterial = SymmetricKey(data: Data(passphrase.utf8))
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKeyMaterial,
                salt: salt,
                info: Data("clipmemory-backup-v1".utf8),
                outputByteCount: 32
            )
        case 2:
            // PBKDF2-HMAC-SHA256.
            var derivedKey = Data(count: 32)
            let passphraseData = Data(passphrase.utf8)
            let derivationStatus = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
                salt.withUnsafeBytes { saltBytes in
                    passphraseData.withUnsafeBytes { passphraseBytes in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passphraseBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                            passphraseData.count,
                            saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            UInt32(pbkdf2Iterations),
                            derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            32
                        )
                    }
                }
            }
            guard derivationStatus == errSecSuccess else {
                // NEW-2 (2026-07-21): zero the buffer before throw too — on
                // failure the derived bytes are still sensitive.
                derivedKey.resetBytes(in: 0..<32)
                throw BackupPackageError.pbkdf2Failure
            }
            // NEW-2 (2026-07-21): defense-in-depth. SymmetricKey copies the
            // bytes — zero the source buffer AFTER the copy, not before.
            // (Bug found in test: zeroing before SymmetricKey(data:) makes
            // the key all zeros, which silently corrupts AES-GCM and
            // breaks testImportWithWrongPasswordFailsAndWritesNothing.)
            // Salt and passphrase are caller-owned; out of scope here.
            let key = SymmetricKey(data: derivedKey)
            derivedKey.resetBytes(in: 0..<32)
            return key
        default:
            throw BackupPackageError.unsupportedKeyDerivationVersion(version)
        }
    }

    // MARK: - ditto helpers

    /// L-10 (2026-07-24 audit): callers pass argv *without* the executable
    /// prefix. Previously `runDitto` accepted `["ditto", "-c", ...]` and used
    /// `arguments.dropFirst()` to strip it — fragile if a caller added an
    /// extra leading element, and obscured the contract. The executable is
    /// owned by `runDitto` itself; callers describe only the args.
    private static func zipDirectory(_ source: URL, to destination: URL) throws {
        try runDitto(args: ["-c", "-k", "--sequesterRsrc", source.path, destination.path])
    }

    private static func unzipArchive(_ archive: URL, to destination: URL) throws {
        // ID-SECURITY-0006 (2026-08-01 audit): enumerate zip members BEFORE
        // extraction and reject hostile paths outright — ditto -x would
        // otherwise write `../` members outside the staging root before
        // validateExtractedTree ever gets a chance to inspect the tree.
        try validateArchiveMembers(archive)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try runDitto(args: ["-x", "-k", archive.path, destination.path])
        try validateExtractedTree(at: destination)
    }

    /// ID-SECURITY-0006 (2026-08-01 audit): pre-extraction member check.
    /// Lists the archive's central directory via `unzip -Z1` (one member per
    /// line, no size/date columns to parse) and refuses the package as
    /// corrupt if any member contains a `..` path component, is an absolute
    /// path, or uses backslash separators (Windows-style traversal). Runs
    /// BEFORE `ditto -x` so a hostile member never reaches the filesystem —
    /// validateExtractedTree (BKP-2) remains as the post-extraction net for
    /// symlinks and resolved-path escapes.
    private static func validateArchiveMembers(_ archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain stdout BEFORE waiting so a large member list can't deadlock
        // the child on a full pipe buffer.
        let listingData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BackupPackageError.archiveFailed }
        let listing = String(decoding: listingData, as: UTF8.self)
        for rawLine in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let member = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !member.isEmpty else { continue }
            let hasDotDot = member.split(separator: "/").contains("..")
            guard !hasDotDot, !member.hasPrefix("/"), !member.contains("\\") else {
                logger.error("Backup package contains unsafe archive member: \(member)")
                throw BackupPackageError.corruptedData(
                    "unsafe archive member: \(member)", .manifest
                )
            }
        }
    }

    /// BKP-2 (2026-07-24 audit): `ditto -x` extracts whatever the zip
    /// declares, with no sanity checks — a hostile `.clipmemory` can carry
    /// symbolic links (later `Data(contentsOf:)` follows them and reads
    /// arbitrary files outside the sandbox of the staging dir, e.g. an
    /// Images/ entry pointing at ~/Library) or `../` member paths that
    /// escape the staging root entirely. Enumerate the extracted tree
    /// BEFORE any file is consumed and reject the package as corrupt when
    /// any entry is a symlink or resolves outside `staging`.
    private static func validateExtractedTree(at staging: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else {
            throw BackupPackageError.corruptedData("extracted package not enumerable", .manifest)
        }
        // resolvingSymlinksInPath so a `staging` path that itself sits under
        // a symlinked temp dir (common on macOS: /var → /private/var) still
        // compares correctly against resolved children.
        let stagingRoot = staging.standardizedFileURL.resolvingSymlinksInPath().path
        while let entry = enumerator.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                logger.error("Backup package contains symbolic link: \(entry.lastPathComponent)")
                throw BackupPackageError.corruptedData(
                    "symbolic link in package: \(entry.lastPathComponent)", .manifest
                )
            }
            let resolved = entry.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved == stagingRoot || resolved.hasPrefix(stagingRoot + "/") else {
                logger.error("Backup package entry escapes staging dir: \(entry.path)")
                throw BackupPackageError.corruptedData(
                    "package entry escapes staging dir: \(entry.lastPathComponent)", .manifest
                )
            }
        }
    }

    /// Runs `/usr/bin/ditto` with the given args and blocks the caller until
    /// completion or the 30 s safety-net timeout. See L-14 below for the
    /// timeout / SIGKILL policy.
    /// M-6 (2026-07-24 audit): the block is a `DispatchSemaphore.wait`, so
    /// callers MUST already be on a background thread. Both production call
    /// sites (`ContentView.exportBackup` / `importBackup`) dispatch to a
    /// `.userInitiated` global queue first — keep that contract if a new
    /// caller is added.
    private static func runDitto(args: [String]) throws {
        // 30s safety net (LOW, 2026-07-20 audit): without a timeout a stuck
        // `ditto` (broken pipe, SMB stall, sandbox entitlement missing on a
        // future macOS release) could block the main thread forever — UI
        // comes back to life only after we terminate the child here. Long
        // enough for any legitimate large archive, short enough that the
        // user can retry instead of force-quitting the app.
        // BUG-022 (2026-07-21): the previous loop polled every 50 ms with
        // Thread.sleep — main thread stays blocked the full timeout window
        // even when ditto exits cleanly at 200 ms, and the SIGKILL escalation
        // is racy (process.isRunning read from a non-atomic getter).
        // terminationHandler signals a semaphore the instant ditto exits, so
        // we wake immediately on success or failure. The 30 s timeout is kept
        // as a safety net; on timeout we still terminate and verify before
        // any escalation (L-14 below).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = args
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        try process.run()
        let timedOut = semaphore.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            // L-14 (2026-07-24 audit): capture the pid now — by the time the
            // grace-period block runs below, the kernel may have reused the
            // PID for an unrelated process, and SIGKILL on the wrong process
            // is far worse than leaving an orphaned `ditto` to be reaped.
            let pid = process.processIdentifier
            process.terminate()  // async SIGTERM
            // SIGTERM is async — give ditto up to 5 s to flush and exit on
            // its own. After the grace period, use `kill(pid, 0)` as a soft
            // existence check: ESRCH means the child is gone (nothing to do);
            // a successful probe means the PID is alive but may now belong to
            // a *different* process, so we DO NOT escalate to SIGKILL —
            // log the situation and let the OS reap on shutdown instead.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                let stillAlive = (kill(pid, 0) == 0)
                guard stillAlive else { return }
                BackupPackage.logger.warning(
                    "runDitto: child pid \(pid) did not exit within 5 s SIGTERM grace period; skipping SIGKILL to avoid hitting a reused PID"
                )
            }
            throw BackupPackageError.archiveFailed
        }
        guard process.terminationStatus == 0 else { throw BackupPackageError.archiveFailed }
    }

    /// Runs `work` synchronously on the main thread.
    ///
    /// C2 fix (2026-07-29 audit): the previous `DispatchQueue.main.sync`
    /// was a deadlock hazard if the call graph ever reversed (main →
    /// background → `onMain`). `MainActor.assumeIsolated` makes the
    /// "we're on main" requirement a runtime trap instead of a silent
    /// block, and the closure signature is now `@MainActor` so the type
    /// system flags misuses at the call site.
    ///
    /// ID-SYNC-0001 (2026-07-30 audit): the C2 fix introduced a regression
    /// — backup import runs `importPackage` from `DispatchQueue.global`
    /// (`BackupSettingsView:155`), which then calls `onMain` and traps
    /// because the caller isn't on MainActor. Restore the threading-jump
    /// semantic: assumeIsolated only when already on the main thread,
    /// otherwise hop via `DispatchQueue.main.sync`. Main-thread callers
    /// stay lock-free (no `main.sync` re-entry); background callers get a
    /// sync hop to main, which is the original intent.
    private static func onMain<T>(_ work: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            // Already on main thread (which IS the MainActor's executor on
            // macOS) — safe to assumeIsolated without dispatching.
            return try MainActor.assumeIsolated(work)
        }
        // Background caller — hop to main synchronously. The closure type
        // demands MainActor isolation; DispatchQueue.main.sync executes on
        // the main queue (== MainActor's executor), satisfying the
        // isolation. No deadlock because the caller is not on main.
        return try DispatchQueue.main.sync(execute: work)
    }

    /// L-11 (2026-07-24 audit): maps the UserDefaults key used in the export
    /// manifest loop to the `BackupFileSource` enum so the `corruptedData`
    /// error pinpoints the failing file rather than collapsing every parse
    /// failure into a generic message.
    private static func source(forKey key: String) -> BackupFileSource {
        switch key {
        case "ClipboardItems": return .items
        case "ClipMemoryTags": return .tags
        case "ClipboardTrashedItems": return .trash
        default: return .items  // unreachable in current caller, defensive default
        }
    }

    // MARK: - Export

    /// Writes a `.clipmemory` package for the current store contents.
    static func exportPackage(
        to destination: URL,
        passphrase: String,
        defaults: UserDefaults = .standard,
        imagesDirectory: URL,
        keyData: Data
    ) throws {
        let salt = try randomBytes(16)
        let derivedKey = try deriveKey(passphrase: passphrase, salt: salt, version: 2)
        let sealedKey = try AES.GCM.seal(keyData, using: derivedKey)
        guard let sealedKeyData = sealedKey.combined else { throw BackupPackageError.missingKeyMaterial }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmemory-export-\(UUID().uuidString)", isDirectory: true)
        defer {
            // ID-07 (2026-07-30 audit): staging-dir leak on every export if
            // removeItem fails (file held open, permissions denied). macOS
            // cleans /tmp on reboot but session-long users accumulate orphans.
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                Self.logger.warning("Failed to clean export staging directory (orphan in /tmp): \(error.localizedDescription, privacy: .public) path=\(staging.path, privacy: .public)")
            }
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Store blobs (still encrypted with the machine key)
        //
        // L-11 (2026-07-24 audit): silently coerced `try?` decode failures to
        // a count of 0, so a corrupt items/tags/trash blob produced a manifest
        // claiming the package is smaller than it actually is — the on-disk
        // data and the manifest then disagreed, and a future `importPackage`
        // would use the wrong counts. Now: log + throw `corruptedData`, the
        // existing package-corruption error, so the export fails loudly
        // instead of producing a misleading manifest.
        var counts = (items: 0, tags: 0, trash: 0)
        for (filename, key) in [("items.json", "ClipboardItems"), ("tags.json", "ClipMemoryTags"), ("trash.json", "ClipboardTrashedItems")] {
            guard let data = defaults.data(forKey: key) else { continue }
            try data.write(to: staging.appendingPathComponent(filename), options: .atomic)
            do {
                switch key {
                case "ClipboardItems":
                    counts.items = try JSONDecoder().decode([ClipboardItem].self, from: data).count
                case "ClipMemoryTags":
                    counts.tags = try JSONDecoder().decode([Tag].self, from: data).count
                default:
                    counts.trash = try JSONDecoder().decode([ClipboardItem].self, from: data).count
                }
            } catch {
                Self.logger.error("Backup manifest count decode failed for \(key): \(error.localizedDescription)")
                throw BackupPackageError.corruptedData("\(key) count decode failed", source(forKey: key))
            }
        }

        var imageCount = 0
        if FileManager.default.fileExists(atPath: imagesDirectory.path) {
            let imagesDestination = staging.appendingPathComponent("Images", isDirectory: true)
            try FileManager.default.copyItem(at: imagesDirectory, to: imagesDestination)
            // BKP-4 (2026-07-24 review): count only .png files — the import
            // side only accepts .png, so counting every staged file (stray
            // .DS_Store etc.) made the manifest disagree with the importable
            // payload.
            imageCount = ((try? FileManager.default.contentsOfDirectory(atPath: imagesDestination.path)) ?? [])
                .filter { $0.hasSuffix(".png") }.count
        }

        try sealedKeyData.write(to: staging.appendingPathComponent("key.enc"), options: .atomic)

        let manifest = BackupManifest(
            formatVersion: currentFormatVersion,
            createdAt: Date(),
            appVersion: AppVersion.current,
            keySalt: salt.base64EncodedString(),
            itemCount: counts.items,
            tagCount: counts.tags,
            imageCount: imageCount,
            // ID-BACKUP-0001: declare the trash count explicitly — the
            // importer validates items.json against itemCount only, and
            // trash.json against this field.
            trashCount: counts.trash,
            keyDerivationVersion: 2
        )
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        // BUG-023 (2026-07-21): the old `removeItem` then `zipDirectory` was
        // non-atomic — if zip failed (disk full, permission, sandbox block),
        // the previous backup was already deleted and no new one existed,
        // leaving the user with zero backups. Build the zip at a temp path
        // first; if it succeeds, atomically replace the destination (or move
        // into place if the destination is new). A failed zip leaves both
        // the old backup and the temp file untouched.
        let tempDestination = destination.deletingLastPathComponent()
            .appendingPathComponent(".clipmemory-export-\(UUID().uuidString).tmp")
        do {
            try zipDirectory(staging, to: tempDestination)
        } catch {
            // ID-09 (2026-07-30 audit): the inner try? swallowed the
            // cleanup-failure error. The original error is re-thrown, but
            // the cleanup-failure was invisible. Log it so the user can
            // see the half-zipped file leaking space.
            do {
                try FileManager.default.removeItem(at: tempDestination)
            } catch {
                Self.logger.warning("Failed to clean half-zipped export temp file: \(error.localizedDescription, privacy: .public) path=\(tempDestination.path, privacy: .public)")
            }
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            // replaceItem keeps `destination` valid until the swap is
            // committed; on success the temp file takes its place.
            var resultingURL: NSURL?
            _ = try FileManager.default.replaceItem(
                at: destination,
                withItemAt: tempDestination,
                backupItemName: nil,
                options: [],
                resultingItemURL: &resultingURL
            )
        } else {
            try FileManager.default.moveItem(at: tempDestination, to: destination)
        }
        logger.info("Exported backup package to \(destination.path)")
    }

    // MARK: - Import

    /// Imports a `.clipmemory` package, re-encrypting every item with the local
    /// machine key and merging into the store (dedupe by id, then contentHash).
    ///
    /// H-5 (2026-07-24 audit): **no internal transaction / no rollback.**
    /// The function merges `items.json` + `trash.json` into the store FIRST,
    /// then `tags.json`, then attempts each image. If the image loop throws
    /// (decrypt-auth failure, file I/O error), the previously-merged items
    /// and tags are NOT reverted — the caller is responsible for guaranteeing
    /// a rollback point beforehand. The only existing caller
    /// (`ContentView.importBackup`) does this via `backupService.backupNow()`
    /// on the call site; if a second caller is added it MUST do the same, or
    /// a mid-import image failure will silently leave the user with a
    /// half-overwritten clipboard history and no recovery point.
    static func importPackage(
        from archive: URL,
        passphrase: String,
        store: ClipboardStore,
        localCrypto: CryptoServiceProtocol,
        imagesDirectory: URL,
        defaults: UserDefaults = .standard
    ) throws -> BackupImportResult {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmemory-import-\(UUID().uuidString)", isDirectory: true)
        defer {
            // ID-08 (2026-07-30 audit): same orphan-dir pattern as ID-07 on
            // the import path. One orphan per import.
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                Self.logger.warning("Failed to clean import staging directory (orphan in /tmp): \(error.localizedDescription, privacy: .public) path=\(staging.path, privacy: .public)")
            }
        }
        try unzipArchive(archive, to: staging)

        let manifestURL = staging.appendingPathComponent("manifest.json")
        // BKP-5 (2026-08-02 audit): size guard BEFORE Data(contentsOf:) —
        // a multi-GB manifest.json would OOM the process.
        try guardStoreBlobSize(url: manifestURL, name: "manifest.json", source: .manifest, maxBytes: maxManifestBytes)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            // M-7: distinguish "manifest file missing" from later corruption.
            throw BackupPackageError.corruptedData("manifest.json missing or unreadable", .manifest)
        }
        guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData) else {
            throw BackupPackageError.corruptedData("manifest.json decode failed", .manifest)
        }
        // BKP-4 (2026-07-24 review): lower bound too — only `<= current` was
        // checked before, so formatVersion 0 / negative slid through as
        // "supported" even though no such format exists.
        guard manifest.formatVersion >= 1, manifest.formatVersion <= currentFormatVersion else {
            throw BackupPackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        // BKP-4 (2026-07-24 review): base64-decodable is not enough — a salt
        // shorter than 16 bytes weakens the passphrase KDF input.
        guard let salt = Data(base64Encoded: manifest.keySalt), salt.count >= 16 else {
            throw BackupPackageError.invalidPackage
        }
        let keyEncURL = staging.appendingPathComponent("key.enc")
        // BKP-5 (2026-08-02 audit): same size guard as manifest.json —
        // key.enc is exactly 60 bytes; a hostile oversized file would
        // OOM the process via Data(contentsOf:).
        try guardStoreBlobSize(url: keyEncURL, name: "key.enc", source: .manifest, maxBytes: maxManifestBytes)
        guard let sealedKeyData = try? Data(contentsOf: keyEncURL) else {
            // M-7: same pattern — surface which file is the offender.
            throw BackupPackageError.corruptedData("key.enc missing or unreadable", .manifest)
        }

        // Passphrase check: GCM open fails on wrong passphrase.
        let derivedKey = try deriveKey(passphrase: passphrase, salt: salt, version: manifest.keyDerivationVersion)
        // ID-BACKUP-0004 (2026-07-31 audit): a structurally broken key.enc
        // (truncated / bit-rot changing the length) must surface as package
        // corruption, not `wrongPassword` — otherwise users retry the correct
        // passphrase forever and troubleshooting goes the wrong way. GCM
        // combined = nonce(12) + key(32) + tag(16) = 60 bytes. Note: a
        // bit-flip INSIDE a well-formed 60-byte blob still fails the GCM tag
        // check and remains cryptographically indistinguishable from a wrong
        // passphrase — only structural breakage is reclassified here.
        guard sealedKeyData.count == 12 + 32 + 16 else {
            throw BackupPackageError.corruptedData(
                "key.enc has unexpected length \(sealedKeyData.count) (expected 60); package file is likely corrupted", .manifest)
        }
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: sealedKeyData)
        } catch {
            throw BackupPackageError.corruptedData(
                "key.enc is not a valid AES-GCM sealed box; package file is likely corrupted", .manifest)
        }
        var packageKeyData: Data
        do {
            packageKeyData = try AES.GCM.open(sealedBox, using: derivedKey)
        } catch {
            throw BackupPackageError.wrongPassword
        }
        let packageCrypto = CryptoService(customKeyData: packageKeyData)
        // ID-CRYPTO-0004 (2026-07-31 audit): wipe the transient raw
        // package-key copy now that the bytes live inside `packageCrypto`'s
        // SymmetricKey — same shared helper as the root-key paths in
        // CryptoService, so zeroing behavior is consistent everywhere.
        CryptoService.wipeKeyMaterial(&packageKeyData)

        var result = BackupImportResult()

        // Items + trash: decode before any store mutation so a corrupt/tampered
        // manifest can be rejected without leaving a half-merged state.
        let packageItems = try decodeItems(from: staging, name: "items.json", source: .items)
        let packageTrash = try decodeItems(from: staging, name: "trash.json", source: .trash)
        let packageTags = try decodeTags(from: staging, name: "tags.json", source: .tags)

        // M-9 (2026-07-25 audit): validate manifest counts BEFORE merging data
        // into the store or importing images. Previously the validation ran
        // after the merge, so a manifest/item-count mismatch left the local
        // store partially modified with no rollback path.
        // ID-BACKUP-0001 (2026-07-31): itemCount is items.json ONLY (that is
        // what the exporter writes); trash.json is validated separately
        // against the optional trashCount field.
        try validateManifestCounts(
            manifest: manifest,
            staging: staging,
            decodedItems: packageItems.count,
            decodedTrash: packageTrash.count,
            decodedTags: packageTags.count
        )

        // BUG-024 (2026-07-22): single-entry GCM auth failures stay per-entry,
        // surfaced via `itemsSkippedCorrupt` so the UI shows "corrupt N" rather
        // than silently dropping them.
        let (reencryptedItems, itemCorruptCount) = reencryptItemsWithCorruptCount(
            packageItems, from: packageCrypto, to: localCrypto
        )
        let (reencryptedTrash, trashCorruptCount) = reencryptItemsWithCorruptCount(
            packageTrash, from: packageCrypto, to: localCrypto
        )
        result.itemsSkippedCorrupt = itemCorruptCount + trashCorruptCount
        // Store mutations (@Published) must run on main (M2 fix).
        // C2 fix (2026-07-29): `onMain` is now `@MainActor`-isolated by
        // signature, so the inner `MainActor.assumeIsolated` is redundant.
        // Callers MUST be on main — `MainActor.assumeIsolated` traps otherwise.
        let merge = onMain { store.importBackupItems(reencryptedItems, trashedItems: reencryptedTrash) }
        result.itemsImported = merge.imported
        result.itemsSkipped = merge.skipped

        // Tags: names are encrypted at the persistence boundary ("v2:" prefix
        // + ciphertext under the SOURCE machine's key) — decrypt them with the
        // package key so the local store holds plaintext (re-encrypted with
        // the local key on the next saveTags).
        let localizedTags = packageTags.map { reencryptTagName($0, from: packageCrypto) }
        // F-1 phase 3 (2026-07-28) + C2 fix (2026-07-29): importBackupTags
        // is @MainActor (inherited from class-level @MainActor on
        // ClipboardStore); `onMain` is now `@MainActor`-isolated by
        // signature, so no inner `MainActor.assumeIsolated` bridge needed.
        result.tagsImported = onMain { store.importBackupTags(localizedTags) }

        // Images: decrypt with package key, re-encrypt with local key.
        // Best-effort — image import failure does not roll back merged items/tags.
        do {
            result.imagesImported = try importImages(
                staging: staging,
                imagesDirectory: imagesDirectory,
                packageCrypto: packageCrypto,
                localCrypto: localCrypto
            )
        } catch {
            logger.error("Image import failed (items/tags already merged): \(error.localizedDescription)")
        }

        logger.info("Imported backup: \(result.itemsImported) items, \(result.tagsImported) tags")
        return result
    }

    /// BKP-4 (2026-07-24 review): manifest declared counts must match what
    /// the package payload actually contains.
    /// ID-BACKUP-0001 (2026-07-31): itemCount covers items.json only;
    /// trash.json is checked against the optional trashCount field
    /// (absent in legacy packages → check skipped).
    private static func validateManifestCounts(
        manifest: BackupManifest,
        staging: URL,
        decodedItems: Int,
        decodedTrash: Int,
        decodedTags: Int
    ) throws {
        guard decodedItems == manifest.itemCount else {
            logger.error("Manifest itemCount \(manifest.itemCount) != items.json entries \(decodedItems)")
            throw BackupPackageError.corruptedData(
                "manifest itemCount \(manifest.itemCount) != items.json entries \(decodedItems)", .manifest
            )
        }
        if let declaredTrash = manifest.trashCount, decodedTrash != declaredTrash {
            logger.error("Manifest trashCount \(declaredTrash) != trash.json entries \(decodedTrash)")
            throw BackupPackageError.corruptedData(
                "manifest trashCount \(declaredTrash) != trash.json entries \(decodedTrash)", .manifest
            )
        }
        guard decodedTags == manifest.tagCount else {
            logger.error("Manifest tagCount \(manifest.tagCount) != tags.json entries \(decodedTags)")
            throw BackupPackageError.corruptedData(
                "manifest tagCount \(manifest.tagCount) != tags.json entries \(decodedTags)", .manifest
            )
        }
        let packageImages = staging.appendingPathComponent("Images", isDirectory: true)
        let pngCount = ((try? FileManager.default.contentsOfDirectory(atPath: packageImages.path)) ?? [])
            .filter { $0.hasSuffix(".png") }.count
        guard pngCount == manifest.imageCount else {
            logger.error("Manifest imageCount \(manifest.imageCount) != packaged .png files \(pngCount)")
            throw BackupPackageError.corruptedData(
                "manifest imageCount \(manifest.imageCount) != packaged .png files \(pngCount)", .manifest
            )
        }
    }

    // MARK: - Private helpers

    /// Decrypt each PNG in `staging/Images` with the package key and re-encrypt with
    /// the local key. Skips files already present locally. Throws
    /// `BackupPackageError.corruptedData(_, .image)` on file-read, decrypt-auth,
    /// or write failure — see spec risk §1 for why this does not roll back items
    /// already merged into the store before this image pass. Returns count imported.
    private static func importImages(
        staging: URL,
        imagesDirectory: URL,
        packageCrypto: CryptoServiceProtocol,
        localCrypto: CryptoServiceProtocol
    ) throws -> Int {
        let packageImages = staging.appendingPathComponent("Images", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageImages.path) else { return 0 }
        var count = 0
        let files = (try? FileManager.default.contentsOfDirectory(atPath: packageImages.path)) ?? []
        // M-2 (2026-07-21 audit): import path lacked a size guard while
        // saveImage caps at 50 MB. A malicious or corrupted 500 MB entry
        // would crash us with OOM during Data(contentsOf:). Cap matches
        // ImageStorage.saveImage so import never exceeds what save would have
        // produced.
        // L-1 (2026-07-27): share the cap with ImageStorage instead of
        // repeating the literal. The two were independent constants before
        // and could drift if one was bumped without the other.
        let maxImageBytes = ImageStorage.maxImageSize
        for file in files where file.hasSuffix(".png") {
            // ID-SECURITY-0006 (2026-08-01 audit): whitelist the packaged
            // image name (UUID + .png, shared with ImageStorage) before any
            // write — a hostile member name must never be used to build the
            // target path inside the local images directory.
            guard ImageStorage.isValidFilename(file) else {
                logger.warning("Skipping image with invalid filename in backup: \(file)")
                continue
            }
            let target = imagesDirectory.appendingPathComponent(file)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            let fileURL = packageImages.appendingPathComponent(file)
            // C-4 (2026-07-24 audit): the prior `if let attrs = try?` chain
            // silently bypassed the size cap whenever `attributesOfItem`
            // failed (permissions, broken symlink, network FS error) — a
            // hostile or corrupted package could then `Data(contentsOf:)`
            // a 500 MB entry and crash the app with OOM. Fail closed: skip
            // the file rather than risk unbounded memory.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int else {
                logger.warning("Cannot determine size of image in backup (skipping): \(file)")
                continue
            }
            guard size <= maxImageBytes else {
                logger.warning("Skipping oversized image in backup: \(file) (\(size) bytes > \(maxImageBytes))")
                continue
            }
            let encrypted: Data
            do {
                encrypted = try Data(contentsOf: fileURL)
            } catch {
                logger.error("Failed to read image \(file): \(error.localizedDescription)")
                throw BackupPackageError.corruptedData(
                    "\(file): \(error.localizedDescription)",
                    .image
                )
            }
            guard let plain = packageCrypto.decryptData(encrypted),
                  let reencrypted = localCrypto.encryptData(plain) else {
                logger.error("Failed to decrypt image \(file)")
                throw BackupPackageError.corruptedData(
                    "\(file): decrypt/auth failed",
                    .image
                )
            }
            do {
                try reencrypted.write(to: target, options: .atomic)
            } catch {
                logger.error("Failed to write image \(file): \(error.localizedDescription)")
                throw BackupPackageError.corruptedData(
                    "\(file): \(error.localizedDescription)",
                    .image
                )
            }
            // ID-SECURITY-0007 (2026-08-01 audit): tighten the imported image
            // to 0o600, matching ImageStorage.saveImage. `.atomic` renames a
            // temp file, so the permission is set on the FINAL path AFTER the
            // write. Log-only on failure (the directory is already 0o700 and
            // the content is encrypted — defense in depth, not a hard gate).
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                logger.warning("Failed to set 0o600 on imported image \(file): \(error.localizedDescription)")
            }
            count += 1
        }
        return count
    }

    /// BKP-3 (2026-07-24 audit): reject a store blob larger than
    /// `maxStoreBlobBytes` BEFORE `Data(contentsOf:)` pulls it into memory —
    /// a hostile package could otherwise ship a multi-GB items.json and OOM
    /// the process. Only enforced when the size is determinable: a missing
    /// file (legal empty state, spec risk §3) has no attributes and falls
    /// through to the existing no-such-file → `[]` path in the caller.
    /// BKP-5 (2026-08-02 audit): `maxBytes` parameter added so the small
    /// header files (manifest.json / key.enc) can share the same guard
    /// with their own 1 MB cap.
    private static func guardStoreBlobSize(url: URL, name: String, source: BackupFileSource, maxBytes: Int = maxStoreBlobBytes) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > maxBytes else { return }
        logger.error("\(name) is \(size) bytes, exceeds \(maxBytes) cap — treating package as corrupt")
        throw BackupPackageError.corruptedData(
            "\(name) exceeds \(maxBytes) byte size cap", source
        )
    }

    /// Re-encrypts each item with the local key, dropping entries whose
    /// ciphertext fails GCM auth (BUG-024 per-entry corruption). Returns
    /// the successfully re-encrypted items and a count of dropped entries.
    private static func reencryptItemsWithCorruptCount(
        _ items: [ClipboardItem],
        from packageCrypto: CryptoServiceProtocol,
        to localCrypto: CryptoServiceProtocol
    ) -> (reencrypted: [ClipboardItem], corruptCount: Int) {
        var reencrypted: [ClipboardItem] = []
        reencrypted.reserveCapacity(items.count)
        var corruptCount = 0
        for item in items {
            if let ok = reencrypt(item: item, from: packageCrypto, to: localCrypto) {
                reencrypted.append(ok)
            } else {
                corruptCount += 1
            }
        }
        return (reencrypted, corruptCount)
    }

    private static func decodeItems(
        from directory: URL,
        name: String,
        source: BackupFileSource
    ) throws -> [ClipboardItem] {
        let url = directory.appendingPathComponent(name)
        try guardStoreBlobSize(url: url, name: name, source: source)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Spec risk §3 (P1 fix 2026-07-22): file missing is a legal empty
            // state (exportPackage skips writing JSON files that would be empty),
            // not package-level corruption. Treat it as an empty array.
            return []
        } catch {
            logger.error("Failed to read \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
        do {
            return try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            logger.error("Failed to decode \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
    }

    private static func decodeTags(
        from directory: URL,
        name: String,
        source: BackupFileSource
    ) throws -> [Tag] {
        let url = directory.appendingPathComponent(name)
        try guardStoreBlobSize(url: url, name: name, source: source)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Spec risk §3 (P1 fix 2026-07-22): file missing is a legal empty
            // state (exportPackage skips writing JSON files that would be empty),
            // not package-level corruption. Treat it as an empty array.
            return []
        } catch {
            logger.error("Failed to read \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
        do {
            return try JSONDecoder().decode([Tag].self, from: data)
        } catch {
            logger.error("Failed to decode \(name): \(error.localizedDescription)")
            throw BackupPackageError.corruptedData(error.localizedDescription, source)
        }
    }

    /// Decrypts item content with the package key and re-encrypts with the
    /// local key. Image items reference filenames (unencrypted) and are
    /// re-keyed at the file level instead. Returns nil when content can't be
    /// decrypted (corrupt entry) or the item is already expired.
    private static func reencrypt(
        item: ClipboardItem,
        from packageCrypto: CryptoServiceProtocol,
        to localCrypto: CryptoServiceProtocol
    ) -> ClipboardItem? {
        if item.isExpired { return nil }
        guard item.type != .image else { return item }

        var newContent = item.content
        var newHash = item.contentHash
        if item.isEncrypted {
            // An encrypted entry that won't decrypt under the package key is
            // corrupt — skip it instead of importing ciphertext the local
            // machine can never read (M1 review finding).
            guard let plaintext = packageCrypto.decrypt(item.content) else { return nil }
            guard let encrypted = localCrypto.encrypt(plaintext) else { return nil }
            newContent = encrypted
            newHash = localCrypto.hmacHex(for: plaintext)
        }
        return item.with(content: newContent, contentHash: newHash)
    }

    /// Tag names persist as "v2:<ciphertext>" under the source machine's key.
    /// Decrypt with the package key so the in-memory store holds plaintext;
    /// names that are already plaintext (legacy packages) pass through.
    private static func reencryptTagName(_ tag: Tag, from packageCrypto: CryptoServiceProtocol) -> Tag {
        let prefix = "v2:"
        guard tag.name.hasPrefix(prefix) else { return tag }
        let ciphertext = String(tag.name.dropFirst(prefix.count))
        guard let plaintext = packageCrypto.decrypt(ciphertext) else { return tag }
        return Tag(
            id: tag.id,
            name: plaintext,
            colorHex: tag.colorHex,
            isAutoSuggested: tag.isAutoSuggested,
            createdAt: tag.createdAt
        )
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        // M-10 fix (2026-07-20 audit): the previous `SecRandomCopyBytes`
        // call discarded its `OSStatus` return. On failure the buffer
        // stays zero-filled, and since this salt feeds HKDF the result
        // is a predictable, attacker-friendly wrapper around a still-secret
        // user passphrase. We also `throw` the new `secureRandomUnavailable`
        // case already declared in `BackupPackageError` (the C1 Keychain
        // path already raises that on the same condition).
        // BUG-025 (2026-07-21): `$0.baseAddress!` would trap if the caller
        // passes `count == 0` (Data(capacity: 0) reports baseAddress == nil).
        // All current call sites pass 16 or 32, but the public-ish signature
        // doesn't enforce that. Guard the unwrap and throw the same
        // secureRandomUnavailable error rather than crashing.
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw BackupPackageError.secureRandomUnavailable
        }
        return data
    }
}
