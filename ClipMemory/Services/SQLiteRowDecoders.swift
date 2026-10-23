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

    /// Decode a `trash_items` row (schema v2).
    ///
    /// Column order comes from the SELECTs in
    /// `SQLiteStorageBackend.loadTrashAll` and `loadTrashItem`:
    ///   0 item_id | 1 type | 2 is_pinned | 3 is_encrypted |
    ///   4 is_sensitive | 5 decryption_failed | 6 expires_at |
    ///   7 created_at | 8 deleted_at | 9 content_hash |
    ///  10 content_blob | 11 tag_ids | 12 ocr_text | 13 ocr_attempted
    ///
    /// ID-CRASH-0022 (2026-10-20): columns 5 and 6 used to be swapped
    /// — content was read from the content_hash column and contentHash
    /// from content_blob, so every restored item came back with an
    /// empty content string (and the ciphertext in the hash slot).
    ///
    /// ID-REVIEW-1024 (PR-C, 2026-10-23): the v1 decoder read eight
    /// columns and dropped the rest, so a restored item came back
    /// stripped of its `deletedAt`, `tagIds`, `ocrText` /
    /// `ocrAttempted`, `decryptionFailed` and `expiresAt` — the
    /// fields docs §11 open question 5 lists. The decoder now carries
    /// the whole model, and the trash round trip is faithful.
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
        let content = text(10) ?? ""
        let contentHash = text(9)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(int(7)))
        let isPinned = int(2) != 0
        let isEncrypted = int(3) != 0
        let isSensitive = int(4) != 0
        let decryptionFailed = int(5) != 0
        let ocrAttempted = int(13) != 0
        let ocrText = text(12)
        let expiresAt: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(int(6)))
        let deletedAt: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(int(8)))
        let tagIds = SQLiteTrashTagIDs.decode(text(11))
        return ClipboardItem(
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
            tagIds: tagIds,
            deletedAt: deletedAt,
            ocrText: ocrText,
            ocrAttempted: ocrAttempted
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

/// The `trash_items.tag_ids` JSON format.
///
/// ID-REVIEW-1024 (PR-C, 2026-10-23): the trash table carries the tag
/// set as a JSON array of tag UUID strings (`"[]"` when the item has
/// no tags) instead of joining the `item_tags` junction table — a
/// trashed item has no row in `items` any more, and `item_tags`
/// carries a foreign key on `items(id)`, so the junction cannot hold
/// a trashed item's membership.
///
/// The encoder and the decoder live together so the two halves of the
/// format cannot drift apart.
enum SQLiteTrashTagIDs {
    /// Keeps the log queries working across the split — same
    /// subsystem/category as the rest of the SQLite layer.
    private static let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "SQLiteStorageBackend"
    )

    /// Encodes a tag set as a JSON array of UUID strings.
    ///
    /// The ids are SORTED so the same tag set always produces the same
    /// bytes — `Set` iteration order is not stable, and a row that
    /// rewrites itself differently on every save is a row nobody can
    /// diff.
    static func encode(_ tagIds: Set<UUID>) -> String {
        let strings = tagIds.map(\.uuidString).sorted()
        guard let data = try? JSONEncoder().encode(strings),
              let json = String(data: data, encoding: .utf8) else {
            // A `[String]` cannot fail to encode; if it somehow did,
            // "[]" is the safe answer (no tags) and is still valid
            // JSON, so the row stays readable.
            logger.error("could not encode a trash row's tag ids — storing an empty tag list")
            return "[]"
        }
        return json
    }

    /// Decodes the JSON array of UUID strings.
    ///
    /// A missing blob means "no tags" and is not an error. A blob that
    /// is present but unreadable yields an empty set: the item itself
    /// is still worth keeping (it holds the user's content), so the
    /// row is NOT skipped — the loss of the tag associations is logged
    /// instead.
    static func decode(_ raw: String?) -> Set<UUID> {
        guard let raw else { return [] }
        guard let data = raw.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            logger.error("a trash row carries an unreadable tag_ids blob — the item keeps its content but loses its tag associations")
            return []
        }
        let ids = strings.compactMap { UUID(uuidString: $0) }
        if ids.count != strings.count {
            logger.error("a trash row's tag_ids blob holds \(strings.count - ids.count) malformed UUID(s) — those tags are lost")
        }
        return Set(ids)
    }
}
