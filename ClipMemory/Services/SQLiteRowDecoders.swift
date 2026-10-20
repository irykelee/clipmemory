//
//  SQLiteRowDecoders.swift
//  ClipMemory
//
//  ID-CRASH-0022 (2026-10-20): the row → model mapping layer of
//  `SQLiteStorageBackend`, split out of that file.
//
//  Why: `SQLiteStorageBackend.swift` crossed the SwiftLint
//  `file_length` error ceiling (1250 lines, see .swiftlint.yml) while
//  the auto-review fixes landed. The repo's intent is to SPLIT these
//  files, not to waive the limit (the waiver is reserved for
//  CryptoService.swift / BackupPackage.swift, whose split is tracked
//  as its own work — see AGENTS.md's audit table). The DDL already
//  moved to `SQLiteSchema.swift`; this is the second, matching cut:
//  the decoders are pure functions of a `sqlite3_stmt` with no
//  instance state, so they are a self-contained unit.
//
//  They stay pure on purpose — a decoder that touched the connection
//  would drag the lock discipline into the mapping layer.
//
//  Contract: docs/design/storage-migration.md §2 (column order).
//

import Foundation
import os.log
import SQLite3

/// Maps `sqlite3_stmt` rows onto the model types.
///
/// Every decoder returns `nil` for a row it cannot decode, and logs
/// the reason — a row that cannot be read is skipped, but it must not
/// vanish silently (the same rule the rest of the backend follows).
enum SQLiteRowDecoder {
    /// The logger keeps the `SQLiteStorageBackend` category on purpose:
    /// existing log queries (`log show --predicate 'category ==
    /// "SQLiteStorageBackend"'`) keep working across the split.
    private static let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "SQLiteStorageBackend"
    )

    /// Decode a `trash_items` row.
    ///
    /// Column order comes from the SELECT in
    /// `SQLiteStorageBackend.loadTrashItem`:
    ///   0 item_id | 1 type | 2 is_pinned | 3 is_encrypted |
    ///   4 is_sensitive | 5 content_hash | 6 content_blob | 7 created_at
    ///
    /// ID-CRASH-0022 (2026-10-20): columns 5 and 6 used to be swapped
    /// — content was read from the content_hash column and contentHash
    /// from content_blob, so every restored item came back with an
    /// empty content string (and the ciphertext in the hash slot).
    static func trashItem(stmt: OpaquePointer) -> ClipboardItem? {
        func text(_ index: Int32) -> String? {
            guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cstr)
        }
        func int(_ index: Int32) -> Int {
            return Int(sqlite3_column_int64(stmt, index))
        }
        guard let idStr = text(0), let id = UUID(uuidString: idStr),
              let typeStr = text(1), let type = ClipboardItemType(rawValue: typeStr) else {
            // ID-CRASH-0022 (2026-10-20): a row we cannot decode is
            // skipped, but it must not vanish silently — log it, so a
            // growing pile of unreadable rows is at least visible.
            logger.error(
                "skipping undecodable trash row (id=\(text(0) ?? "<null>"), type=\(text(1) ?? "<null>"))"
            )
            return nil
        }
        let content = text(6) ?? ""
        let contentHash = text(5)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(int(7)))
        let isPinned = int(2) != 0
        let isEncrypted = int(3) != 0
        let isSensitive = int(4) != 0
        return ClipboardItem(
            id: id,
            content: content,
            type: type,
            createdAt: createdAt,
            isPinned: isPinned,
            isSensitive: isSensitive,
            isEncrypted: isEncrypted,
            contentHash: contentHash
        )
    }

    /// Decode an `items` row.
    ///
    /// Column order comes from the SELECT in
    /// `SQLiteStorageBackend.loadItemsFromDB`:
    ///   0 id | 1 type | 2 is_pinned | 3 is_encrypted | 4 is_sensitive |
    ///   5 decryption_failed | 6 expires_at | 7 created_at | 8 updated_at |
    ///   9 content_hash | 10 content_blob | 11 ocr_text | 12 ocr_attempted
    static func item(stmt: OpaquePointer) -> ClipboardItem? {
        func text(_ index: Int32) -> String? {
            guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cstr)
        }
        guard let idStr = text(0), let id = UUID(uuidString: idStr),
              let typeStr = text(1), let type = ClipboardItemType(rawValue: typeStr) else {
            // ID-CRASH-0022 (2026-10-20): same as trashItem — a row we
            // cannot decode is skipped, but not silently.
            logger.error(
                "skipping undecodable items row (id=\(text(0) ?? "<null>"), type=\(text(1) ?? "<null>"))"
            )
            return nil
        }
        let content = text(10) ?? ""
        let contentHash = text(9)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
        let expiresAt: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
        let isPinned = sqlite3_column_int(stmt, 2) != 0
        let isEncrypted = sqlite3_column_int(stmt, 3) != 0
        let isSensitive = sqlite3_column_int(stmt, 4) != 0
        let decryptionFailed = sqlite3_column_int(stmt, 5) != 0
        let ocrText = text(11)
        let ocrAttempted = sqlite3_column_int(stmt, 12) != 0
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 8)))
        let item = ClipboardItem(
            id: id,
            content: content,
            type: type,
            createdAt: createdAt,
            isPinned: isPinned,
            isSensitive: isSensitive,
            expiresAt: expiresAt,
            isEncrypted: isEncrypted,
            contentHash: contentHash,
            decryptionFailed: decryptionFailed,
            ocrText: ocrText,
            ocrAttempted: ocrAttempted
        )
        // updatedAt is not a public field on ClipboardItem, but we
        // record the value in case future audit fields need it.
        _ = updatedAt
        return item
    }

    /// Decode a `tags` row.
    ///
    /// Column order comes from the SELECT in
    /// `SQLiteStorageBackend.loadTagsFromDB`:
    ///   0 id | 1 name | 2 color_hex | 3 is_auto | 4 created_at
    static func tag(stmt: OpaquePointer) -> Tag? {
        // ID-CRASH-0022 (2026-10-20): same as item / trashItem — a row
        // we cannot decode is skipped, but not silently.
        guard let idC = sqlite3_column_text(stmt, 0),
              let nameC = sqlite3_column_text(stmt, 1) else {
            logger.error("skipping undecodable tags row")
            return nil
        }
        guard let id = UUID(uuidString: String(cString: idC)) else {
            logger.error("skipping tags row with a non-UUID id")
            return nil
        }
        let name = String(cString: nameC)
        let colorHex = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let isAuto = sqlite3_column_int(stmt, 3) != 0
        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
        return Tag(
            id: id,
            name: name,
            colorHex: colorHex,
            isAutoSuggested: isAuto,
            createdAt: createdAt
        )
    }
}
