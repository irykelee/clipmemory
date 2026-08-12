//
//  ClipboardStore+Encryption.swift
//  ClipMemory
//
//  ARCH-0002 PR #3 — Encryption split: extract encrypt/decrypt/cache surface
//  to its own file. Pure extension move (no logic changes). The 7 visibility
//  loosenings required for cross-file access (private → internal) are tracked
//  in the PR #60 ship record.
//
//  Methods moved verbatim:
//   - handleCryptoKeyPrepared(_:)
//   - encryptTagNames(_:)
//   - decryptTagNames(_:)
//   - getDecryptedContent(_:)
//   - isDecryptionPendingFailed(_:)
//   - recordPendingDiagnostic(_:)
//   - mergePendingDiagnostics()
//   - scheduleDecryptionFailedMark(_:)
//   - mergePendingDecryptionFailures()
//
//  State stays in the main class body (Swift extension cannot declare stored
//  properties) and has been loosened from `private` to internal where the
//  moved methods touch it from this file.
//

import Foundation

extension ClipboardStore {

    /// H-2 (2026-07-25 audit): retry captures that were deferred while the
    /// encryption key was still being prepared. On success, re-feed every
    /// pending item through `addItem(_:)` (dedup and ordering are preserved).
    /// On failure, drop them with the same encryption-failed notification that
    /// an immediate failure would have posted.
    func handleCryptoKeyPrepared(_ notification: Notification) {
        let success = notification.userInfo?["success"] as? Bool ?? false
        pendingKeyItemsLock.lock()
        let pending = pendingKeyItems
        pendingKeyItems.removeAll()
        pendingKeyItemsLock.unlock()

        // CRIT-1 (2026-07-26 review): handler now runs on main thread by
        // type-system guarantee (F-3 queue: .main observer), not by defensive
        // DispatchQueue.main.async wrap. addItem(_:) directly callable.
        if success {
            // P0-2 N4: 复位 dismiss（H-2 重放前）
            resetDiagnosticsDismissed()
            // ID-STORE-NEG-CACHE-SYNC (2026-08-07): mirror CryptoService's
            // negativeCache.removeAll() on key re-ready. Without this, an
            // item that hit .dataCorrupted/.internalError right before the
            // .cryptoKeyPrepared(success) event sits in pendingFailedIDs
            // and gets merged into items[].decryptionFailed = true on the
            // next main-loop tick, permanently skipping the item for the
            // rest of the session (prewarm:1651 short-circuits on the
            // flag). Clearing the buffer here lets the merge snapshot an
            // empty set and keeps the in-session state aligned with
            // CryptoService's "retry transient failures on key ready"
            // contract.
            pendingFailedIDsLock.lock()
            pendingFailedIDs.removeAll()
            pendingFailedIDsLock.unlock()
            // ID-SILENT-0019 (2026-08-08 audit): paired with the
            // `pendingFailedIDs.removeAll()` above (ID-STORE-NEG-CACHE-SYNC,
            // `aeedf6e`). The buffer clear alone is necessary but not
            // sufficient — `mergePendingDecryptionFailures` runs on the
            // main loop tick after each `scheduleDecryptionFailedMark` and
            // sets `items[].decryptionFailed = true`, which then
            // short-circuits `getDecryptedContent` (`:1471`) and `prewarm`
            // (`:1651`) for the rest of the session. Without this reset,
            // items that failed to decrypt during the cold-start key-not-
            // ready window stay blank until next app launch (which
            // triggers `loadItems` to re-mark them based on actual
            // ciphertext integrity).
            //
            // On key re-ready, transient failures (key-unavailable → data
            // genuinely fine) heal in-session. Permanent failures
            // (genuine dataCorrupted) will re-fail on next getDecrypted
            // and re-trip the flag — same observable behavior as pre-fix
            // for those items, with one wasted retry per key-ready event.
            rebuildItemIndexIfStale()
            var flagResetChanged = false
            for index in items.indices where items[index].decryptionFailed {
                items[index].decryptionFailed = false
                flagResetChanged = true
            }
            if flagResetChanged { objectWillChange.send() }
            for item in pending { self.addItem(item) }
            // M2 (2026-08-01 roadmap): heal items stored with contentHash = nil
            // while the key was unavailable — backfill their hashes and merge
            // the duplicates that piled up in the key-not-ready window.
            backfillHashesAndMergeDuplicatesAfterKeyReady()
        } else {
            guard !pending.isEmpty else { return }
            self.logger.error("Encryption key preparation failed; dropping \(pending.count) deferred clipboard capture(s)")
            NotificationCenter.default.post(
                name: .encryptionFailed,
                object: nil,
                userInfo: [
                    "source": "addItem",
                    "itemType": "deferred"
                ]
            )
        }
    }

    /// Encrypt tag names for disk storage. Names are plaintext in memory
    /// (decrypted by `loadTags`); the only encrypted names on disk are the
    /// locked placeholders, whose original ciphertext is restored from the
    /// backup map. A name that happens to start with the marker prefix (e.g.
    /// a user-created tag literally named "v2:work") is encrypted like any
    /// other plaintext — the old decrypt probe was unnecessary because
    /// `loadTags` already separates real ciphertext from accidental prefixes.
    /// L-2 (2026-07-25 audit): removed the per-tag AES-GCM decrypt on save.
    func encryptTagNames(_ tags: [Tag]) -> [Tag] {
        tags.map { tag in
            // Restore original ciphertext for tags whose names failed to decrypt.
            if tag.name == Self.lockedPlaceholder,
               let backup = encryptedTagNamesBackup[tag.id] {
                return Tag(
                    id: tag.id,
                    name: backup,
                    colorHex: tag.colorHex,
                    isAutoSuggested: tag.isAutoSuggested,
                    createdAt: tag.createdAt
                )
            }
            guard let encryptedName = ServiceContainer.crypto.encrypt(tag.name) else {
                // I-3 fix (2026-07-20 audit): tag encryption failure must NOT
                // persist the plaintext tag name — that's the equivalent of a
                // missed encrypt on items but the tag pipeline silently swallowed
                // it. Match the decryptTagNames path: surface a placeholder,
                // keep the original ciphertext in the backup map so saveTags
                // doesn't overwrite it on subsequent calls, and notify the UI
                // (so the user knows the encryption layer is unhealthy).
                logger.error("Failed to encrypt tag name for \(tag.id); storing as [locked]")
                encryptedTagNamesBackup[tag.id] = tag.name
                NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                return Tag(
                    id: tag.id,
                    name: Self.lockedPlaceholder,
                    colorHex: tag.colorHex,
                    isAutoSuggested: tag.isAutoSuggested,
                    createdAt: tag.createdAt
                )
            }
            return Tag(
                id: tag.id,
                name: Self.encryptedNamePrefix + encryptedName,
                colorHex: tag.colorHex,
                isAutoSuggested: tag.isAutoSuggested,
                createdAt: tag.createdAt
            )
        }
    }

    /// Decrypt tag names loaded from disk. Plaintext names (legacy or tests)
    /// are returned unchanged.
    func decryptTagNames(_ tags: [Tag]) -> [Tag] {
        tags.map { tag in
            guard tag.name.hasPrefix(Self.encryptedNamePrefix) else {
                return tag
            }
            let ciphertext = String(tag.name.dropFirst(Self.encryptedNamePrefix.count))
            guard let decrypted = ServiceContainer.crypto.decrypt(ciphertext) else {
                logger.error("Failed to decrypt tag name for \(tag.id); using placeholder")
                encryptedTagNamesBackup[tag.id] = tag.name
                return Tag(
                    id: tag.id,
                    name: Self.lockedPlaceholder,
                    colorHex: tag.colorHex,
                    isAutoSuggested: tag.isAutoSuggested,
                    createdAt: tag.createdAt
                )
            }
            return Tag(
                id: tag.id,
                name: decrypted,
                colorHex: tag.colorHex,
                isAutoSuggested: tag.isAutoSuggested,
                createdAt: tag.createdAt
            )
        }
    }

    // ID-SYNC-0003 (2026-08-01 audit): nonisolated decrypt kernel. Every
    // state this touches is thread-safe by contract — contentCache (NSCache),
    // isDecryptionPendingFailed / pendingDiagnostics / scheduleDecryptionFailedMark
    // (NSLock-guarded), ServiceContainer.crypto.decryptWithReason (internally
    // NSLock-guarded; ImageStorage already decrypts/encrypts with it off-main).
    // Called from @MainActor read paths AND prewarm's utility-queue workers.
    nonisolated func getDecryptedContent(_ item: ClipboardItem) -> String? {
        // Image items store a filename (UUID.png), not encrypted text. Decrypting
        // a filename always fails and would incorrectly mark the item as
        // decryptionFailed. ImageStorage handles image-file encryption separately.
        guard item.type != .image else { return item.content }

        // Already-known-corrupt items: bail out WITHOUT re-decrypting or
        // re-marking. Rendering an encrypted-but-undecryptable row used to
        // re-mark on EVERY body evaluation, publishing during view update in
        // an endless loop that pinned the main thread at 100% CPU (the
        // "open full window freezes" bug).
        if item.decryptionFailed { return nil }
        // C5: also bail for failures whose write-back is still pending, so the
        // gap between first failure and the async merge doesn't re-run AES.
        if isDecryptionPendingFailed(item.id) { return nil }

        let key = item.id.uuidString as NSString
        if let cached = contentCache.object(forKey: key) {
            return cached as String
        }
        // P0-2 T4: 单 chokepoint 分类解密。把 reason 写入 pendingDiagnostics 缓冲，
        // merge 由 view 层 (filter pass 末尾) 触发。
        let decryptOutcome: DecryptResult
        if item.isEncrypted {
            decryptOutcome = ServiceContainer.crypto.decryptWithReason(item.content, itemID: item.id)
        } else {
            decryptOutcome = .success(item.content)
        }

        switch decryptOutcome {
        case .success(let plaintext):
            // ID-PERF-0017 (2026-07-31 audit): pass the plaintext byte
            // count as cost — totalCostLimit was dead code while every
            // setObject defaulted cost to 0, so the 10MB cap never fired.
            contentCache.setObject(plaintext as NSString, forKey: key, cost: plaintext.utf8.count)
            // N4: 不 append .success。成功 = 无需诊断 = merge 时显式 SET 零态。
            return plaintext
        case .keyUnavailable:
            pendingDiagnosticsLock.lock()
            pendingDiagnostics.append(.keyUnavailable)
            pendingDiagnosticsLock.unlock()
            return nil
        case .dataCorrupted:
            // N5: 只有永久失败才标 decryptionFailed（MF-2 修复点）
            scheduleDecryptionFailedMark(item.id)
            pendingDiagnosticsLock.lock()
            pendingDiagnostics.append(.dataCorrupted)
            pendingDiagnosticsLock.unlock()
            return nil
        case .internalError:
            scheduleDecryptionFailedMark(item.id)
            pendingDiagnosticsLock.lock()
            pendingDiagnostics.append(.internalError)
            pendingDiagnosticsLock.unlock()
            return nil
        }
    }

    /// C5: lock-guarded check so any thread can cheaply bail on pending failures.
    /// ID-SYNC-0003: nonisolated — NSLock contract makes it callable off-main.
    nonisolated func isDecryptionPendingFailed(_ id: UUID) -> Bool {
        pendingFailedIDsLock.lock()
        defer { pendingFailedIDsLock.unlock() }
        return pendingFailedIDs.contains(id)
    }

    /// P0-2 T5: append a diagnostic from any call path (search, OCR, RTF).
    /// Internal so extensions in other files (ClipboardStore+OCR) can reach it
    /// without duplicating the lock/unlock dance.
    /// ID-SYNC-0003: nonisolated — NSLock contract makes it callable off-main.
    nonisolated func recordPendingDiagnostic(_ d: PendingDiagnostic) {
        pendingDiagnosticsLock.lock()
        pendingDiagnostics.append(d)
        pendingDiagnosticsLock.unlock()
    }

    /// P0-2 F4: main.async merge into @Published (must not publish inside view-body).
    /// P3: SET (not +=) per-pass aggregate so counts don't climb across passes.
    /// N4: no early return on empty snapshot — even an empty snapshot explicitly
    ///     SETs zero state, resetting a prior pass's diagnostics.
    func mergePendingDiagnostics() {
        pendingDiagnosticsLock.lock()
        let snapshot = pendingDiagnostics
        pendingDiagnostics.removeAll()
        pendingDiagnosticsLock.unlock()

        // N4: no guard !snapshot.isEmpty early return. An empty snapshot must
        // explicitly SET zero state so the banner hides when all failures clear.
        var passKeyUnavailable = false
        var passDataCount = 0
        var passInternalCount = 0
        for d in snapshot {
            switch d {
            case .keyUnavailable:
                passKeyUnavailable = true
            case .dataCorrupted:
                passDataCount += 1
            case .internalError:
                passInternalCount += 1
            }
        }
        let snapshotForAsync = (passKeyUnavailable, passDataCount, passInternalCount)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // P3: SET (not +=) so banner reflects current pass state only
            let new = DecryptionDiagnostics(
                keyUnavailable: snapshotForAsync.0,
                dataCorruptedCount: snapshotForAsync.1,
                internalErrorCount: snapshotForAsync.2,
                dismissed: diagnostics.dismissed
            )
            if new != diagnostics { diagnostics = new }
        }
    }

    /// C5: buffer a failed id and schedule exactly one async merge per new id.
    /// ID-SYNC-0003: nonisolated — NSLock insert + Task hop to @MainActor,
    /// safe from prewarm's utility-queue workers.
    nonisolated func scheduleDecryptionFailedMark(_ id: UUID) {
        pendingFailedIDsLock.lock()
        let inserted = pendingFailedIDs.insert(id).inserted
        pendingFailedIDsLock.unlock()
        guard inserted else { return }
        Task { @MainActor [weak self] in
            self?.mergePendingDecryptionFailures()
        }
    }

    /// C5: applies buffered failure marks to `items` in one batch. Runs on the
    /// main queue, guaranteed outside any view-body evaluation by the async hop.
    func mergePendingDecryptionFailures() {
        pendingFailedIDsLock.lock()
        let ids = pendingFailedIDs
        // BUG-015 (2026-07-21): without removeAll, pendingFailedIDs grew
        // monotonically — every failed decryption ID accumulated forever.
        // Each subsequent merge re-processed the entire set. Clear inside
        // the same lock window to keep the snapshot/clear atomic.
        pendingFailedIDs.removeAll()
        pendingFailedIDsLock.unlock()
        var changed = false
        // ID-PERF-0014 (2026-07-30 audit): reuse the ID-PERF-0015
        // UUID→index map (amortized O(1) per id) instead of
        // `items.firstIndex(where:)` per id — O(n·k) → O(n+k) for batched
        // failure merges. Property-only mutation below doesn't reorder
        // `items`, so the index stays valid (no invalidateItemIndex).
        //
        // PR54-H (v2.8.4 latent bug batch): route through `resolvedIndex`
        // so the rebuild-stale + bounds-check trio lives in one place — the
        // other 5 sites in `ClipboardStore.swift` and this extension's
        // decryption-merge site share the same stale-defending contract.
        for id in ids {
            if let index = resolvedIndex(for: id),
               !items[index].decryptionFailed {
                items[index].decryptionFailed = true
                changed = true
            }
        }
        if changed { scheduleSave() }
    }
}
